defmodule AshBilling.QuantitySyncTest do
  @moduledoc """
  Phase A (0.7.0) acceptance tests for subscription quantity and
  provider_subscription_item_id persistence, synchronization, concurrency,
  multi-node durability, write protection, and multitenancy.
  """
  use ExUnit.Case, async: false
  @moduletag :postgres

  import Plug.Conn
  import Plug.Test

  alias AshBilling.Test.{
    DurablePeerHelper,
    PostgresCustomer,
    PostgresDomain,
    PostgresOwnedScopedSubscription,
    PostgresScopedCustomer,
    PostgresSubscription,
    PostgresWebhookEvent,
    Repo
  }

  alias AshBilling.WebhookSync

  @opts [domain: PostgresDomain, authorize?: false]
  @sync_opts @opts ++
               [customer_resource: PostgresCustomer, subscription_resource: PostgresSubscription]

  defmodule ProtectedWildcardSubscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshBilling.QuantitySyncTest.ProtectedDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshBilling.Subscription]

    attributes do
      uuid_primary_key :id
      attribute :user_id, :uuid, public?: true
      attribute :note, :string, public?: true
    end

    relationships do
      belongs_to :user, AshBilling.QuantitySyncTest.ProtectedCustomer
    end

    billing_subscription do
      customer_relationship :user
    end

    actions do
      default_accept :*
      defaults [:read, :create, :update, :destroy]
    end
  end

  defmodule ProtectedCustomer do
    @moduledoc false
    use Ash.Resource,
      domain: AshBilling.QuantitySyncTest.ProtectedDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshBilling.Resource]

    attributes do
      uuid_primary_key :id
      attribute :email, :string, public?: true
    end

    actions do
      default_accept :*
      defaults [:read, :create, :update, :destroy]
    end
  end

  defmodule ProtectedDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource ProtectedCustomer
      resource ProtectedWildcardSubscription
    end
  end

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

  defmodule LegacyFallbackProvider do
    @moduledoc false
    @behaviour AshBilling.Provider

    @impl true
    def create_customer(_, _), do: {:error, :not_implemented}
    @impl true
    def create_checkout_session(_, _), do: {:error, :not_implemented}
    @impl true
    def create_portal_session(_, _), do: {:error, :not_implemented}
    @impl true
    def cancel_subscription(_, _), do: {:error, :not_implemented}
    @impl true
    def resume_subscription(_, _), do: {:error, :not_implemented}
    @impl true
    def verify_webhook(_, _, _, _), do: {:error, :not_implemented}

    @impl true
    def get_subscription(sub_id, opts) do
      {:ok,
       %{
         "id" => sub_id,
         "status" => "active",
         "items" => %{
           "data" => [
             %{
               "id" => Keyword.get(opts, :item_id, "si_legacy_1"),
               "price" => %{"id" => Keyword.get(opts, :remote_price, "price_legacy")},
               "quantity" => Keyword.get(opts, :remote_quantity, 5)
             }
           ]
         }
       }}
    end

    @impl true
    def swap_plan(sub_id, new_price_id, opts) do
      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:legacy_swap_plan, sub_id, new_price_id, opts})
      end

      {:ok,
       %{
         "id" => sub_id,
         "status" => "active",
         "items" => %{
           "data" => [
             %{
               "id" => Keyword.get(opts, :subscription_item_id, "si_legacy_1"),
               "price" => %{"id" => new_price_id},
               "quantity" => Keyword.get(opts, :quantity)
             }
           ]
         }
       }}
    end
  end

  defmodule FailingRollbackHandler do
    @moduledoc false
    def handle_event(_event), do: {:error, :downstream_handler_failure}
  end

  setup do
    Ecto.Adapters.SQL.query!(
      Repo,
      "TRUNCATE billing_test_subscriptions, billing_test_customers, billing_scoped_subscriptions, billing_scoped_customers, webhook_events"
    )

    customer = Ash.create!(PostgresCustomer, %{stripe_customer_id: "cus_qty_1"}, @opts)
    t1 = DateTime.utc_now() |> DateTime.add(-300, :second) |> DateTime.truncate(:second)

    %{customer: customer, t1: t1}
  end

  defp stripe_sub_object(sub_id, customer_id, price_id, quantity, opts) do
    status = Keyword.get(opts, :status, "active")
    item_id = Keyword.get(opts, :item_id, "si_#{sub_id}")

    item =
      %{"id" => item_id, "price" => %{"id" => price_id}}
      |> then(fn map ->
        case quantity do
          :omit -> map
          val -> Map.put(map, "quantity", val)
        end
      end)

    %{
      "id" => sub_id,
      "customer" => customer_id,
      "status" => status,
      "cancel_at_period_end" => Keyword.get(opts, :cancel_at_period_end, false),
      "items" => %{"data" => [item]}
    }
  end

  defp sub_event(event_id, type, created_dt, object) do
    %{
      "id" => event_id,
      "type" => type,
      "livemode" => false,
      "created" => DateTime.to_unix(created_dt),
      "data" => %{"object" => object}
    }
  end

  defp sign_webhook(payload, secret, timestamp \\ System.system_time(:second)) do
    sig =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{sig}"
  end

  test "1. syncs and persists subscriptions with 1, 5, 20, and 100 seats and preserves checkout quantity",
       %{customer: customer, t1: t1} do
    # Verify create_checkout_session/2 continues forwarding seat quantity to Stripe
    checkout_plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = URI.decode_query(body)
      assert decoded["line_items[0][price]"] == "price_pro"
      assert decoded["line_items[0][quantity]"] == "20"
      assert decoded["mode"] == "subscription"

      Req.Test.json(conn, %{
        "id" => "cs_test_qty_20",
        "url" => "https://checkout.stripe.com/c/pay/cs_test_qty_20"
      })
    end

    assert {:ok, %{id: "cs_test_qty_20"}} =
             AshBilling.create_checkout_session(customer,
               price: "price_pro",
               quantity: 20,
               success_url: "https://app.example/success",
               cancel_url: "https://app.example/cancel",
               api_key: "sk_test_qty",
               req_opts: [plug: checkout_plug, retry: false]
             )

    for seats <- [1, 5, 20, 100] do
      sub_id = "sub_seats_#{seats}"
      item_id = "si_seats_#{seats}"
      object = stripe_sub_object(sub_id, "cus_qty_1", "price_pro", seats, item_id: item_id)
      event = sub_event("evt_create_#{seats}", "customer.subscription.created", t1, object)

      assert {:ok, created} = WebhookSync.sync_event(event, @sync_opts)
      assert created.provider_subscription_id == sub_id
      assert created.price_id == "price_pro"
      assert created.quantity == seats
      assert created.provider_subscription_item_id == item_id

      reloaded = Ash.get!(PostgresSubscription, created.id, @opts)
      assert reloaded.quantity == seats
      assert reloaded.provider_subscription_item_id == item_id
    end
  end

  test "2. updates quantity without changing plan both pre- and post-reconciliation and isolates Stripe API payload",
       %{t1: t1} do
    # Verify Stripe provider update_quantity/3 sends only item id + quantity (no price)
    bypass_plug = fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v1/subscriptions/sub_qty_only"} ->
          Req.Test.json(
            conn,
            stripe_sub_object("sub_qty_only", "cus_qty_1", "price_pro", 5, item_id: "si_qty_only")
          )

        {"POST", "/v1/subscriptions/sub_qty_only"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = URI.decode_query(body)
          assert decoded["items[0][id]"] == "si_qty_only"
          assert decoded["items[0][quantity]"] == "15"
          refute Map.has_key?(decoded, "items[0][price]")

          Req.Test.json(
            conn,
            stripe_sub_object("sub_qty_only", "cus_qty_1", "price_pro", 15,
              item_id: "si_qty_only"
            )
          )
      end
    end

    assert {:ok, remote_updated} =
             AshBilling.update_quantity("sub_qty_only", 15,
               api_key: "sk_test_qty",
               req_opts: [plug: bypass_plug, retry: false]
             )

    assert hd(remote_updated["items"]["data"])["quantity"] == 15

    # Pre-reconciliation webhook changing ONLY quantity (5 -> 15)
    initial_obj =
      stripe_sub_object("sub_qty_only", "cus_qty_1", "price_pro", 5, item_id: "si_qty_only")

    assert {:ok, created} =
             WebhookSync.sync_event(
               sub_event("evt_q1", "customer.subscription.created", t1, initial_obj),
               @sync_opts
             )

    assert created.quantity == 5
    assert created.price_id == "price_pro"

    t2 = DateTime.add(t1, 30, :second)

    qty_only_obj =
      stripe_sub_object("sub_qty_only", "cus_qty_1", "price_pro", 15, item_id: "si_qty_only")

    assert {:ok, updated} =
             WebhookSync.sync_event(
               sub_event("evt_q2", "customer.subscription.updated", t2, qty_only_obj),
               @sync_opts
             )

    assert updated.quantity == 15
    assert updated.price_id == "price_pro"
    assert updated.status == :active

    # Post-reconciliation webhook changing ONLY quantity (15 -> 25) MUST detect financial diff and re-verify
    assert {:ok, reconciled} =
             AshBilling.reconcile_subscription(updated,
               provider: CountingProvider,
               live_response: qty_only_obj,
               domain: PostgresDomain,
               authorize?: false
             )

    assert %DateTime{} = reconciled.last_reconciled_at
    assert reconciled.quantity == 15

    {:ok, counter} = Agent.start_link(fn -> 0 end)
    t3 = DateTime.add(reconciled.last_reconciled_at, 120, :second)

    qty_25_obj =
      stripe_sub_object("sub_qty_only", "cus_qty_1", "price_pro", 25, item_id: "si_qty_only")

    assert {:ok, after_reverify} =
             WebhookSync.sync_event(
               sub_event("evt_q3", "customer.subscription.updated", t3, qty_25_obj),
               @sync_opts ++
                 [provider: CountingProvider, counter: counter, live_response: qty_25_obj]
             )

    assert Agent.get(counter, & &1) == 1
    assert after_reverify.quantity == 25
    assert after_reverify.price_id == "price_pro"
  end

  test "3. swap_plan preserves quantity remotely and locally in PostgreSQL", %{t1: t1} do
    bypass_plug = fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v1/subscriptions/sub_swap_qty"} ->
          Req.Test.json(
            conn,
            stripe_sub_object("sub_swap_qty", "cus_qty_1", "price_basic", 20,
              item_id: "si_swap_qty"
            )
          )

        {"POST", "/v1/subscriptions/sub_swap_qty"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = URI.decode_query(body)
          assert decoded["items[0][id]"] == "si_swap_qty"
          assert decoded["items[0][price]"] == "price_enterprise"
          assert decoded["items[0][quantity]"] == "20"

          Req.Test.json(
            conn,
            stripe_sub_object("sub_swap_qty", "cus_qty_1", "price_enterprise", 20,
              item_id: "si_swap_qty"
            )
          )
      end
    end

    obj_basic =
      stripe_sub_object("sub_swap_qty", "cus_qty_1", "price_basic", 20, item_id: "si_swap_qty")

    assert {:ok, created} =
             WebhookSync.sync_event(
               sub_event("evt_swap_1", "customer.subscription.created", t1, obj_basic),
               @sync_opts
             )

    assert created.price_id == "price_basic"
    assert created.quantity == 20

    assert {:ok, swapped_remote} =
             AshBilling.swap_plan(created, "price_enterprise",
               api_key: "sk_test_qty",
               req_opts: [plug: bypass_plug, retry: false]
             )

    t2 = DateTime.add(t1, 60, :second)

    assert {:ok, synced} =
             WebhookSync.sync_event(
               sub_event("evt_swap_2", "customer.subscription.updated", t2, swapped_remote),
               @sync_opts
             )

    assert synced.price_id == "price_enterprise"
    assert synced.quantity == 20
    assert synced.provider_subscription_item_id == "si_swap_qty"
  end

  test "4. delayed webhook with obsolete quantity does not overwrite newer or reconciled quantity",
       %{t1: t1} do
    t2 = DateTime.add(t1, 60, :second)

    obj_20 =
      stripe_sub_object("sub_stale_qty", "cus_qty_1", "price_pro", 20, item_id: "si_stale_qty")

    assert {:ok, created} =
             WebhookSync.sync_event(
               sub_event("evt_stale_init", "customer.subscription.created", t2, obj_20),
               @sync_opts
             )

    assert created.quantity == 20

    # A) Clearly older event (t1 < t2): ignored in fast path with 0 provider calls
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    obj_5 =
      stripe_sub_object("sub_stale_qty", "cus_qty_1", "price_pro", 5, item_id: "si_stale_qty")

    assert {:ok, ignored} =
             WebhookSync.sync_event(
               sub_event("evt_stale_old", "customer.subscription.updated", t1, obj_5),
               @sync_opts ++ [provider: CountingProvider, counter: counter, live_response: obj_20]
             )

    assert Agent.get(counter, & &1) == 0
    assert ignored.quantity == 20

    # B) Reconcile to 50 seats, then receive a delayed webhook carrying stale 10 seats
    #    with event.created > last_reconciled_at + 120s (outside 60s window)
    obj_50 =
      stripe_sub_object("sub_stale_qty", "cus_qty_1", "price_pro", 50, item_id: "si_stale_qty")

    assert {:ok, reconciled} =
             AshBilling.reconcile_subscription(ignored,
               provider: CountingProvider,
               live_response: obj_50,
               domain: PostgresDomain,
               authorize?: false
             )

    assert reconciled.quantity == 50

    outside_window_ts = DateTime.add(reconciled.last_reconciled_at, 120, :second)

    obj_10 =
      stripe_sub_object("sub_stale_qty", "cus_qty_1", "price_pro", 10, item_id: "si_stale_qty")

    assert {:ok, preserved} =
             WebhookSync.sync_event(
               sub_event(
                 "evt_stale_outside_window",
                 "customer.subscription.updated",
                 outside_window_ts,
                 obj_10
               ),
               @sync_opts ++ [provider: CountingProvider, counter: counter, live_response: obj_50]
             )

    assert Agent.get(counter, & &1) == 1
    assert preserved.quantity == 50
  end

  test "5. duplicate quantity webhook is deduplicated via PostgreSQL WebhookEvent lease", %{
    t1: t1
  } do
    secret = "whsec_qty_dedup_test"

    obj_12 =
      stripe_sub_object("sub_dedup_qty", "cus_qty_1", "price_pro", 12, item_id: "si_dedup_qty")

    payload =
      Jason.encode!(sub_event("evt_dedup_qty_1", "customer.subscription.created", t1, obj_12))

    plug_opts =
      AshBilling.Plug.init(
        webhook_secret: secret,
        expected_livemode: false,
        customer_resource: PostgresCustomer,
        subscription_resource: PostgresSubscription,
        deduplication_resource: PostgresWebhookEvent,
        domain: PostgresDomain
      )

    conn1 =
      conn(:post, "/webhooks/stripe", payload)
      |> put_req_header("stripe-signature", sign_webhook(payload, secret))
      |> AshBilling.Plug.call(plug_opts)

    assert conn1.status == 200

    [sub] = Ash.read!(PostgresSubscription, @opts)
    assert sub.quantity == 12

    # Second identical delivery is deduplicated without re-running sync
    conn2 =
      conn(:post, "/webhooks/stripe", payload)
      |> put_req_header("stripe-signature", sign_webhook(payload, secret))
      |> AshBilling.Plug.call(plug_opts)

    assert conn2.status == 200
    assert Jason.decode!(conn2.resp_body)["status"] == "already_processed"

    [sub_after] = Ash.read!(PostgresSubscription, @opts)
    assert sub_after.quantity == 12
    assert Ash.get!(PostgresWebhookEvent, "evt_dedup_qty_1", @opts).status == :processed
  end

  test "6. same-second timestamp conflict differing ONLY in quantity triggers live provider reconciliation",
       %{t1: t1} do
    obj_5 =
      stripe_sub_object("sub_same_sec_qty", "cus_qty_1", "price_pro", 5,
        item_id: "si_same_sec_qty"
      )

    assert {:ok, created} =
             WebhookSync.sync_event(
               sub_event("evt_ss_1", "customer.subscription.created", t1, obj_5),
               @sync_opts
             )

    assert created.quantity == 5

    # Second event with exact same created second (t1), identical price/status, different quantity
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    obj_incoming_3 =
      stripe_sub_object("sub_same_sec_qty", "cus_qty_1", "price_pro", 3,
        item_id: "si_same_sec_qty"
      )

    obj_live_10 =
      stripe_sub_object("sub_same_sec_qty", "cus_qty_1", "price_pro", 10,
        item_id: "si_same_sec_qty"
      )

    assert {:ok, resolved} =
             WebhookSync.sync_event(
               sub_event("evt_ss_2", "customer.subscription.updated", t1, obj_incoming_3),
               @sync_opts ++
                 [provider: CountingProvider, counter: counter, live_response: obj_live_10]
             )

    assert Agent.get(counter, & &1) == 1
    assert resolved.quantity == 10
    assert resolved.price_id == "price_pro"
  end

  test "7. reconcile_subscription heals missed quantity and plan webhooks atomically", %{t1: t1} do
    obj_initial =
      stripe_sub_object("sub_missed_qty", "cus_qty_1", "price_basic", 2, item_id: "si_missed_1")

    assert {:ok, created} =
             WebhookSync.sync_event(
               sub_event("evt_miss_1", "customer.subscription.created", t1, obj_initial),
               @sync_opts
             )

    assert created.price_id == "price_basic"
    assert created.quantity == 2
    assert created.provider_subscription_item_id == "si_missed_1"

    # Webhooks dropped while Stripe updated price, quantity, and item
    live_remote =
      stripe_sub_object("sub_missed_qty", "cus_qty_1", "price_enterprise", 40,
        item_id: "si_missed_2"
      )

    assert {:ok, reconciled} =
             AshBilling.reconcile_subscription(created,
               provider: CountingProvider,
               live_response: live_remote,
               domain: PostgresDomain,
               authorize?: false
             )

    assert reconciled.price_id == "price_enterprise"
    assert reconciled.quantity == 40
    assert reconciled.provider_subscription_item_id == "si_missed_2"
    assert %DateTime{} = reconciled.last_reconciled_at
    assert DateTime.compare(reconciled.last_event_created_at, t1) == :eq
  end

  test "8. PostgreSQL rollback leaves quantity and item_id untouched on handler failure", %{
    t1: t1
  } do
    secret = "whsec_qty_rollback"

    obj_5 =
      stripe_sub_object("sub_rollback_qty", "cus_qty_1", "price_pro", 5, item_id: "si_rollback_1")

    assert {:ok, created} =
             WebhookSync.sync_event(
               sub_event("evt_rb_init", "customer.subscription.created", t1, obj_5),
               @sync_opts
             )

    t2 = DateTime.add(t1, 30, :second)

    obj_50 =
      stripe_sub_object("sub_rollback_qty", "cus_qty_1", "price_pro", 50,
        item_id: "si_rollback_2"
      )

    payload =
      Jason.encode!(sub_event("evt_rb_fail", "customer.subscription.updated", t2, obj_50))

    plug_opts =
      AshBilling.Plug.init(
        webhook_secret: secret,
        expected_livemode: false,
        customer_resource: PostgresCustomer,
        subscription_resource: PostgresSubscription,
        deduplication_resource: PostgresWebhookEvent,
        handler: FailingRollbackHandler,
        domain: PostgresDomain
      )

    conn =
      conn(:post, "/webhooks/stripe", payload)
      |> put_req_header("stripe-signature", sign_webhook(payload, secret))
      |> AshBilling.Plug.call(plug_opts)

    assert conn.status == 500

    reloaded = Ash.get!(PostgresSubscription, created.id, @opts)
    assert reloaded.quantity == 5
    assert reloaded.provider_subscription_item_id == "si_rollback_1"
    assert Ash.get!(PostgresWebhookEvent, "evt_rb_fail", @opts).status == :failed
  end

  test "9. two real Erlang VM peer nodes sharing PostgreSQL preserve reconciled quantity", %{
    t1: t1
  } do
    obj_5 =
      stripe_sub_object("sub_peer_qty", "cus_qty_1", "price_pro", 5, item_id: "si_peer_qty")

    assert {:ok, _created} =
             WebhookSync.sync_event(
               sub_event("evt_peer_init", "customer.subscription.created", t1, obj_5),
               @sync_opts
             )

    app_env = Application.get_all_env(:ash_billing)

    start_peer = fn ->
      {:ok, pid, _node} = :peer.start_link(%{connection: :standard_io})
      true = :peer.call(pid, :code, :set_path, [:code.get_path()])
      {:ok, os_pid} = :peer.call(pid, DurablePeerHelper, :bootstrap, [app_env])
      {pid, os_pid}
    end

    {peer_a, pid_a} = start_peer.()
    {peer_b, pid_b} = start_peer.()

    try do
      assert pid_a != pid_b

      live_30 =
        stripe_sub_object("sub_peer_qty", "cus_qty_1", "price_pro", 30, item_id: "si_peer_qty")

      assert {:ok, reconciled_a} =
               :peer.call(peer_a, DurablePeerHelper, :reconcile, ["sub_peer_qty", live_30])

      assert reconciled_a.quantity == 30
      assert %DateTime{} = reconciled_a.last_reconciled_at

      # Node B receives a delayed older webhook carrying stale quantity 8
      t_delayed = DateTime.add(reconciled_a.last_reconciled_at, 180, :second)

      stale_8 =
        stripe_sub_object("sub_peer_qty", "cus_qty_1", "price_pro", 8, item_id: "si_peer_qty")

      delayed_event =
        sub_event("evt_peer_stale_qty", "customer.subscription.updated", t_delayed, stale_8)

      assert {:ok, synced_b} =
               :peer.call(peer_b, DurablePeerHelper, :sync_webhook, [delayed_event, live_30])

      assert synced_b.quantity == 30

      assert {:ok, fetched_a} =
               :peer.call(peer_a, DurablePeerHelper, :fetch_subscription, ["sub_peer_qty"])

      assert fetched_a.quantity == 30
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

  test "10. 0.6.0 migration compatibility: historical rows with quantity=NULL remain queryable, never assume 1, and sync cleanly",
       %{customer: customer, t1: t1} do
    # Insert a historical 0.6.0-style row directly via SQL (quantity = NULL, item_id = NULL)
    sub_uuid = Ecto.UUID.generate()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO billing_test_subscriptions
        (id, user_id, provider_subscription_id, status, price_id, cancel_at_period_end, last_event_created_at)
      VALUES ($1, $2, $3, $4, $5, false, $6)
      """,
      [
        Ecto.UUID.dump!(sub_uuid),
        Ecto.UUID.dump!(customer.id),
        "sub_legacy_060",
        "active",
        "price_pro",
        DateTime.to_naive(t1)
      ]
    )

    loaded = Ash.get!(PostgresSubscription, sub_uuid, @opts)
    assert is_nil(loaded.quantity)
    assert is_nil(loaded.provider_subscription_item_id)

    # Metered/usage-based webhook without quantity must preserve quantity = nil (NOT default to 1)
    t2 = DateTime.add(t1, 30, :second)

    metered_obj =
      stripe_sub_object("sub_legacy_060", "cus_qty_1", "price_metered", :omit,
        item_id: "si_metered_1"
      )

    assert {:ok, metered_synced} =
             WebhookSync.sync_event(
               sub_event("evt_metered", "customer.subscription.updated", t2, metered_obj),
               @sync_opts
             )

    assert metered_synced.price_id == "price_metered"
    assert is_nil(metered_synced.quantity)
    assert metered_synced.provider_subscription_item_id == "si_metered_1"

    # Reconcile to a seat-based plan populates quantity & item_id atomically
    live_seated =
      stripe_sub_object("sub_legacy_060", "cus_qty_1", "price_seats", 7, item_id: "si_seated_1")

    assert {:ok, reconciled} =
             AshBilling.reconcile_subscription(metered_synced,
               provider: CountingProvider,
               live_response: live_seated,
               domain: PostgresDomain,
               authorize?: false
             )

    assert reconciled.quantity == 7
    assert reconciled.provider_subscription_item_id == "si_seated_1"
  end

  test "11. custom provider with incomplete responses, legitimate zero quantity, fail-closed malformed quantity, and legacy fallback",
       %{t1: t1} do
    # A) Incomplete custom provider payload (no items, no quantity) -> quantity = nil (not 1)
    incomplete_obj = %{
      "id" => "sub_custom_1",
      "customer" => "cus_qty_1",
      "status" => "active",
      "price" => "price_custom"
    }

    assert {:ok, sub} =
             WebhookSync.sync_event(
               sub_event("evt_cust_1", "customer.subscription.created", t1, incomplete_obj),
               @sync_opts
             )

    assert sub.price_id == "price_custom"
    assert is_nil(sub.quantity)
    assert is_nil(sub.provider_subscription_item_id)

    # B) Explicit nil quantity (metered / custom provider contract) remains nil cleanly
    t_nil = DateTime.add(t1, 10, :second)

    assert {:ok, synced_nil} =
             WebhookSync.sync_event(
               sub_event(
                 "evt_cust_nil",
                 "customer.subscription.updated",
                 t_nil,
                 Map.put(incomplete_obj, "quantity", nil)
               ),
               @sync_opts
             )

    assert is_nil(synced_nil.quantity)

    # C) Top-level custom provider valid quantity & subscription_item_id are persisted
    t_valid = DateTime.add(t1, 20, :second)

    custom_valid = %{
      "id" => "sub_custom_1",
      "customer" => "cus_qty_1",
      "status" => "active",
      "price" => "price_custom",
      "quantity" => 9,
      "subscription_item_id" => "custom_item_9"
    }

    assert {:ok, synced_custom} =
             WebhookSync.sync_event(
               sub_event(
                 "evt_cust_valid",
                 "customer.subscription.updated",
                 t_valid,
                 custom_valid
               ),
               @sync_opts
             )

    assert synced_custom.quantity == 9
    assert synced_custom.provider_subscription_item_id == "custom_item_9"

    # D) Malformed quantity values fail closed BEFORE last_reconciled_at and NEVER erase valid quantity=9
    for {bad_qty, idx} <- Enum.with_index([-5, "10", 2.5, true, %{"seats" => 5}], 1) do
      ts = DateTime.add(t_valid, idx * 10, :second)
      bad_obj = Map.put(custom_valid, "quantity", bad_qty)

      assert {:error, :invalid_quantity} =
               WebhookSync.sync_event(
                 sub_event(
                   "evt_cust_bad_pre_#{idx}",
                   "customer.subscription.updated",
                   ts,
                   bad_obj
                 ),
                 @sync_opts
               )

      persisted = Ash.get!(PostgresSubscription, synced_custom.id, @opts)
      assert persisted.quantity == 9
      assert DateTime.compare(persisted.last_event_created_at, t_valid) == :eq
    end

    # E) Legitimately zero quantity (0 contracted seats) persists exact 0 (never nil, never 1)
    t_zero = DateTime.add(t_valid, 100, :second)
    zero_obj = Map.put(custom_valid, "quantity", 0)

    assert {:ok, synced_zero} =
             WebhookSync.sync_event(
               sub_event("evt_cust_zero", "customer.subscription.updated", t_zero, zero_obj),
               @sync_opts
             )

    assert synced_zero.quantity === 0

    # F) Legacy custom provider without update_quantity/3 continues falling back to swap_plan/3
    assert {:ok, _} =
             AshBilling.update_quantity("sub_legacy_fallback", 12,
               provider: LegacyFallbackProvider,
               test_pid: self()
             )

    assert_received {:legacy_swap_plan, "sub_legacy_fallback", "price_legacy", swap_opts}
    assert Keyword.get(swap_opts, :quantity) == 12
    assert Keyword.get(swap_opts, :subscription_item_id) == "si_legacy_1"
  end

  test "11b. regression: fail-closed malformed quantity and zero-seat semantics preserve valid quantity both pre- and post-reconciliation",
       %{t1: t1} do
    # Create single-item Stripe subscription with valid quantity=10
    obj_10 =
      stripe_sub_object("sub_qty_guard", "cus_qty_1", "price_pro", 10, item_id: "si_qty_guard")

    assert {:ok, created} =
             WebhookSync.sync_event(
               sub_event("evt_guard_init", "customer.subscription.created", t1, obj_10),
               @sync_opts
             )

    assert created.quantity == 10

    # 1) Pre-reconciliation: malformed Stripe item quantity fails closed via Plug (HTTP 500)
    #    and preserves quantity=10 without marking event processed.
    secret = "whsec_qty_malformed"
    t2 = DateTime.add(t1, 30, :second)

    malformed_item_obj =
      stripe_sub_object("sub_qty_guard", "cus_qty_1", "price_pro", "10", item_id: "si_qty_guard")

    malformed_payload =
      Jason.encode!(
        sub_event("evt_guard_bad_plug", "customer.subscription.updated", t2, malformed_item_obj)
      )

    plug_opts =
      AshBilling.Plug.init(
        webhook_secret: secret,
        expected_livemode: false,
        customer_resource: PostgresCustomer,
        subscription_resource: PostgresSubscription,
        deduplication_resource: PostgresWebhookEvent,
        domain: PostgresDomain
      )

    conn =
      conn(:post, "/webhooks/stripe", malformed_payload)
      |> put_req_header("stripe-signature", sign_webhook(malformed_payload, secret))
      |> AshBilling.Plug.call(plug_opts)

    assert conn.status == 500
    assert Ash.get!(PostgresSubscription, created.id, @opts).quantity == 10
    assert Ash.get!(PostgresWebhookEvent, "evt_guard_bad_plug", @opts).status == :failed

    # 2) Reconcile subscription so last_reconciled_at is set
    assert {:ok, reconciled} =
             AshBilling.reconcile_subscription(created,
               provider: CountingProvider,
               live_response: obj_10,
               domain: PostgresDomain,
               authorize?: false
             )

    checkpoint_1 = reconciled.last_reconciled_at
    assert %DateTime{} = checkpoint_1
    assert reconciled.quantity == 10

    # 3) Post-reconciliation: malformed webhook quantities (-5, "10", 2.5) fail closed BEFORE
    #    calling Stripe and preserve quantity=10, last_event_created_at, and last_reconciled_at.
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    for {bad_qty, idx} <- Enum.with_index([-5, "10", 2.5], 1) do
      ts = DateTime.add(checkpoint_1, 120 + idx, :second)

      bad_obj =
        stripe_sub_object("sub_qty_guard", "cus_qty_1", "price_pro", bad_qty,
          item_id: "si_qty_guard"
        )

      assert {:error, :invalid_quantity} =
               WebhookSync.sync_event(
                 sub_event(
                   "evt_guard_post_bad_#{idx}",
                   "customer.subscription.updated",
                   ts,
                   bad_obj
                 ),
                 @sync_opts ++
                   [provider: CountingProvider, counter: counter, live_response: obj_10]
               )
    end

    assert Agent.get(counter, & &1) == 0
    after_bad_post = Ash.get!(PostgresSubscription, created.id, @opts)
    assert after_bad_post.quantity == 10
    assert DateTime.compare(after_bad_post.last_reconciled_at, checkpoint_1) == :eq

    # 4) Post-reconciliation: malformed quantity returned by LIVE provider GET also fails closed
    t_live_bad = DateTime.add(checkpoint_1, 150, :second)

    valid_incoming_20 =
      stripe_sub_object("sub_qty_guard", "cus_qty_1", "price_pro", 20, item_id: "si_qty_guard")

    malformed_live_obj =
      stripe_sub_object("sub_qty_guard", "cus_qty_1", "price_pro", -3, item_id: "si_qty_guard")

    assert {:error, :invalid_quantity} =
             WebhookSync.sync_event(
               sub_event(
                 "evt_guard_live_bad",
                 "customer.subscription.updated",
                 t_live_bad,
                 valid_incoming_20
               ),
               @sync_opts ++
                 [provider: CountingProvider, counter: counter, live_response: malformed_live_obj]
             )

    assert Agent.get(counter, & &1) == 1
    assert Ash.get!(PostgresSubscription, created.id, @opts).quantity == 10

    # 5) Direct reconcile_subscription/2 with malformed live quantity also fails closed
    assert {:error, :invalid_quantity} =
             AshBilling.reconcile_subscription(after_bad_post,
               provider: CountingProvider,
               live_response: malformed_live_obj,
               domain: PostgresDomain,
               authorize?: false
             )

    assert Ash.get!(PostgresSubscription, created.id, @opts).quantity == 10

    # 6) Post-reconciliation legitimate quantity=0:
    #    - Stale 0 webhook when Stripe still has 10 -> re-verifies and preserves 10
    t_zero_stale = DateTime.add(checkpoint_1, 180, :second)

    obj_0 =
      stripe_sub_object("sub_qty_guard", "cus_qty_1", "price_pro", 0, item_id: "si_qty_guard")

    assert {:ok, preserved_10} =
             WebhookSync.sync_event(
               sub_event(
                 "evt_guard_zero_stale",
                 "customer.subscription.updated",
                 t_zero_stale,
                 obj_0
               ),
               @sync_opts ++ [provider: CountingProvider, counter: counter, live_response: obj_10]
             )

    assert preserved_10.quantity == 10

    #    - Legitimate 0 webhook confirmed by live Stripe -> persists exact 0 (never nil, never 1)
    t_zero_live = DateTime.add(checkpoint_1, 210, :second)

    assert {:ok, confirmed_0} =
             WebhookSync.sync_event(
               sub_event(
                 "evt_guard_zero_live",
                 "customer.subscription.updated",
                 t_zero_live,
                 obj_0
               ),
               @sync_opts ++ [provider: CountingProvider, counter: counter, live_response: obj_0]
             )

    assert confirmed_0.quantity === 0

    #    - Delayed stale 10 webhook while live Stripe is 0 -> preserves exact 0
    t_stale_10 = DateTime.add(checkpoint_1, 240, :second)

    assert {:ok, preserved_0} =
             WebhookSync.sync_event(
               sub_event(
                 "evt_guard_stale_10",
                 "customer.subscription.updated",
                 t_stale_10,
                 obj_10
               ),
               @sync_opts ++ [provider: CountingProvider, counter: counter, live_response: obj_0]
             )

    assert preserved_0.quantity === 0

    #    - Transitioning to legitimately nil/metered plan confirmed by live Stripe -> clears cleanly
    t_metered_live = DateTime.add(checkpoint_1, 270, :second)

    obj_metered =
      stripe_sub_object("sub_qty_guard", "cus_qty_1", "price_metered", :omit,
        item_id: "si_qty_guard"
      )

    assert {:ok, confirmed_metered} =
             WebhookSync.sync_event(
               sub_event(
                 "evt_guard_metered",
                 "customer.subscription.updated",
                 t_metered_live,
                 obj_metered
               ),
               @sync_opts ++
                 [provider: CountingProvider, counter: counter, live_response: obj_metered]
             )

    assert confirmed_metered.price_id == "price_metered"
    assert is_nil(confirmed_metered.quantity)
  end

  test "12. rejects multi-item non-terminal subscriptions, clears fields on terminal multi-item, and prevents canceled reactivation via quantity webhook",
       %{t1: t1} do
    obj_valid =
      stripe_sub_object("sub_multi_qty", "cus_qty_1", "price_pro", 10, item_id: "si_single_1")

    assert {:ok, created} =
             WebhookSync.sync_event(
               sub_event("evt_multi_init", "customer.subscription.created", t1, obj_valid),
               @sync_opts
             )

    assert created.quantity == 10

    t2 = DateTime.add(t1, 30, :second)

    multi_item_active = %{
      "id" => "sub_multi_qty",
      "customer" => "cus_qty_1",
      "status" => "active",
      "items" => %{
        "data" => [
          %{"id" => "si_1", "price" => %{"id" => "price_pro"}, "quantity" => 10},
          %{"id" => "si_2", "price" => %{"id" => "price_addon"}, "quantity" => 5}
        ]
      }
    }

    assert {:error, :unsupported_subscription_items} =
             WebhookSync.sync_event(
               sub_event(
                 "evt_multi_active",
                 "customer.subscription.updated",
                 t2,
                 multi_item_active
               ),
               @sync_opts
             )

    # Prior supported state (quantity 10, price_pro) is preserved
    reloaded = Ash.get!(PostgresSubscription, created.id, @opts)
    assert reloaded.quantity == 10
    assert reloaded.price_id == "price_pro"

    # Truncated has_more: true is also rejected
    truncated_active = %{
      "id" => "sub_multi_qty",
      "customer" => "cus_qty_1",
      "status" => "active",
      "items" => %{
        "has_more" => true,
        "data" => [%{"id" => "si_1", "price" => %{"id" => "price_pro"}, "quantity" => 99}]
      }
    }

    assert {:error, :unsupported_subscription_items} =
             WebhookSync.sync_event(
               sub_event(
                 "evt_multi_trunc",
                 "customer.subscription.updated",
                 t2,
                 truncated_active
               ),
               @sync_opts
             )

    assert Ash.get!(PostgresSubscription, created.id, @opts).quantity == 10

    # Terminal multi-item event revokes access cleanly without picking an arbitrary item/quantity
    t3 = DateTime.add(t1, 60, :second)
    multi_item_canceled = Map.put(multi_item_active, "status", "canceled")

    assert {:ok, canceled} =
             WebhookSync.sync_event(
               sub_event(
                 "evt_multi_cancel",
                 "customer.subscription.deleted",
                 t3,
                 multi_item_canceled
               ),
               @sync_opts
             )

    assert canceled.status == :canceled
    assert is_nil(canceled.price_id)
    assert is_nil(canceled.quantity)
    assert is_nil(canceled.provider_subscription_item_id)

    # Delayed active quantity webhook NEVER reactivates a canceled Stripe subscription
    t4 = DateTime.add(t1, 90, :second)

    delayed_active_qty =
      stripe_sub_object("sub_multi_qty", "cus_qty_1", "price_pro", 50, item_id: "si_single_1")

    assert {:ok, still_canceled} =
             WebhookSync.sync_event(
               sub_event(
                 "evt_after_cancel_qty",
                 "customer.subscription.updated",
                 t4,
                 delayed_active_qty
               ),
               @sync_opts
             )

    assert still_canceled.status == :canceled
    assert is_nil(still_canceled.quantity)
  end

  test "13. Stripe HTTP failure during post-reconciliation quantity re-verification fails closed",
       %{t1: t1} do
    obj_10 =
      stripe_sub_object("sub_http_fail_qty", "cus_qty_1", "price_pro", 10,
        item_id: "si_http_fail"
      )

    assert {:ok, created} =
             WebhookSync.sync_event(
               sub_event("evt_hf_1", "customer.subscription.created", t1, obj_10),
               @sync_opts
             )

    assert {:ok, reconciled} =
             AshBilling.reconcile_subscription(created,
               provider: CountingProvider,
               live_response: obj_10,
               domain: PostgresDomain,
               authorize?: false
             )

    t2 = DateTime.add(reconciled.last_reconciled_at, 120, :second)

    obj_99 =
      stripe_sub_object("sub_http_fail_qty", "cus_qty_1", "price_pro", 99,
        item_id: "si_http_fail"
      )

    assert {:error, {:reconciliation_failed, %{status: 503, error: "service_unavailable"}}} =
             WebhookSync.sync_event(
               sub_event("evt_hf_2", "customer.subscription.updated", t2, obj_99),
               @sync_opts ++
                 [
                   provider: CountingProvider,
                   live_response: {:error, %{status: 503, error: "service_unavailable"}}
                 ]
             )

    persisted = Ash.get!(PostgresSubscription, created.id, @opts)
    assert persisted.quantity == 10
    assert DateTime.compare(persisted.last_event_created_at, t1) == :eq
  end

  test "14. protects quantity and provider_subscription_item_id from client writes and isolates multitenant subscriptions",
       %{t1: t1} do
    # A) Write protection on default_accept :* resource
    create_action = Ash.Resource.Info.primary_action!(ProtectedWildcardSubscription, :create)
    update_action = Ash.Resource.Info.primary_action!(ProtectedWildcardSubscription, :update)

    refute :quantity in create_action.accept
    refute :provider_subscription_item_id in create_action.accept
    refute :quantity in update_action.accept
    refute :provider_subscription_item_id in update_action.accept

    # Direct client attempt to pass quantity or provider_subscription_item_id fails
    assert {:error, _} =
             ProtectedWildcardSubscription
             |> Ash.Changeset.for_create(
               :create,
               %{quantity: 999, provider_subscription_item_id: "si_forged"},
               domain: ProtectedDomain,
               authorize?: false
             )
             |> Ash.create()

    # B) Multitenant isolation: same provider_subscription_id across two tenants stays isolated
    cust_a =
      Ash.create!(
        PostgresScopedCustomer,
        %{stripe_customer_id: "cus_tenant_shared"},
        domain: PostgresDomain,
        tenant: "tenant_a",
        authorize?: false
      )

    cust_b =
      Ash.create!(
        PostgresScopedCustomer,
        %{stripe_customer_id: "cus_tenant_shared"},
        domain: PostgresDomain,
        tenant: "tenant_b",
        authorize?: false
      )

    assert cust_a.id != cust_b.id

    scoped_opts = fn tenant ->
      [
        domain: PostgresDomain,
        tenant: tenant,
        authorize?: false,
        customer_resource: PostgresScopedCustomer,
        subscription_resource: PostgresOwnedScopedSubscription
      ]
    end

    obj_a =
      stripe_sub_object("sub_shared_id", "cus_tenant_shared", "price_pro", 5,
        item_id: "si_tenant_a"
      )

    obj_b =
      stripe_sub_object("sub_shared_id", "cus_tenant_shared", "price_basic", 25,
        item_id: "si_tenant_b"
      )

    assert {:ok, sub_a} =
             WebhookSync.sync_event(
               sub_event("evt_ta_1", "customer.subscription.created", t1, obj_a),
               scoped_opts.("tenant_a")
             )

    assert {:ok, sub_b} =
             WebhookSync.sync_event(
               sub_event("evt_tb_1", "customer.subscription.created", t1, obj_b),
               scoped_opts.("tenant_b")
             )

    assert sub_a.quantity == 5
    assert sub_b.quantity == 25

    # Reconciling tenant_a to 50 seats MUST NOT touch tenant_b
    live_a_50 =
      stripe_sub_object("sub_shared_id", "cus_tenant_shared", "price_pro", 50,
        item_id: "si_tenant_a"
      )

    assert {:ok, reconciled_a} =
             AshBilling.reconcile_subscription(sub_a,
               provider: CountingProvider,
               live_response: live_a_50,
               domain: PostgresDomain,
               tenant: "tenant_a",
               authorize?: false
             )

    assert reconciled_a.quantity == 50

    reloaded_b =
      Ash.get!(PostgresOwnedScopedSubscription, sub_b.id,
        domain: PostgresDomain,
        tenant: "tenant_b",
        authorize?: false
      )

    assert reloaded_b.quantity == 25
    assert reloaded_b.provider_subscription_item_id == "si_tenant_b"
  end
end
