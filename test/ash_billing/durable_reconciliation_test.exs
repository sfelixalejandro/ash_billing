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

      if delay_ms = Keyword.get(opts, :delay_ms) do
        receive do
        after
          delay_ms -> :ok
        end
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
    # 1. Host clock lagging 120s behind existing last_event_created_at (or 0.5.x ahead cursor):
    # reconcile_subscription/2 updates live state, sets last_reconciled_at, and clears the
    # ahead last_event_created_at to nil so subsequent real webhooks are not silently dropped.
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
    assert is_nil(reconciled.last_event_created_at)
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
                   live_response: live_ultimate
                 ]
             )

    assert Agent.get(counter, & &1) == 1
    assert upgraded.price_id == "price_ultimate"

    # 3. Old webhook outside 60s window (+120s beyond last_reconciled_at) proposing stale price,
    # stale cancel_at_period_end, and stale period must still re-verify live provider state and NOT overwrite.
    {:ok, stale_outside_counter} = Agent.start_link(fn -> 0 end)
    outside_horizon_ts = DateTime.to_unix(DateTime.add(upgraded.last_reconciled_at, 120, :second))

    stale_outside_webhook = %{
      "id" => "evt_stale_outside_60s_window",
      "type" => "customer.subscription.updated",
      "created" => outside_horizon_ts,
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "active",
          "cancel_at_period_end" => true,
          "current_period_end" =>
            DateTime.to_unix(DateTime.add(DateTime.utc_now(), -86_400, :second)),
          "items" => %{"data" => [%{"price" => %{"id" => "price_basic"}}]}
        }
      }
    }

    assert {:ok, stale_rejected} =
             WebhookSync.sync_event(
               stale_outside_webhook,
               @sync_opts ++
                 [
                   provider: CountingProvider,
                   counter: stale_outside_counter,
                   live_response: live_ultimate
                 ]
             )

    assert Agent.get(stale_outside_counter, & &1) == 1
    assert stale_rejected.price_id == "price_ultimate"
    assert stale_rejected.cancel_at_period_end == false
    assert is_nil(stale_rejected.current_period_end)

    # 4. Non-mutating webhook outside 60s window (identical financial attributes) skips provider GET
    {:ok, noop_counter} = Agent.start_link(fn -> 0 end)
    noop_ts = outside_horizon_ts + 30

    noop_webhook = %{
      "id" => "evt_noop_outside_window",
      "type" => "customer.subscription.updated",
      "created" => noop_ts,
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "active",
          "cancel_at_period_end" => false,
          "items" => %{"data" => [%{"price" => %{"id" => "price_ultimate"}}]}
        }
      }
    }

    assert {:ok, after_noop} =
             WebhookSync.sync_event(
               noop_webhook,
               @sync_opts ++
                 [
                   provider: CountingProvider,
                   counter: noop_counter,
                   live_response: live_ultimate
                 ]
             )

    assert Agent.get(noop_counter, & &1) == 0
    assert after_noop.price_id == "price_ultimate"

    # 5. Legitimate new upgrade outside 60s window re-verifies with provider and updates state
    {:ok, upgrade_counter} = Agent.start_link(fn -> 0 end)

    live_after_horizon = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "active",
      "items" => %{"data" => [%{"price" => %{"id" => "price_after_horizon"}}]}
    }

    legit_outside_webhook = %{
      "id" => "evt_legit_outside_60s_window",
      "type" => "customer.subscription.updated",
      "created" => noop_ts + 60,
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "active",
          "items" => %{"data" => [%{"price" => %{"id" => "price_after_horizon"}}]}
        }
      }
    }

    assert {:ok, outside_applied} =
             WebhookSync.sync_event(
               legit_outside_webhook,
               @sync_opts ++
                 [
                   provider: CountingProvider,
                   counter: upgrade_counter,
                   live_response: live_after_horizon
                 ]
             )

    assert Agent.get(upgrade_counter, & &1) == 1
    assert outside_applied.price_id == "price_after_horizon"

    # 6. Delayed terminal webhook outside 60s window also re-verifies live provider state
    {:ok, terminal_outside_counter} = Agent.start_link(fn -> 0 end)

    delayed_terminal_outside = %{
      "id" => "evt_delayed_terminal_outside_60s",
      "type" => "customer.subscription.deleted",
      "created" => noop_ts + 120,
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "canceled",
          "items" => %{"data" => [%{"price" => %{"id" => "price_basic"}}]}
        }
      }
    }

    assert {:ok, preserved_after_terminal} =
             WebhookSync.sync_event(
               delayed_terminal_outside,
               @sync_opts ++
                 [
                   provider: CountingProvider,
                   counter: terminal_outside_counter,
                   live_response: live_after_horizon
                 ]
             )

    assert Agent.get(terminal_outside_counter, & &1) == 1
    assert preserved_after_terminal.status == :active
    assert preserved_after_terminal.price_id == "price_after_horizon"

    # 7. Provider HTTP 503 failure during outside-window re-verification fails closed without applying payload
    stale_http_fail = %{
      "id" => "evt_http_503_outside_window",
      "type" => "customer.subscription.updated",
      "created" => noop_ts + 180,
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "active",
          "items" => %{"data" => [%{"price" => %{"id" => "price_basic"}}]}
        }
      }
    }

    assert {:error, {:reconciliation_failed, %{status: 503}}} =
             WebhookSync.sync_event(
               stale_http_fail,
               @sync_opts ++
                 [provider: CountingProvider, live_response: {:error, %{status: 503}}]
             )

    persisted_after_503 = Ash.get!(PostgresSubscription, sub.id, @opts)
    assert persisted_after_503.price_id == "price_after_horizon"
  end

  test "measures additional provider calls and latency impact across fast-paths and financial diffs",
       %{subscription: sub} do
    # Reconcile once so last_reconciled_at is set
    live_enterprise = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "active",
      "items" => %{"data" => [%{"price" => %{"id" => "price_enterprise"}}]}
    }

    assert {:ok, reconciled} =
             AshBilling.reconcile_subscription(sub,
               provider: CountingProvider,
               live_response: live_enterprise,
               domain: PostgresDomain,
               authorize?: false
             )

    # 1. Obsolete event (< last_event_created_at): 0 extra provider calls
    {:ok, obsolete_counter} = Agent.start_link(fn -> 0 end)
    obsolete_ts = DateTime.to_unix(DateTime.add(reconciled.last_event_created_at, -30, :second))

    obsolete_event = %{
      "id" => "evt_measure_obsolete",
      "type" => "customer.subscription.updated",
      "created" => obsolete_ts,
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "active",
          "items" => %{"data" => [%{"price" => %{"id" => "price_basic"}}]}
        }
      }
    }

    {obsolete_us, {:ok, _}} =
      :timer.tc(fn ->
        WebhookSync.sync_event(
          obsolete_event,
          @sync_opts ++
            [
              provider: CountingProvider,
              counter: obsolete_counter,
              delay_ms: 40,
              live_response: live_enterprise
            ]
        )
      end)

    assert Agent.get(obsolete_counter, & &1) == 0

    # 2. No financial diff outside window: 0 extra provider calls
    {:ok, noop_counter} = Agent.start_link(fn -> 0 end)
    later_ts = DateTime.to_unix(DateTime.add(reconciled.last_reconciled_at, 120, :second))

    noop_event = %{
      "id" => "evt_measure_noop",
      "type" => "customer.subscription.updated",
      "created" => later_ts,
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "active",
          "items" => %{"data" => [%{"price" => %{"id" => "price_enterprise"}}]}
        }
      }
    }

    {noop_us, {:ok, _}} =
      :timer.tc(fn ->
        WebhookSync.sync_event(
          noop_event,
          @sync_opts ++
            [
              provider: CountingProvider,
              counter: noop_counter,
              delay_ms: 40,
              live_response: live_enterprise
            ]
        )
      end)

    assert Agent.get(noop_counter, & &1) == 0

    # 3. Critical financial diff outside window: 1 extra provider GET adding provider RTT latency
    {:ok, diff_counter} = Agent.start_link(fn -> 0 end)

    live_pro = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "active",
      "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
    }

    diff_event = %{
      "id" => "evt_measure_diff",
      "type" => "customer.subscription.updated",
      "created" => later_ts + 30,
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "active",
          "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
        }
      }
    }

    {diff_us, {:ok, updated}} =
      :timer.tc(fn ->
        WebhookSync.sync_event(
          diff_event,
          @sync_opts ++
            [
              provider: CountingProvider,
              counter: diff_counter,
              delay_ms: 40,
              live_response: live_pro
            ]
        )
      end)

    assert Agent.get(diff_counter, & &1) == 1
    assert updated.price_id == "price_pro"
    assert diff_us >= 40_000
    assert diff_us > noop_us
    assert diff_us > obsolete_us

    IO.puts(
      "[0.6.0-dev Latency Measure] obsolete=#{obsolete_us}us (calls=0), noop=#{noop_us}us (calls=0), financial_diff=#{diff_us}us (calls=1, simulated_rtt=40ms)"
    )
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

  test "0.5.3 upgrade compatibility: clears ahead synthetic last_event_created_at on 0.6.0 reconciliation so real webhooks are not ignored",
       %{subscription: sub} do
    # 1. Simulate a pre-0.6.0 (0.5.3) subscription where synthetic reconciliation stamped
    #    last_event_created_at ahead of Stripe/PostgreSQL current time (e.g., +180s forward skew)
    #    and last_reconciled_at is NULL after adding the 0.6.0 column.
    synthetic_ahead_ts =
      DateTime.utc_now()
      |> DateTime.add(180, :second)
      |> DateTime.truncate(:second)

    {:ok, legacy_053_sub} =
      sub
      |> Ash.Changeset.for_update(
        :revise,
        %{
          status: :active,
          price_id: "price_pro",
          last_event_created_at: synthetic_ahead_ts,
          last_reconciled_at: nil
        },
        @opts
      )
      |> Ash.update(@opts)

    assert is_nil(legacy_053_sub.last_reconciled_at)

    # 2. After upgrading to 0.6.0, reconcile_subscription/2 fetches live state from Stripe.
    remote_pro = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "active",
      "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
    }

    assert {:ok, reconciled_060} =
             AshBilling.reconcile_subscription(legacy_053_sub,
               provider: CountingProvider,
               live_response: remote_pro,
               domain: PostgresDomain,
               authorize?: false
             )

    assert %DateTime{} = reconciled_060.last_reconciled_at
    assert is_nil(reconciled_060.last_event_created_at)

    # 3. A delayed stale webhook arriving immediately after clearing the synthetic cursor
    #    is STILL blocked from overwriting reconciled state because last_reconciled_at triggers
    #    live provider re-verification.
    stale_past_ts =
      DateTime.utc_now()
      |> DateTime.add(-600, :second)
      |> DateTime.truncate(:second)

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    stale_webhook = %{
      "id" => "evt_stale_after_053_upgrade",
      "type" => "customer.subscription.updated",
      "created" => DateTime.to_unix(stale_past_ts),
      "data" => %{
        "object" => %{
          "id" => "sub_durable_1",
          "customer" => "cus_durable",
          "status" => "active",
          "items" => %{"data" => [%{"price" => %{"id" => "price_basic"}}]}
        }
      }
    }

    assert {:ok, after_stale} =
             WebhookSync.sync_event(
               stale_webhook,
               @sync_opts ++
                 [provider: CountingProvider, counter: counter, live_response: remote_pro]
             )

    assert Agent.get(counter, & &1) == 1
    assert after_stale.price_id == "price_pro"

    # 4. Now a legitimate real Stripe webhook arrives with event.created < synthetic_ahead_ts
    #    (real current Stripe time) upgrading the plan to price_enterprise.
    #    It MUST NOT be ignored by existing_event_newer?/2.
    real_webhook_ts =
      DateTime.utc_now()
      |> DateTime.add(5, :second)
      |> DateTime.truncate(:second)

    assert DateTime.compare(real_webhook_ts, synthetic_ahead_ts) == :lt

    remote_enterprise = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "active",
      "items" => %{"data" => [%{"price" => %{"id" => "price_enterprise"}}]}
    }

    legitimate_webhook = %{
      "id" => "evt_legit_after_053_upgrade",
      "type" => "customer.subscription.updated",
      "created" => DateTime.to_unix(real_webhook_ts),
      "data" => %{
        "object" => remote_enterprise
      }
    }

    assert {:ok, after_legit} =
             WebhookSync.sync_event(
               legitimate_webhook,
               @sync_opts ++
                 [provider: CountingProvider, counter: counter, live_response: remote_enterprise]
             )

    assert Agent.get(counter, & &1) == 2
    assert after_legit.price_id == "price_enterprise"
    assert DateTime.compare(after_legit.last_event_created_at, real_webhook_ts) == :eq

    # 5. Shared App+PostgreSQL forward skew case: synthetic last_event_created_at <= DB clock
    #    (e.g., DB clock was also ahead of Stripe). Explicit reset_event_cursor?: true clears
    #    last_event_created_at atomically with last_reconciled_at so earlier Stripe events apply.
    shared_skew_ts =
      DateTime.utc_now()
      |> DateTime.add(-10, :second)
      |> DateTime.truncate(:second)

    {:ok, shared_skew_sub} =
      after_legit
      |> Ash.Changeset.for_update(
        :revise,
        %{
          status: :active,
          price_id: "price_enterprise",
          last_event_created_at: shared_skew_ts,
          last_reconciled_at: nil
        },
        @opts
      )
      |> Ash.update(@opts)

    assert {:ok, reset_sub} =
             AshBilling.reconcile_subscription(shared_skew_sub,
               provider: CountingProvider,
               live_response: remote_enterprise,
               reset_event_cursor?: true,
               domain: PostgresDomain,
               authorize?: false
             )

    assert %DateTime{} = reset_sub.last_reconciled_at
    assert is_nil(reset_sub.last_event_created_at)

    stripe_behind_db_ts = DateTime.add(shared_skew_ts, -30, :second)

    remote_canceled = %{
      "id" => "sub_durable_1",
      "customer" => "cus_durable",
      "status" => "canceled",
      "items" => %{"data" => [%{"price" => %{"id" => "price_enterprise"}}]}
    }

    legitimate_cancel = %{
      "id" => "evt_legit_cancel_shared_skew",
      "type" => "customer.subscription.deleted",
      "created" => DateTime.to_unix(stripe_behind_db_ts),
      "data" => %{"object" => remote_canceled}
    }

    assert {:ok, canceled_sub} =
             WebhookSync.sync_event(
               legitimate_cancel,
               @sync_opts ++
                 [provider: CountingProvider, counter: counter, live_response: remote_canceled]
             )

    assert canceled_sub.status == :canceled
    assert DateTime.compare(canceled_sub.last_event_created_at, stripe_behind_db_ts) == :eq
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
