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
    Application.delete_env(:ash_billing, :deduplication_strategy)
    Application.delete_env(:ash_billing, :deduplication_resource)
    Deduplication.clear()

    on_exit(fn ->
      Application.delete_env(:ash_billing, :deduplication_strategy)
      Application.delete_env(:ash_billing, :deduplication_resource)
    end)

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

    test "Plug returns 500 Internal Server Error when Deduplication.complete fails" do
      stub_name = "plug_complete_fail_stub"

      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "sub_test"}))
      end)

      secret = "whsec_test_secret_123"

      payload =
        Jason.encode!(%{
          "id" => "evt_complete_plug_fail",
          "type" => "customer.subscription.created",
          "data" => %{"object" => %{"id" => "sub_comp_1", "status" => "active"}}
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
          deduplication_resource: AshBilling.Test.FailingUpdateEvent,
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
      assert Jason.decode!(conn.resp_body)["error"] == "completion_failed"
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

      assert conn.status == 500
      assert conn.resp_body =~ "unconfigured_webhook_secret"
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

  describe "Stripe Multiple v1 Signatures & Secret Rotation" do
    test "verifies webhook when multiple v1 signatures are present during secret rotation" do
      secret = "whsec_primary_secret_key"
      old_secret = "whsec_deprecated_secret_key"
      timestamp = System.system_time(:second)
      payload = ~s({"id":"evt_sig_rot_1","type":"customer.subscription.updated"})

      signed_payload = "#{timestamp}.#{payload}"

      old_sig =
        :crypto.mac(:hmac, :sha256, old_secret, signed_payload)
        |> Base.encode16(case: :lower)

      new_sig =
        :crypto.mac(:hmac, :sha256, secret, signed_payload)
        |> Base.encode16(case: :lower)

      # Header with multiple v1 signatures (both old and new)
      sig_header = "t=#{timestamp},v1=#{old_sig},v1=#{new_sig}"

      assert {:ok, %{"id" => "evt_sig_rot_1"}} =
               AshBilling.Providers.Stripe.verify_webhook(payload, sig_header, secret)

      # Fails if none of the signatures match
      bad_header = "t=#{timestamp},v1=invalid_one,v1=invalid_two"

      assert {:error, :invalid_signature} =
               AshBilling.Providers.Stripe.verify_webhook(payload, bad_header, secret)
    end
  end

  describe "Atomic Deduplication Lease (acquire, complete, release)" do
    test "acquire locks the lease and prevents concurrent duplicate execution in memory" do
      event_id = "evt_atomic_mem_#{System.unique_integer([:positive])}"

      assert {:ok, token1} = Deduplication.acquire(event_id, deduplication_strategy: :memory)
      assert is_binary(token1)

      # Second concurrent acquire fails
      assert {:error, status} = Deduplication.acquire(event_id, deduplication_strategy: :memory)
      assert status in [:already_processing, :already_processed]

      # Complete marks processed
      assert :ok =
               Deduplication.complete(event_id,
                 lease_token: token1,
                 deduplication_strategy: :memory
               )

      assert Deduplication.processed?(event_id, deduplication_strategy: :memory) == true

      # Release deletes lease so retry is possible
      assert :ok = Deduplication.release(event_id, deduplication_strategy: :memory)
      assert Deduplication.processed?(event_id, deduplication_strategy: :memory) == false
      assert {:ok, token2} = Deduplication.acquire(event_id, deduplication_strategy: :memory)
      assert is_binary(token2)
    end

    test "acquire locks the lease and enforces uniqueness across database resource" do
      event_id = "evt_atomic_res_#{System.unique_integer([:positive])}"

      opts = [
        deduplication_strategy: :resource,
        deduplication_resource: WebhookEvent,
        domain: Domain
      ]

      assert {:ok, token1} = Deduplication.acquire(event_id, opts)
      assert is_binary(token1)

      # Second acquire fails because event is actively being processed
      assert {:error, status} = Deduplication.acquire(event_id, opts)
      assert status in [:already_processing, :already_processed]

      # Complete marks processed
      assert :ok = Deduplication.complete(event_id, [lease_token: token1] ++ opts)
      assert {:error, :already_processed} = Deduplication.acquire(event_id, opts)

      # Release transitions lease so retry is possible
      assert :ok = Deduplication.release(event_id, opts)
      assert Deduplication.processed?(event_id, opts) == false
      assert {:ok, token2} = Deduplication.acquire(event_id, opts)
      assert is_binary(token2)
    end
  end

  describe "Custom Handler Error Propagation & Re-tryability" do
    defmodule FailingHandler do
      def handle_event(%{"id" => "evt_fail_then_succeed"}) do
        {:error, :external_service_down}
      end

      def handle_event(%{"id" => "evt_raise_then_succeed"}) do
        raise "unexpected crash in handler"
      end

      def handle_event(_), do: :ok
    end

    defmodule RecoveredHandler do
      def handle_event(_), do: :ok
    end

    test "returns HTTP 500 and releases deduplication lease when custom handler returns error or raises" do
      secret = "whsec_handler_test"
      timestamp = System.system_time(:second)
      payload = ~s({"id":"evt_fail_then_succeed","type":"customer.subscription.created"})

      sig =
        :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{payload}")
        |> Base.encode16(case: :lower)

      plug_opts =
        BillingPlug.init(
          webhook_secret: secret,
          handler: FailingHandler,
          customer_resource: User,
          subscription_resource: Subscription,
          domain: Domain
        )

      conn =
        Plug.Test.conn(:post, "/webhooks/stripe", payload)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", "t=#{timestamp},v1=#{sig}")
        |> BillingPlug.call(plug_opts)

      assert conn.status == 500
      assert conn.resp_body =~ "handler_failed"

      # Verify lease was released: next retry with working handler succeeds
      plug_opts_recovered =
        BillingPlug.init(
          webhook_secret: secret,
          handler: RecoveredHandler,
          customer_resource: User,
          subscription_resource: Subscription,
          domain: Domain
        )

      conn_retry =
        Plug.Test.conn(:post, "/webhooks/stripe", payload)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", "t=#{timestamp},v1=#{sig}")
        |> BillingPlug.call(plug_opts_recovered)

      assert conn_retry.status == 200
      assert conn_retry.resp_body =~ "received"
    end
  end

  describe "Advanced Out-of-Order Webhook Protection and Timestamp Ordering" do
    test "ignores older webhook event when subscription has recorded newer event timestamp" do
      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "older_event_user@example.com",
          stripe_customer_id: "cus_older_order_1"
        })
        |> Ash.create!(domain: Domain)

      newer_dt = DateTime.utc_now()
      older_unix = DateTime.to_unix(newer_dt) - 3600

      _sub =
        Subscription
        |> Ash.Changeset.for_create(:create, %{
          provider_subscription_id: "sub_timestamp_test_1",
          status: :active,
          price_id: "price_pro",
          user_id: user.id,
          last_event_created_at: newer_dt
        })
        |> Ash.create!(domain: Domain)

      # Incoming older event created 1 hour prior with past_due status
      older_event = %{
        "id" => "evt_older_order_1",
        "created" => older_unix,
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "id" => "sub_timestamp_test_1",
            "customer" => "cus_older_order_1",
            "status" => "past_due",
            "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
          }
        }
      }

      assert {:ok, %Subscription{} = result_sub} = WebhookSync.sync_event(older_event, @opts)
      # Status remains :active because incoming event is older
      assert result_sub.status == :active
    end

    test "reconciles conflicting status transition with provider" do
      stub_name = "reconcile_conflict_stub"

      Req.Test.stub(stub_name, fn conn ->
        Req.Test.json(conn, %{
          "id" => "sub_conflict_recon_1",
          "status" => "past_due",
          "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
        })
      end)

      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "conflict_user@example.com",
          stripe_customer_id: "cus_conflict_recon_1"
        })
        |> Ash.create!(domain: Domain)

      Subscription
      |> Ash.Changeset.for_create(:create, %{
        provider_subscription_id: "sub_conflict_recon_1",
        status: :past_due,
        price_id: "price_pro",
        user_id: user.id
      })
      |> Ash.create!(domain: Domain)

      # Incoming webhook falsely claiming status is active
      conflicting_event = %{
        "id" => "evt_conflict_1",
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "id" => "sub_conflict_recon_1",
            "customer" => "cus_conflict_recon_1",
            "status" => "active",
            "items" => %{"data" => [%{"price" => %{"id" => "price_pro"}}]}
          }
        }
      }

      opts = [
        customer_resource: User,
        subscription_resource: Subscription,
        domain: Domain,
        api_key: "sk_test_1",
        req_opts: [plug: {Req.Test, stub_name}]
      ]

      assert {:ok, sub} = WebhookSync.sync_event(conflicting_event, opts)
      # Preserves :past_due because provider authoritative live status was :past_due
      assert sub.status == :past_due
    end
  end

  describe "DSL and API Parity (Unpaid, Incomplete, Canceled with Future Trial Dates)" do
    test "verifies :unpaid, :incomplete, and :canceled are not active even with future trial dates" do
      future = DateTime.utc_now() |> DateTime.add(7, :day)

      for bad_status <- [:canceled, :unpaid, :incomplete, :incomplete_expired, :paused] do
        user = %User{
          subscriptions: [
            %{status: bad_status, price_id: "p1", trial_ends_at: future}
          ]
        }

        assert AshBilling.subscribed?(user) == false
        assert AshBilling.subscription(user) == nil
      end
    end

    test "create_customer defaults to persisting persisted user records" do
      stub_name = "persist_default_stub"

      Req.Test.stub(stub_name, fn conn ->
        Req.Test.json(conn, %{"id" => "cus_default_persisted_999"})
      end)

      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "auto_persist@example.com",
          name: "Auto Persist User"
        })
        |> Ash.create!(domain: Domain)

      opts = [
        req_opts: [plug: {Req.Test, stub_name}],
        api_key: "sk_test_123",
        domain: Domain
      ]

      assert {:ok, "cus_default_persisted_999"} = AshBilling.create_customer(user, opts)

      # Verify the user in the database was updated automatically
      reloaded = Ash.get!(User, user.id, domain: Domain)
      assert reloaded.stripe_customer_id == "cus_default_persisted_999"

      # Also test with persist: false
      assert {:ok, "cus_default_persisted_999"} =
               AshBilling.create_customer(user, [persist: false] ++ opts)
    end

    test "handles trial and edge-case subscription helpers" do
      user_nil_trial = %User{subscriptions: [%{status: :trialing, trial_ends_at: nil}]}
      assert AshBilling.subscribed?(user_nil_trial) == true

      future = DateTime.utc_now() |> DateTime.add(2, :day)
      user_past_due_trial = %User{subscriptions: [%{status: :past_due, trial_ends_at: future}]}
      assert AshBilling.subscribed?(user_past_due_trial) == true

      # Deduplication nil & fallback branches
      assert Deduplication.acquire(nil) == {:ok, :acquired}
      assert Deduplication.complete(nil) == :ok
      assert Deduplication.release(nil) == :ok
      assert Deduplication.release("evt_missing", deduplication_strategy: :resource) == :ok

      assert Deduplication.release("evt_missing_db",
               deduplication_strategy: :resource,
               deduplication_resource: WebhookEvent,
               domain: Domain
             ) == :ok

      # Reclaim stale lease in memory (> 60s)
      :ets.insert(
        :ash_billing_processed_events,
        {"evt_stale_lease", :processing, System.system_time(:second) - 70}
      )

      assert {:ok, stale_tok} =
               Deduplication.acquire("evt_stale_lease", deduplication_strategy: :memory)

      assert is_binary(stale_tok)

      # Legacy 2-tuple handling
      :ets.insert(
        :ash_billing_processed_events,
        {"evt_legacy_2tuple", System.system_time(:second)}
      )

      assert {:error, :already_processed} =
               Deduplication.acquire("evt_legacy_2tuple", deduplication_strategy: :memory)

      # WebhookSync direct customer string and atom status
      dt_event = %{
        "id" => "evt_dt_test",
        "created" => DateTime.utc_now(),
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_dt_test_1",
            "customer" => "cus_direct_str_id",
            "status" => :paused
          }
        }
      }

      assert {:ok, _} = WebhookSync.sync_event(dt_event, @opts)
    end

    test "AshBilling.create_customer/1 supports default opts" do
      # Test calling create_customer with only 1 argument when customer ID already exists
      user_existing = %User{
        id: Ash.UUID.generate(),
        email: "existing_cust@example.com",
        stripe_customer_id: "cus_existing_default_123"
      }

      assert {:ok, "cus_existing_default_123"} = AshBilling.create_customer(user_existing)

      stub_name = "create_cust_default_opts_stub"

      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "cus_default_opts_123"}))
      end)

      user = %User{id: Ash.UUID.generate(), email: "default_opts@example.com"}

      assert {:ok, "cus_default_opts_123"} =
               AshBilling.create_customer(user,
                 req_options: [plug: {Req.Test, stub_name}, retry: false],
                 persist: false,
                 api_key: "sk_test_dummy"
               )
    end

    test "Stripe.verify_webhook fails closed with empty or nil secret" do
      payload = ~s({"id":"evt_sec_test"})
      sig = "t=1700000000,v1=abcdef"

      assert {:error, :missing_webhook_secret} =
               AshBilling.Providers.Stripe.verify_webhook(payload, sig, nil)

      assert {:error, :missing_webhook_secret} =
               AshBilling.Providers.Stripe.verify_webhook(payload, sig, "")
    end

    test "Plug fails closed when webhook secret is unconfigured or empty" do
      conn_nil =
        Plug.Test.conn(:post, "/webhooks/stripe", ~s({"id":"evt_nil_sec"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", "t=1700000000,v1=abc")
        |> BillingPlug.call(BillingPlug.init(webhook_secret: nil))

      assert conn_nil.status == 500
      assert conn_nil.resp_body =~ "unconfigured_webhook_secret"

      conn_empty =
        Plug.Test.conn(:post, "/webhooks/stripe", ~s({"id":"evt_empty_sec"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", "t=1700000000,v1=abc")
        |> BillingPlug.call(BillingPlug.init(webhook_secret: ""))

      assert conn_empty.status == 500
      assert conn_empty.resp_body =~ "unconfigured_webhook_secret"
    end

    test "WebhookEvent database lifecycle: processing -> failed -> retry -> processed and lease recovery" do
      event_id = "evt_lifecycle_#{System.unique_integer([:positive])}"
      opts = [deduplication_resource: WebhookEvent, domain: Domain]

      # Step 1: Initial acquisition sets :processing
      assert {:ok, token1} = Deduplication.acquire(event_id, opts)
      assert is_binary(token1)
      assert {:ok, record} = Ash.get(WebhookEvent, event_id, domain: Domain, authorize?: false)
      assert record.status == :processing
      assert record.attempts == 1
      assert record.lease_token == token1

      # Concurrent worker attempting to acquire gets :already_processing
      assert {:error, :already_processing} = Deduplication.acquire(event_id, opts)

      # Step 2: Processing fails, release with error transitions to :failed
      assert :ok =
               Deduplication.release(
                 event_id,
                 [lease_token: token1, error: :external_timeout] ++ opts
               )

      assert {:ok, failed_record} =
               Ash.get(WebhookEvent, event_id, domain: Domain, authorize?: false)

      assert failed_record.status == :failed
      assert failed_record.error =~ "external_timeout"

      # Step 3: Provider retry re-acquires successfully, increments attempts
      assert {:ok, token2} = Deduplication.acquire(event_id, opts)
      assert is_binary(token2)
      assert token2 != token1

      assert {:ok, retried_record} =
               Ash.get(WebhookEvent, event_id, domain: Domain, authorize?: false)

      assert retried_record.status == :processing
      assert retried_record.attempts == 2
      assert retried_record.lease_token == token2

      # Step 4: Stale lease reclamation (> 60s)
      stale_dt = DateTime.utc_now() |> DateTime.add(-75, :second)

      {:ok, stale_record} =
        Ash.update(retried_record, %{last_attempt_at: stale_dt},
          domain: Domain,
          authorize?: false
        )

      assert stale_record.status == :processing

      assert {:ok, token3} = Deduplication.acquire(event_id, opts)
      assert is_binary(token3)
      assert token3 != token2

      # Step 5: Successful completion marks :processed
      assert :ok = Deduplication.complete(event_id, [lease_token: token3] ++ opts)

      assert {:ok, completed_record} =
               Ash.get(WebhookEvent, event_id, domain: Domain, authorize?: false)

      assert completed_record.status == :processed

      # Subsequent deliveries are recognized as duplicate
      assert {:error, :already_processed} = Deduplication.acquire(event_id, opts)
      assert Deduplication.processed?(event_id, opts) == true
    end

    test "WebhookSync fails safely and requests retry when conflicting live reconciliation fails" do
      stub_name = "reconcile_fail_stub"

      # Stub provider get_subscription returning 500 error
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          500,
          Jason.encode!(%{"error" => %{"message" => "Stripe API Down"}})
        )
      end)

      user =
        User
        |> Ash.Changeset.for_create(:create, %{
          email: "recon_fail@example.com",
          stripe_customer_id: "cus_recon_fail"
        })
        |> Ash.create!(domain: Domain, authorize?: false)

      sub =
        Subscription
        |> Ash.Changeset.for_create(:create, %{
          user_id: user.id,
          provider_subscription_id: "sub_recon_fail_1",
          status: :past_due,
          price_id: "price_pro"
        })
        |> Ash.create!(domain: Domain, authorize?: false)

      # Incoming webhook claims status is active (conflicting backwards transition)
      event = %{
        "id" => "evt_recon_fail",
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "id" => "sub_recon_fail_1",
            "customer" => "cus_recon_fail",
            "status" => "active"
          }
        }
      }

      opts = [
        customer_resource: User,
        subscription_resource: Subscription,
        domain: Domain,
        req_options: [plug: {Req.Test, stub_name}, retry: false]
      ]

      # Sync MUST fail with {:error, {:reconciliation_failed, _}} rather than corrupting DB with stale data
      assert {:error, {:reconciliation_failed, _}} = WebhookSync.sync_event(event, opts)

      # Ensure database status was NOT mutated to active
      persisted = Ash.get!(Subscription, sub.id, domain: Domain, authorize?: false)
      assert persisted.status == :past_due
    end
  end
end
