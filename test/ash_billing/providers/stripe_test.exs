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

    test "returns error for invalid signature" do
      payload = ~s({"id":"evt_123"})
      timestamp = System.system_time(:second)
      header = "t=#{timestamp},v1=bad_signature"

      assert {:error, :invalid_signature} = Stripe.verify_webhook(payload, header, @secret)
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
  end
end
