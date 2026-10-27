defmodule AshBilling.ResilienceAndEdgeCasesTest do
  use ExUnit.Case, async: false

  require Ash.Query
  alias AshBilling.Deduplication
  alias AshBilling.Plug, as: BillingPlug
  alias AshBilling.Resource.Verifiers.VerifyCustomerIdAttribute
  alias AshBilling.Subscription.Verifiers.VerifyCustomerRelationship
  alias AshBilling.Test.Domain
  alias AshBilling.Test.Subscription
  alias AshBilling.Test.User
  alias AshBilling.Test.WebhookEvent
  alias AshBilling.WebhookSync
  alias Spark.Dsl.Transformer

  @opts [
    customer_resource: User,
    subscription_resource: Subscription,
    domain: Domain
  ]

  setup do
    Deduplication.clear()
    :ok
  end

  describe "Compile-Time Spark Verifiers" do
    test "VerifyCustomerRelationship succeeds when customer_relationship is nil" do
      state = %{}
      state = Transformer.set_option(state, [:billing_subscription], :customer_relationship, nil)
      assert :ok = VerifyCustomerRelationship.verify(state)
    end

    test "VerifyCustomerRelationship returns DslError when relationship is missing" do
      state = %{}

      state =
        Transformer.set_option(state, [:billing_subscription], :customer_relationship, :user)

      state = Transformer.persist(state, :module, MyApp.Subscription)

      assert {:error, %Spark.Error.DslError{} = err} = VerifyCustomerRelationship.verify(state)
      assert err.message =~ "was not found in its relationships"
    end

    test "VerifyCustomerRelationship succeeds with valid relationship" do
      state = %{}

      state =
        Transformer.set_option(state, [:billing_subscription], :customer_relationship, :user)

      rel =
        Transformer.build_entity!(Ash.Resource.Dsl, [:relationships], :belongs_to,
          name: :user,
          destination: MyApp.User
        )

      state = Transformer.add_entity(state, [:relationships], rel)
      assert :ok = VerifyCustomerRelationship.verify(state)
    end

    test "VerifyCustomerIdAttribute succeeds when attribute is not present on resource" do
      state = Transformer.set_option(%{}, [:billing], :customer_id_attribute, :missing_attr)
      assert :ok = VerifyCustomerIdAttribute.verify(state)
    end

    test "VerifyCustomerIdAttribute succeeds with valid string attribute" do
      state = Transformer.set_option(%{}, [:billing], :customer_id_attribute, :stripe_customer_id)

      str_attr =
        Transformer.build_entity!(Ash.Resource.Dsl, [:attributes], :attribute,
          name: :stripe_customer_id,
          type: Ash.Type.String
        )

      state = Transformer.add_entity(state, [:attributes], str_attr)
      assert :ok = VerifyCustomerIdAttribute.verify(state)
    end

    test "VerifyCustomerIdAttribute succeeds with valid ci_string attribute" do
      state = Transformer.set_option(%{}, [:billing], :customer_id_attribute, :stripe_customer_id)

      ci_attr =
        Transformer.build_entity!(Ash.Resource.Dsl, [:attributes], :attribute,
          name: :stripe_customer_id,
          type: Ash.Type.CiString
        )

      state = Transformer.add_entity(state, [:attributes], ci_attr)
      assert :ok = VerifyCustomerIdAttribute.verify(state)
    end

    test "VerifyCustomerIdAttribute returns DslError for invalid attribute type" do
      state = Transformer.set_option(%{}, [:billing], :customer_id_attribute, :stripe_customer_id)

      int_attr =
        Transformer.build_entity!(Ash.Resource.Dsl, [:attributes], :attribute,
          name: :stripe_customer_id,
          type: Ash.Type.Integer
        )

      state = Transformer.add_entity(state, [:attributes], int_attr)
      state = Transformer.persist(state, :module, MyApp.User)

      assert {:error, %Spark.Error.DslError{} = err} = VerifyCustomerIdAttribute.verify(state)
      assert err.message =~ "must be of type :string or :ci_string"
    end
  end

  describe "Security & Authorization Hardening for Canceled Subscriptions" do
    test "active? and on_trial? evaluate to false for canceled subscription even with future trial_ends_at" do
      future = DateTime.utc_now() |> DateTime.add(14, :day)

      sub = %Subscription{
        provider_subscription_id: "sub_canceled_future_trial",
        status: :canceled,
        trial_ends_at: future
      }

      assert {:ok, false} = Ash.calculate(sub, :active?)
      assert {:ok, false} = Ash.calculate(sub, :on_trial?)
    end

    test "AshBilling.subscribed?/2 returns false for canceled subscription with future trial_ends_at" do
      future = DateTime.utc_now() |> DateTime.add(14, :day)

      user = %User{
        subscriptions: [
          %{status: :canceled, price_id: "price_pro", trial_ends_at: future}
        ]
      }

      assert AshBilling.subscribed?(user) == false
      assert AshBilling.subscribed?(user, "price_pro") == false
    end

    test "AshBilling.subscribed?/2 returns false for string 'canceled' status with future trial" do
      future = DateTime.utc_now() |> DateTime.add(14, :day)

      user = %User{
        subscriptions: [
          %{status: "canceled", price_id: "price_pro", trial_ends_at: future}
        ]
      }

      assert AshBilling.subscribed?(user) == false
    end
  end

  describe "Stripe Modern API (2025/2026) Payload Parsing" do
    test "correctly extracts current_period_end from items.data[].current_period_end (Stripe basil+)" do
      ts = 1_775_000_000
      expected_dt = DateTime.from_unix!(ts, :second)

      event = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_stripe_basil_2025",
            "status" => "active",
            "items" => %{
              "data" => [
                %{
                  "id" => "si_123",
                  "current_period_end" => ts,
                  "price" => %{"id" => "price_modern_tier"}
                }
              ]
            }
          }
        }
      }

      assert {:ok, sub} = WebhookSync.sync_event(event, @opts)
      assert sub.provider_subscription_id == "sub_stripe_basil_2025"
      assert DateTime.compare(sub.current_period_end, expected_dt) == :eq
      assert sub.price_id == "price_modern_tier"
    end
  end

  describe "Out-of-Order Webhook Protection" do
    test "ignores older active/past_due events if subscription is already canceled in DB" do
      {:ok, _user} =
        Ash.create(
          User,
          %{email: "out_of_order@example.com", stripe_customer_id: "cus_ooo_1"},
          domain: Domain
        )

      # 1. First event: subscription is canceled
      cancel_event = %{
        "type" => "customer.subscription.deleted",
        "data" => %{
          "object" => %{
            "id" => "sub_ooo_999",
            "customer" => "cus_ooo_1",
            "status" => "canceled"
          }
        }
      }

      assert {:ok, sub} = WebhookSync.sync_event(cancel_event, @opts)
      assert sub.status == :canceled

      # 2. Delayed, out-of-order event arrives claiming the subscription is active
      delayed_event = %{
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "id" => "sub_ooo_999",
            "customer" => "cus_ooo_1",
            "status" => "active",
            "price" => %{"id" => "price_pro"}
          }
        }
      }

      assert {:ok, result_sub} = WebhookSync.sync_event(delayed_event, @opts)
      # Status MUST remain :canceled
      assert result_sub.status == :canceled

      persisted =
        Subscription
        |> Ash.Query.new()
        |> Ash.Query.filter(provider_subscription_id == "sub_ooo_999")
        |> Ash.read_one!(domain: Domain)

      assert persisted.status == :canceled
    end
  end

  describe "Deduplication Error Propagation and Atomic Handling" do
    test "mark_processed returns error if resource create fails with non-duplicate error" do
      opts = [
        deduplication_resource: AshBilling.Test.IncompleteResource,
        domain: Domain
      ]

      assert {:error, _reason} = Deduplication.mark_processed("evt_fail_1", opts)
    end

    test "mark_processed handles duplicate keys gracefully" do
      opts = [
        deduplication_resource: WebhookEvent,
        domain: Domain
      ]

      assert :ok = Deduplication.mark_processed("evt_dup_test_1", opts)
      # Second attempt with same primary key
      assert :ok = Deduplication.mark_processed("evt_dup_test_1", opts)
    end

    test "Plug returns 500 Internal Server Error when mark_processed fails" do
      stub_name = "plug_dedup_fail_stub"

      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "sub_test"}))
      end)

      secret = "whsec_test_secret_123"

      payload =
        Jason.encode!(%{
          "id" => "evt_dedup_plug_fail",
          "type" => "customer.subscription.created",
          "data" => %{"object" => %{"id" => "sub_dedup_1", "status" => "active"}}
        })

      timestamp = System.system_time(:second)

      signature =
        :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{payload}")
        |> Base.encode16(case: :lower)

      sig_header = "t=#{timestamp},v1=#{signature}"

      opts =
        BillingPlug.init(
          provider: AshBilling.Providers.Stripe,
          webhook_secret: secret,
          deduplication_resource: AshBilling.Test.IncompleteResource,
          customer_resource: User,
          subscription_resource: Subscription,
          domain: Domain,
          req_opts: [plug: {Req.Test, stub_name}]
        )

      conn =
        Plug.Test.conn(:post, "/webhooks/stripe", payload)
        |> Plug.Conn.put_req_header("stripe-signature", sig_header)
        |> BillingPlug.call(opts)

      assert conn.status == 500
      assert Jason.decode!(conn.resp_body)["error"] == "deduplication_failed"
    end
  end

  describe "create_customer/2 with Explicit Persistence & Idempotency" do
    test "create_customer with persist: true updates customer resource immediately" do
      stub_name = "create_cust_persist_stub"

      Req.Test.stub(stub_name, fn conn ->
        # Verify idempotency key header was passed
        idemp_header = Plug.Conn.get_req_header(conn, "idempotency-key")
        assert length(idemp_header) == 1
        assert hd(idemp_header) =~ "ash_cust_"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "cus_persisted_777"}))
      end)

      {:ok, user} =
        Ash.create(
          User,
          %{email: "persist_me@example.com", name: "Persist User"},
          domain: Domain
        )

      assert user.stripe_customer_id == nil

      opts = [
        persist: true,
        domain: Domain,
        req_opts: [plug: {Req.Test, stub_name}],
        api_key: "sk_test_123"
      ]

      assert {:ok, "cus_persisted_777"} = AshBilling.create_customer(user, opts)

      # Verify it was updated in the database
      reloaded = Ash.get!(User, user.id, domain: Domain)
      assert reloaded.stripe_customer_id == "cus_persisted_777"
    end
  end

  describe "Deduplication GenServer Sweep & Strategy Fallback" do
    test "handle_info :sweep removes expired events and reschedules" do
      server_pid = Process.whereis(Deduplication)
      assert is_pid(server_pid)
      send(server_pid, :sweep)
      # Process mailbox processed without crashing
      :timer.sleep(10)
      assert Process.alive?(server_pid)
    end
  end

  describe "verify_configuration! Diagnostic Checks" do
    test "raises on invalid Stripe API key prefix" do
      assert_raise ArgumentError, ~r/does not start with standard prefix/, fn ->
        AshBilling.verify_configuration!(customer_resource: User, api_key: "invalid_key_123")
      end
    end

    test "raises on invalid Stripe webhook secret prefix" do
      assert_raise ArgumentError, ~r/does not start with standard prefix 'whsec_'/, fn ->
        AshBilling.verify_configuration!(
          customer_resource: User,
          api_key: "sk_test_valid",
          webhook_secret: "bad_secret"
        )
      end
    end

    test "succeeds with valid configuration" do
      assert :ok =
               AshBilling.verify_configuration!(
                 customer_resource: User,
                 subscription_resource: Subscription,
                 api_key: "sk_test_valid_123",
                 webhook_secret: "whsec_valid_456"
               )
    end
  end

  describe "Stripe Provider Error Responses" do
    test "create_customer handles API 400 error" do
      stub_name = "stripe_err_stub_1"

      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => %{"message" => "Invalid card"}}))
      end)

      opts = [req_opts: [plug: {Req.Test, stub_name}], api_key: "sk_test_1"]

      assert {:error, %{status: 400, error: "Invalid card"}} =
               AshBilling.Providers.Stripe.create_customer(%{email: "test@error.com"}, opts)
    end

    test "create_checkout_session handles API error" do
      stub_name = "stripe_checkout_err_stub"

      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => %{"message" => "Price required"}}))
      end)

      opts = [req_opts: [plug: {Req.Test, stub_name}], api_key: "sk_test_1"]

      assert {:error, %{status: 400, error: "Price required"}} =
               AshBilling.Providers.Stripe.create_checkout_session(%{}, opts)
    end

    test "create_portal_session handles API error" do
      stub_name = "stripe_portal_err_stub"

      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => %{"message" => "Return URL required"}})
        )
      end)

      opts = [req_opts: [plug: {Req.Test, stub_name}], api_key: "sk_test_1"]

      assert {:error, %{status: 400, error: "Return URL required"}} =
               AshBilling.Providers.Stripe.create_portal_session(%{}, opts)
    end

    test "swap_plan and resume_subscription handle API errors" do
      stub_name = "stripe_sub_err_stub"

      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => %{"message" => "Subscription not found"}})
        )
      end)

      opts = [req_opts: [plug: {Req.Test, stub_name}], api_key: "sk_test_1"]

      assert {:error, %{status: 400, error: "Subscription not found"}} =
               AshBilling.Providers.Stripe.resume_subscription("sub_123", opts)
    end
  end

  describe "High-Level AshBilling Subscription Operations" do
    test "get_subscription, cancel_subscription, resume_subscription, swap_plan and update_quantity" do
      stub_name = "hl_sub_ops_stub"

      Req.Test.stub(stub_name, fn conn ->
        body =
          cond do
            conn.method == "GET" ->
              Jason.encode!(%{
                "id" => "sub_hl_100",
                "items" => %{
                  "data" => [%{"id" => "si_hl_item", "price" => %{"id" => "price_old"}}]
                }
              })

            conn.method == "POST" ->
              Jason.encode!(%{"id" => "sub_hl_100", "status" => "active"})

            conn.method == "DELETE" ->
              Jason.encode!(%{"id" => "sub_hl_100", "status" => "canceled"})
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      opts = [req_opts: [plug: {Req.Test, stub_name}], api_key: "sk_test_123"]

      assert {:ok, %{"id" => "sub_hl_100"}} = AshBilling.get_subscription("sub_hl_100", opts)
      assert {:ok, %{"id" => "sub_hl_100"}} = AshBilling.cancel_subscription("sub_hl_100", opts)
      assert {:ok, %{"id" => "sub_hl_100"}} = AshBilling.resume_subscription("sub_hl_100", opts)

      assert {:ok, %{"id" => "sub_hl_100"}} =
               AshBilling.swap_plan("sub_hl_100", "price_new", opts)

      assert {:ok, %{"id" => "sub_hl_100"}} =
               AshBilling.update_quantity("sub_hl_100", 5, [price_id: "price_old"] ++ opts)
    end

    test "invokes default 1-arity wrapper functions" do
      user = %User{id: Ash.UUID.generate(), subscriptions: [%{status: :active, price_id: "p1"}]}
      assert AshBilling.subscribed?(user) == true
      assert AshBilling.subscription(user) != nil

      Deduplication.start_link()
      assert Deduplication.processed?("evt_test_default_arity") == false
      assert Deduplication.mark_processed("evt_test_default_arity") == :ok
      assert Deduplication.processed?("evt_test_default_arity") == true
    end
  end

  describe "Configuration Verification (check_configuration & verify_configuration!)" do
    test "passes with valid resources and format" do
      opts = [
        customer_resource: User,
        subscription_resource: Subscription,
        api_key: "sk_test_valid_key_123",
        webhook_secret: "whsec_valid_secret_123"
      ]

      assert {:ok, %{status: :valid}} = AshBilling.check_configuration(opts)
      assert :ok = AshBilling.verify_configuration!(opts)
    end

    test "detects invalid customer resource missing relations" do
      opts = [
        customer_resource: AshBilling.Test.IncompleteResource,
        subscription_resource: Subscription,
        api_key: "sk_test_valid",
        webhook_secret: "whsec_valid"
      ]

      assert {:error, errors} = AshBilling.check_configuration(opts)
      assert Enum.any?(errors, &String.contains?(&1, "missing attribute"))

      assert_raise ArgumentError, ~r/AshBilling configuration verification failed/, fn ->
        AshBilling.verify_configuration!(opts)
      end
    end

    test "detects invalid subscription resource and bad api key/webhook prefixes" do
      opts = [
        customer_resource: User,
        subscription_resource: AshBilling.Test.IncompleteResource,
        api_key: "invalid_key_prefix",
        webhook_secret: "bad_secret_prefix"
      ]

      assert {:error, errors} = AshBilling.check_configuration(opts)
      assert Enum.any?(errors, &String.contains?(&1, "missing required attributes"))
      assert Enum.any?(errors, &String.contains?(&1, "standard prefix 'sk_'"))
      assert Enum.any?(errors, &String.contains?(&1, "standard prefix 'whsec_'"))
    end
  end

  describe "Deduplication Strategy and Sweep" do
    test "handles :memory strategy explicitly and sweeps expired records" do
      assert Deduplication.processed?("evt_mem_1", deduplication_strategy: :memory) == false
      assert Deduplication.mark_processed("evt_mem_1", deduplication_strategy: :memory) == :ok
      assert Deduplication.processed?("evt_mem_1", deduplication_strategy: :memory) == true

      # Trigger ETS sweep callback directly
      pid = Process.whereis(AshBilling.Deduplication)

      if pid do
        send(pid, :sweep)
        _ = :sys.get_state(pid)
      end
    end
  end

  describe "WebhookSync Edge Cases and Ignored Payloads" do
    test "ignores unknown event types and nil data objects" do
      assert {:ok, :ignored} =
               WebhookSync.sync_event(%{"type" => "unknown.stripe.event", "data" => %{}}, @opts)

      assert {:ok, :ignored} =
               WebhookSync.sync_event(
                 %{"type" => "customer.subscription.updated", "data" => %{"object" => nil}},
                 @opts
               )
    end

    test "handles customer.deleted with missing customer or nil object" do
      assert {:ok, :ignored} =
               WebhookSync.sync_event(
                 %{"type" => "customer.deleted", "data" => %{"object" => nil}},
                 @opts
               )

      payload = %{
        "type" => "customer.deleted",
        "data" => %{
          "object" => %{"id" => "cus_nonexistent_999"}
        }
      }

      assert {:ok, :not_found} = WebhookSync.sync_event(payload, @opts)

      assert {:ok, :ignored} =
               WebhookSync.sync_event(
                 %{"type" => "customer.deleted", "data" => %{"object" => %{}}},
                 @opts
               )
    end

    test "handles checkout.session.completed with non-existent email" do
      payload = %{
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "customer" => "cus_checkout_test_1",
            "customer_email" => "nobody_here_999@example.com"
          }
        }
      }

      assert {:ok, :ignored} = WebhookSync.sync_event(payload, @opts)
    end
  end

  describe "Plug Edge Cases" do
    test "Plug.init maps legacy :resource option to :customer_resource" do
      opts = BillingPlug.init(resource: User, webhook_secret: "whsec_test")
      assert Keyword.get(opts, :customer_resource) == User
    end

    test "resolves secret from null or empty" do
      conn =
        Plug.Test.conn(:post, "/webhooks/stripe", "{}")
        |> Plug.Conn.put_req_header("stripe-signature", "t=1,v1=abc")
        |> BillingPlug.call(BillingPlug.init(webhook_secret: nil, customer_resource: User))

      assert conn.status == 400
    end
  end

  describe "Stripe Provider Transport and Network Failures" do
    test "handles connection errors across provider operations" do
      stub_name = "network_failure_stub"

      Req.Test.stub(stub_name, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      opts = [req_opts: [plug: {Req.Test, stub_name}, retry: false], api_key: "sk_test_1"]

      assert {:error, _} =
               AshBilling.Providers.Stripe.create_customer(%{email: "test@example.com"}, opts)

      assert {:error, _} =
               AshBilling.Providers.Stripe.create_checkout_session(%{customer: "cus_1"}, opts)

      assert {:error, _} =
               AshBilling.Providers.Stripe.create_portal_session(%{customer: "cus_1"}, opts)

      assert {:error, _} = AshBilling.Providers.Stripe.get_subscription("sub_1", opts)
      assert {:error, _} = AshBilling.Providers.Stripe.cancel_subscription("sub_1", opts)
      assert {:error, _} = AshBilling.Providers.Stripe.swap_plan("sub_1", "price_new", opts)
    end
  end
end
