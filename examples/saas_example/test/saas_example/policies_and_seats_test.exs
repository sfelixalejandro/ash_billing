defmodule SaasExample.PoliciesAndSeatsTest do
  use SaasExampleWeb.ConnCase, async: false

  alias SaasExample.{Accounts, Billing, Workspace}
  alias SaasExample.Billing.Catalog

  test "enforces AshBilling.Checks.Subscribed and AshBilling.Checks.HasPrice across Free, Starter, Pro, Enterprise, and Canceled tiers" do
    free_user = create_user!(%{email: "tier_free@example.com"})

    starter_user =
      create_user!(%{email: "tier_starter@example.com", stripe_customer_id: "cus_t_s"})

    pro_user = create_user!(%{email: "tier_pro@example.com", stripe_customer_id: "cus_t_p"})
    ent_user = create_user!(%{email: "tier_ent@example.com", stripe_customer_id: "cus_t_e"})

    starter_sub =
      create_subscription!(starter_user, %{
        provider_subscription_id: "sub_t_starter",
        price_id: Catalog.price_id!(:starter),
        quantity: 2
      })

    _pro_sub =
      create_subscription!(pro_user, %{
        provider_subscription_id: "sub_t_pro",
        price_id: Catalog.price_id!(:pro),
        quantity: 5
      })

    _ent_sub =
      create_subscription!(ent_user, %{
        provider_subscription_id: "sub_t_ent",
        price_id: Catalog.price_id!(:enterprise),
        quantity: 10
      })

    {:ok, starter_user} = Accounts.load_fresh_actor(starter_user.id)
    {:ok, pro_user} = Accounts.load_fresh_actor(pro_user.id)
    {:ok, ent_user} = Accounts.load_fresh_actor(ent_user.id)

    # Free user denied by Subscribed
    assert {:error, %Ash.Error.Forbidden{}} =
             Workspace.create_report(free_user, %{title: "Blocked"})

    assert {:error, :subscription_required} =
             Workspace.assign_seat(free_user, "blocked@example.com")

    # Starter user: allowed by Subscribed, DENIED by HasPrice (Pro Export & Enterprise Audit)
    {:ok, starter_report} = Workspace.create_report(starter_user, %{title: "Starter Report"})

    assert {:error, %Ash.Error.Forbidden{}} =
             Workspace.export_report(starter_user, starter_report.id)

    assert {:error, %Ash.Error.Forbidden{}} =
             Workspace.audit_report(starter_user, starter_report.id)

    # Pro user: allowed by Pro/Enterprise HasPrice (Export), DENIED by Enterprise-only HasPrice (Audit)
    {:ok, pro_report} = Workspace.create_report(pro_user, %{title: "Pro Report"})
    assert {:ok, exported} = Workspace.export_report(pro_user, pro_report.id)
    assert %DateTime{} = exported.exported_at
    assert {:error, %Ash.Error.Forbidden{}} = Workspace.audit_report(pro_user, pro_report.id)

    # Enterprise user: allowed for both Pro Export and Enterprise Audit
    {:ok, ent_report} = Workspace.create_report(ent_user, %{title: "Enterprise Report"})
    assert {:ok, ent_exp} = Workspace.export_report(ent_user, ent_report.id)
    assert %DateTime{} = ent_exp.exported_at
    assert {:ok, ent_aud} = Workspace.audit_report(ent_user, ent_report.id)
    assert %DateTime{} = ent_aud.audited_at

    # Revocation freshness: once subscription is canceled via webhook, immediate reload revokes access
    canceled_event = %{
      "id" => "evt_tier_cancel_1",
      "type" => "customer.subscription.deleted",
      "livemode" => false,
      "created" => System.system_time(:second),
      "data" => %{
        "object" =>
          stripe_subscription_payload(
            starter_sub.provider_subscription_id,
            "cus_t_s",
            Catalog.price_id!(:starter),
            2,
            status: "canceled"
          )
      }
    }

    assert post_signed_webhook(build_conn(), canceled_event).status == 200

    # HTTP request reloads fresh actor and immediately denies report creation
    denied_conn =
      post(log_in_user(build_conn(), starter_user), "/workspace/reports", %{
        "title" => "After Cancel"
      })

    assert redirected_to(denied_conn) == "/dashboard"
    assert Phoenix.Flash.get(denied_conn.assigns.flash, :error) =~ "Active subscription required"
  end

  test "enforces contracted quantity seat limits, seat-downsize protection, nil/zero quantity fail-closed, and concurrent FOR UPDATE locking" do
    user = create_user!(%{email: "seats_owner@example.com", stripe_customer_id: "cus_seats_1"})

    sub =
      create_subscription!(user, %{
        provider_subscription_id: "sub_seats_1",
        price_id: Catalog.price_id!(:pro),
        quantity: 2,
        provider_subscription_item_id: "si_seats_1"
      })

    {:ok, user} = Accounts.load_fresh_actor(user.id)

    # Assign 2 seats up to contracted quantity: 2
    assert {:ok, seat1} = Workspace.assign_seat(user, "member1@team.example")
    assert {:ok, _seat2} = Workspace.assign_seat(user, "member2@team.example")

    # 3rd seat fails closed with :seat_limit_reached
    assert {:error, {:seat_limit_reached, 2, 2}} =
             Workspace.assign_seat(user, "member3@team.example")

    # Cannot reduce Stripe quantity below 2 active seats (never hits Stripe!)
    configure_stripe_stub(:stripe_should_not_be_called, fn _conn ->
      flunk("Stripe should not be called when active seats exceed requested new quantity")
    end)

    assert {:error, {:seats_exceed_new_quantity, 2}} =
             Billing.update_quantity(user, sub.id, 1)

    # Revoking 1 seat frees capacity for a new member
    assert {:ok, _revoked} = Workspace.revoke_seat(user, seat1.id)
    assert Workspace.active_seat_count(user) == 1

    # Concurrency test: 5 parallel seat assignments racing for the 1 remaining slot
    # PostgreSQL FOR UPDATE row lock ensures EXACTLY 1 succeeds and 4 fail with :seat_limit_reached
    results =
      1..5
      |> Task.async_stream(
        fn i -> Workspace.assign_seat(user, "race_#{i}@team.example") end,
        max_concurrency: 5,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, res} -> res end)

    successes = Enum.count(results, &match?({:ok, _}, &1))
    limit_errors = Enum.count(results, &match?({:error, {:seat_limit_reached, 2, 2}}, &1))

    assert successes == 1
    assert limit_errors == 4
    assert Workspace.active_seat_count(user) == 2

    # Zero or nil contracted seats fails closed with :no_contracted_seats
    zero_user = create_user!(%{email: "zero_seats@example.com", stripe_customer_id: "cus_zero"})

    create_subscription!(zero_user, %{
      provider_subscription_id: "sub_zero_seats",
      price_id: Catalog.price_id!(:starter),
      quantity: 0
    })

    {:ok, zero_user} = Accounts.load_fresh_actor(zero_user.id)
    assert {:error, :no_contracted_seats} = Workspace.assign_seat(zero_user, "x@zero.example")

    nil_user = create_user!(%{email: "nil_seats@example.com", stripe_customer_id: "cus_nil"})

    create_subscription!(nil_user, %{
      provider_subscription_id: "sub_nil_seats",
      price_id: Catalog.price_id!(:starter),
      quantity: nil
    })

    {:ok, nil_user} = Accounts.load_fresh_actor(nil_user.id)
    assert {:error, :no_contracted_seats} = Workspace.assign_seat(nil_user, "x@nil.example")
  end
end
