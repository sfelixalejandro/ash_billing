defmodule AshBillingTest do
  use ExUnit.Case, async: true

  alias AshBilling.Test.User

  setup do
    stub_name = :"stripe_top_level_stub_#{System.unique_integer([:positive])}"
    opts = [req_opts: [plug: {Req.Test, stub_name}], base_url: "http://stripe.test"]
    {:ok, stub_name: stub_name, opts: opts}
  end

  describe "customer_id/1" do
    test "extracts customer id from Ash record" do
      user = %User{id: Ash.UUID.generate(), stripe_customer_id: "cus_xyz123"}
      assert AshBilling.customer_id(user) == "cus_xyz123"
    end

    test "returns nil when not set" do
      user = %User{id: Ash.UUID.generate(), stripe_customer_id: nil}
      assert AshBilling.customer_id(user) == nil
    end

    test "returns nil for non-Ash structs" do
      assert AshBilling.customer_id(%{stripe_customer_id: "cus_123"}) == nil
    end
  end

  describe "create_customer/2" do
    test "returns existing customer id if already present", %{opts: opts} do
      user = %User{id: Ash.UUID.generate(), stripe_customer_id: "cus_already_there"}
      assert {:ok, "cus_already_there"} = AshBilling.create_customer(user, opts)
    end

    test "creates customer in provider if not present", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "cus_new_123"}))
      end)

      user = %User{id: Ash.UUID.generate(), email: "alex@example.com", name: "Alex"}
      assert {:ok, "cus_new_123"} = AshBilling.create_customer(user, opts)
    end

    test "creates customer from raw map params", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "cus_raw_map_99"}))
      end)

      assert {:ok, "cus_raw_map_99"} =
               AshBilling.create_customer(%{email: "raw@example.com", name: "Raw Map"}, opts)
    end
  end

  describe "create_checkout_session/2" do
    test "creates checkout session for a customer record and auto-injects metadata", %{
      stub_name: stub_name,
      opts: opts
    } do
      user_id = Ash.UUID.generate()
      user = %User{id: user_id, stripe_customer_id: "cus_123"}

      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["client_reference_id"] == user_id
        assert params["metadata[resource_id]"] == user_id
        assert params["subscription_data[metadata][resource_id]"] == user_id
        assert params["metadata[org_tier]"] == "enterprise"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"id" => "cs_123", "url" => "https://checkout.test/cs_123"})
        )
      end)

      checkout_opts =
        opts
        |> Keyword.merge(
          price: "price_pro_monthly",
          success_url: "https://example.com/success",
          cancel_url: "https://example.com/cancel",
          metadata: %{org_tier: "enterprise"}
        )

      assert {:ok, %{id: "cs_123", url: "https://checkout.test/cs_123"}} =
               AshBilling.create_checkout_session(user, checkout_opts)
    end

    test "creates checkout session with explicit line_items and payment mode", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["mode"] == "payment"
        assert params["line_items[0][price]"] == "price_one_time"
        assert params["line_items[0][quantity]"] == "2"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"id" => "cs_pay_123", "url" => "https://checkout.test/cs_pay_123"})
        )
      end)

      checkout_opts =
        opts
        |> Keyword.merge(
          mode: "payment",
          line_items: [%{price: "price_one_time", quantity: 2}],
          success_url: "https://example.com/success",
          cancel_url: "https://example.com/cancel"
        )

      assert {:ok, %{id: "cs_pay_123"}} =
               AshBilling.create_checkout_session("cus_str_id", checkout_opts)
    end

    test "handles error from provider", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => %{"message" => "Invalid price"}})
        )
      end)

      checkout_opts =
        opts
        |> Keyword.merge(
          price: "price_bad",
          success_url: "https://example.com/success",
          cancel_url: "https://example.com/cancel"
        )

      assert {:error, %{status: 400, error: "Invalid price"}} =
               AshBilling.create_checkout_session("cus_123", checkout_opts)
    end
  end

  describe "create_portal_session/2" do
    test "creates portal session", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"url" => "https://portal.test/session_123"})
        )
      end)

      user = %User{id: Ash.UUID.generate(), stripe_customer_id: "cus_123"}

      portal_opts = Keyword.merge(opts, return_url: "https://example.com/billing")

      assert {:ok, %{url: "https://portal.test/session_123"}} =
               AshBilling.create_portal_session(user, portal_opts)
    end

    test "creates portal session with direct customer ID string", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"url" => "https://portal.test/session_from_str"})
        )
      end)

      portal_opts = Keyword.merge(opts, return_url: "https://example.com/billing")

      assert {:ok, %{url: "https://portal.test/session_from_str"}} =
               AshBilling.create_portal_session("cus_string_id_999", portal_opts)
    end

    test "handles error from provider", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => %{"message" => "Customer has no portal access"}})
        )
      end)

      portal_opts = Keyword.merge(opts, return_url: "https://example.com/billing")

      assert {:error, %{status: 400, error: "Customer has no portal access"}} =
               AshBilling.create_portal_session("cus_bad", portal_opts)
    end
  end

  describe "get_subscription/2" do
    test "fetches subscription by string ID", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "sub_top_123", "status" => "active"}))
      end)

      assert {:ok, %{"id" => "sub_top_123"}} = AshBilling.get_subscription("sub_top_123", opts)
    end

    test "fetches subscription by struct record with provider_subscription_id", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "sub_record_456"}))
      end)

      sub = %{provider_subscription_id: "sub_record_456"}
      assert {:ok, %{"id" => "sub_record_456"}} = AshBilling.get_subscription(sub, opts)
    end
  end

  describe "cancel_subscription/2" do
    test "cancels subscription by string ID", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"id" => "sub_cancel_789", "status" => "canceled"})
        )
      end)

      assert {:ok, %{"status" => "canceled"}} =
               AshBilling.cancel_subscription("sub_cancel_789", opts)
    end

    test "cancels subscription by struct record", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "sub_cancel_struct"}))
      end)

      sub = %{stripe_subscription_id: "sub_cancel_struct"}
      assert {:ok, %{"id" => "sub_cancel_struct"}} = AshBilling.cancel_subscription(sub, opts)
    end
  end

  describe "subscribed?/2" do
    test "returns true when active subscription exists" do
      user = %User{
        subscriptions: [
          %{status: :active, price_id: "price_basic"},
          %{status: :canceled, price_id: "price_old"}
        ]
      }

      assert AshBilling.subscribed?(user) == true
      assert AshBilling.subscribed?(user, "price_basic") == true
      assert AshBilling.subscribed?(user, "price_pro") == false
    end

    test "returns true for trialing subscription" do
      user = %User{
        subscriptions: [
          %{status: :trialing, price_id: "price_trial"}
        ]
      }

      assert AshBilling.subscribed?(user) == true
      assert AshBilling.subscribed?(user, "price_trial") == true
    end

    test "returns true for string status active and trialing" do
      user_active = %User{subscriptions: [%{status: "active", price_id: "price_str"}]}
      user_trialing = %User{subscriptions: [%{status: "trialing", price_id: "price_str"}]}

      assert AshBilling.subscribed?(user_active) == true
      assert AshBilling.subscribed?(user_trialing) == true
    end

    test "returns false when all subscriptions are canceled" do
      user = %User{
        subscriptions: [
          %{status: :canceled, price_id: "price_old"}
        ]
      }

      assert AshBilling.subscribed?(user) == false
    end

    test "returns false when subscriptions relationship is not loaded" do
      user = %User{}
      assert AshBilling.subscribed?(user) == false
    end
  end
end
