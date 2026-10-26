defmodule AshBilling.TelemetryTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias AshBilling.Test.{Domain, Subscription, User}

  setup do
    stub_name = :"stripe_telemetry_stub_#{System.unique_integer([:positive])}"
    opts = [req_opts: [plug: {Req.Test, stub_name}], base_url: "http://stripe.test"]
    {:ok, stub_name: stub_name, opts: opts}
  end

  test "emits telemetry spans for create_checkout_session", %{stub_name: stub_name, opts: opts} do
    test_pid = self()
    handler_id = "test-checkout-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:ash_billing, :checkout, :start],
        [:ash_billing, :checkout, :stop]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Req.Test.stub(stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"id" => "cs_telemetry_123", "url" => "https://checkout.test/cs_123"})
      )
    end)

    user = %User{id: Ash.UUID.generate(), stripe_customer_id: "cus_telemetry_123"}

    checkout_opts =
      opts
      |> Keyword.merge(
        price: "price_pro_monthly",
        success_url: "https://example.com/success",
        cancel_url: "https://example.com/cancel"
      )

    assert {:ok, _} = AshBilling.create_checkout_session(user, checkout_opts)

    assert_receive {:telemetry_event, [:ash_billing, :checkout, :start], measurements, metadata}
    assert is_integer(measurements[:system_time])
    assert metadata[:mode] == "subscription"
    assert metadata[:customer] == "cus_telemetry_123"

    assert_receive {:telemetry_event, [:ash_billing, :checkout, :stop], measurements, metadata}
    assert is_integer(measurements[:duration])
    assert metadata[:status] == :ok
    assert metadata[:session_id] == "cs_telemetry_123"
  end

  test "emits telemetry spans for create_portal_session", %{stub_name: stub_name, opts: opts} do
    test_pid = self()
    handler_id = "test-portal-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:ash_billing, :portal, :start],
        [:ash_billing, :portal, :stop]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Req.Test.stub(stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"url" => "https://portal.test/telemetry_123"})
      )
    end)

    user = %User{id: Ash.UUID.generate(), stripe_customer_id: "cus_portal_telem"}
    portal_opts = Keyword.merge(opts, return_url: "https://example.com/billing")

    assert {:ok, _} = AshBilling.create_portal_session(user, portal_opts)

    assert_receive {:telemetry_event, [:ash_billing, :portal, :start], measurements, metadata}
    assert is_integer(measurements[:system_time])
    assert metadata[:customer] == "cus_portal_telem"

    assert_receive {:telemetry_event, [:ash_billing, :portal, :stop], measurements, metadata}
    assert is_integer(measurements[:duration])
    assert metadata[:status] == :ok
    assert metadata[:url] == "https://portal.test/telemetry_123"
  end

  test "emits telemetry spans for webhook synchronization" do
    test_pid = self()
    handler_id = "test-sync-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:ash_billing, :sync, :start],
        [:ash_billing, :sync, :stop]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _user} =
      Ash.create(
        User,
        %{
          email: "telemetry_user@example.com",
          stripe_customer_id: "cus_telem_999"
        },
        domain: Domain
      )

    event = %{
      "id" => "evt_telem_123",
      "type" => "customer.subscription.created",
      "data" => %{
        "object" => %{
          "id" => "sub_stripe_telem_100",
          "customer" => "cus_telem_999",
          "status" => "active",
          "cancel_at_period_end" => false,
          "current_period_end" => 1_735_689_600,
          "items" => %{
            "data" => [
              %{"price" => %{"id" => "price_telem_monthly"}}
            ]
          }
        }
      }
    }

    sync_opts = [
      customer_resource: User,
      subscription_resource: Subscription,
      domain: Domain
    ]

    assert {:ok, _} = AshBilling.WebhookSync.sync_event(event, sync_opts)

    assert_receive {:telemetry_event, [:ash_billing, :sync, :start], measurements, metadata}
    assert is_integer(measurements[:system_time])
    assert metadata[:event_type] == "customer.subscription.created"
    assert metadata[:event_id] == "evt_telem_123"

    assert_receive {:telemetry_event, [:ash_billing, :sync, :stop], measurements, metadata}
    assert is_integer(measurements[:duration])
    assert metadata[:status] == :ok
  end

  test "emits telemetry spans during Plug webhook handling" do
    test_pid = self()
    handler_id = "test-plug-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:ash_billing, :webhook, :start],
        [:ash_billing, :webhook, :stop]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    secret = "whsec_test_secret"
    payload = Jason.encode!(%{"id" => "evt_plug_telem_1", "type" => "invoice.paid"})
    timestamp = System.system_time(:second)
    signed_payload = "#{timestamp}.#{payload}"

    sig =
      :crypto.mac(:hmac, :sha256, secret, signed_payload)
      |> Base.encode16(case: :lower)

    signature_header = "t=#{timestamp},v1=#{sig}"

    conn =
      conn(:post, "/webhooks/stripe", payload)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("stripe-signature", signature_header)
      |> AshBilling.Plug.call(
        webhook_secret: secret,
        deduplicate?: false
      )

    assert conn.status == 200

    assert_receive {:telemetry_event, [:ash_billing, :webhook, :start], measurements, _metadata}
    assert is_integer(measurements[:system_time])

    assert_receive {:telemetry_event, [:ash_billing, :webhook, :stop], measurements, metadata}
    assert is_integer(measurements[:duration])
    assert metadata[:status] == :received
    assert metadata[:event_id] == "evt_plug_telem_1"
    assert metadata[:event_type] == "invoice.paid"
  end
end
