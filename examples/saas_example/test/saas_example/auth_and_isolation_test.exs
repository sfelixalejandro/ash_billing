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

  test "prevents privilege escalation on public registration while keeping administrative creation separate" do
    # 1. Direct Accounts.register_user/1 ignores atom and string :role inputs
    assert {:ok, atom_attempt} =
             Accounts.register_user(%{
               email: "escalate_atom@example.com",
               name: "Atom Attacker",
               password: "password1234",
               role: :admin
             })

    assert atom_attempt.role == :member

    assert {:ok, str_attempt} =
             Accounts.register_user(%{
               "email" => "escalate_str@example.com",
               "name" => "String Attacker",
               "password" => "password1234",
               "role" => "admin"
             })

    assert str_attempt.role == :member

    # 2. HTTP POST /register with role=admin always creates :member
    reg_conn =
      post(build_conn(), "/register", %{
        "name" => "HTTP Attacker",
        "email" => "escalate_http@example.com",
        "password" => "password1234",
        "role" => "admin"
      })

    assert redirected_to(reg_conn) == "/dashboard"
    user_id = get_session(reg_conn, :user_id)
    {:ok, registered} = Accounts.load_fresh_actor(user_id)
    assert registered.role == :member

    # 3. Direct Ash :create_admin action is forbidden for regular member actors
    assert {:error, %Ash.Error.Forbidden{}} =
             SaasExample.Accounts.User
             |> Ash.Changeset.for_create(:create_admin, %{
               email: "forged_admin@example.com",
               name: "Forged",
               hashed_password: SaasExample.Accounts.Password.hash("password1234")
             })
             |> Ash.create(domain: Accounts, actor: registered, authorize?: true)

    # 4. Separate administrative provisioning creates :admin
    assert {:ok, admin} =
             Accounts.create_admin_user(%{
               email: "real_admin@example.com",
               name: "Real Admin",
               password: "strongpassword99"
             })

    assert admin.role == :admin
  end

  test "enforces secure runtime configuration and blocks demo seeds outside local dev/demo environments" do
    alias SaasExample.{DemoSeeds, Security}

    valid_prod_secret = String.duplicate("a1b2c3d4", 10)

    # Production rejects missing, short, or dev/placeholder secret_key_base
    assert_raise RuntimeError, ~r/strong SECRET_KEY_BASE/, fn ->
      Security.verify_runtime_config!(env: :prod, secret_key_base: nil, api_key: "sk_test_123")
    end

    assert_raise RuntimeError, ~r/strong SECRET_KEY_BASE/, fn ->
      Security.verify_runtime_config!(
        env: :prod,
        secret_key_base: "too_short",
        api_key: "sk_test_123"
      )
    end

    assert_raise RuntimeError, ~r/development or placeholder SECRET_KEY_BASE/, fn ->
      Security.verify_runtime_config!(
        env: :prod,
        secret_key_base:
          "dev_only_secret_key_base_never_valid_in_prod_0123456789abcdefghijklmnopqrstuvwxyz",
        api_key: "sk_test_123"
      )
    end

    assert_raise RuntimeError, ~r/development or placeholder SECRET_KEY_BASE/, fn ->
      Security.verify_runtime_config!(
        env: :prod,
        secret_key_base:
          "replace_with_real_secret_key_base_0123456789abcdefghijklmnopqrstuvwxyz0123456789",
        api_key: "sk_test_123"
      )
    end

    # Live Stripe key is rejected unless explicitly opted in
    assert_raise RuntimeError, ~r/live Stripe API key/, fn ->
      Security.verify_runtime_config!(
        env: :prod,
        secret_key_base: valid_prod_secret,
        api_key: "sk_live_not_allowed_by_default",
        allow_stripe_live_mode?: false
      )
    end

    # Valid production config passes
    assert :ok =
             Security.verify_runtime_config!(
               env: :prod,
               secret_key_base: valid_prod_secret,
               api_key: "sk_test_safe_key",
               allow_stripe_live_mode?: false
             )

    # Demo seeds refuse to run in :prod (even if allow_demo_seeds?: true) and in :staging without opt-in
    assert_raise RuntimeError, ~r/Refusing to seed demo accounts.*:prod/, fn ->
      DemoSeeds.run!(env: :prod, allow_demo_seeds?: true)
    end

    assert_raise RuntimeError, ~r/Refusing to seed demo accounts.*:staging/, fn ->
      DemoSeeds.run!(env: :staging, allow_demo_seeds?: false)
    end

    # Zero demo users created after blocked seed attempts
    assert {:ok, []} = Ash.read(SaasExample.Accounts.User, domain: Accounts, authorize?: false)

    # Demo seeds run cleanly and idempotently in :dev
    assert :ok = DemoSeeds.run!(env: :dev)
    assert :ok = DemoSeeds.run!(env: :dev)

    {:ok, users} = Ash.read(SaasExample.Accounts.User, domain: Accounts, authorize?: false)
    roles_by_email = Map.new(users, &{to_string(&1.email), &1.role})

    assert roles_by_email["free@example.com"] == :member
    assert roles_by_email["starter@example.com"] == :member
    assert roles_by_email["pro@example.com"] == :member
    assert roles_by_email["enterprise@example.com"] == :admin
  end
end
