defmodule AshBilling.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias AshBilling.Plug, as: BillingPlug

  @secret "whsec_plug_test_secret"

  defmodule MockHandler do
    def handle_event(event) do
      send(self(), {:webhook_handled, event})
    end
  end

  defp build_signed_conn(payload) do
    timestamp = System.system_time(:second)
    signed_payload = "#{timestamp}.#{payload}"

    sig =
      :crypto.mac(:hmac, :sha256, @secret, signed_payload)
      |> Base.encode16(case: :lower)

    conn(:post, "/webhooks/stripe", payload)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", "t=#{timestamp},v1=#{sig}")
  end

  describe "AshBilling.Plug" do
    test "processes valid webhook and calls handler" do
      payload = ~s({"id":"evt_test_123","type":"customer.subscription.created"})
      conn = build_signed_conn(payload)

      opts =
        BillingPlug.init(
          webhook_secret: @secret,
          handler: MockHandler
        )

      conn = BillingPlug.call(conn, opts)

      assert conn.status == 200
      assert conn.resp_body == ~s({"status":"received"})
      assert_received {:webhook_handled, %{"id" => "evt_test_123"}}
    end

    test "deduplicates duplicate webhook event IDs" do
      payload = ~s({"id":"evt_duplicate_check_99","type":"customer.subscription.created"})
      opts = BillingPlug.init(webhook_secret: @secret, handler: MockHandler)

      # First delivery
      conn1 = build_signed_conn(payload)
      conn1 = BillingPlug.call(conn1, opts)
      assert conn1.status == 200
      assert conn1.resp_body == ~s({"status":"received"})
      assert_received {:webhook_handled, %{"id" => "evt_duplicate_check_99"}}

      # Second delivery (Stripe retry)
      conn2 = build_signed_conn(payload)
      conn2 = BillingPlug.call(conn2, opts)
      assert conn2.status == 200
      assert conn2.resp_body == ~s({"status":"already_processed"})
      refute_received {:webhook_handled, %{"id" => "evt_duplicate_check_99"}}
    end

    test "returns 503 with Retry-After when event is currently already_processing" do
      event_id = "evt_in_flight_#{System.unique_integer([:positive])}"
      payload = ~s({"id":"#{event_id}","type":"customer.subscription.created"})
      opts = BillingPlug.init(webhook_secret: @secret, handler: MockHandler)

      # Acquire lease in advance simulating an in-flight worker
      assert {:ok, _token} =
               AshBilling.Deduplication.acquire(event_id, deduplication_strategy: :memory)

      conn = build_signed_conn(payload)
      conn = BillingPlug.call(conn, opts)

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["5"]

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "already_processing",
               "message" => "Event is currently being processed by another worker"
             }

      refute_received {:webhook_handled, %{"id" => ^event_id}}
    end

    test "rejects request with invalid signature" do
      timestamp = System.system_time(:second)

      conn =
        conn(:post, "/webhooks/stripe", ~s({"id":"evt_123"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("stripe-signature", "t=#{timestamp},v1=bad_sig")

      opts = BillingPlug.init(webhook_secret: @secret)
      conn = BillingPlug.call(conn, opts)

      assert conn.status == 400
      assert conn.resp_body =~ "invalid_signature"
    end

    test "rejects request with missing signature" do
      conn =
        conn(:post, "/webhooks/stripe", ~s({"id":"evt_123"}))
        |> put_req_header("content-type", "application/json")

      opts = BillingPlug.init(webhook_secret: @secret)
      conn = BillingPlug.call(conn, opts)

      assert conn.status == 400
      assert conn.resp_body =~ "missing_signature_header"
    end

    test "resolves webhook secret from function or mfa tuple" do
      payload = ~s({"id":"evt_tuple_secret","type":"test"})
      conn = build_signed_conn(payload)

      # 0-arity function
      opts_fn = BillingPlug.init(webhook_secret: fn -> @secret end)
      conn_fn = BillingPlug.call(conn, opts_fn)
      assert conn_fn.status == 200

      # MFA tuple
      System.put_env("TEST_WEBHOOK_SECRET_KEY", @secret)
      conn2 = build_signed_conn(payload)
      opts_mfa = BillingPlug.init(webhook_secret: {System, :get_env, ["TEST_WEBHOOK_SECRET_KEY"]})
      conn_mfa = BillingPlug.call(conn2, opts_mfa)
      assert conn_mfa.status == 200
    end

    test "uses raw_body from conn.assigns when present" do
      payload = ~s({"id":"evt_assigns_raw","type":"test"})

      conn =
        build_signed_conn(payload)
        |> assign(:raw_body, payload)

      opts = BillingPlug.init(webhook_secret: @secret)
      conn = BillingPlug.call(conn, opts)
      assert conn.status == 200
    end

    test "returns 500 on database sync error to trigger Stripe retry" do
      import ExUnit.CaptureLog

      non_existent_uuid = "00000000-0000-0000-0000-000000000000"

      payload =
        ~s({"id":"evt_sync_fail_500","type":"checkout.session.completed","data":{"object":{"customer":"cus_fail_1","client_reference_id":"#{non_existent_uuid}"}}})

      conn = build_signed_conn(payload)

      opts =
        BillingPlug.init(
          webhook_secret: @secret,
          customer_resource: AshBilling.Test.User,
          subscription_resource: AshBilling.Test.Subscription,
          domain: AshBilling.Test.Domain
        )

      log =
        capture_log(fn ->
          conn = BillingPlug.call(conn, opts)
          assert conn.status == 500
          assert conn.resp_body =~ "synchronization_failed"
        end)

      assert log =~ "Returning HTTP 500 to trigger Stripe retry"

      # Also verify backwards-compatible return_500_on_sync_error: false
      conn2 = build_signed_conn(payload)
      opts2 = Keyword.put(opts, :return_500_on_sync_error, false)

      capture_log(fn ->
        conn2 = BillingPlug.call(conn2, opts2)
        assert conn2.status == 200
      end)
    end

    test "returns 400 when body exceeds size limit" do
      conn =
        conn(:post, "/webhooks/stripe", "a very long body that exceeds length limit")
        |> put_req_header("content-type", "application/json")

      opts = BillingPlug.init(webhook_secret: @secret, read_body_opts: [length: 4])
      conn = BillingPlug.call(conn, opts)

      assert conn.status == 400
      assert conn.resp_body =~ "body_too_large"
    end
  end
end
