defmodule AshBilling.FinalHardeningTest do
  use ExUnit.Case, async: false
  require Ash.Query

  alias AshBilling.Test.{
    ConsumerUser,
    ConsumerSubscription,
    HardeningDomain,
    HardeningProvider,
    CustomProviderSubscription,
    TenantEvent,
    Repo
  }

  alias AshBilling.Deduplication, as: D
  @ash [domain: HardeningDomain, authorize?: false]

  defp id(prefix), do: prefix <> Ash.UUID.generate()

  defp event(type \\ "audit.test", object \\ %{}) do
    %{
      "id" => id("evt_"),
      "created" => System.system_time(:second),
      "type" => type,
      "data" => %{"object" => object}
    }
  end

  defp opts(tenant),
    do: [domain: HardeningDomain, deduplication_resource: TenantEvent, tenant: tenant]

  defp request(ev, opts) do
    payload = Jason.encode!(ev)
    ts = System.system_time(:second)
    secret = "whsec_hardening"
    sig = :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{payload}") |> Base.encode16(case: :lower)

    Plug.Test.conn(:post, "/webhooks/stripe", payload)
    |> Plug.Conn.put_req_header("stripe-signature", "t=#{ts},v1=#{sig}")
    |> AshBilling.Plug.call([webhook_secret: secret] ++ opts)
  end

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS billing_tenant_events (
      LIKE webhook_events INCLUDING DEFAULTS,
      tenant_id TEXT NOT NULL,
      PRIMARY KEY (tenant_id, event_id)
    )
    """)

    :ok
  end

  test "U1 ordinary consumer CRUD cannot mass-assign customer identity or tombstones" do
    user = Ash.create!(ConsumerUser, %{name: "Original"}, @ash)
    on_exit(fn -> Ash.destroy!(user, @ash) end)

    for key <- [:stripe_customer_id, :billing_deleted_at], input <- [key, Atom.to_string(key)] do
      value = if key == :stripe_customer_id, do: "cus_someone_else", else: DateTime.utc_now()
      assert {:error, _} = Ash.update(user, %{input => value}, actor: user, authorize?: true)

      assert {:error, _} =
               Ash.create(ConsumerUser, %{input => value}, actor: user, authorize?: true)
    end

    assert {:ok, updated} = Ash.update(user, %{name: "Allowed"}, actor: user, authorize?: true)
    assert updated.name == "Allowed"
    assert updated.stripe_customer_id == nil
    assert updated.billing_deleted_at == nil

    assert {:error, :no_customer_id} =
             AshBilling.create_portal_session(updated, return_url: "https://app.test")
  end

  test "U1 user input cannot grant entitlements, extend trials or steal subscription ownership" do
    user = Ash.create!(ConsumerUser, %{}, @ash)

    attrs = %{
      user_id: user.id,
      provider_subscription_id: id("sub_"),
      status: :canceled,
      price_id: "price_basic"
    }

    {:ok, sub} =
      AshBilling.Transformers.ProtectBillingAttributes.create(ConsumerSubscription, attrs, @ash)

    on_exit(fn ->
      Ash.destroy!(sub, @ash)
      Ash.destroy!(user, @ash)
    end)

    sensitive = %{
      provider_subscription_id: "sub_foreign",
      status: :active,
      price_id: "price_premium",
      trial_ends_at: DateTime.add(DateTime.utc_now(), 86400),
      current_period_end: DateTime.utc_now(),
      cancel_at_period_end: true,
      cancel_at: DateTime.utc_now(),
      last_event_created_at: DateTime.utc_now(),
      user_id: Ash.UUID.generate()
    }

    for {key, value} <- sensitive, input <- [key, Atom.to_string(key)] do
      assert {:error, _} = Ash.update(sub, %{input => value}, actor: user, authorize?: true)
    end

    assert {:error, _} =
             Ash.create(ConsumerSubscription, sensitive, actor: user, authorize?: true)

    unchanged = Ash.get!(ConsumerSubscription, sub.id, @ash)
    assert unchanged.status == :canceled
    assert unchanged.user_id == user.id
    refute AshBilling.subscribed?(%{subscriptions: [unchanged]})
  end

  test "U1 trusted billing writes still use actions, policies and deletion guards" do
    user = Ash.create!(ConsumerUser, %{}, @ash)

    on_exit(fn ->
      for sub <- Ash.read!(Ash.Query.filter(ConsumerSubscription, user_id == ^user.id), @ash),
          do: Ash.destroy!(sub, @ash)

      Ash.destroy!(user, @ash)
    end)

    assert {:error, {:persistence_failed, _, _}} =
             AshBilling.create_customer(user,
               persist: true,
               domain: HardeningDomain,
               authorize?: true
             )

    assert {:ok, "cus_custom"} =
             AshBilling.create_customer(user,
               persist: true,
               actor: user,
               domain: HardeningDomain,
               authorize?: true
             )

    sync = [
      domain: HardeningDomain,
      customer_resource: ConsumerUser,
      subscription_resource: ConsumerSubscription,
      actor: user,
      authorize?: true
    ]

    ev =
      event("customer.subscription.created", %{
        "id" => id("sub_"),
        "customer" => "cus_custom",
        "status" => "active",
        "items" => %{"data" => [%{"price" => %{"id" => "price_premium"}}]}
      })

    assert {:ok, created} = AshBilling.WebhookSync.sync_event(ev, sync)
    assert created.user_id == user.id
    assert created.status == :active

    invalid =
      event("customer.subscription.created", %{
        "id" => id("sub_invalid_"),
        "customer" => "cus_custom",
        "status" => "paused"
      })

    assert {:error, _} = AshBilling.WebhookSync.sync_event(invalid, sync)

    assert {:ok, _} =
             AshBilling.WebhookSync.sync_event(
               event("customer.deleted", %{"id" => "cus_custom"}),
               sync
             )

    assert Ash.get!(ConsumerSubscription, created.id, @ash).status == :canceled
    assert Ash.get!(ConsumerUser, user.id, @ash).billing_deleted_at != nil
  end

  test "U2 tenant flows through acquisition, execution, completion, release, reads and retry" do
    ev = id("evt_tenant_")
    a = opts(id("tenant_a_"))
    b = opts(id("tenant_b_"))
    on_exit(fn -> Repo.query!("DELETE FROM billing_tenant_events WHERE event_id = $1", [ev]) end)
    assert {:error, _} = D.acquire(ev, Keyword.delete(a, :tenant))
    assert {:ok, ta} = D.acquire(ev, a)
    assert {:ok, tb} = D.acquire(ev, b)
    assert {:ok, :ok} = D.with_lease(ev, ta, a, fn -> D.complete(ev, [lease_token: ta] ++ a) end)
    assert D.processed?(ev, a)
    refute D.processed?(ev, b)
    assert {:error, :lease_token_mismatch} = D.complete(ev, [lease_token: ta] ++ b)
    assert :ok = D.release(ev, [lease_token: tb, error: :retry] ++ b)
    assert {:ok, tc} = D.acquire(ev, b)
    refute tb == tc

    assert {:error, :lease_token_mismatch} =
             D.with_lease(ev, tb, b, fn -> flunk("stale token ran") end)

    assert {:ok, :ok} = D.with_lease(ev, tc, b, fn -> D.complete(ev, [lease_token: tc] ++ b) end)
    assert D.processed?(ev, b)
    assert {:error, :already_processed} = D.acquire(ev, a)
    assert {:error, :already_processed} = D.acquire(ev, b)

    assert [[_, 1], [_, 2]] =
             Repo.query!(
               "SELECT tenant_id, attempts FROM billing_tenant_events WHERE event_id = $1 ORDER BY tenant_id",
               [ev]
             ).rows
  end

  test "U2 another tenant can reclaim while the same-ID owner stays fenced" do
    ev = id("evt_parallel_")
    a = opts(id("tenant_a_"))
    b = opts(id("tenant_b_"))
    on_exit(fn -> Repo.query!("DELETE FROM billing_tenant_events WHERE event_id = $1", [ev]) end)
    assert {:ok, ta} = D.acquire(ev, a)
    assert {:ok, tb} = D.acquire(ev, b)

    Repo.query!(
      "UPDATE billing_tenant_events SET last_attempt_at = $1 WHERE event_id = $2 AND tenant_id = $3",
      [DateTime.add(DateTime.utc_now(), -120), ev, b[:tenant]]
    )

    owner = self()

    task =
      Task.async(fn ->
        D.with_lease(ev, ta, a, fn ->
          send(owner, {:fenced, self()})

          receive do
            :finish -> D.complete(ev, [lease_token: ta] ++ a)
          end
        end)
      end)

    assert_receive {:fenced, worker}, 2000
    assert {:error, :already_processing} = D.acquire(ev, a)
    assert {:ok, next} = D.acquire(ev, b)
    refute next == tb

    assert {:ok, :ok} =
             D.with_lease(ev, next, b, fn -> D.complete(ev, [lease_token: next] ++ b) end)

    assert {:error, :already_processing} = D.release(ev, [lease_token: next] ++ a)
    send(worker, :finish)
    assert {:ok, :ok} = Task.await(task)
    assert D.processed?(ev, a) and D.processed?(ev, b)
  end

  test "U2 memory tenants with equal and different IDs have separate leases" do
    ev = id("evt_mem_")
    a = [tenant: "a", deduplication_strategy: :memory]
    b = [tenant: "b", deduplication_strategy: :memory]
    assert {:ok, ta} = D.acquire(ev, a)
    assert {:ok, tb} = D.acquire(ev, b)
    assert {:ok, _} = D.acquire(ev <> "different", b)
    assert {:ok, :ok} = D.with_lease(ev, ta, a, fn -> D.complete(ev, [lease_token: ta] ++ a) end)
    refute D.processed?(ev, b)
    assert {:error, :lease_token_mismatch} = D.release(ev, [lease_token: ta] ++ b)
    assert :ok = D.release(ev, [lease_token: tb] ++ b)
    assert {:ok, _} = D.acquire(ev, b)
    assert D.processed?(ev, a)
  end

  test "U3 account and mode rejection happens before dedup or entitlement writes" do
    ev = event() |> Map.put("account", "acct_allowed") |> Map.put("livemode", true)
    opts = opts(id("tenant_scope_")) ++ [stripe_account: "acct_allowed", expected_livemode: true]

    on_exit(fn ->
      Repo.query!("DELETE FROM billing_tenant_events WHERE event_id = $1", [ev["id"]])
    end)

    for rejected <- [
          Map.put(ev, "account", "acct_other"),
          Map.delete(ev, "account"),
          Map.put(ev, "livemode", false),
          Map.delete(ev, "livemode"),
          Map.put(ev, "context", "ctx_unsupported")
        ] do
      assert request(rejected, opts).status == 400

      assert Repo.query!("SELECT count(*) FROM billing_tenant_events WHERE event_id = $1", [
               ev["id"]
             ]).rows == [[0]]
    end

    assert request(ev, opts).status == 200
    assert D.processed?(ev["id"], opts)
    assert request(Map.put(ev, "account", "acct_other"), opts).status == 400
    assert request(ev, opts).status == 200
  end

  test "U3 platform default rejects Connect; explicit false mode is enforced strictly" do
    ev = event() |> Map.put("account", "acct_connected") |> Map.put("livemode", false)
    assert request(ev, []).status == 400
    platform = Map.delete(ev, "account")
    assert request(Map.put(platform, "livemode", true), expected_livemode: false).status == 400
    assert request(Map.put(platform, "livemode", "false"), []).status == 400
    assert request(platform, expected_livemode: false).status == 200
    assert request(platform, expected_livemode: :invalid).status == 400
  end

  test "U3 reconciliation API uses the configured account header, including idempotency" do
    Req.Test.stub(:hardening_connect, fn conn ->
      assert Plug.Conn.get_req_header(conn, "stripe-account") == ["acct_expected"]
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["stable_effect"]
      Req.Test.json(conn, %{id: "sub_connect", status: "active"})
    end)

    assert {:ok, _} =
             AshBilling.get_subscription("sub_connect",
               stripe_account: "acct_expected",
               idempotency_key: "stable_effect",
               base_url: "http://stripe.test",
               req_opts: [
                 plug: {Req.Test, :hardening_connect},
                 headers: [{"stripe-account", "acct_wrong"}]
               ]
             )
  end

  test "U4 subscription APIs and quantity lookup honor the resource provider" do
    sub = %CustomProviderSubscription{provider_subscription_id: "sub_custom"}
    assert {:ok, _} = AshBilling.get_subscription(sub)
    assert_receive {:provider_called, :get_subscription, ["sub_custom", _]}
    assert {:ok, _} = AshBilling.cancel_subscription(sub)
    assert_receive {:provider_called, :cancel_subscription, ["sub_custom", _]}
    assert {:ok, _} = AshBilling.resume_subscription(sub)
    assert_receive {:provider_called, :resume_subscription, ["sub_custom", _]}
    assert {:ok, _} = AshBilling.swap_plan(sub, "price_new")
    assert_receive {:provider_called, :swap_plan, ["sub_custom", "price_new", _]}
    assert {:ok, _} = AshBilling.update_quantity(sub, 3)
    assert_receive {:provider_called, :get_subscription, ["sub_custom", _]}
    assert_receive {:provider_called, :swap_plan, ["sub_custom", "price_custom", options]}
    assert options[:quantity] == 3
    assert {:ok, _} = AshBilling.update_quantity(sub, 5, price_id: "price_known")
    assert_receive {:provider_called, :swap_plan, ["sub_custom", "price_known", options]}
    assert options[:quantity] == 5
    refute_receive {:provider_called, :get_subscription, _}
  end

  test "U4 customer, checkout and portal use their resource provider" do
    user = %ConsumerUser{id: Ash.UUID.generate(), stripe_customer_id: "cus_owned"}

    assert {:ok, "cus_custom"} =
             AshBilling.create_customer(%ConsumerUser{id: Ash.UUID.generate()}, persist: false)

    assert_receive {:provider_called, :create_customer, _}

    assert {:ok, _} =
             AshBilling.create_checkout_session(user,
               price: "price_one",
               success_url: "https://app.test/ok",
               cancel_url: "https://app.test/cancel"
             )

    assert_receive {:provider_called, :create_checkout_session, _}
    assert {:ok, _} = AshBilling.create_portal_session(user, return_url: "https://app.test")
    assert_receive {:provider_called, :create_portal_session, _}
    assert {:ok, _} = AshBilling.get_subscription("sub_raw", provider: HardeningProvider)
    assert_receive {:provider_called, :get_subscription, ["sub_raw", _]}
  end

  test "U4 explicit overrides and raw-ID Stripe defaults remain compatible" do
    Req.Test.stub(:hardening_default, fn conn ->
      assert conn.request_path == "/v1/subscriptions/sub_custom"
      Req.Test.json(conn, %{source: "stripe"})
    end)

    opts = [base_url: "http://stripe.test", req_opts: [plug: {Req.Test, :hardening_default}]]

    assert {:ok, %{"source" => "stripe"}} =
             AshBilling.get_subscription(
               %CustomProviderSubscription{provider_subscription_id: "sub_custom"},
               [provider: AshBilling.Providers.Stripe] ++ opts
             )

    assert {:ok, %{"source" => "stripe"}} = AshBilling.get_subscription("sub_custom", opts)
    refute_receive {:provider_called, _, _}
  end

  test "U1 custom and manually declared fields are protected; explicit repair is deliberate" do
    resource = AshBilling.Test.ConsumerAlternateUser
    user = Ash.create!(resource, %{}, @ash)
    on_exit(fn -> Ash.destroy!(user, @ash) end)
    assert {:error, _} = Ash.update(user, %{payment_customer_id: "cus_stolen"}, @ash)
    assert {:error, _} = Ash.update(user, %{billing_deleted_at: DateTime.utc_now()}, @ash)

    assert {:ok, repaired} =
             Ash.update(
               user,
               %{payment_customer_id: "cus_repaired"},
               [action: :trusted_repair] ++ @ash
             )

    assert repaired.payment_customer_id == "cus_repaired"
  end

  test "U2 fallback destruction cannot release a different tenant's event" do
    ev = id("evt_fallback_")
    a = opts(id("tenant_a_"))
    b = opts(id("tenant_b_"))
    on_exit(fn -> Repo.query!("DELETE FROM billing_tenant_events WHERE event_id = $1", [ev]) end)
    assert {:ok, ta} = D.acquire(ev, a)
    assert {:ok, tb} = D.acquire(ev, b)
    fallback = Keyword.put(a, :deduplication_resource, AshBilling.Test.TenantEventWithoutUpdate)
    assert :ok = D.release(ev, [lease_token: ta] ++ fallback)

    assert Repo.query!(
             "SELECT tenant_id, lease_token FROM billing_tenant_events WHERE event_id = $1",
             [ev]
           ).rows == [[b[:tenant], tb]]

    assert {:error, :lease_token_mismatch} = D.complete(ev, [lease_token: ta] ++ b)
    assert {:ok, _} = D.acquire(ev, a)
  end

  test "U2 tenant fences are shared across independent BEAM nodes" do
    ev = id("evt_nodes_")
    a = opts(id("tenant_a_"))
    b = opts(id("tenant_b_"))
    on_exit(fn -> Repo.query!("DELETE FROM billing_tenant_events WHERE event_id = $1", [ev]) end)
    {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"2:2"]})

    try do
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
      :ok = :peer.call(peer, Application, :put_env, [:ash_billing, Repo, Repo.config()])
      assert {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ash_billing])
      assert {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ash_postgres])
      assert {:ok, _} = :peer.call(peer, AshBilling.Test.SecurityProvider, :start_repo, [])
      assert {:ok, ta} = D.acquire(ev, a)
      owner = self()

      task =
        Task.async(fn ->
          D.with_lease(ev, ta, a, fn ->
            send(owner, {:fenced, self()})

            receive do
              :finish -> D.complete(ev, [lease_token: ta] ++ a)
            end
          end)
        end)

      assert_receive {:fenced, worker}, 2000
      assert {:error, :already_processing} = :peer.call(peer, D, :acquire, [ev, a])
      assert {:ok, tb} = :peer.call(peer, D, :acquire, [ev, b])
      assert {:ok, :ok} = :peer.call(peer, HardeningProvider, :complete_event, [ev, tb, b])
      assert D.processed?(ev, b)
      refute D.processed?(ev, a)
      send(worker, :finish)
      assert {:ok, :ok} = Task.await(task)
      assert {:error, :already_processed} = :peer.call(peer, D, :acquire, [ev, a])
    after
      :peer.stop(peer)
    end
  end

  test "U3 separately configured account/environment tenants cannot cross subscription state" do
    alias AshBilling.Test.{PostgresScopedCustomer, PostgresOwnedScopedSubscription}

    a =
      opts(id("account_a_")) ++
        [
          stripe_account: "acct_a",
          expected_livemode: true,
          customer_resource: PostgresScopedCustomer,
          subscription_resource: PostgresOwnedScopedSubscription
        ]

    b =
      opts(id("account_b_")) ++
        [
          stripe_account: "acct_b",
          expected_livemode: false,
          customer_resource: PostgresScopedCustomer,
          subscription_resource: PostgresOwnedScopedSubscription
        ]

    cus = id("cus_scoped_")

    ua =
      Ash.create!(
        PostgresScopedCustomer,
        %{stripe_customer_id: cus},
        @ash ++ [tenant: a[:tenant]]
      )

    ub =
      Ash.create!(
        PostgresScopedCustomer,
        %{stripe_customer_id: cus},
        @ash ++ [tenant: b[:tenant]]
      )

    ev =
      event("customer.subscription.created", %{
        "id" => id("sub_shared_"),
        "customer" => cus,
        "status" => "active",
        "items" => %{"data" => [%{"price" => %{"id" => "price_premium"}}]}
      })
      |> Map.put("account", "acct_a")
      |> Map.put("livemode", true)

    other =
      ev
      |> Map.put("account", "acct_b")
      |> Map.put("livemode", false)
      |> put_in(["data", "object", "status"], "canceled")

    on_exit(fn ->
      for options <- [a, b] do
        for sub <- Ash.read!(PostgresOwnedScopedSubscription, @ash ++ [tenant: options[:tenant]]),
            do: Ash.destroy!(sub, @ash ++ [tenant: options[:tenant]])
      end

      Ash.destroy!(ua, @ash ++ [tenant: a[:tenant]])
      Ash.destroy!(ub, @ash ++ [tenant: b[:tenant]])
      Repo.query!("DELETE FROM billing_tenant_events WHERE event_id = $1", [ev["id"]])
    end)

    assert request(other, a).status == 400
    assert request(ev, b).status == 400
    assert request(ev, a).status == 200
    assert request(other, b).status == 200
    assert [sa] = Ash.read!(PostgresOwnedScopedSubscription, @ash ++ [tenant: a[:tenant]])
    assert [sb] = Ash.read!(PostgresOwnedScopedSubscription, @ash ++ [tenant: b[:tenant]])
    assert sa.user_id == ua.id and sa.status == :active and sa.price_id == "price_premium"
    assert sb.user_id == ub.id and sb.status == :canceled
    assert request(other, a).status == 400

    assert Ash.get!(PostgresOwnedScopedSubscription, sa.id, @ash ++ [tenant: a[:tenant]]).status ==
             :active
  end

  test "U4 explicit overrides take precedence for every public billing operation" do
    provider = AshBilling.Test.OverrideProvider
    sub = %CustomProviderSubscription{provider_subscription_id: "sub_custom"}
    user = %ConsumerUser{id: Ash.UUID.generate(), stripe_customer_id: "cus_owned"}
    opts = [provider: provider]

    calls = [
      fn -> AshBilling.get_subscription(sub, opts) end,
      fn -> AshBilling.cancel_subscription(sub, opts) end,
      fn -> AshBilling.resume_subscription(sub, opts) end,
      fn -> AshBilling.swap_plan(sub, "price_one", opts) end,
      fn -> AshBilling.update_quantity(sub, 2, opts) end,
      fn -> AshBilling.update_quantity(sub, 2, [price_id: "price_one"] ++ opts) end,
      fn ->
        AshBilling.create_customer(
          %ConsumerUser{id: Ash.UUID.generate()},
          [persist: false] ++ opts
        )
      end,
      fn ->
        AshBilling.create_checkout_session(
          user,
          [
            price: "price_one",
            success_url: "https://app.test/ok",
            cancel_url: "https://app.test/cancel"
          ] ++ opts
        )
      end,
      fn -> AshBilling.create_portal_session(user, [return_url: "https://app.test"] ++ opts) end
    ]

    for call <- calls, do: assert(call.() == {:error, :explicit_override})
    refute_receive {:provider_called, _, _}
  end

  test "U2 equivalent Ash.ToTenant representations share database and memory fences" do
    ev = id("evt_alias_")
    tenant = id("tenant_alias_")
    a = opts(%AshBilling.Test.TenantRef{value: tenant})
    b = opts(tenant)
    on_exit(fn -> Repo.query!("DELETE FROM billing_tenant_events WHERE event_id = $1", [ev]) end)

    for {a, b} <- [
          {a, b},
          {[tenant: a[:tenant], deduplication_strategy: :memory],
           [tenant: tenant, deduplication_strategy: :memory]}
        ] do
      assert {:ok, token} = D.acquire(ev, a)
      assert {:error, :already_processing} = D.acquire(ev, b)

      assert {:ok, :ok} =
               D.with_lease(ev, token, a, fn -> D.complete(ev, [lease_token: token] ++ b) end)

      assert D.processed?(ev, a) and D.processed?(ev, b)
      assert {:error, :already_processed} = D.acquire(ev, b)
    end
  end

  test "U3 environment defaults follow configured credentials; Connect needs a bound mode" do
    ev = event() |> Map.put("livemode", false)
    assert request(ev, api_key: "sk_live_fixture").status == 400
    assert request(ev, api_key: "rk_live_fixture").status == 400
    assert request(Map.delete(ev, "livemode"), api_key: "sk_test_fixture").status == 400
    assert request(ev, api_key: "sk_test_fixture").status == 200
    connect = Map.put(event(), "account", "acct_bound") |> Map.put("livemode", true)
    assert request(connect, stripe_account: "acct_bound").status == 400
    assert request(connect, stripe_account: "acct_bound", expected_livemode: nil).status == 400

    assert request(connect, stripe_account: "acct_bound", api_key: "sk_live_fixture").status ==
             200
  end

  test "U4 same-second reconciliation also resolves the subscription resource provider" do
    now = System.system_time(:second)
    timestamp = DateTime.from_unix!(now)

    sub =
      Ash.create!(
        CustomProviderSubscription,
        %{
          provider_subscription_id: id("sub_custom_"),
          status: :active,
          price_id: "price_old",
          last_event_created_at: timestamp
        },
        @ash
      )

    on_exit(fn -> Ash.destroy!(sub, @ash) end)

    ev =
      event("customer.subscription.updated", %{
        "id" => sub.provider_subscription_id,
        "status" => "active",
        "items" => %{"data" => [%{"price" => %{"id" => "price_changed"}}]}
      })
      |> Map.put("created", now)

    assert {:ok, updated} =
             AshBilling.WebhookSync.sync_event(ev,
               domain: HardeningDomain,
               subscription_resource: CustomProviderSubscription
             )

    assert_receive {:provider_called, :get_subscription, [_, _]}
    assert updated.status == :active
    assert updated.price_id == "price_custom"
  end

  test "U3 malformed envelopes and invalid scope configuration fail closed" do
    assert request([], []).status == 400
    assert request(event(), stripe_account: 123).status == 400
    assert request(event(), expected_livemode: "false").status == 400
  end

  test "U2 different PostgreSQL event IDs cannot complete another tenant's record" do
    ea = id("evt_distinct_a_")
    eb = id("evt_distinct_b_")
    a = opts(id("tenant_a_"))
    b = opts(id("tenant_b_"))

    on_exit(fn ->
      Repo.query!("DELETE FROM billing_tenant_events WHERE event_id = ANY($1::text[])", [[ea, eb]])
    end)

    assert {:ok, ta} = D.acquire(ea, a)
    assert {:ok, tb} = D.acquire(eb, b)
    assert {:error, _} = D.complete(ea, [lease_token: ta] ++ b)
    assert {:ok, :ok} = D.with_lease(ea, ta, a, fn -> D.complete(ea, [lease_token: ta] ++ a) end)
    refute D.processed?(ea, b)
    refute D.processed?(eb, b)
    assert {:ok, :ok} = D.with_lease(eb, tb, b, fn -> D.complete(eb, [lease_token: tb] ++ b) end)
    assert D.processed?(ea, a) and D.processed?(eb, b)
  end

  test "U2 tenant values cannot become ETS match-spec wildcards during reclaim" do
    ev = id("evt_literal_")
    a = [deduplication_strategy: :memory, tenant: :_]
    b = [deduplication_strategy: :memory, tenant: :other]
    assert {:ok, ta} = D.acquire(ev, a)
    assert {:ok, tb} = D.acquire(ev, b)
    assert :ok = D.release(ev, [lease_token: ta] ++ a)
    assert :ok = D.release(ev, [lease_token: tb] ++ b)
    assert {:ok, next} = D.acquire(ev, a)

    assert {:ok, :ok} =
             D.with_lease(ev, next, a, fn -> D.complete(ev, [lease_token: next] ++ a) end)

    refute D.processed?(ev, b)
    assert {:ok, _} = D.acquire(ev, b)
    assert D.processed?(ev, a)
  end

  test "U3 automatic customer idempotency separates resources and canonical tenants" do
    local_id = Ash.UUID.generate()
    user = %ConsumerUser{id: local_id}
    other = %AshBilling.Test.ConsumerAlternateUser{id: local_id}
    inputs = [{user, [tenant: "a"]}, {user, [tenant: "b"]}, {other, [tenant: "a"]}]

    keys =
      for {record, scope} <- inputs do
        assert {:ok, _} =
                 AshBilling.create_customer(
                   record,
                   [provider: HardeningProvider, persist: false] ++ scope
                 )

        assert_receive {:provider_called, :create_customer, [_, options]}
        options[:idempotency_key]
      end

    assert Enum.uniq(keys) == keys

    assert {:ok, _} =
             AshBilling.create_customer(user,
               provider: HardeningProvider,
               persist: false,
               tenant: %AshBilling.Test.TenantRef{value: "a"}
             )

    assert_receive {:provider_called, :create_customer, [_, options]}
    assert options[:idempotency_key] == hd(keys)
  end
end
