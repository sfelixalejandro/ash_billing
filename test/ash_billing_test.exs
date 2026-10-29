defmodule AshBillingTest do
  use ExUnit.Case, async: true

  alias AshBilling.Test.User

  setup do
    stub_name = :"stripe_top_level_stub_#{System.unique_integer([:positive])}"
    opts = [req_opts: [plug: {Req.Test, stub_name}], base_url: "http://stripe.test"]
    {:ok, stub_name: stub_name, opts: opts}
  end

  test "preserves subscription options with and without checkout metadata", %{
    stub_name: stub_name,
    opts: opts
  } do
    for metadata <- [%{}, %{team: "core"}] do
      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["subscription_data[trial_period_days]"] == "14"
        assert params["subscription_data[metadata][source]"] == "campaign"

        if map_size(metadata) > 0 do
          assert params["subscription_data[metadata][team]"] == "core"
        end

        Req.Test.json(conn, %{id: "cs_trial", url: "https://checkout.test/trial"})
      end)

      assert {:ok, %{id: "cs_trial"}} =
               AshBilling.create_checkout_session(
                 "cus_trial",
                 Keyword.merge(opts,
                   price: "price_trial",
                   success_url: "https://example.com/success",
                   cancel_url: "https://example.com/cancel",
                   metadata: metadata,
                   subscription_data: %{trial_period_days: 14, metadata: %{source: "campaign"}}
                 )
               )
    end
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

    test "creates customer when email is an Ash.CiString", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["email"] == "CI_USER@EXAMPLE.COM"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "cus_ci_string_123"}))
      end)

      ci_email = Ash.CiString.new("CI_USER@EXAMPLE.COM")
      user = %User{id: Ash.UUID.generate(), email: ci_email, name: "Ci User"}
      assert {:ok, "cus_ci_string_123"} = AshBilling.create_customer(user, opts)
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

    test "respects explicit idempotency_key in opts", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["custom_idemp_key_1"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "cus_idemp_1"}))
      end)

      user = %User{id: Ash.UUID.generate(), email: "idemp@example.com"}
      opts_with_idemp = Keyword.put(opts, :idempotency_key, "custom_idemp_key_1")
      assert {:ok, "cus_idemp_1"} = AshBilling.create_customer(user, opts_with_idemp)
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

    test "supports atom mode: :subscription and attaches metadata to subscription_data", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["mode"] == "subscription"
        assert params["subscription_data[metadata][team]"] == "core"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"id" => "cs_atom_sub", "url" => "https://checkout.test/cs_atom"})
        )
      end)

      checkout_opts =
        opts
        |> Keyword.merge(
          mode: :subscription,
          line_items: [%{price: "price_pro", quantity: 1}],
          success_url: "https://example.com/success",
          cancel_url: "https://example.com/cancel",
          metadata: %{team: "core"}
        )

      assert {:ok, %{id: "cs_atom_sub"}} =
               AshBilling.create_checkout_session("cus_atom_test", checkout_opts)
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

    test "auto-injects customer_email when user has no customer_id", %{
      stub_name: stub_name,
      opts: opts
    } do
      user = %User{id: Ash.UUID.generate(), email: "prefill@example.com", stripe_customer_id: nil}

      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["customer_email"] == "prefill@example.com"
        refute Map.has_key?(params, "customer")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"id" => "cs_email_1", "url" => "https://checkout.test"})
        )
      end)

      checkout_opts =
        Keyword.merge(opts,
          price: "price_basic",
          success_url: "https://example.com/ok",
          cancel_url: "https://example.com/cancel"
        )

      assert {:ok, %{id: "cs_email_1"}} =
               AshBilling.create_checkout_session(user, checkout_opts)
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

    test "returns {:error, :no_customer_id} when record has no customer ID", %{opts: opts} do
      user = %User{id: Ash.UUID.generate(), stripe_customer_id: nil}
      portal_opts = Keyword.merge(opts, return_url: "https://example.com/billing")

      assert {:error, :no_customer_id} = AshBilling.create_portal_session(user, portal_opts)
      assert {:error, :no_customer_id} = AshBilling.create_portal_session(nil, portal_opts)
      assert {:error, :no_customer_id} = AshBilling.create_portal_session("", portal_opts)
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

  describe "resume_subscription/2" do
    test "resumes subscription by string ID", %{stub_name: stub_name, opts: opts} do
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
               AshBilling.resume_subscription("sub_res_123", opts)
    end

    test "resumes subscription by struct record", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "sub_struct_res"}))
      end)

      sub = %{provider_subscription_id: "sub_struct_res"}
      assert {:ok, %{"id" => "sub_struct_res"}} = AshBilling.resume_subscription(sub, opts)
    end
  end

  describe "swap_plan/3 and update_quantity/3" do
    test "swaps plan with telemetry span emission", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/subscriptions/sub_top_swap"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "items%5B0%5D%5Bprice%5D=price_scale"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"id" => "sub_top_swap", "status" => "active"})
        )
      end)

      opts = Keyword.merge(opts, subscription_item_id: "si_direct_123")

      assert {:ok, %{"id" => "sub_top_swap"}} =
               AshBilling.swap_plan("sub_top_swap", "price_scale", opts)
    end

    test "updates quantity on existing price", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/subscriptions/sub_qty_123"

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "items%5B0%5D%5Bquantity%5D=5"
        assert body =~ "items%5B0%5D%5Bprice%5D=price_seats"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "sub_qty_123", "status" => "active"}))
      end)

      opts =
        opts
        |> Keyword.put(:subscription_item_id, "si_seat_item")
        |> Keyword.put(:price_id, "price_seats")

      assert {:ok, %{"id" => "sub_qty_123"}} =
               AshBilling.update_quantity("sub_qty_123", 5, opts)
    end

    test "updates quantity without price_id by auto-resolving from provider", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{
                "id" => "sub_qty_auto",
                "items" => %{
                  "data" => [%{"id" => "si_seat_auto", "price" => %{"id" => "price_auto_plan"}}]
                }
              })
            )

          "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert body =~ "items%5B0%5D%5Bid%5D=si_seat_auto"
            assert body =~ "items%5B0%5D%5Bprice%5D=price_auto_plan"
            assert body =~ "items%5B0%5D%5Bquantity%5D=3"

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              200,
              Jason.encode!(%{"id" => "sub_qty_auto", "status" => "active"})
            )
        end
      end)

      assert {:ok, %{"id" => "sub_qty_auto"}} =
               AshBilling.update_quantity("sub_qty_auto", 3, opts)
    end

    test "handles error in update_quantity when subscription fetch fails", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => %{"message" => "Not found"}}))
      end)

      assert {:error, %{status: 404, error: "Not found"}} =
               AshBilling.update_quantity("sub_qty_missing", 2, opts)
    end

    test "handles error in swap_plan", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => %{"message" => "Card declined"}}))
      end)

      opts = Keyword.merge(opts, subscription_item_id: "si_direct_123")

      assert {:error, %{status: 400, error: "Card declined"}} =
               AshBilling.swap_plan("sub_top_bad", "price_fail", opts)
    end
  end

  describe "subscription/2 and subscribed?/2" do
    test "returns active subscription struct or nil" do
      sub_active = %{status: :active, price_id: "price_pro"}
      sub_canceled = %{status: :canceled, price_id: "price_old"}
      user = %User{subscriptions: [sub_active, sub_canceled]}

      assert AshBilling.subscription(user) == sub_active
      assert AshBilling.subscription(user, "price_pro") == sub_active
      assert AshBilling.subscription(user, "price_enterprise") == nil

      assert AshBilling.subscribed?(user) == true
      assert AshBilling.subscribed?(user, "price_pro") == true
      assert AshBilling.subscribed?(user, "price_enterprise") == false
    end

    test "returns nil when no subscriptions are loaded or active" do
      user_empty = %User{subscriptions: []}
      user_nil = %User{subscriptions: nil}
      user_canceled = %User{subscriptions: [%{status: :canceled, price_id: "price_old"}]}

      assert AshBilling.subscription(user_empty) == nil
      assert AshBilling.subscription(user_nil) == nil
      assert AshBilling.subscription(user_canceled) == nil

      assert AshBilling.subscribed?(user_empty) == false
      assert AshBilling.subscribed?(user_nil) == false
      assert AshBilling.subscribed?(user_canceled) == false
    end

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

    test "returns true when subscription has active trial_ends_at in the future" do
      future = DateTime.utc_now() |> DateTime.add(5, :day)
      past = DateTime.utc_now() |> DateTime.add(-2, :day)

      user_on_trial = %User{
        subscriptions: [
          %{status: :trialing, price_id: "price_trial_plan", trial_ends_at: future}
        ]
      }

      user_expired_trial = %User{
        subscriptions: [
          %{status: :trialing, price_id: "price_trial_plan", trial_ends_at: past}
        ]
      }

      assert AshBilling.subscribed?(user_on_trial) == true
      assert AshBilling.subscribed?(user_on_trial, "price_trial_plan") == true
      assert AshBilling.subscribed?(user_expired_trial) == false
    end

    test "returns false when subscriptions relationship is not loaded" do
      user = %User{}
      assert AshBilling.subscribed?(user) == false
    end
  end

  describe "subscription management delegators" do
    test "get_subscription/2 delegator", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.json(conn, %{"id" => "sub_del_1", "status" => "active"})
      end)

      assert {:ok, %{"id" => "sub_del_1"}} = AshBilling.get_subscription("sub_del_1", opts)
    end

    test "cancel_subscription/2 delegator", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.json(conn, %{"id" => "sub_del_1", "cancel_at_period_end" => true})
      end)

      assert {:ok, %{"cancel_at_period_end" => true}} =
               AshBilling.cancel_subscription("sub_del_1", opts)
    end

    test "resume_subscription/2 delegator", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        Req.Test.json(conn, %{"id" => "sub_del_1", "cancel_at_period_end" => false})
      end)

      assert {:ok, %{"cancel_at_period_end" => false}} =
               AshBilling.resume_subscription("sub_del_1", opts)
    end

    test "swap_plan/3 delegator", %{stub_name: stub_name, opts: opts} do
      Req.Test.stub(stub_name, fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, %{
              "id" => "sub_del_1",
              "items" => %{"data" => [%{"id" => "si_del_1", "price" => %{"id" => "price_old"}}]}
            })

          "POST" ->
            Req.Test.json(conn, %{"id" => "sub_del_1", "status" => "active"})
        end
      end)

      assert {:ok, %{"id" => "sub_del_1"}} = AshBilling.swap_plan("sub_del_1", "price_new", opts)
    end

    test "update_quantity/3 delegator with and without price_id", %{
      stub_name: stub_name,
      opts: opts
    } do
      Req.Test.stub(stub_name, fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, %{
              "id" => "sub_del_1",
              "items" => %{"data" => [%{"id" => "si_del_1", "price" => %{"id" => "price_known"}}]}
            })

          "POST" ->
            Req.Test.json(conn, %{"id" => "sub_del_1", "status" => "active"})
        end
      end)

      # without price_id
      assert {:ok, %{"id" => "sub_del_1"}} = AshBilling.update_quantity("sub_del_1", 5, opts)

      # with price_id
      assert {:ok, %{"id" => "sub_del_1"}} =
               AshBilling.update_quantity(
                 "sub_del_1",
                 10,
                 Keyword.put(opts, :price_id, "price_known")
               )
    end
  end

  describe "check_configuration/1 and verify_configuration!/1" do
    test "credential diagnostics and exceptions never disclose the supplied API key" do
      for key <- ["Bearer sk_test_DO_NOT_DISCLOSE", " sk_live_DO_NOT_DISCLOSE"] do
        assert {:error, errors} = AshBilling.check_configuration(api_key: key)
        refute inspect(errors) =~ key
        refute inspect(errors) =~ "DO_NOT_DISCLOSE"

        exception =
          assert_raise ArgumentError, fn -> AshBilling.verify_configuration!(api_key: key) end

        refute Exception.message(exception) =~ key
        refute Exception.message(exception) =~ "DO_NOT_DISCLOSE"

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            require Logger
            Logger.error(Exception.message(exception))
          end)

        refute log =~ "DO_NOT_DISCLOSE"
      end
    end

    test "validates proper configuration" do
      valid_opts = [
        customer_resource: AshBilling.Test.User,
        subscription_resource: AshBilling.Test.Subscription,
        api_key: "sk_test_1234567890abcdef",
        webhook_secret: "whsec_1234567890abcdef"
      ]

      assert {:ok, %{status: :valid}} = AshBilling.check_configuration(valid_opts)
      assert :ok = AshBilling.verify_configuration!(valid_opts)
    end

    test "detects misconfigurations and raises on verify_configuration!" do
      invalid_opts = [
        customer_resource: AshBilling.Test.NotResource,
        api_key: "invalid_prefix",
        webhook_secret: "invalid_secret"
      ]

      assert {:error, errors} = AshBilling.check_configuration(invalid_opts)
      assert length(errors) >= 2

      assert_raise ArgumentError, ~r/AshBilling configuration verification failed/, fn ->
        AshBilling.verify_configuration!(invalid_opts)
      end
    end

    test "check_configuration/0 with default opts returns valid when no resources specified" do
      assert {:ok, %{status: :valid}} = AshBilling.check_configuration([])
    end

    test "subscription helper utilities: active? with past_due and resolve_subscription_id with map",
         %{
           stub_name: stub_name,
           opts: opts
         } do
      user_past_due = %User{
        subscriptions: [
          %{status: :past_due, trial_ends_at: nil}
        ]
      }

      refute AshBilling.subscribed?(user_past_due)

      Req.Test.stub(stub_name, fn conn ->
        Req.Test.json(conn, %{"id" => "sub_map_1", "status" => "active"})
      end)

      # resolves id from map
      assert {:ok, %{"id" => "sub_map_1"}} =
               AshBilling.get_subscription(%{id: "sub_map_1"}, opts)
    end

    test "canceling?/1 rejects terminal atom and string statuses with retained cancellation fields" do
      future = DateTime.add(DateTime.utc_now(), 5, :day)
      past = DateTime.add(DateTime.utc_now(), -5, :day)

      for status <- [:canceled, :incomplete_expired, "canceled", "incomplete_expired"],
          period_end <- [false, true],
          cancel_at <- [nil, past, future] do
        refute AshBilling.canceling?(%{
                 status: status,
                 cancel_at_period_end: period_end,
                 cancel_at: cancel_at
               })
      end
    end

    test "canceling?/1 identifies period-end and future scheduled cancellations" do
      future = DateTime.utc_now() |> DateTime.add(5, :day)
      past = DateTime.utc_now() |> DateTime.add(-5, :day)

      refute AshBilling.canceling?(nil)

      refute AshBilling.canceling?(%{
               status: :active,
               cancel_at_period_end: false,
               cancel_at: nil
             })

      refute AshBilling.canceling?(%{
               status: :active,
               cancel_at_period_end: false,
               cancel_at: past
             })

      assert AshBilling.canceling?(%{
               status: :active,
               cancel_at_period_end: true,
               cancel_at: past
             })

      refute AshBilling.canceling?(%{other: :value})

      assert AshBilling.canceling?(%{cancel_at_period_end: true})
      assert AshBilling.canceling?(%{cancel_at_period_end: false, cancel_at: future})
    end
  end
end
