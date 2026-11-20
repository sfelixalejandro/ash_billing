defmodule SaasExample.WebhooksAndResilienceTest do
  use SaasExampleWeb.ConnCase, async: false

  alias SaasExample.{Accounts, Billing, Repo}
  alias SaasExample.Billing.{Catalog, Subscription, WebhookEvent}

  require Ash.Query

  test "verifies Stripe HMAC signatures, rejects live events in test mode, and deduplicates via PostgreSQL" do
    user = create_user!(%{email: "wh_dedup@example.com", stripe_customer_id: "cus_wh_1"})

    event = %{
      "id" => "evt_wh_dedup_1",
      "type" => "customer.subscription.created",
      "livemode" => false,
      "created" => System.system_time(:second),
      "data" => %{
        "object" =>
          stripe_subscription_payload(
            "sub_wh_1",
            "cus_wh_1",
            Catalog.price_id!(:pro),
            4,
            item_id: "si_wh_1"
          )
      }
    }

    # 1. Invalid HMAC signature -> 400 and zero DB mutations
    bad_sig_conn = post_signed_webhook(build_conn(), event, signature: "t=12345,v1=deadbeef")
    assert bad_sig_conn.status == 400
    assert {:ok, []} = Ash.read(Subscription, domain: Billing, authorize?: false)

    # 2. Livemode mismatch (livemode: true when expected_livemode: false) -> 400 fail-closed
    live_event = Map.put(event, "livemode", true)
    live_conn = post_signed_webhook(build_conn(), live_event)
    assert live_conn.status == 400
    assert {:ok, []} = Ash.read(Subscription, domain: Billing, authorize?: false)

    # 3. Valid signed webhook succeeds and persists subscription + processed WebhookEvent
    ok_conn = post_signed_webhook(build_conn(), event)
    assert ok_conn.status == 200

    {:ok, loaded_user} = Accounts.load_fresh_actor(user.id)
    assert Billing.primary_subscription(loaded_user).quantity == 4

    ev_record =
      WebhookEvent
      |> Ash.Query.filter(event_id == "evt_wh_dedup_1")
      |> Ash.read_one!(domain: Billing, authorize?: false)

    assert ev_record.status == :processed

    # 4. Duplicate redelivery returns 200 already_processed without re-running sync
    dup_conn = post_signed_webhook(build_conn(), event)
    assert dup_conn.status == 200
    assert Jason.decode!(dup_conn.resp_body)["status"] == "already_processed"
  end

  test "fails closed with HTTP 500 on Stripe outage during post-reconciliation re-verification and releases dedup lease for retry" do
    user = create_user!(%{email: "outage@example.com", stripe_customer_id: "cus_outage_1"})

    sub =
      create_subscription!(user, %{
        provider_subscription_id: "sub_outage_1",
        price_id: Catalog.price_id!(:enterprise),
        quantity: 10,
        provider_subscription_item_id: "si_outage_1",
        last_reconciled_at: DateTime.utc_now()
      })

    {:ok, user} = Accounts.load_fresh_actor(user.id)

    # Simulate Stripe 503 outage
    configure_stripe_stub(:stripe_503, fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => %{"message" => "Stripe temporarily unavailable"}})
    end)

    # Direct billing actions fail gracefully without corrupting local PostgreSQL state
    assert {:error, _} = Billing.reconcile_user_subscription(user, sub.id)
    assert {:error, _} = Billing.swap_plan(user, sub.id, :starter)

    # Delayed stale downgrade webhook arrives after reconciliation while Stripe returns 503:
    # AshBilling MUST fail closed with HTTP 500 (never silently overwriting Enterprise -> Starter)
    # and release/mark failed the dedup lease so Stripe can safely retry.
    stale_downgrade = %{
      "id" => "evt_outage_retry_1",
      "type" => "customer.subscription.updated",
      "livemode" => false,
      "created" => System.system_time(:second) + 120,
      "data" => %{
        "object" =>
          stripe_subscription_payload(
            "sub_outage_1",
            "cus_outage_1",
            Catalog.price_id!(:starter),
            1,
            item_id: "si_outage_1"
          )
      }
    }

    outage_conn = post_signed_webhook(build_conn(), stale_downgrade)
    assert outage_conn.status == 500

    # Local state was NOT corrupted by stale downgrade
    untouched = Ash.get!(Subscription, sub.id, domain: Billing, authorize?: false)
    assert untouched.price_id == Catalog.price_id!(:enterprise)
    assert untouched.quantity == 10

    # Deduplication lease is NOT stuck in :processed (released/failed so retry succeeds when Stripe recovers)
    configure_stripe_stub(:stripe_recovered, fn conn ->
      Req.Test.json(
        conn,
        stripe_subscription_payload(
          "sub_outage_1",
          "cus_outage_1",
          Catalog.price_id!(:enterprise),
          10,
          item_id: "si_outage_1"
        )
      )
    end)

    retry_conn = post_signed_webhook(build_conn(), stale_downgrade)
    assert retry_conn.status == 200

    preserved = Ash.get!(Subscription, sub.id, domain: Billing, authorize?: false)
    assert preserved.price_id == Catalog.price_id!(:enterprise)
    assert preserved.quantity == 10
  end

  test "PostgreSQL lock contention aborts cleanly without corrupting subscription state" do
    user = create_user!(%{email: "pg_lock@example.com", stripe_customer_id: "cus_pglock_1"})

    sub =
      create_subscription!(user, %{
        provider_subscription_id: "sub_pglock_1",
        price_id: Catalog.price_id!(:pro),
        quantity: 4,
        provider_subscription_item_id: "si_pglock_1"
      })

    test_pid = self()

    # Hold a FOR UPDATE lock on the subscription row in a separate transaction
    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM subscriptions WHERE id = $1 FOR UPDATE", [
            Ecto.UUID.dump!(sub.id)
          ])

          send(test_pid, :row_locked)

          receive do
            :release -> :ok
          after
            5_000 -> :timeout
          end
        end)
      end)

    assert_receive :row_locked, 2_000

    # Concurrent transaction with short lock_timeout fails cleanly under ResourceLock without partial write
    lock_result =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '30ms'")

        res =
          AshBilling.ResourceLock.run(
            [Subscription],
            {:reconcile, sub.id},
            fn ->
              Repo.query!("SELECT id FROM subscriptions WHERE id = $1 FOR UPDATE", [
                Ecto.UUID.dump!(sub.id)
              ])
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

    assert {:error,
            {:transaction_failed, %Postgrex.Error{postgres: %{code: :lock_not_available}}}} =
             lock_result

    # Subscription row remains intact
    reloaded = Ash.get!(Subscription, sub.id, domain: Billing, authorize?: false)
    assert reloaded.price_id == Catalog.price_id!(:pro)
    assert reloaded.quantity == 4
  end

  test "recovers consistency via reconciliation when Stripe confirms quantity change but PostgreSQL fails before commit" do
    user = create_user!(%{email: "partial_fail@example.com", stripe_customer_id: "cus_pf_1"})

    sub =
      create_subscription!(user, %{
        provider_subscription_id: "sub_pf_1",
        price_id: Catalog.price_id!(:pro),
        quantity: 2,
        provider_subscription_item_id: "si_pf_1",
        last_reconciled_at: nil
      })

    {:ok, user} = Accounts.load_fresh_actor(user.id)

    {:ok, stripe_state} =
      Agent.start_link(fn -> %{quantity: 2, get_count: 0, post_count: 0} end)

    configure_stripe_stub(:stripe_partial_failure, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case {conn.method, conn.request_path} do
        {"GET", "/v1/subscriptions/sub_pf_1"} ->
          qty =
            Agent.get_and_update(stripe_state, fn st ->
              {st.quantity, %{st | get_count: st.get_count + 1}}
            end)

          Req.Test.json(
            conn,
            stripe_subscription_payload(
              "sub_pf_1",
              "cus_pf_1",
              Catalog.price_id!(:pro),
              qty,
              item_id: "si_pf_1"
            )
          )

        {"POST", "/v1/subscriptions/sub_pf_1"} ->
          [_, qty_str] = Regex.run(~r/quantity%5D=(\d+)/, body)
          new_qty = String.to_integer(qty_str)

          Agent.update(stripe_state, fn st ->
            %{st | quantity: new_qty, post_count: st.post_count + 1}
          end)

          Req.Test.json(
            conn,
            stripe_subscription_payload(
              "sub_pf_1",
              "cus_pf_1",
              Catalog.price_id!(:pro),
              new_qty,
              item_id: "si_pf_1"
            )
          )
      end
    end)

    # 1. Stripe confirms quantity 2 -> 5 (GET + POST = 2 HTTP calls), then PostgreSQL fails before commit
    assert {:error, :simulated_postgres_commit_failure} =
             Billing.update_quantity(user, sub.id, 5,
               on_before_commit: fn -> {:error, :simulated_postgres_commit_failure} end
             )

    # Verify Stripe confirmed quantity=5 (exact 1 GET + 1 POST), while PostgreSQL rolled back cleanly to 2
    assert Agent.get(stripe_state, & &1) == %{quantity: 5, get_count: 1, post_count: 1}
    rolled_back = Ash.get!(Subscription, sub.id, domain: Billing, authorize?: false)
    assert rolled_back.quantity == 2
    assert is_nil(rolled_back.last_reconciled_at)

    # 2. Subsequent reconciliation recovers PostgreSQL to quantity=5 via read-only GET (0 duplicate POSTs!)
    assert {:ok, reconciled} = Billing.reconcile_user_subscription(user, sub.id)
    assert reconciled.quantity == 5
    assert reconciled.provider_subscription_item_id == "si_pf_1"
    assert %DateTime{} = reconciled.last_reconciled_at
    assert Agent.get(stripe_state, & &1) == %{quantity: 5, get_count: 2, post_count: 1}

    # 3. Repeated reconciliation & delayed webhook are strictly idempotent (zero duplicate/invented mutations)
    assert {:ok, reconciled_again} = Billing.reconcile_user_subscription(user, sub.id)
    assert reconciled_again.quantity == 5
    assert Agent.get(stripe_state, & &1).post_count == 1

    delayed_webhook = %{
      "id" => "evt_pf_delayed_1",
      "type" => "customer.subscription.updated",
      "livemode" => false,
      "created" => System.system_time(:second),
      "data" => %{
        "object" =>
          stripe_subscription_payload(
            "sub_pf_1",
            "cus_pf_1",
            Catalog.price_id!(:pro),
            5,
            item_id: "si_pf_1"
          )
      }
    }

    assert post_signed_webhook(build_conn(), delayed_webhook).status == 200

    final_sub = Ash.get!(Subscription, sub.id, domain: Billing, authorize?: false)
    assert final_sub.quantity == 5
    assert Agent.get(stripe_state, & &1).post_count == 1
  end
end
