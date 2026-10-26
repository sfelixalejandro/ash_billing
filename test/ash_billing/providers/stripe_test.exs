defmodule AshBilling.Providers.StripeTest do
  use ExUnit.Case, async: true

  alias AshBilling.Providers.Stripe

  setup do
    stub_name = :"stripe_stub_#{System.unique_integer([:positive])}"
    opts = [req_opts: [plug: {Req.Test, stub_name}], base_url: "http://stripe.test"]
    {:ok, stub_name: stub_name, opts: opts}
  end

  describe "to_form_params/2" do
    test "flattens nested maps and lists for Stripe API" do
      params = %{
        customer: "cus_123",
        line_items: [
          %{price: "price_abc", quantity: 2}
        ],
        metadata: %{user_id: "user_456"}
      }

      form_params = Stripe.to_form_params(params)
      query = URI.encode_query(form_params)

      assert query =~ "customer=cus_123"
      assert query =~ "line_items%5B0%5D%5Bprice%5D=price_abc"
      assert query =~ "line_items%5B0%5D%5Bquantity%5D=2"
      assert query =~ "metadata%5Buser_id%5D=user_456"
    end
  end

  describe "create_customer/2" do
    test "creates a customer and returns the ID", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/customers"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "cus_success123"}))
      end)

      assert {:ok, "cus_success123"} =
               Stripe.create_customer(%{email: "test@example.com"}, opts)
    end

    test "attaches bearer authorization header when api_key option is provided", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk_test_secret_key"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "cus_auth_123"}))
      end)

      opts_with_key = Keyword.put(opts, :api_key, "sk_test_secret_key")

      assert {:ok, "cus_auth_123"} =
               Stripe.create_customer(%{email: "auth@test.com"}, opts_with_key)
    end

    test "resolves api_key from 0-arity function and MFA tuple", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk_dynamic_key"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "cus_dynamic_123"}))
      end)

      # Function resolution
      opts_fn = Keyword.put(opts, :api_key, fn -> "sk_dynamic_key" end)
      assert {:ok, "cus_dynamic_123"} = Stripe.create_customer(%{email: "fn@test.com"}, opts_fn)

      # MFA tuple resolution
      System.put_env("TEST_STRIPE_KEY_ENV", "sk_dynamic_key")
      opts_mfa = Keyword.put(opts, :api_key, {System, :get_env, ["TEST_STRIPE_KEY_ENV"]})
      assert {:ok, "cus_dynamic_123"} = Stripe.create_customer(%{email: "mfa@test.com"}, opts_mfa)
    end

    test "handles error from Stripe API", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => %{"message" => "Invalid email"}})
        )
      end)

      assert {:error, %{status: 400, error: "Invalid email"}} =
               Stripe.create_customer(%{email: "bad_email"}, opts)
    end

    test "handles non-standard error structure from Stripe API", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          500,
          Jason.encode!(%{"error" => "Gateway Timeout"})
        )
      end)

      assert {:error, %{status: 500, error: %{"error" => "Gateway Timeout"}}} =
               Stripe.create_customer(%{email: "timeout@test.com"}, opts)
    end
  end

  describe "create_checkout_session/2" do
    test "creates checkout session with url and id", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/checkout/sessions"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "cs_test_123",
            "url" => "https://checkout.stripe.com/pay/cs_test_123"
          })
        )
      end)

      params = %{
        customer: "cus_123",
        line_items: [%{price: "price_pro", quantity: 1}],
        success_url: "http://app.test/success",
        cancel_url: "http://app.test/cancel"
      }

      assert {:ok, %{id: "cs_test_123", url: "https://checkout.stripe.com/pay/cs_test_123"}} =
               Stripe.create_checkout_session(params, opts)
    end
  end

  describe "create_portal_session/2" do
    test "creates customer portal session", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/billing_portal/sessions"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"url" => "https://billing.stripe.com/p/session/portal_123"})
        )
      end)

      assert {:ok, %{url: "https://billing.stripe.com/p/session/portal_123"}} =
               Stripe.create_portal_session(
                 %{customer: "cus_123", return_url: "http://app.test"},
                 opts
               )
    end

    test "handles error from Stripe API", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => %{"message" => "No such customer"}})
        )
      end)

      assert {:error, %{status: 400, error: "No such customer"}} =
               Stripe.create_portal_session(
                 %{customer: "cus_missing", return_url: "http://app.test"},
                 opts
               )
    end
  end

  describe "get_subscription/2" do
    test "fetches subscription details", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/subscriptions/sub_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "sub_123", "status" => "active"}))
      end)

      assert {:ok, %{"id" => "sub_123", "status" => "active"}} =
               Stripe.get_subscription("sub_123", opts)
    end

    test "handles error when subscription not found", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          Jason.encode!(%{"error" => %{"message" => "No such subscription"}})
        )
      end)

      assert {:error, %{status: 404, error: "No such subscription"}} =
               Stripe.get_subscription("sub_missing", opts)
    end
  end

  describe "cancel_subscription/2" do
    test "cancels at period end by default", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/subscriptions/sub_123"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "cancel_at_period_end=true"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"id" => "sub_123", "cancel_at_period_end" => true})
        )
      end)

      assert {:ok, %{"id" => "sub_123", "cancel_at_period_end" => true}} =
               Stripe.cancel_subscription("sub_123", opts)
    end

    test "cancels immediately when at_period_end is false", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/v1/subscriptions/sub_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "sub_123", "status" => "canceled"}))
      end)

      immediate_opts = Keyword.put(opts, :at_period_end, false)

      assert {:ok, %{"id" => "sub_123", "status" => "canceled"}} =
               Stripe.cancel_subscription("sub_123", immediate_opts)
    end

    test "handles error from Stripe API on cancel", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => %{"message" => "Subscription already canceled"}})
        )
      end)

      assert {:error, %{status: 400, error: "Subscription already canceled"}} =
               Stripe.cancel_subscription("sub_123", opts)
    end
  end

  describe "resume_subscription/2" do
    test "resumes subscription with cancel_at_period_end false", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/subscriptions/sub_res_123"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "cancel_at_period_end=false"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"id" => "sub_res_123", "cancel_at_period_end" => false})
        )
      end)

      assert {:ok, %{"id" => "sub_res_123", "cancel_at_period_end" => false}} =
               Stripe.resume_subscription("sub_res_123", opts)
    end

    test "handles error from Stripe API on resume", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => %{"message" => "Subscription cannot be resumed"}})
        )
      end)

      assert {:error, %{status: 400, error: "Subscription cannot be resumed"}} =
               Stripe.resume_subscription("sub_res_bad", opts)
    end
  end

  describe "swap_plan/3" do
    test "swaps plan directly when subscription_item_id is provided", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/subscriptions/sub_swap_123"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "items%5B0%5D%5Bid%5D=si_item_999"
        assert body =~ "items%5B0%5D%5Bprice%5D=price_enterprise"
        assert body =~ "proration_behavior=create_prorations"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"id" => "sub_swap_123", "status" => "active"})
        )
      end)

      opts = Keyword.merge(opts, subscription_item_id: "si_item_999")

      assert {:ok, %{"id" => "sub_swap_123", "status" => "active"}} =
               Stripe.swap_plan("sub_swap_123", "price_enterprise", opts)
    end

    test "fetches subscription item id if not provided, then swaps plan", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        case conn.method do
          "GET" ->
            assert conn.request_path == "/v1/subscriptions/sub_auto_item"

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{
                "id" => "sub_auto_item",
                "items" => %{"data" => [%{"id" => "si_auto_found"}]}
              })
            )

          "POST" ->
            assert conn.request_path == "/v1/subscriptions/sub_auto_item"
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert body =~ "items%5B0%5D%5Bid%5D=si_auto_found"
            assert body =~ "items%5B0%5D%5Bprice%5D=price_new_pro"
            assert body =~ "proration_behavior=none"

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"id" => "sub_auto_item", "status" => "active"})
            )
        end
      end)

      opts = Keyword.merge(opts, proration_behavior: "none")

      assert {:ok, %{"id" => "sub_auto_item", "status" => "active"}} =
               Stripe.swap_plan("sub_auto_item", "price_new_pro", opts)
    end

    test "handles error from Stripe API on swap_plan", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => %{"message" => "Invalid price ID"}})
        )
      end)

      opts = Keyword.merge(opts, subscription_item_id: "si_item_999")

      assert {:error, %{status: 400, error: "Invalid price ID"}} =
               Stripe.swap_plan("sub_swap_bad", "price_invalid", opts)
    end

    test "handles proration_date and quantity options", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "proration_date=1799000000"
        assert body =~ "items%5B0%5D%5Bquantity%5D=10"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "sub_swap_opts"}))
      end)

      opts =
        opts
        |> Keyword.put(:subscription_item_id, "si_item_123")
        |> Keyword.put(:proration_date, 1_799_000_000)
        |> Keyword.put(:quantity, 10)

      assert {:ok, %{"id" => "sub_swap_opts"}} =
               Stripe.swap_plan("sub_swap_opts", "price_opts", opts)
    end

    test "handles missing items when resolving subscription item", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"id" => "sub_no_items", "items" => %{"data" => []}})
        )
      end)

      assert {:error, {:missing_subscription_item, _}} =
               Stripe.swap_plan("sub_no_items", "price_any", opts)
    end

    test "handles error from get_subscription when resolving item id", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => %{"message" => "Not found"}}))
      end)

      assert {:error, %{status: 404, error: "Not found"}} =
               Stripe.swap_plan("sub_missing", "price_any", opts)
    end
  end

  describe "verify_webhook/4" do
    @secret "whsec_test_secret_key"

    test "verifies valid payload and signature" do
      payload = ~s({"id":"evt_123","type":"customer.subscription.updated"})
      timestamp = System.system_time(:second)
      signed_payload = "#{timestamp}.#{payload}"

      sig =
        :crypto.mac(:hmac, :sha256, @secret, signed_payload)
        |> Base.encode16(case: :lower)

      header = "t=#{timestamp},v1=#{sig}"

      assert {:ok, %{"id" => "evt_123", "type" => "customer.subscription.updated"}} =
               Stripe.verify_webhook(payload, header, @secret)
    end

    test "returns error for missing signature header" do
      payload = ~s({"id":"evt_123"})
      assert {:error, :missing_signature_header} = Stripe.verify_webhook(payload, nil, @secret)
    end

    test "returns error for invalid signature header format" do
      payload = ~s({"id":"evt_123"})

      assert {:error, :invalid_signature_header} =
               Stripe.verify_webhook(payload, "invalid_format", @secret)
    end

    test "returns error for non-integer timestamp in header" do
      payload = ~s({"id":"evt_123"})

      assert {:error, :invalid_timestamp_in_header} =
               Stripe.verify_webhook(payload, "t=abc,v1=signature", @secret)
    end

    test "returns error for invalid signature" do
      payload = ~s({"id":"evt_123"})
      timestamp = System.system_time(:second)
      header = "t=#{timestamp},v1=bad_signature"

      assert {:error, :invalid_signature} = Stripe.verify_webhook(payload, header, @secret)

      # Mismatched byte length
      short_header = "t=#{timestamp},v1=short"
      assert {:error, :invalid_signature} = Stripe.verify_webhook(payload, short_header, @secret)
    end

    test "returns error when timestamp is outside tolerance" do
      payload = ~s({"id":"evt_123"})
      # 500 seconds in the past
      old_timestamp = System.system_time(:second) - 500
      signed_payload = "#{old_timestamp}.#{payload}"

      sig =
        :crypto.mac(:hmac, :sha256, @secret, signed_payload)
        |> Base.encode16(case: :lower)

      header = "t=#{old_timestamp},v1=#{sig}"

      assert {:error, :timestamp_outside_tolerance} =
               Stripe.verify_webhook(payload, header, @secret, tolerance: 300)
    end

    test "returns error when payload is invalid JSON" do
      payload = "{invalid_json"
      timestamp = System.system_time(:second)
      signed_payload = "#{timestamp}.#{payload}"

      sig =
        :crypto.mac(:hmac, :sha256, @secret, signed_payload)
        |> Base.encode16(case: :lower)

      header = "t=#{timestamp},v1=#{sig}"

      assert {:error, %Jason.DecodeError{}} = Stripe.verify_webhook(payload, header, @secret)
    end
  end
end
