defmodule SaasExample.AuthAndIsolationTest do
  use SaasExampleWeb.ConnCase, async: false

  alias SaasExample.{Accounts, Billing, Workspace}
  alias SaasExample.Billing.Catalog

  test "registration, login, wrong password rejection, logout, and health endpoint", %{conn: conn} do
    # Health endpoint confirms PostgreSQL connectivity
    health_conn = get(conn, "/health")
    assert json_response(health_conn, 200) == %{"status" => "ok", "database" => "connected"}

    # Unauthenticated access to dashboard redirects to /login
    unauth_conn = get(conn, "/dashboard")
    assert redirected_to(unauth_conn) == "/login"

    # Register new user
    reg_conn =
      post(conn, "/register", %{
        "name" => "Alice Founder",
        "email" => "alice@saas.example",
        "password" => "supersecret99"
      })

    assert redirected_to(reg_conn) == "/dashboard"
    assert get_session(reg_conn, :user_id) != nil

    # Dashboard renders for authenticated user
    dash_conn =
      build_conn()
      |> init_test_session(%{user_id: get_session(reg_conn, :user_id)})
      |> get("/dashboard")

    assert html_response(dash_conn, 200) =~ "Alice Founder"
    assert html_response(dash_conn, 200) =~ "Choose a Plan"

    # Wrong password is rejected with 401
    bad_login =
      post(build_conn(), "/login", %{
        "email" => "alice@saas.example",
        "password" => "wrongpassword"
      })

    assert html_response(bad_login, 401) =~ "Invalid email or password"

    # Valid login succeeds
    good_login =
      post(build_conn(), "/login", %{
        "email" => "alice@saas.example",
        "password" => "supersecret99"
      })

    assert redirected_to(good_login) == "/dashboard"
    assert get_session(good_login, :user_id) != nil

    # Logout drops session
    logout_conn =
      build_conn()
      |> init_test_session(%{user_id: get_session(good_login, :user_id)})
      |> delete("/logout")

    assert redirected_to(logout_conn) == "/login"
  end

  test "enforces strict cross-user isolation on subscriptions, seats, reports, and billing endpoints" do
    alice = create_user!(%{email: "alice_iso@example.com", stripe_customer_id: "cus_iso_alice"})
    bob = create_user!(%{email: "bob_iso@example.com", stripe_customer_id: "cus_iso_bob"})

    alice_sub =
      create_subscription!(alice, %{
        provider_subscription_id: "sub_iso_alice",
        price_id: Catalog.price_id!(:enterprise),
        quantity: 5
      })

    _bob_sub =
      create_subscription!(bob, %{
        provider_subscription_id: "sub_iso_bob",
        price_id: Catalog.price_id!(:enterprise),
        quantity: 5
      })

    {:ok, alice} = Accounts.load_fresh_actor(alice.id)
    {:ok, bob} = Accounts.load_fresh_actor(bob.id)

    {:ok, alice_seat} = Workspace.assign_seat(alice, "teammate@alice.example")

    {:ok, alice_report} =
      Workspace.create_report(alice, %{title: "Alice Confidential Board Deck"})

    # Bob cannot fetch, swap, update quantity, cancel, resume, or reconcile Alice's subscription
    assert {:error, :not_found} = Billing.get_user_subscription(bob, alice_sub.id)
    assert {:error, :not_found} = Billing.swap_plan(bob, alice_sub.id, :starter)
    assert {:error, :not_found} = Billing.update_quantity(bob, alice_sub.id, 10)
    assert {:error, :not_found} = Billing.cancel_subscription(bob, alice_sub.id)
    assert {:error, :not_found} = Billing.resume_subscription(bob, alice_sub.id)
    assert {:error, :not_found} = Billing.reconcile_user_subscription(bob, alice_sub.id)

    # Bob cannot read Alice's seats or reports, cannot revoke Alice's seat, cannot export/audit Alice's report
    assert {:ok, []} = Workspace.list_seats(bob)
    assert {:ok, []} = Workspace.list_reports(bob)
    assert {:error, :not_found} = Workspace.revoke_seat(bob, alice_seat.id)
    assert {:error, %Ash.Error.Forbidden{}} = Workspace.export_report(bob, alice_report.id)
    assert {:error, %Ash.Error.Forbidden{}} = Workspace.audit_report(bob, alice_report.id)

    # HTTP-level cross-user isolation check on billing & workspace endpoints
    bob_conn = log_in_user(build_conn(), bob)

    resp1 =
      post(bob_conn, "/billing/swap-plan", %{
        "subscription_id" => alice_sub.id,
        "plan" => "starter"
      })

    assert resp1.status == 302
    assert Phoenix.Flash.get(resp1.assigns.flash, :error) =~ "Subscription not found"

    resp2 = post(log_in_user(build_conn(), bob), "/workspace/reports/#{alice_report.id}/audit")
    assert resp2.status == 302
    assert Phoenix.Flash.get(resp2.assigns.flash, :error) =~ "Forbidden"

    # Alice's report remained completely untouched
    reloaded_report =
      Ash.get!(SaasExample.Workspace.Report, alice_report.id,
        domain: Workspace,
        authorize?: false
      )

    assert is_nil(reloaded_report.audited_at)
    assert is_nil(reloaded_report.exported_at)
  end
end
