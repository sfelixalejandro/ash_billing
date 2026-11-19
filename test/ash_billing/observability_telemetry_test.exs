defmodule AshBilling.ObservabilityTelemetryTest do
  @moduledoc """
  Phase B (B4 / B5) tests verifying low-cardinality Telemetry emission once per
  logical operation for reconciliation, webhook re-verification, deduplication,
  PostgreSQL lock contention, and batch reconciler runs.
  """
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias AshBilling.{Deduplication, Reconciler, WebhookSync}

  alias AshBilling.Test.{
    PostgresCustomer,
    PostgresDomain,
    PostgresSubscription,
    PostgresWebhookEvent,
    Repo
  }

  @opts [domain: PostgresDomain, authorize?: false]
  @sync_opts @opts ++
               [customer_resource: PostgresCustomer, subscription_resource: PostgresSubscription]

  defmodule TelemetryProvider do
    @moduledoc false
    def get_subscription(_id, opts) do
      case Keyword.get(opts, :live_response) do
        %{} = payload -> {:ok, payload}
        {:error, _} = err -> err
      end
    end
  end

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE billing_test_subscriptions, billing_test_customers, webhook_events"
    )

    test_pid = self()
    handler_id = "ash-billing-obs-test-#{System.unique_integer([:positive])}"

    events = [
      [:ash_billing, :reconcile, :start],
      [:ash_billing, :reconcile, :stop],
      [:ash_billing, :reconcile, :exception],
      [:ash_billing, :reverify, :start],
      [:ash_billing, :reverify, :stop],
      [:ash_billing, :reverify, :exception],
      [:ash_billing, :deduplication, :acquire],
      [:ash_billing, :deduplication, :complete],
      [:ash_billing, :deduplication, :release],
      [:ash_billing, :postgres, :contention],
      [:ash_billing, :reconciler, :batch]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    customer = Ash.create!(PostgresCustomer, %{stripe_customer_id: "cus_obs_1"}, @opts)
    t1 = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

    sub =
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: customer.id,
          provider_subscription_id: "sub_obs_1",
          status: :active,
          price_id: "price_basic",
          quantity: 2,
          last_event_created_at: t1
        },
        @opts
      )

    %{customer: customer, sub: sub, t1: t1}
  end

  defp collect_events(target_event) do
    receive do
      {:telemetry, ^target_event, m, meta} -> [{m, meta} | collect_events(target_event)]
    after
      0 -> []
    end
  end

  test "emits [:ash_billing, :reconcile] once per call with drift detection and low-cardinality metadata",
       %{sub: sub} do
    live_remote = %{
      "id" => "sub_obs_1",
      "customer" => "cus_obs_1",
      "status" => "active",
      "items" => %{
        "data" => [%{"id" => "si_obs_1", "price" => %{"id" => "price_pro"}, "quantity" => 10}]
      }
    }

    assert {:ok, reconciled} =
             AshBilling.reconcile_subscription(sub,
               provider: TelemetryProvider,
               live_response: live_remote,
               domain: PostgresDomain,
               authorize?: false
             )

    assert reconciled.quantity == 10

    starts = collect_events([:ash_billing, :reconcile, :start])
    stops = collect_events([:ash_billing, :reconcile, :stop])
    assert length(starts) == 1
    assert length(stops) == 1

    [{measurements, meta}] = stops
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert meta.status == :ok
    assert meta.drift_detected == true
    assert :price_id in meta.changed_fields
    assert :quantity in meta.changed_fields
    assert is_nil(meta.error_category)

    # Low-cardinality check: no subscription_id, customer_id, or secrets in metadata
    refute Map.has_key?(meta, :subscription_id)
    refute Map.has_key?(meta, :customer_id)
    refute Map.has_key?(meta, :event_id)

    # Provider outage emits error_category without fabricating success
    assert {:error, %{status: 503}} =
             AshBilling.reconcile_subscription(reconciled,
               provider: TelemetryProvider,
               live_response: {:error, %{status: 503}},
               domain: PostgresDomain,
               authorize?: false
             )

    [{_m2, err_meta}] = collect_events([:ash_billing, :reconcile, :stop])
    assert err_meta.status == :error
    assert err_meta.error_category == :provider_http_error
    assert err_meta.drift_detected == false
  end

  test "emits [:ash_billing, :reverify] once per post-reconciliation webhook live GET", %{
    sub: sub
  } do
    live_pro = %{
      "id" => "sub_obs_1",
      "customer" => "cus_obs_1",
      "status" => "active",
      "items" => %{
        "data" => [%{"id" => "si_obs_1", "price" => %{"id" => "price_pro"}, "quantity" => 10}]
      }
    }

    {:ok, reconciled} =
      AshBilling.reconcile_subscription(sub,
        provider: TelemetryProvider,
        live_response: live_pro,
        domain: PostgresDomain,
        authorize?: false
      )

    # Drain reconcile events
    _ = collect_events([:ash_billing, :reconcile, :start])
    _ = collect_events([:ash_billing, :reconcile, :stop])

    later_ts = DateTime.add(reconciled.last_reconciled_at, 120, :second)

    delayed_stale = %{
      "id" => "evt_obs_reverify_1",
      "type" => "customer.subscription.updated",
      "created" => DateTime.to_unix(later_ts),
      "data" => %{
        "object" => %{
          "id" => "sub_obs_1",
          "customer" => "cus_obs_1",
          "status" => "active",
          "items" => %{
            "data" => [
              %{"id" => "si_obs_1", "price" => %{"id" => "price_basic"}, "quantity" => 2}
            ]
          }
        }
      }
    }

    assert {:ok, synced} =
             WebhookSync.sync_event(
               delayed_stale,
               @sync_opts ++ [provider: TelemetryProvider, live_response: live_pro]
             )

    assert synced.price_id == "price_pro"

    reverify_stops = collect_events([:ash_billing, :reverify, :stop])
    assert length(reverify_stops) == 1
    [{m, meta}] = reverify_stops
    assert is_integer(m.duration)
    assert meta.status == :ok
    assert meta.drift_detected == false
    refute Map.has_key?(meta, :event_id)
  end

  test "emits [:ash_billing, :deduplication] once per logical acquire, duplicate, complete, and release" do
    dedup_opts = [
      deduplication_strategy: :resource,
      deduplication_resource: PostgresWebhookEvent,
      domain: PostgresDomain
    ]

    # 1. Acquire
    assert {:ok, token} = Deduplication.acquire("evt_obs_dedup_1", dedup_opts)
    [{m1, meta1}] = collect_events([:ash_billing, :deduplication, :acquire])
    assert m1.count == 1
    assert is_integer(m1.duration)
    assert meta1 == %{strategy: :resource, outcome: :acquired, error_category: nil}

    # 2. In-flight contention -> :already_processing
    assert {:error, :already_processing} = Deduplication.acquire("evt_obs_dedup_1", dedup_opts)
    [{_m2, meta2}] = collect_events([:ash_billing, :deduplication, :acquire])
    assert meta2.outcome == :already_processing

    # 3. Release -> :release
    assert :ok = Deduplication.release("evt_obs_dedup_1", [lease_token: token] ++ dedup_opts)
    [{m_rel, meta_rel}] = collect_events([:ash_billing, :deduplication, :release])
    assert m_rel.count == 1
    assert meta_rel == %{strategy: :resource, status: :ok}

    # 4. Re-acquire & Complete -> :complete
    assert {:ok, token2} = Deduplication.acquire("evt_obs_dedup_1", dedup_opts)
    _ = collect_events([:ash_billing, :deduplication, :acquire])

    assert :ok = Deduplication.complete("evt_obs_dedup_1", [lease_token: token2] ++ dedup_opts)
    [{m_comp, meta_comp}] = collect_events([:ash_billing, :deduplication, :complete])
    assert m_comp.count == 1
    assert meta_comp == %{strategy: :resource, status: :ok}

    # 5. Duplicate -> :duplicate
    assert {:error, :already_processed} = Deduplication.acquire("evt_obs_dedup_1", dedup_opts)
    [{_m_dup, meta_dup}] = collect_events([:ash_billing, :deduplication, :acquire])
    assert meta_dup.outcome == :duplicate
  end

  test "emits [:ash_billing, :postgres, :contention] on PostgreSQL lock_timeout and [:ash_billing, :reconciler, :batch]",
       %{sub: sub} do
    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM billing_test_subscriptions WHERE id = $1 FOR UPDATE", [
            Ecto.UUID.dump!(sub.id)
          ])

          send(test_pid, :locked)

          receive do
            :release -> :ok
          after
            5_000 -> :timeout
          end
        end)
      end)

    assert_receive :locked, 1_000

    assert {:error, _} =
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL lock_timeout = '20ms'")

               res =
                 AshBilling.ResourceLock.run(
                   [PostgresSubscription],
                   {:test, sub.id},
                   fn ->
                     Repo.query!(
                       "SELECT id FROM billing_test_subscriptions WHERE id = $1 FOR UPDATE",
                       [Ecto.UUID.dump!(sub.id)]
                     )
                   end,
                   rollback_on_error?: true
                 )

               case res do
                 {:error, err} -> Repo.rollback(err)
                 other -> other
               end
             end)

    send(holder.pid, :release)
    Task.await(holder, 5_000)

    contention = collect_events([:ash_billing, :postgres, :contention])
    assert length(contention) == 1
    [{%{count: 1}, meta}] = contention
    assert meta.operation == :transaction_lock
    assert meta.reason == :lock_not_available

    # Batch telemetry
    live_pro = %{
      "id" => "sub_obs_1",
      "customer" => "cus_obs_1",
      "status" => "active",
      "items" => %{
        "data" => [%{"id" => "si_obs_1", "price" => %{"id" => "price_pro"}, "quantity" => 5}]
      }
    }

    assert {:ok, _report} =
             Reconciler.run(
               domain: PostgresDomain,
               subscription_resource: PostgresSubscription,
               subscription_id: "sub_obs_1",
               mode: :dry_run,
               authorize?: false,
               provider: TelemetryProvider,
               live_response: live_pro
             )

    [{batch_m, batch_meta}] = collect_events([:ash_billing, :reconciler, :batch])
    assert batch_meta == %{mode: :dry_run}
    assert batch_m.total == 1
    assert batch_m.drifted == 1
    assert is_integer(batch_m.duration)
  end
end
