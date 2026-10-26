defmodule AshBilling.PaymentTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias AshBilling.Plug, as: BillingPlug
  alias AshBilling.Test.{Domain, Subscription, User}
  require Ash.Query

  @secret "whsec_payment_test_secret_777"

  defmodule PaymentFulfillmentHandler do
    def handle_event(%{"type" => "checkout.session.completed"} = event) do
      send(self(), {:fulfill_payment, event})
    end

    def handle_event(%{"type" => "invoice.payment_succeeded"} = event) do
      send(self(), {:invoice_paid, event})
    end

    def handle_event(%{"type" => "invoice.payment_failed"} = event) do
      send(self(), {:payment_failed_alert, event})
    end

    def handle_event(_), do: :ok
  end

  setup do
    stub_name = :"payment_stripe_stub_#{System.unique_integer([:positive])}"
    opts = [req_opts: [plug: {Req.Test, stub_name}], base_url: "http://stripe.test"]
    {:ok, stub_name: stub_name, opts: opts}
  end

  defp send_signed_webhook(event, plug_opts) do
    payload = Jason.encode!(event)
    timestamp = System.system_time(:second)
    signed_payload = "#{timestamp}.#{payload}"

    sig =
      :crypto.mac(:hmac, :sha256, @secret, signed_payload)
      |> Base.encode16(case: :lower)

    conn(:post, "/webhooks/stripe", payload)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", "t=#{timestamp},v1=#{sig}")
    |> BillingPlug.call(plug_opts)
  end

  describe "One-off Payments and Checkout Sessions" do
    test "processes one-time credit purchase and fulfills product via handler", %{
      stub_name: stub_name,
      opts: opts
    } do
      plug_opts =
        BillingPlug.init(
          webhook_secret: @secret,
          customer_resource: User,
          domain: Domain,
          handler: PaymentFulfillmentHandler
        )

      # 1. User signs up without a customer ID
      {:ok, user} =
        Ash.create(
          User,
          %{email: "tokens@saas.com", name: "Token Buyer"},
          domain: Domain
        )

      assert user.stripe_customer_id == nil

      # 2. User purchases one-time AI credits pack
      Req.Test.stub(stub_name, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)

        assert params["mode"] == "payment"
        assert params["line_items[0][price]"] == "price_tokens_50k"
        assert params["line_items[0][quantity]"] == "1"
        assert params["metadata[credits]"] == "50000"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "cs_pay_one_time_101",
            "url" => "https://checkout.stripe.test/pay/cs_pay_one_time_101"
          })
        )
      end)

      checkout_opts =
        opts
        |> Keyword.merge(
          mode: "payment",
          line_items: [%{price: "price_tokens_50k", quantity: 1}],
          metadata: %{"credits" => "50000", "purpose" => "token_topup"},
          success_url: "https://saas.com/tokens/success",
          cancel_url: "https://saas.com/tokens/cancel"
        )

      assert {:ok, session} = AshBilling.create_checkout_session(user, checkout_opts)
      assert session.id == "cs_pay_one_time_101"

      # 3. Stripe sends checkout.session.completed for the one-off charge
      checkout_completed_event = %{
        "id" => "evt_one_time_paid_101",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "id" => "cs_pay_one_time_101",
            "customer" => "cus_stripe_tokens_buyer",
            "payment_status" => "paid",
            "amount_total" => 4900,
            "currency" => "usd",
            "metadata" => %{
              "resource_id" => user.id,
              "credits" => "50000"
            }
          }
        }
      }

      conn = send_signed_webhook(checkout_completed_event, plug_opts)
      assert conn.status == 200

      # 4. Verify Ash User has their stripe_customer_id automatically linked
      user = Ash.get!(User, user.id, domain: Domain)
      assert user.stripe_customer_id == "cus_stripe_tokens_buyer"

      # 5. Verify the custom payment fulfillment handler received the paid session
      assert_received {:fulfill_payment, received_event}
      assert received_event["data"]["object"]["payment_status"] == "paid"
      assert received_event["data"]["object"]["metadata"]["credits"] == "50000"
      assert received_event["data"]["object"]["amount_total"] == 4900
    end
  end

  describe "Invoice Lifecycle and Payment Failures (Dunning)" do
    test "handles recurring invoice payment success for receipt generation" do
      plug_opts =
        BillingPlug.init(
          webhook_secret: @secret,
          handler: PaymentFulfillmentHandler
        )

      invoice_paid_event = %{
        "id" => "evt_invoice_paid_202",
        "type" => "invoice.payment_succeeded",
        "data" => %{
          "object" => %{
            "id" => "in_stripe_monthly_888",
            "customer" => "cus_subscriber_1",
            "amount_paid" => 2900,
            "currency" => "usd",
            "hosted_invoice_url" => "https://invoice.stripe.test/in_888"
          }
        }
      }

      conn = send_signed_webhook(invoice_paid_event, plug_opts)
      assert conn.status == 200

      assert_received {:invoice_paid, event}
      assert event["data"]["object"]["id"] == "in_stripe_monthly_888"
      assert event["data"]["object"]["amount_paid"] == 2900
    end

    test "handles invoice payment failure and updates subscription to past_due" do
      plug_opts =
        BillingPlug.init(
          webhook_secret: @secret,
          customer_resource: User,
          subscription_resource: Subscription,
          domain: Domain,
          handler: PaymentFulfillmentHandler
        )

      # 1. Existing subscriber with active subscription
      {:ok, user} =
        Ash.create(
          User,
          %{email: "dunning@saas.com", stripe_customer_id: "cus_dunning_303"},
          domain: Domain
        )

      {:ok, subscription} =
        Ash.create(
          Subscription,
          %{
            user_id: user.id,
            provider_subscription_id: "sub_dunning_303",
            status: :active,
            price_id: "price_pro_monthly"
          },
          domain: Domain
        )

      assert subscription.status == :active

      # 2. Stripe invoice fails (e.g. card expired / insufficient funds)
      invoice_failed_event = %{
        "id" => "evt_invoice_fail_404",
        "type" => "invoice.payment_failed",
        "data" => %{
          "object" => %{
            "id" => "in_stripe_failed_999",
            "customer" => "cus_dunning_303",
            "subscription" => "sub_dunning_303",
            "attempt_count" => 1,
            "next_payment_attempt" => System.system_time(:second) + 86_400,
            "amount_due" => 2900
          }
        }
      }

      conn1 = send_signed_webhook(invoice_failed_event, plug_opts)
      assert conn1.status == 200

      # Verify app handler received failure notification to alert user
      assert_received {:payment_failed_alert, fail_event}
      assert fail_event["data"]["object"]["attempt_count"] == 1
      assert fail_event["data"]["object"]["amount_due"] == 2900

      # 3. Stripe transitions subscription to past_due (grace period)
      sub_past_due_event = %{
        "id" => "evt_sub_past_due_505",
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "id" => "sub_dunning_303",
            "customer" => "cus_dunning_303",
            "status" => "past_due",
            "cancel_at_period_end" => false
          }
        }
      }

      conn2 = send_signed_webhook(sub_past_due_event, plug_opts)
      assert conn2.status == 200

      # 4. Verify subscription status in database is now past_due
      updated_sub =
        Subscription
        |> Ash.Query.new()
        |> Ash.Query.filter(provider_subscription_id == "sub_dunning_303")
        |> Ash.read_one!(domain: Domain)

      assert updated_sub.status == :past_due

      # 5. Calculation active? evaluates to false when past_due (or grace period expired)
      {:ok, active?} = Ash.calculate(updated_sub, :active?, domain: Domain)
      assert active? == false
    end
  end
end
