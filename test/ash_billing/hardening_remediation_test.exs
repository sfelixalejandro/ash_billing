defmodule AshBilling.HardeningRemediationTest do
  @moduledoc """
  Regression tests verifying the hardening remediations (AB-01 through AB-06).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AshBilling.Plug, as: BillingPlug
  alias AshBilling.Providers.Stripe
  alias AshBilling.Test.{PostgresCustomer, PostgresDomain, PostgresSubscription, Repo}
  alias AshBilling.WebhookSync

  @secret "whsec_hardening_remediation"
  @opts [domain: PostgresDomain, authorize?: false]
  @sync_opts @opts ++
               [customer_resource: PostgresCustomer, subscription_resource: PostgresSubscription]

  defp sign(payload) do
    ts = System.system_time(:second)

    sig =
      :crypto.mac(:hmac, :sha256, @secret, "#{ts}.#{payload}") |> Base.encode16(case: :lower)

    conn(:post, "/webhooks/stripe", payload)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", "t=#{ts},v1=#{sig}")
  end

  defmodule StripeSim do
    @moduledoc false
    def start(state), do: Agent.start_link(fn -> state end)
  end

  defp sim(agent, hook \\ nil) do
    name = :"sim_#{System.unique_integer([:positive])}"

    Req.Test.stub(name, fn conn ->
      case conn.method do
        "GET" ->
          s = Agent.get(agent, & &1)

          body = %{
            "id" => "sub_1",
            "status" => "active",
            "items" => %{
              "data" => [
                %{"id" => "si_1", "quantity" => s.quantity, "price" => %{"id" => s.price}}
              ]
            }
          }

          if hook, do: hook.()
          Req.Test.json(conn, body)

        "POST" ->
          {:ok, encoded, conn} = Plug.Conn.read_body(conn)
          params = URI.decode_query(encoded)
          send(self(), {:post, params})

          Agent.update(agent, fn s ->
            %{
              s
              | price: params["items[0][price]"] || s.price,
                quantity: String.to_integer(params["items[0][quantity]"])
            }
          end)

          Req.Test.json(conn, %{"id" => "sub_1"})
      end
    end)

    [req_opts: [plug: {Req.Test, name}, retry: false]]
  end

  # ===========================================================================
  # AB-01 & AB-02: update_quantity correctness & race-condition protection
  # ===========================================================================

  describe "AB-01 & AB-02: update_quantity" do
    test "aborts with {:error, {:price_mismatch, actual}} when :price_id assertion is stale" do
      {:ok, agent} = StripeSim.start(%{price: "price_current", quantity: 3})
      opts = sim(agent) ++ [price_id: "price_STALE", provider: Stripe]

      assert {:error, {:price_mismatch, "price_current"}} =
               AshBilling.update_quantity("sub_1", 5, opts)

      # Ensure no POST was made to Stripe and subscription state is untouched
      refute_received {:post, _}
      final = Agent.get(agent, & &1)
      assert final.price == "price_current"
      assert final.quantity == 3
    end

    test "updates only quantity and preserves a concurrent plan change between GET and POST" do
      {:ok, agent} = StripeSim.start(%{price: "price_A", quantity: 3})

      # Hook runs after GET body is constructed; a concurrent actor moves plan to price_B
      hook = fn -> Agent.update(agent, &%{&1 | price: "price_B"}) end
      opts = sim(agent, hook) ++ [provider: Stripe]

      assert {:ok, _} = AshBilling.update_quantity("sub_1", 9, opts)
      assert_received {:post, params}

      # Wire format check: POST body must NOT include price
      assert is_nil(params["items[0][price]"])
      assert params["items[0][quantity]"] == "9"
      assert params["items[0][id]"] == "si_1"

      # The subscription in Stripe retained the newer plan price_B
      final = Agent.get(agent, & &1)
      assert final.price == "price_B"
      assert final.quantity == 9
    end

    test "with explicit subscription_item_id and no price_id makes zero GETs" do
      name = :"zero_get_#{System.unique_integer([:positive])}"

      Req.Test.stub(name, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/subscriptions/sub_fast"

        {:ok, encoded, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(encoded)
        assert params["items[0][id]"] == "si_fast"
        assert params["items[0][quantity]"] == "7"
        assert is_nil(params["items[0][price]"])

        Req.Test.json(conn, %{"id" => "sub_fast"})
      end)

      opts = [
        req_opts: [plug: {Req.Test, name}, retry: false],
        subscription_item_id: "si_fast",
        provider: Stripe
      ]

      assert {:ok, %{"id" => "sub_fast"}} = AshBilling.update_quantity("sub_fast", 7, opts)
    end
  end

  # ===========================================================================
  # AB-03: URL safety and subscription ID validation
  # ===========================================================================

  describe "AB-03: URL encoding and subscription ID safety" do
    test "percent-encodes subscription IDs preventing traversal and injection" do
      name = :"url_safe_#{System.unique_integer([:positive])}"

      Req.Test.stub(name, fn conn ->
        send(self(), {:path, conn.method, conn.request_path, conn.query_string})
        Req.Test.json(conn, %{"id" => "sub_ok"})
      end)

      opts = [req_opts: [plug: {Req.Test, name}, retry: false], provider: Stripe]

      # Path traversal attempt is safely percent-encoded
      assert {:ok, _} = AshBilling.get_subscription("sub_1/../../customers/cus_victim", opts)
      assert_received {:path, "GET", path1, q1}
      assert path1 == "/v1/subscriptions/sub_1%2F..%2F..%2Fcustomers%2Fcus_victim"
      assert q1 == ""

      # Query parameter injection attempt is safely percent-encoded
      assert {:ok, _} = AshBilling.get_subscription("sub_1?expand[]=customer", opts)
      assert_received {:path, "GET", path2, q2}
      assert path2 == "/v1/subscriptions/sub_1%3Fexpand%5B%5D%3Dcustomer"
      assert q2 == ""

      # DELETE path traversal is safely percent-encoded
      assert {:ok, _} =
               AshBilling.cancel_subscription(
                 "sub_1/../../customers/cus_victim",
                 [at_period_end: false] ++ opts
               )

      assert_received {:path, "DELETE", path3, q3}
      assert path3 == "/v1/subscriptions/sub_1%2F..%2F..%2Fcustomers%2Fcus_victim"
      assert q3 == ""
    end

    test "rejects blank or invalid subscription IDs before making any HTTP request" do
      for invalid <- [nil, "", "   ", 123, :atom] do
        assert {:error, :invalid_subscription_id} =
                 AshBilling.get_subscription(invalid, provider: Stripe)

        assert {:error, :invalid_subscription_id} =
                 AshBilling.cancel_subscription(invalid, provider: Stripe)

        assert {:error, :invalid_subscription_id} =
                 AshBilling.resume_subscription(invalid, provider: Stripe)

        assert {:error, :invalid_subscription_id} =
                 AshBilling.swap_plan(invalid, "price_1", provider: Stripe)

        assert {:error, :invalid_subscription_id} =
                 AshBilling.update_quantity(invalid, 2, provider: Stripe)
      end
    end
  end

  # ===========================================================================
  # AB-04: Plug error normalization
  # ===========================================================================

  describe "AB-04: Plug error normalization" do
    test "validly signed non-JSON body returns 400 invalid_payload without crashing" do
      conn = sign("not a valid json payload")
      opts = BillingPlug.init(webhook_secret: @secret)

      resp_conn = BillingPlug.call(conn, opts)
      assert resp_conn.status == 400
      assert resp_conn.resp_body =~ "invalid_payload"
    end
  end

  # ===========================================================================
  # AB-05: Information disclosure prevention
  # ===========================================================================

  describe "AB-05: Pre-authentication boundary error disclosure" do
    test "unauthenticated 503 response redacts internal repo module names" do
      conn = conn(:post, "/webhooks/stripe", "{}")
      opts = BillingPlug.init(webhook_secret: @secret, customer_resource: PostgresCustomer)

      Repo.transaction(fn ->
        resp = BillingPlug.call(conn, opts)
        assert resp.status == 503
        decoded = Jason.decode!(resp.resp_body)
        assert decoded["error"] == "transaction_boundary"
        assert decoded["message"] == "Service temporarily unavailable"
        refute Map.has_key?(decoded, "details")
        refute resp.resp_body =~ "AshBilling.Test.Repo"
      end)
    end
  end

  # ===========================================================================
  # AB-06: Public contract robustness
  # ===========================================================================

  describe "AB-06: create_customer input validation" do
    test "returns {:error, :invalid_customer} on non-struct / non-map inputs without raising" do
      for invalid <- [nil, "", "  ", 123, 4.5, :atom, []] do
        assert {:error, :invalid_customer} = AshBilling.create_customer(invalid)
      end
    end
  end

  # ===========================================================================
  # 72-Permutation Out-of-Order Webhook Delivery Property Test
  # ===========================================================================

  describe "PostgreSQL out-of-order delivery convergence" do
    defmodule LiveProvider do
      def get_subscription(_id, opts), do: {:ok, Keyword.fetch!(opts, :live)}
    end

    setup do
      Ecto.Adapters.SQL.query!(
        Repo,
        "TRUNCATE billing_test_subscriptions, billing_test_customers, billing_scoped_subscriptions"
      )

      :ok
    end

    defp obj(sub_id, status, price) do
      %{
        "id" => sub_id,
        "customer" => "cus_perm",
        "status" => status,
        "items" => %{"data" => [%{"price" => %{"id" => price}}]}
      }
    end

    defp evt(sub_id, status, price, ts) do
      %{
        "id" => "evt_#{System.unique_integer([:positive])}",
        "type" => "customer.subscription.updated",
        "created" => ts,
        "data" => %{"object" => obj(sub_id, status, price)}
      }
    end

    defp permutations([]), do: [[]]

    defp permutations(list),
      do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

    @sequences %{
      lifecycle: [
        {"active", "p1"},
        {"past_due", "p1"},
        {"active", "p1"},
        {"canceled", "p1"}
      ],
      plan_changes: [{"trialing", "p1"}, {"active", "p1"}, {"active", "p2"}, {"active", "p3"}],
      dunning: [{"active", "p1"}, {"active", "p2"}, {"past_due", "p2"}, {"active", "p2"}]
    }

    for {name, seq} <- @sequences do
      test "every delivery order of #{name} converges to the newest event" do
        seq = unquote(Macro.escape(seq))
        base = 1_700_000_000

        events =
          seq
          |> Enum.with_index(1)
          |> Enum.map(fn {{status, price}, i} -> {i, status, price, base + i * 10} end)

        {_, last_status, last_price, _} = List.last(events)
        truth = obj("sub_perm_#{unquote(name)}", last_status, last_price)

        failures =
          for order <- permutations(events), reduce: [] do
            acc ->
              Ecto.Adapters.SQL.query!(
                Repo,
                "TRUNCATE billing_test_subscriptions, billing_test_customers"
              )

              Ash.create!(PostgresCustomer, %{stripe_customer_id: "cus_perm"}, @opts)

              for {_i, status, price, ts} <- order do
                e = evt("sub_perm_#{unquote(name)}", status, price, ts)

                case WebhookSync.sync_event(
                       e,
                       [provider: LiveProvider, live: truth] ++ @sync_opts
                     ) do
                  {:ok, _} -> :ok
                  other -> send(self(), {:sync_error, order, other})
                end
              end

              [persisted] = Ash.read!(PostgresSubscription, @opts)

              if to_string(persisted.status) == last_status and persisted.price_id == last_price do
                acc
              else
                [{Enum.map(order, &elem(&1, 0)), persisted.status, persisted.price_id} | acc]
              end
          end

        refute_received {:sync_error, _, _}
        assert failures == []
      end
    end
  end
end
