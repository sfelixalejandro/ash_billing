defmodule AshBilling.ProductionHardeningTest do
  use ExUnit.Case, async: false

  alias AshBilling.Test.{
    Domain,
    User,
    Subscription,
    PostgresDomain,
    PostgresCustomer,
    PostgresSubscription,
    PostgresWebhookEvent
  }

  @ash [domain: Domain, authorize?: false]
  @pg [domain: PostgresDomain, authorize?: false]

  alias AshBilling.Test.NoUpdateCustomer, as: NoUpdateUser
  alias AshBilling.Test.PersistenceDomain, as: LocalDomain

  defp unique(prefix), do: prefix <> String.replace(Ash.UUID.generate(), "-", "")

  defp event(type, object),
    do: %{
      "id" => unique("evt_audit_"),
      "type" => type,
      "created" => System.system_time(:second),
      "data" => %{"object" => object}
    }

  defp request(event, opts) do
    payload = Jason.encode!(event)
    ts = System.system_time(:second)
    secret = "whsec_independent_audit"
    sig = :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{payload}") |> Base.encode16(case: :lower)

    Plug.Test.conn(:post, "/webhooks/stripe", payload)
    |> Plug.Conn.put_req_header("stripe-signature", "t=#{ts},v1=#{sig}")
    |> AshBilling.Plug.call([webhook_secret: secret] ++ opts)
  end

  test "H1 swap preserves twenty seats after reading the item" do
    stub = :independent_audit_swap

    Req.Test.stub(stub, fn conn ->
      body =
        if conn.method == "GET" do
          %{
            "items" => %{
              "data" => [
                %{"id" => "si_audit", "quantity" => 20, "price" => %{"id" => "price_old"}}
              ]
            }
          }
        else
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          params = URI.decode_query(body)
          assert params["items[0][price]"] == "price_new"
          assert params["items[0][quantity]"] == "20"
          send(self(), {:audit_post, conn.method})
          %{"id" => "sub_audit"}
        end

      Req.Test.json(conn, body)
    end)

    assert {:ok, _} =
             AshBilling.swap_plan("sub_audit", "price_new", req_opts: [plug: {Req.Test, stub}])

    assert_received {:audit_post, "POST"}
  end

  test "H2 multiple subscription prices are rejected independently of item order" do
    cus = unique("cus_hardening_")
    user = Ash.create!(User, %{stripe_customer_id: cus}, @ash)

    for prices <- [["price_base", "price_enterprise"], ["price_enterprise", "price_base"]] do
      ev =
        event("customer.subscription.created", %{
          "id" => unique("sub_hardening_"),
          "customer" => cus,
          "status" => "active",
          "items" => %{"data" => Enum.map(prices, &%{"price" => %{"id" => &1}})}
        })

      assert {:error, :unsupported_subscription_items} =
               AshBilling.WebhookSync.sync_event(
                 ev,
                 [customer_resource: User, subscription_resource: Subscription] ++ @ash
               )
    end

    loaded = Ash.load!(user, :subscriptions, @ash)
    assert loaded.subscriptions == []
    refute AshBilling.Checks.HasPrice.match?(loaded, %{domain: Domain}, price: "price_base")
    refute AshBilling.Checks.HasPrice.match?(loaded, %{domain: Domain}, price: "price_enterprise")
  end

  test "A3 loaded actor still authorizes after subscription cancellation in storage" do
    user = Ash.create!(User, %{}, @ash)

    sub =
      Ash.create!(
        Subscription,
        %{
          user_id: user.id,
          provider_subscription_id: unique("sub_audit_"),
          status: :active,
          price_id: "price_pro"
        },
        @ash
      )

    actor = Ash.load!(user, :subscriptions, @ash)
    Ash.update!(sub, %{status: :canceled}, @ash)
    assert AshBilling.Checks.HasPrice.match?(actor, %{domain: Domain}, price: "price_pro")

    refute AshBilling.Checks.HasPrice.match?(
             Ash.load!(Ash.get!(User, user.id, @ash), :subscriptions, @ash),
             %{domain: Domain},
             price: "price_pro"
           )
  end

  test "H3 persist true rejects a resource without update before contacting provider" do
    user = Ash.create!(NoUpdateUser, %{}, domain: LocalDomain)

    assert {:error, :update_action_required} =
             AshBilling.create_customer(user,
               provider: AshBilling.Test.HardeningProvider,
               persist: true
             )

    refute_received {:provider_called, :create_customer, _}
    assert Ash.get!(NoUpdateUser, user.id, domain: LocalDomain).stripe_customer_id == nil
  end

  test "H5 durable webhook rolls back partial association and supports retry after repair" do
    a = Ash.create!(PostgresCustomer, %{stripe_customer_id: unique("cus_audit_")}, @pg)
    b = Ash.create!(PostgresCustomer, %{}, @pg)

    sub =
      Ash.create!(
        PostgresSubscription,
        %{user_id: a.id, provider_subscription_id: unique("sub_audit_"), status: :active},
        @pg
      )

    cus = unique("cus_audit_new_")

    ev =
      event("customer.subscription.updated", %{
        "id" => sub.provider_subscription_id,
        "customer" => cus,
        "status" => "active",
        "metadata" => %{"resource_id" => b.id}
      })

    opts =
      [
        customer_resource: PostgresCustomer,
        subscription_resource: PostgresSubscription,
        deduplication_resource: PostgresWebhookEvent
      ] ++ @pg

    on_exit(fn ->
      Ash.destroy!(sub, @pg)
      Ash.destroy!(a, @pg)
      Ash.destroy!(b, @pg)
      AshBilling.Test.Repo.query!("DELETE FROM webhook_events WHERE event_id = $1", [ev["id"]])
    end)

    telemetry_id = unique("hardening_telemetry_")
    owner = self()

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:ash_billing, :webhook, :stop],
        fn _event, _measurements, metadata, receiver ->
          send(receiver, {:webhook_stop, metadata})
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)
    assert request(ev, opts).status == 500
    assert_receive {:webhook_stop, %{status: :sync_failed}}
    assert Ash.get!(PostgresWebhookEvent, ev["id"], @pg).status == :failed
    assert Ash.get!(PostgresCustomer, b.id, @pg).stripe_customer_id == nil
    assert Ash.get!(PostgresSubscription, sub.id, @pg).user_id == a.id
    Ash.update!(sub, %{user_id: b.id}, @pg)
    assert request(ev, opts).status == 200
    assert Ash.get!(PostgresWebhookEvent, ev["id"], @pg).status == :processed
    assert Ash.get!(PostgresCustomer, b.id, @pg).stripe_customer_id == cus
  end

  test "A6 payment checkout without customer cannot request customer creation through params" do
    user = %User{id: Ash.UUID.generate()}

    opts = [
      provider: AshBilling.Test.HardeningProvider,
      mode: "payment",
      price: "price_credits",
      success_url: "https://example.test/success",
      cancel_url: "https://example.test/cancel",
      params: %{customer_creation: "always"},
      customer_creation: "always"
    ]

    assert {:ok, _} = AshBilling.create_checkout_session(user, opts)
    assert_received {:provider_called, :create_checkout_session, [params, _]}
    refute Map.has_key?(params, :customer)
    refute Map.has_key?(params, :customer_creation)

    ev =
      event("checkout.session.completed", %{
        "customer" => nil,
        "metadata" => %{"resource_id" => user.id}
      })

    assert {:ok, :ignored} =
             AshBilling.WebhookSync.sync_event(ev, [customer_resource: User] ++ @ash)
  end

  test "A7 diagnostics accept explicitly missing credentials" do
    assert {:ok, %{status: :valid}} =
             AshBilling.check_configuration(api_key: nil, webhook_secret: nil)

    assert :ok = AshBilling.verify_configuration!(api_key: nil, webhook_secret: nil)
  end

  test "public checkout validation returns errors before effects" do
    assert {:error, :invalid_price} =
             AshBilling.create_checkout_session("cus_audit",
               success_url: "https://example.test",
               cancel_url: "https://example.test"
             )

    assert {:error, :invalid_line_items} =
             AshBilling.create_checkout_session("cus_audit", line_items: "invalid")

    assert {:error, :invalid_subscription_id} = AshBilling.get_subscription(nil)
  end

  test "H4 concurrent checkout uses one persisted identity or fails before provider effects" do
    user = Ash.create!(User, %{}, @ash)

    opts = [
      provider: AshBilling.Test.HardeningProvider,
      price: "price_pro",
      success_url: "https://example.test/success",
      cancel_url: "https://example.test/cancel"
    ]

    assert {:error, :no_customer_id} = AshBilling.create_checkout_session(user, opts)
    refute_received {:provider_called, :create_checkout_session, _}

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          result =
            AshBilling.create_customer(user,
              provider: AshBilling.Test.HardeningProvider,
              persist: true
            )

          assert_receive {:provider_called, :create_customer, [_, creation_opts]}
          {result, creation_opts[:idempotency_key]}
        end)
      end

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.all?(results, fn {result, _} -> result == {:ok, "cus_custom"} end)
    assert results |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1
    user = Ash.get!(User, user.id, @ash)

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          assert {:ok, _} = AshBilling.create_checkout_session(user, opts)
          assert_receive {:provider_called, :create_checkout_session, [params, _]}
          params.customer
        end)
      end

    assert Enum.map(tasks, &Task.await/1) == ["cus_custom", "cus_custom"]
  end

  test "unexpected custom handler returns remain retryable" do
    ev = event("audit.handler", %{})

    opts = [
      handler: AshBilling.ProductionHardeningTest.UnexpectedHandler,
      deduplication_strategy: :memory
    ]

    assert request(ev, opts).status == 500
    refute AshBilling.Deduplication.processed?(ev["id"], opts)
  end

  defmodule UnexpectedHandler do
    def handle_event(_), do: {:failed, :could_not_deliver}
  end

  test "A11 negative control explicit different domain works with these resource contracts" do
    user = Ash.create!(User, %{stripe_customer_id: unique("cus_audit_")}, @ash)
    ev = event("checkout.session.completed", %{"customer" => user.stripe_customer_id})

    assert {:ok, %{id: id}} =
             AshBilling.WebhookSync.sync_event(ev,
               customer_resource: User,
               domain: PostgresDomain,
               authorize?: false
             )

    assert id == user.id
  end

  defmodule WritingHandler do
    @pg [domain: PostgresDomain, authorize?: false]
    def handle_event(event) do
      sub = Ash.get!(PostgresSubscription, event["local_subscription_id"], @pg)
      Ash.update!(sub, %{price_id: "price_uncommitted_handler"}, @pg)

      case event["handler_outcome"] do
        "error" -> {:error, :handler_declined}
        "raise" -> raise "unexpected handler failure"
        "unexpected" -> false
        "ok_tuple" -> {:ok, :delivered}
      end
    end
  end

  defp pg_fixture do
    user = Ash.create!(PostgresCustomer, %{stripe_customer_id: unique("cus_hardening_")}, @pg)

    sub =
      Ash.create!(
        PostgresSubscription,
        %{
          user_id: user.id,
          provider_subscription_id: unique("sub_hardening_"),
          status: :active,
          price_id: "price_original"
        },
        @pg
      )

    opts =
      [
        customer_resource: PostgresCustomer,
        subscription_resource: PostgresSubscription,
        deduplication_resource: PostgresWebhookEvent
      ] ++ @pg

    on_exit(fn ->
      Ash.destroy!(sub, @pg)
      Ash.destroy!(user, @pg)
    end)

    {user, sub, opts}
  end

  for outcome <- ["error", "raise", "unexpected"] do
    test "H5 handler #{outcome} rolls back SQL writes and leaves a retryable lease" do
      {user, sub, opts} = pg_fixture()

      ev =
        event("customer.subscription.deleted", %{
          "id" => sub.provider_subscription_id,
          "customer" => user.stripe_customer_id,
          "status" => "canceled"
        })
        |> Map.put("local_subscription_id", sub.id)
        |> Map.put("handler_outcome", unquote(outcome))

      on_exit(fn ->
        AshBilling.Test.Repo.query!("DELETE FROM webhook_events WHERE event_id = $1", [ev["id"]])
      end)

      assert request(ev, [handler: WritingHandler] ++ opts).status == 500

      persisted =
        Task.async(fn -> Ash.get!(PostgresSubscription, sub.id, @pg) end) |> Task.await()

      assert persisted.status == :active
      assert persisted.price_id == "price_original"
      assert Ash.get!(PostgresWebhookEvent, ev["id"], @pg).status == :failed
      assert request(ev, opts).status == 200
      assert Ash.get!(PostgresSubscription, sub.id, @pg).status == :canceled
      assert Ash.get!(PostgresWebhookEvent, ev["id"], @pg).status == :processed
    end
  end

  test "H5 raw lease callbacks propagate returned errors and roll back SQL" do
    {_user, sub, opts} = pg_fixture()
    ev = unique("evt_hardening_")

    on_exit(fn ->
      AshBilling.Test.Repo.query!("DELETE FROM webhook_events WHERE event_id = $1", [ev])
    end)

    assert {:ok, token} = AshBilling.Deduplication.acquire(ev, opts)

    assert {:error, :declined} =
             AshBilling.Deduplication.with_lease(ev, token, opts, fn ->
               Ash.update!(sub, %{price_id: "price_partial"}, @pg)
               {:error, :declined}
             end)

    assert Ash.get!(PostgresSubscription, sub.id, @pg).price_id == "price_original"
    assert :ok = AshBilling.Deduplication.release(ev, [lease_token: token] ++ opts)
    assert {:ok, _} = AshBilling.Deduplication.acquire(ev, opts)
  end

  test "H2 unsupported external updates retain last supported snapshot but terminal events revoke" do
    {user, sub, opts} = pg_fixture()

    object = %{
      "id" => sub.provider_subscription_id,
      "customer" => user.stripe_customer_id,
      "status" => "active",
      "items" => %{
        "data" => [
          %{"price" => %{"id" => "price_enterprise"}},
          %{"price" => %{"id" => "price_base"}}
        ]
      }
    }

    assert {:error, :unsupported_subscription_items} =
             AshBilling.WebhookSync.sync_event(
               event("customer.subscription.updated", object),
               opts
             )

    assert Ash.get!(PostgresSubscription, sub.id, @pg).price_id == "price_original"

    assert {:ok, canceled} =
             AshBilling.WebhookSync.sync_event(
               event("customer.subscription.deleted", Map.put(object, "status", "canceled")),
               opts
             )

    assert canceled.status == :canceled
    assert canceled.price_id == nil
  end

  test "H2 a multiple item reconciliation response cannot select its first price" do
    {user, sub, opts} = pg_fixture()
    Ash.update!(sub, %{status: :past_due}, @pg)
    name = "multiple_live_#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fn conn ->
      Req.Test.json(conn, %{
        "status" => "active",
        "items" => %{
          "data" => [
            %{"price" => %{"id" => "price_pro"}},
            %{"price" => %{"id" => "price_other"}}
          ]
        }
      })
    end)

    ev =
      event("customer.subscription.updated", %{
        "id" => sub.provider_subscription_id,
        "customer" => user.stripe_customer_id,
        "status" => "active"
      })

    assert {:error, :unsupported_subscription_items} =
             AshBilling.WebhookSync.sync_event(
               ev,
               [req_opts: [plug: {Req.Test, name}]] ++ opts
             )

    assert Ash.get!(PostgresSubscription, sub.id, @pg).status == :past_due
    assert Ash.get!(PostgresSubscription, sub.id, @pg).price_id == "price_original"
  end

  test "H2 subscription Checkout rejects multiple lines before provider calls; payment supports them" do
    opts = [
      provider: AshBilling.Test.HardeningProvider,
      line_items: [%{price: "price_a"}, %{price: "price_b"}],
      success_url: "https://example.test/success",
      cancel_url: "https://example.test/cancel"
    ]

    assert {:error, :unsupported_subscription_items} =
             AshBilling.create_checkout_session("cus_owned", opts)

    refute_received {:provider_called, :create_checkout_session, _}
    assert {:ok, _} = AshBilling.create_checkout_session("cus_owned", [mode: "payment"] ++ opts)
  end

  test "H3 denied local persistence retains remote customer ID for recovery" do
    user = Ash.create!(AshBilling.Test.PolicyUser, %{}, authorize?: false)

    assert {:error, {:persistence_failed, "cus_custom", _}} =
             AshBilling.create_customer(user,
               provider: AshBilling.Test.HardeningProvider,
               persist: true,
               authorize?: true
             )

    assert Ash.get!(AshBilling.Test.PolicyUser, user.id, authorize?: false).stripe_customer_id ==
             nil
  end

  test "H3 persist false and existing customer retain their explicit contracts" do
    user = Ash.create!(User, %{}, @ash)

    assert {:ok, "cus_custom"} =
             AshBilling.create_customer(user,
               provider: AshBilling.Test.HardeningProvider,
               persist: false
             )

    assert Ash.get!(User, user.id, @ash).stripe_customer_id == nil
    assert_receive {:provider_called, :create_customer, _}
    user = Ash.update!(user, %{stripe_customer_id: "cus_existing"}, @ash)

    assert {:ok, "cus_existing"} =
             AshBilling.create_customer(user, provider: AshBilling.Test.HardeningProvider)

    refute_received {:provider_called, :create_customer, _}
  end

  test "H4 record ownership references cannot be replaced by caller metadata" do
    user = %User{id: Ash.UUID.generate(), stripe_customer_id: "cus_owned"}

    assert {:ok, _} =
             AshBilling.create_checkout_session(user,
               provider: AshBilling.Test.HardeningProvider,
               price: "price_pro",
               success_url: "https://example.test/success",
               cancel_url: "https://example.test/cancel",
               metadata: %{"resource_id" => "attacker", :resource_id => "attacker"},
               subscription_data: %{
                 "metadata" => %{"resource_id" => "attacker", :resource_id => "attacker"}
               },
               client_reference_id: "attacker"
             )

    assert_receive {:provider_called, :create_checkout_session, [params, _]}
    assert params.client_reference_id == user.id
    assert params.metadata == %{"resource_id" => user.id}
    assert params.subscription_data.metadata == %{"resource_id" => user.id}
  end

  test "H4 a loaded customer from another tenant fails before remote effects" do
    tenant = unique("tenant_hardening_")
    resource = AshBilling.Test.PostgresScopedCustomer

    user =
      Ash.create!(resource, %{stripe_customer_id: unique("cus_scoped_")}, [tenant: tenant] ++ @pg)

    on_exit(fn -> Ash.destroy!(user, [tenant: tenant] ++ @pg) end)

    assert {:error, :customer_tenant_mismatch} =
             AshBilling.create_customer(user,
               provider: AshBilling.Test.HardeningProvider,
               tenant: "another_tenant"
             )

    assert {:error, :customer_tenant_mismatch} =
             AshBilling.create_checkout_session(user,
               provider: AshBilling.Test.HardeningProvider,
               tenant: "another_tenant"
             )

    refute_received {:provider_called, _, _}
  end

  test "H3 raw params cannot silently ignore required persistence" do
    assert {:error, :invalid_customer_resource} =
             AshBilling.create_customer(%{email: "raw@example.test"},
               provider: AshBilling.Test.HardeningProvider,
               persist: true
             )

    refute_received {:provider_called, _, _}
  end

  for strategy <- [:memory, :disabled] do
    test "H5 #{strategy} also rolls back handler SQL and does not prematurely mark memory processed" do
      {user, sub, base_opts} = pg_fixture()

      opts =
        base_opts
        |> Keyword.delete(:deduplication_resource)
        |> Keyword.merge(
          deduplication_strategy: :memory,
          deduplicate?: unquote(strategy != :disabled)
        )

      ev =
        event("customer.subscription.deleted", %{
          "id" => sub.provider_subscription_id,
          "customer" => user.stripe_customer_id,
          "status" => "canceled"
        })
        |> Map.put("local_subscription_id", sub.id)
        |> Map.put("handler_outcome", "error")

      assert request(ev, [handler: WritingHandler] ++ opts).status == 500
      assert Ash.get!(PostgresSubscription, sub.id, @pg).status == :active
      assert Ash.get!(PostgresSubscription, sub.id, @pg).price_id == "price_original"
      refute AshBilling.Deduplication.processed?(ev["id"], opts)
      assert request(ev, opts).status == 200
      assert Ash.get!(PostgresSubscription, sub.id, @pg).status == :canceled
    end
  end

  for outcome <- ["error", "raise", "unexpected"] do
    test "legacy acknowledgment opt-out #{outcome} preserves rollback and rejects non-business failures" do
      {user, sub, opts} = pg_fixture()

      ev =
        event("customer.subscription.deleted", %{
          "id" => sub.provider_subscription_id,
          "customer" => user.stripe_customer_id,
          "status" => "canceled"
        })
        |> Map.put("local_subscription_id", sub.id)
        |> Map.put("handler_outcome", unquote(outcome))

      on_exit(fn ->
        AshBilling.Test.Repo.query!("DELETE FROM webhook_events WHERE event_id = $1", [ev["id"]])
      end)

      expected = if unquote(outcome) == "error", do: 200, else: 500

      assert request(ev, [handler: WritingHandler, return_500_on_sync_error: false] ++ opts).status ==
               expected

      assert Ash.get!(PostgresSubscription, sub.id, @pg).status == :active
      assert Ash.get!(PostgresSubscription, sub.id, @pg).price_id == "price_original"
      assert Ash.get!(PostgresWebhookEvent, ev["id"], @pg).status == :failed
    end
  end

  test "successful handler ok tuple commits SQL and durable completion together" do
    {user, sub, opts} = pg_fixture()

    ev =
      event("customer.subscription.deleted", %{
        "id" => sub.provider_subscription_id,
        "customer" => user.stripe_customer_id,
        "status" => "canceled"
      })
      |> Map.put("local_subscription_id", sub.id)
      |> Map.put("handler_outcome", "ok_tuple")

    on_exit(fn ->
      AshBilling.Test.Repo.query!("DELETE FROM webhook_events WHERE event_id = $1", [ev["id"]])
    end)

    assert request(ev, [handler: WritingHandler] ++ opts).status == 200
    assert Ash.get!(PostgresSubscription, sub.id, @pg).status == :canceled
    assert Ash.get!(PostgresSubscription, sub.id, @pg).price_id == "price_uncommitted_handler"
    assert Ash.get!(PostgresWebhookEvent, ev["id"], @pg).status == :processed
  end

  test "H4 separate BEAM nodes converge on the same persisted customer identity" do
    alias AshBilling.Test.Repo
    user = Ash.create!(PostgresCustomer, %{}, @pg)
    on_exit(fn -> Ash.destroy!(user, @pg) end)
    {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: [~c"+S", ~c"2:2"]})

    try do
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
      :ok = :peer.call(peer, Application, :put_env, [:ash_billing, Repo, Repo.config()])
      assert {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ash_billing])
      assert {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ash_postgres])
      assert {:ok, _} = :peer.call(peer, AshBilling.Test.SecurityProvider, :start_repo, [])
      opts = [provider: AshBilling.Test.HardeningProvider, persist: true] ++ @pg
      remote = Task.async(fn -> :peer.call(peer, AshBilling, :create_customer, [user, opts]) end)
      assert {:ok, "cus_custom"} = AshBilling.create_customer(user, opts)
      assert {:ok, "cus_custom"} = Task.await(remote)
      assert Ash.get!(PostgresCustomer, user.id, @pg).stripe_customer_id == "cus_custom"
    after
      :peer.stop(peer)
    end
  end

  test "H4 nil tenant options retain the loaded tenant for persistence and idempotency" do
    tenant = unique("tenant_inherited_")
    resource = AshBilling.Test.PostgresScopedCustomer
    user = Ash.create!(resource, %{}, [tenant: tenant] ++ @pg)
    on_exit(fn -> Ash.destroy!(user, [tenant: tenant] ++ @pg) end)
    opts = [provider: AshBilling.Test.HardeningProvider, persist: true, tenant: nil] ++ @pg
    assert {:ok, "cus_custom"} = AshBilling.create_customer(user, opts)
    assert_receive {:provider_called, :create_customer, [_, first_opts]}
    assert Ash.get!(resource, user.id, [tenant: tenant] ++ @pg).stripe_customer_id == "cus_custom"

    assert {:ok, "cus_custom"} =
             AshBilling.create_customer(user, Keyword.merge(opts, persist: false, tenant: tenant))

    assert_receive {:provider_called, :create_customer, [_, second_opts]}
    assert first_opts[:idempotency_key] == second_opts[:idempotency_key]
  end
end
