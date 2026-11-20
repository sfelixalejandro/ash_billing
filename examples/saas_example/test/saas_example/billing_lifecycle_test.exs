defmodule SaasExample.BillingLifecycleTest do
  use SaasExampleWeb.ConnCase, async: false

  alias SaasExample.{Accounts, Billing, Workspace}
  alias SaasExample.Billing.{Catalog, Subscription}

  test "full Stripe lifecycle: Checkout -> Webhook -> Portal -> Swap Plan -> Quantity -> Cancel -> Resume -> Reconcile" do
    user = create_user!(%{email: "founder@lifecycle.example", name: "Founder"})
    test_pid = self()

    configure_stripe_stub(:stripe_lifecycle, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:stripe_http, conn.method, conn.request_path, body})

      case {conn.method, conn.request_path} do
        {"POST", "/v1/customers"} ->
          Req.Test.json(conn, %{"id" => "cus_life_1", "email" => "founder@lifecycle.example"})

        {"POST", "/v1/checkout/sessions"} ->
          Req.Test.json(conn, %{
            "id" => "cs_test_life_1",
            "url" => "https://checkout.stripe.com/c/pay/cs_test_life_1"
          })

        {"POST", "/v1/billing_portal/sessions"} ->
          Req.Test.json(conn, %{
            "id" => "bps_test_life_1",
            "url" => "https://billing.stripe.com/p/session/bps_test_life_1"
          })

        {"GET", "/v1/subscriptions/sub_life_1"} ->
          # Authoritative live state in Stripe (used by swap_plan quantity preservation,
          # update_quantity optimistic price check, and reconcile_subscription)
          state = Process.get(:live_sub_state) || :initial

          payload =
            case state do
              :initial ->
                stripe_subscription_payload(
                  "sub_life_1",
                  "cus_life_1",
                  Catalog.price_id!(:starter),
                  3,
                  item_id: "si_life_1"
                )

              :reconciled_enterprise ->
                stripe_subscription_payload(
                  "sub_life_1",
                  "cus_life_1",
                  Catalog.price_id!(:enterprise),
                  7,
                  item_id: "si_life_1"
                )
            end

          Req.Test.json(conn, payload)

        {"POST", "/v1/subscriptions/sub_life_1"} ->
          Req.Test.json(
            conn,
            stripe_subscription_payload(
              "sub_life_1",
              "cus_life_1",
              Catalog.price_id!(:pro),
              3,
              item_id: "si_life_1"
            )
          )
      end
    end)

    # 1. Server-catalog rejects unknown price_id before hitting Stripe
    bad_checkout =
      post(log_in_user(build_conn(), user), "/billing/checkout", %{
        "plan" => "price_attacker_free_override",
        "quantity" => "1"
      })

    assert redirected_to(bad_checkout) == "/dashboard"

    assert Phoenix.Flash.get(bad_checkout.assigns.flash, :error) =~
             "not in the server billing catalog"

    refute_received {:stripe_http, _, _, _}

    # 2. Valid Checkout creates & persists Stripe Customer first, then creates Checkout session
    checkout_conn =
      post(log_in_user(build_conn(), user), "/billing/checkout", %{
        "plan" => "starter",
        "quantity" => "3"
      })

    assert redirected_to(checkout_conn) == "https://checkout.stripe.com/c/pay/cs_test_life_1"
    assert_received {:stripe_http, "POST", "/v1/customers", _}
    assert_received {:stripe_http, "POST", "/v1/checkout/sessions", checkout_body}
    assert checkout_body =~ Catalog.price_id!(:starter)
    assert checkout_body =~ "quantity%5D=3"

    {:ok, persisted_user} = Accounts.load_fresh_actor(user.id)
    assert persisted_user.stripe_customer_id == "cus_life_1"

    # 3. Signed Stripe webhook delivers customer.subscription.created (Starter, quantity: 3)
    created_event = %{
      "id" => "evt_life_created_1",
      "type" => "customer.subscription.created",
      "livemode" => false,
      "created" => System.system_time(:second),
      "data" => %{
        "object" =>
          stripe_subscription_payload(
            "sub_life_1",
            "cus_life_1",
            Catalog.price_id!(:starter),
            3,
            item_id: "si_life_1"
          )
      }
    }

    wh_conn = post_signed_webhook(build_conn(), created_event)
    assert wh_conn.status == 200

    {:ok, synced_user} = Accounts.load_fresh_actor(user.id)
    sub = Billing.primary_subscription(synced_user)
    assert sub.provider_subscription_id == "sub_life_1"
    assert sub.price_id == Catalog.price_id!(:starter)
    assert sub.quantity == 3
    assert sub.provider_subscription_item_id == "si_life_1"
    assert AshBilling.subscribed?(synced_user)

    # 4. Billing Portal redirects to Stripe Portal
    portal_conn = post(log_in_user(build_conn(), synced_user), "/billing/portal")
    assert redirected_to(portal_conn) == "https://billing.stripe.com/p/session/bps_test_life_1"
    assert_received {:stripe_http, "POST", "/v1/billing_portal/sessions", _}

    # 5. Plan Swap (Starter -> Pro) preserves quantity
    swap_conn =
      post(log_in_user(build_conn(), synced_user), "/billing/swap-plan", %{
        "subscription_id" => sub.id,
        "plan" => "pro"
      })

    assert redirected_to(swap_conn) == "/dashboard"
    assert Phoenix.Flash.get(swap_conn.assigns.flash, :info) =~ "Plan swap requested"
    assert_received {:stripe_http, "POST", "/v1/subscriptions/sub_life_1", swap_body}
    assert swap_body =~ Catalog.price_id!(:pro)

    # 6. Quantity Update sends ONLY item id + quantity (omitting price) with optimistic price check
    qty_conn =
      post(log_in_user(build_conn(), synced_user), "/billing/quantity", %{
        "subscription_id" => sub.id,
        "quantity" => "5"
      })

    assert redirected_to(qty_conn) == "/dashboard"
    assert Phoenix.Flash.get(qty_conn.assigns.flash, :info) =~ "Seat quantity updated"
    assert_received {:stripe_http, "POST", "/v1/subscriptions/sub_life_1", qty_body}
    assert qty_body =~ "quantity%5D=5"
    refute qty_body =~ "price%5D="

    # 7. Cancel at period end + Resume
    cancel_conn =
      post(log_in_user(build_conn(), synced_user), "/billing/cancel", %{
        "subscription_id" => sub.id
      })

    assert redirected_to(cancel_conn) == "/dashboard"
    assert Phoenix.Flash.get(cancel_conn.assigns.flash, :info) =~ "cancel at period end"
    assert_received {:stripe_http, "POST", "/v1/subscriptions/sub_life_1", cancel_body}
    assert cancel_body =~ "cancel_at_period_end=true"

    resume_conn =
      post(log_in_user(build_conn(), synced_user), "/billing/resume", %{
        "subscription_id" => sub.id
      })

    assert redirected_to(resume_conn) == "/dashboard"
    assert Phoenix.Flash.get(resume_conn.assigns.flash, :info) =~ "resumed"
    assert_received {:stripe_http, "POST", "/v1/subscriptions/sub_life_1", resume_body}
    assert resume_body =~ "cancel_at_period_end=false"

    # 8. Reconcile recovers dropped webhooks and updates local PostgreSQL + last_reconciled_at
    configure_stripe_stub(:stripe_lifecycle_reconcile, fn conn ->
      Req.Test.json(
        conn,
        stripe_subscription_payload(
          "sub_life_1",
          "cus_life_1",
          Catalog.price_id!(:enterprise),
          7,
          item_id: "si_life_1"
        )
      )
    end)

    rec_conn =
      post(log_in_user(build_conn(), synced_user), "/billing/reconcile", %{
        "subscription_id" => sub.id
      })

    assert redirected_to(rec_conn) == "/dashboard"
    assert Phoenix.Flash.get(rec_conn.assigns.flash, :info) =~ "reconciled authoritatively"

    reconciled_sub = Ash.get!(Subscription, sub.id, domain: Billing, authorize?: false)
    assert reconciled_sub.price_id == Catalog.price_id!(:enterprise)
    assert reconciled_sub.quantity == 7
    assert %DateTime{} = reconciled_sub.last_reconciled_at

    # Verify Enterprise access is now immediately active via HasPrice policy
    {:ok, enterprise_user} = Accounts.load_fresh_actor(user.id)
    {:ok, report} = Workspace.create_report(enterprise_user, %{title: "Post-Reconcile Audit"})
    assert {:ok, audited} = Workspace.audit_report(enterprise_user, report.id)
    assert %DateTime{} = audited.audited_at
  end
end
