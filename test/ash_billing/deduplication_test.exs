defmodule AshBilling.DeduplicationTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshBilling.Deduplication
  alias AshBilling.Test.{Domain, WebhookEvent}

  setup do
    Deduplication.clear()
    :ok
  end

  describe "AshBilling.Deduplication with :memory strategy" do
    test "returns false for unprocessed events" do
      refute Deduplication.processed?("evt_unseen_1")
      refute Deduplication.processed?(nil)
    end

    test "marks event as processed and detects duplicate" do
      event_id = "evt_stripe_duplicate_check_1"
      refute Deduplication.processed?(event_id)

      assert :ok = Deduplication.mark_processed(event_id)
      assert Deduplication.processed?(event_id)
      assert :ok = Deduplication.mark_processed(nil)
    end

    test "handles :resource strategy when deduplication_resource is not provided" do
      # Falls back to memory strategy
      event_id = "evt_res_fallback_1"
      opts = [deduplication_strategy: :resource]

      refute Deduplication.processed?(event_id, opts)
      assert :ok = Deduplication.mark_processed(event_id, opts)
      assert Deduplication.processed?(event_id, opts)
    end

    test "handles explicit :memory strategy and application environment config" do
      event_id = "evt_mem_explicit_1"
      opts = [deduplication_strategy: :memory]

      refute Deduplication.processed?(event_id, opts)
      assert :ok = Deduplication.mark_processed(event_id, opts)
      assert Deduplication.processed?(event_id, opts)

      # Test application env config
      Application.put_env(:ash_billing, :deduplication_strategy, :memory)
      assert Deduplication.processed?(event_id)
    end

    test "sweep removes entries older than 24h" do
      old_time = System.system_time(:second) - 90_000
      :ets.insert(:ash_billing_processed_events, {"evt_ancient_123", old_time})
      assert Deduplication.processed?("evt_ancient_123")

      send(Process.whereis(AshBilling.Deduplication), :sweep)
      :timer.sleep(20)

      refute Deduplication.processed?("evt_ancient_123")
    end

    test "clear/0 empties the table" do
      event_id = "evt_to_clear"
      Deduplication.mark_processed(event_id)
      assert Deduplication.processed?(event_id)

      Deduplication.clear()
      refute Deduplication.processed?(event_id)
    end
  end

  describe "AshBilling.Deduplication with :resource strategy (database/multi-node)" do
    test "tracks events using Ash resource" do
      opts = [deduplication_resource: WebhookEvent, domain: Domain]
      event_id = "evt_db_cluster_test_100"

      refute Deduplication.processed?(event_id, opts)

      assert :ok = Deduplication.mark_processed(event_id, opts)
      assert Deduplication.processed?(event_id, opts)

      # Verify it was actually saved in the Ash resource
      require Ash.Query

      assert WebhookEvent
             |> Ash.Query.filter(event_id == ^event_id)
             |> Ash.exists?(domain: Domain, authorize?: false)
    end

    test "deduplicates in Plug using resource strategy" do
      secret = "whsec_db_test_secret"
      event_id = "evt_plug_db_dedup_1"
      payload = Jason.encode!(%{"id" => event_id, "type" => "invoice.payment_succeeded"})
      timestamp = System.system_time(:second)
      signed_payload = "#{timestamp}.#{payload}"

      sig =
        :crypto.mac(:hmac, :sha256, secret, signed_payload)
        |> Base.encode16(case: :lower)

      signature_header = "t=#{timestamp},v1=#{sig}"

      plug_opts = [
        webhook_secret: secret,
        deduplication_resource: WebhookEvent,
        domain: Domain
      ]

      # First delivery: processed
      conn1 =
        conn(:post, "/webhooks/stripe", payload)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", signature_header)
        |> AshBilling.Plug.call(plug_opts)

      assert conn1.status == 200
      assert conn1.resp_body =~ "received"

      # Second delivery (retry from another node): recognized as duplicate
      conn2 =
        conn(:post, "/webhooks/stripe", payload)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", signature_header)
        |> AshBilling.Plug.call(plug_opts)

      assert conn2.status == 200
      assert conn2.resp_body =~ "already_processed"
    end

    test "AshBilling.WebhookEvent defines sections and transformers" do
      assert is_list(AshBilling.WebhookEvent.sections())
      assert is_list(AshBilling.WebhookEvent.transformers())
    end
  end
end
