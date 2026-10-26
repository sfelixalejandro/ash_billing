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
  end
end
