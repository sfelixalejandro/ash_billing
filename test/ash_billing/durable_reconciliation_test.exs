defmodule AshBilling.DurableReconciliationTest do
  @moduledoc """
  Acceptance tests for 0.6.0 durable PostgreSQL reconciliation checkpoints (`last_reconciled_at`).
  """
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias AshBilling.Test.{
    DurablePeerHelper,
    PostgresCustomer,
    PostgresDomain,
    PostgresSubscription,
    Repo
  }

  alias AshBilling.WebhookSync

  @opts [domain: PostgresDomain, authorize?: false]
  @sync_opts @opts ++
               [customer_resource: PostgresCustomer, subscription_resource: PostgresSubscription]

  defmodule CountingProvider do
    @moduledoc false
    def get_subscription(id, opts) do
      if counter = Keyword.get(opts, :counter) do
        Agent.update(counter, &(&1 + 1))
      end

      case Keyword.get(opts, :live_response) do
        %{} = payload -> {:ok, payload}
        {:error, _} = err -> err
        _ -> {:error, {:unexpected_id, id}}
      end
    end
  end

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE billing_test_subscriptions, billing_test_customers"
    )

    customer = Ash.create!(PostgresCustomer, %{stripe_customer_id: "cus_durable"}, @opts)

    t1 =
      DateTime.utc_now()
      |> DateTime.add(-300, :second)
      |> DateTime.truncate(:second)

    sub =
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: customer.id,
          provider_subscription_id: "sub_durable_1",
          status: :active,
          price_id: "price_basic",
          last_event_created_at: t1
        },
        @opts
      )

    %{customer: customer, subscription: sub, t1: t1}
  end

  test "persists last_reconciled_at across full :ash_billing application restart", %{
    subscription: sub,
    t1: t1
  } do
    remote_enterprise = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "active",
      "items" => %{"data" => [%{"price" => %{"id" => "price_enterprise"}}]}
    }

    assert {:ok, reconciled} =
             AshBilling.reconcile_subscription(sub,
               provider: CountingProvider,
               live_response: remote_enterprise,
               domain: PostgresDomain,
               authorize?: false
             )

    assert reconciled.price_id == "price_enterprise"
    assert DateTime.compare(reconciled.last_event_created_at, t1) == :eq
    assert %DateTime{} = reconciled.last_reconciled_at

    # Restart :ash_billing OTP application (wiping all in-memory state)
    assert :ok = Application.stop(:ash_billing)
    {:ok, _} = Application.ensure_all_started(:ash_billing)

    t2_delayed = DateTime.add(t1, 120, :second)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    delayed_webhook = %{
      "id" => "evt_delayed_after_restart",
      "type" => "customer.subscription.updated",
      "created" => DateTime.to_unix(t2_delayed),
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "active",
          "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
        }
      }
    }

    assert {:ok, synced} =
             WebhookSync.sync_event(
               delayed_webhook,
               @sync_opts ++
                 [
                   provider: CountingProvider,
                   counter: counter,
                   live_response: remote_enterprise
                 ]
             )

    assert Agent.get(counter, & &1) == 1
    assert synced.price_id == "price_enterprise"
  end

  test "preserves reconciled state across two real OS-level Erlang VM peer nodes sharing PostgreSQL",
       %{t1: t1} do
    code_paths = Enum.map(:code.get_path(), &List.to_string/1)
    app_env = Application.get_all_env(:ash_billing)

    start_peer = fn ->
      {:ok, pid, _node} = :peer.start_link(%{connection: :standard_io})
      true = :peer.call(pid, :code, :set_path, [:code.get_path()])
      {:ok, os_pid} = :peer.call(pid, DurablePeerHelper, :bootstrap, [app_env])
      {pid, os_pid}
    end

    assert length(code_paths) > 0
    {peer_a, pid_a} = start_peer.()
    {peer_b, pid_b} = start_peer.()

    try do
      assert pid_a != pid_b
      assert pid_a != :os.getpid()

      remote_enterprise = %{
        "id" => "sub_durable_1",
        "customer" => "cus_durable",
        "status" => "active",
        "items" => %{"data" => [%{"price" => %{"id" => "price_enterprise"}}]}
      }

      # Node A reconciles live state from Stripe into shared PostgreSQL
      assert {:ok, reconciled_on_a} =
               :peer.call(peer_a, DurablePeerHelper, :reconcile, [
                 "sub_durable_1",
                 remote_enterprise
               ])

      assert reconciled_on_a.price_id == "price_enterprise"
      assert %DateTime{} = reconciled_on_a.last_reconciled_at

      # Node B (separate OS process & ETS) receives delayed older webhook
      t2_delayed = DateTime.add(t1, 150, :second)

      delayed_webhook = %{
        "id" => "evt_delayed_node_b",
        "type" => "customer.subscription.updated",
        "created" => DateTime.to_unix(t2_delayed),
        "data" => %{
          "object" => %{
            "id" => "sub_durable_1",
            "customer" => "cus_durable",
            "status" => "active",
            "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
          }
        }
      }

      assert {:ok, synced_on_b} =
               :peer.call(peer_b, DurablePeerHelper, :sync_webhook, [
                 delayed_webhook,
                 remote_enterprise
               ])

      assert synced_on_b.price_id == "price_enterprise"

      {:ok, read_from_a} =
        :peer.call(peer_a, DurablePeerHelper, :fetch_subscription, ["sub_durable_1"])

      assert read_from_a.price_id == "price_enterprise"
    after
      try do
        :peer.stop(peer_a)
      catch
        _, _ -> :ok
      end

      try do
        :peer.stop(peer_b)
      catch
        _, _ -> :ok
      end
    end
  end

  test "protects against multi-day (>24h) delayed webhooks and delayed terminal events", %{
    subscription: sub
  } do
    t_72h_ago =
      DateTime.utc_now() |> DateTime.add(-72 * 3600, :second) |> DateTime.truncate(:second)

    t_50h_ago = DateTime.add(t_72h_ago, 22 * 3600, :second)
    t_49h_ago = DateTime.add(t_72h_ago, 23 * 3600, :second)
    t_48h_ago = DateTime.add(t_72h_ago, 24 * 3600, :second)

    # Simulate multi-day elapsed state persisted in PostgreSQL + run Deduplication sweeps
    {:ok, sub_reconciled_long_ago} =
      sub
      |> Ash.Changeset.for_update(
        :revise,
        %{
          status: :canceled,
          price_id: "price_enterprise",
          last_event_created_at: t_72h_ago,
          last_reconciled_at: t_48h_ago
        },
        @opts
      )
      |> Ash.update(@opts)

    dedup_pid = Process.whereis(AshBilling.Deduplication)
    send(dedup_pid, :sweep)
    _ = :sys.get_state(dedup_pid)

    assert sub_reconciled_long_ago.price_id == "price_enterprise"

    remote_canceled_enterprise = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "canceled",
      "items" => %{"data" => [%{"price" => %{"id" => "price_enterprise"}}]}
    }

    # Delayed terminal event from 49h ago carrying stale price_pro must re-verify live state
    # and NOT overwrite reconciled price_enterprise.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    delayed_terminal = %{
      "id" => "evt_delayed_terminal_49h",
      "type" => "customer.subscription.deleted",
      "created" => DateTime.to_unix(t_49h_ago),
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "canceled",
          "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
        }
      }
    }

    assert {:ok, after_terminal} =
             WebhookSync.sync_event(
               delayed_terminal,
               @sync_opts ++
                 [
                   provider: CountingProvider,
                   counter: counter,
                   live_response: remote_canceled_enterprise
                 ]
             )

    assert Agent.get(counter, & &1) == 1
    assert after_terminal.status == :canceled
    assert after_terminal.price_id == "price_enterprise"

    # Also verify non-Stripe custom provider reactivation cannot be falsely re-canceled by delayed deleted webhook
    {:ok, reactivated} =
      after_terminal
      |> Ash.Changeset.for_update(
        :revise,
        %{
          status: :active,
          price_id: "price_enterprise",
          last_event_created_at: t_72h_ago,
          last_reconciled_at: t_48h_ago
        },
        @opts
      )
      |> Ash.update(@opts)

    remote_active_enterprise = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "active",
      "items" => %{"data" => [%{"price" => %{"id" => "price_enterprise"}}]}
    }

    delayed_old_deleted = %{
      "id" => "evt_delayed_old_deleted_custom",
      "type" => "customer.subscription.deleted",
      "created" => DateTime.to_unix(t_50h_ago),
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "canceled",
          "items" => %{"data" => [%{"price" => %{"id" => "price_basic"}}]}
        }
      }
    }

    assert {:ok, preserved_active} =
             WebhookSync.sync_event(
               delayed_old_deleted,
               @sync_opts ++
                 [
                   provider: CountingProvider,
                   live_response: remote_active_enterprise
                 ]
             )

    assert preserved_active.id == reactivated.id
    assert preserved_active.status == :active
    assert preserved_active.price_id == "price_enterprise"
  end

  test "concurrent delayed webhook blocks until reconcile commits both state and last_reconciled_at",
       %{subscription: sub, t1: t1} do
    test_pid = self()

    defmodule CommitRaceProvider do
      def get_subscription(id, opts) do
        pid = Keyword.fetch!(opts, :test_pid)
        send(pid, {:reconcile_paused, self()})

        receive do
          :release -> :ok
        after
          5_000 -> raise "timeout waiting for :release"
        end

        {:ok,
         %{
           "id" => id,
           "customer" => "cus_durable",
           "status" => "active",
           "items" => %{"data" => [%{"price" => %{"id" => "price_enterprise"}}]}
         }}
      end
    end

    task_reconcile =
      Task.async(fn ->
        AshBilling.reconcile_subscription(sub,
          provider: CommitRaceProvider,
          test_pid: test_pid,
          domain: PostgresDomain,
          authorize?: false
        )
      end)

    assert_receive {:reconcile_paused, pause_pid}, 1_000

    t2_delayed = DateTime.add(t1, 100, :second)

    delayed_webhook = %{
      "id" => "evt_concurrent_delayed_race",
      "type" => "customer.subscription.updated",
      "created" => DateTime.to_unix(t2_delayed),
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "active",
          "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
        }
      }
    }

    live_enterprise = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "active",
      "items" => %{"data" => [%{"price" => %{"id" => "price_enterprise"}}]}
    }

    task_webhook =
      Task.async(fn ->
        WebhookSync.sync_event(
          delayed_webhook,
          @sync_opts ++ [provider: CountingProvider, live_response: live_enterprise]
        )
      end)

    # Confirm PostgreSQL row lock contention while reconcile has not yet committed
    assert :ok == wait_for_pg_lock_contention(2_000)

    # Release reconcile -> commits price_enterprise + last_reconciled_at atomically in one UPDATE
    send(pause_pid, :release)

    assert {:ok, reconciled} = Task.await(task_reconcile, 5_000)
    assert reconciled.price_id == "price_enterprise"
    assert %DateTime{} = reconciled.last_reconciled_at

    assert {:ok, after_webhook} = Task.await(task_webhook, 5_000)
    assert after_webhook.price_id == "price_enterprise"
    assert Ash.get!(PostgresSubscription, sub.id, @opts).price_id == "price_enterprise"
  end

  test "handles host clock skew and uncertainty window without silent loss or regressions", %{
    subscription: sub
  } do
    # 1. Host clock lagging 120s behind existing last_event_created_at:
    # reconcile_subscription/2 still updates live state without advancing last_event_created_at
    ahead_ts = DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.truncate(:second)

    {:ok, sub_ahead} =
      sub
      |> Ash.Changeset.for_update(:revise, %{last_event_created_at: ahead_ts}, @opts)
      |> Ash.update(@opts)

    remote_enterprise = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "active",
      "items" => %{"data" => [%{"price" => %{"id" => "price_enterprise"}}]}
    }

    assert {:ok, reconciled} =
             AshBilling.reconcile_subscription(sub_ahead,
               provider: CountingProvider,
               live_response: remote_enterprise,
               domain: PostgresDomain,
               authorize?: false
             )

    assert reconciled.price_id == "price_enterprise"
    assert DateTime.compare(reconciled.last_event_created_at, ahead_ts) == :eq
    assert %DateTime{} = reconciled.last_reconciled_at

    # 2. Event inside uncertainty window [last_reconciled_at, last_reconciled_at + skew_seconds]:
    # A genuine upgrade occurring 5s after reconciliation still re-verifies live state and applies.
    {:ok, sub_recent} =
      reconciled
      |> Ash.Changeset.for_update(
        :revise,
        %{
          last_event_created_at:
            DateTime.add(DateTime.utc_now(), -30, :second) |> DateTime.truncate(:second)
        },
        @opts
      )
      |> Ash.update(@opts)

    live_ultimate = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "active",
      "items" => %{"data" => [%{"price" => %{"id" => "price_ultimate"}}]}
    }

    in_window_ts = DateTime.to_unix(DateTime.add(sub_recent.last_reconciled_at, 5, :second))
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    in_window_upgrade = %{
      "id" => "evt_genuine_in_window_upgrade",
      "type" => "customer.subscription.updated",
      "created" => in_window_ts,
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "active",
          "items" => %{"data" => [%{"price" => %{"id" => "price_ultimate"}}]}
        }
      }
    }

    assert {:ok, upgraded} =
             WebhookSync.sync_event(
               in_window_upgrade,
               @sync_opts ++
                 [
                   provider: CountingProvider,
                   counter: counter,
                   live_response: live_ultimate,
                   reconciliation_skew_seconds: 60
                 ]
             )

    assert Agent.get(counter, & &1) == 1
    assert upgraded.price_id == "price_ultimate"
  end

  test "rolls back cleanly on provider and PostgreSQL errors without advancing last_reconciled_at",
       %{
         subscription: sub,
         t1: t1
       } do
    # 1. Provider 500 during reconcile_subscription/2 leaves DB and last_reconciled_at untouched
    assert {:error, %{status: 500}} =
             AshBilling.reconcile_subscription(sub,
               provider: CountingProvider,
               live_response: {:error, %{status: 500}},
               domain: PostgresDomain,
               authorize?: false
             )

    persisted_after_500 = Ash.get!(PostgresSubscription, sub.id, @opts)
    assert persisted_after_500.price_id == "price_basic"
    assert is_nil(persisted_after_500.last_reconciled_at)

    # 2. Succeed reconciliation to enterprise
    remote_enterprise = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "active",
      "items" => %{"data" => [%{"price" => %{"id" => "price_enterprise"}}]}
    }

    assert {:ok, reconciled} =
             AshBilling.reconcile_subscription(sub,
               provider: CountingProvider,
               live_response: remote_enterprise,
               domain: PostgresDomain,
               authorize?: false
             )

    checkpoint_1 = reconciled.last_reconciled_at
    assert %DateTime{} = checkpoint_1

    # 3. Provider failure during ambiguous delayed-webhook re-verification fails closed and rolls back
    t2_delayed = DateTime.add(t1, 60, :second)

    delayed_webhook = %{
      "id" => "evt_fail_closed_reverify",
      "type" => "customer.subscription.updated",
      "created" => DateTime.to_unix(t2_delayed),
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "active",
          "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
        }
      }
    }

    assert {:error, {:reconciliation_failed, :timeout}} =
             WebhookSync.sync_event(
               delayed_webhook,
               @sync_opts ++ [provider: CountingProvider, live_response: {:error, :timeout}]
             )

    persisted_after_fail = Ash.get!(PostgresSubscription, sub.id, @opts)
    assert persisted_after_fail.price_id == "price_enterprise"
    assert DateTime.compare(persisted_after_fail.last_reconciled_at, checkpoint_1) == :eq
    assert DateTime.compare(persisted_after_fail.last_event_created_at, t1) == :eq

    # 4. PostgreSQL lock failure during delayed-webhook sync also fails closed without modifying state or checkpoint
    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM billing_test_subscriptions WHERE id = $1 FOR UPDATE", [
            Ecto.UUID.dump!(sub.id)
          ])

          send(test_pid, :sub_row_locked)

          receive do
            :release_row -> :ok
          after
            5_000 -> :timeout
          end
        end)
      end)

    assert_receive :sub_row_locked, 1_000

    assert {:error, _lock_err} =
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL lock_timeout = '25ms'")

               case WebhookSync.sync_event(
                      %{
                        "id" => "evt_pg_lock_fail",
                        "type" => "customer.subscription.updated",
                        "created" => DateTime.to_unix(t2_delayed),
                        "data" => %{
                          "object" => %{
                            "id" => "sub_durable_1",
                            "customer" => "cus_durable",
                            "status" => "active",
                            "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
                          }
                        }
                      },
                      @sync_opts ++ [provider: CountingProvider, live_response: remote_enterprise]
                    ) do
                 {:ok, val} -> val
                 {:error, err} -> Repo.rollback(err)
               end
             end)

    send(holder.pid, :release_row)
    Task.await(holder, 5_000)

    persisted_after_pg_fail = Ash.get!(PostgresSubscription, sub.id, @opts)
    assert persisted_after_pg_fail.price_id == "price_enterprise"
    assert DateTime.compare(persisted_after_pg_fail.last_reconciled_at, checkpoint_1) == :eq
  end

  defp wait_for_pg_lock_contention(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_pg_lock_contention(deadline)
  end

  defp do_wait_for_pg_lock_contention(deadline) do
    %{rows: [[blocked_count]]} =
      Repo.query!(
        "SELECT COUNT(*) FROM pg_locks WHERE NOT granted AND locktype IN ('transactionid', 'tuple')"
      )

    if blocked_count > 0 do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :no_pg_lock_contention_observed}
      else
        :erlang.yield()
        do_wait_for_pg_lock_contention(deadline)
      end
    end
  end
end
