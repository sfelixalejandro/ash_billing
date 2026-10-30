defmodule AshBilling.EndToEndTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias AshBilling.Plug, as: BillingPlug
  alias AshBilling.Test.{Domain, Subscription, User}

  @secret "whsec_e2e_test_secret"

  setup do
    stub_name = :"e2e_stripe_stub_#{System.unique_integer([:positive])}"
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

  describe "Full SaaS subscription lifecycle" do
    test "from user signup, checkout, webhook sync, and cancellation", %{
      stub_name: stub_name,
      opts: opts
    } do
      plug_opts =
        BillingPlug.init(
          webhook_secret: @secret,
          customer_resource: User,
          subscription_resource: Subscription,
          domain: Domain
        )

      # 1. User signs up in the app
      {:ok, user} =
        Ash.create(
          User,
          %{email: "founder@saas.com", name: "Alex Felix"},
          domain: Domain
        )

      assert user.stripe_customer_id == nil

      # 2. User starts checkout
      Req.Test.stub(stub_name, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "cs_e2e_123",
            "url" => "https://checkout.stripe.test/cs_e2e_123"
          })
        )
      end)

      checkout_opts =
        opts
        |> Keyword.merge(
          price: "price_pro_annual",
          success_url: "https://saas.com/success",
          cancel_url: "https://saas.com/cancel"
        )

      assert {:ok, %{url: url}} = AshBilling.create_checkout_session(user, checkout_opts)
      assert url =~ "checkout.stripe.test"

      # 3. User finishes checkout -> Stripe sends checkout.session.completed webhook
      checkout_completed_event = %{
        "id" => "evt_" <> Ash.UUID.generate(),
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "customer" => "cus_stripe_e2e_founder",
            "metadata" => %{
              "resource_id" => user.id
            }
          }
        }
      }

      conn = send_signed_webhook(checkout_completed_event, plug_opts)
      assert conn.status == 200

      # Verify customer ID was linked to user in the database
      user = Ash.get!(User, user.id, domain: Domain)
      assert user.stripe_customer_id == "cus_stripe_e2e_founder"

      # 4. Stripe sends customer.subscription.created webhook
      sub_created_event = %{
        "id" => "evt_" <> Ash.UUID.generate(),
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_stripe_pro_100",
            "customer" => "cus_stripe_e2e_founder",
            "status" => "active",
            "cancel_at_period_end" => false,
            "current_period_end" => 1_767_225_600,
            "items" => %{
              "data" => [
                %{"price" => %{"id" => "price_pro_annual"}}
              ]
            }
          }
        }
      }

      conn = send_signed_webhook(sub_created_event, plug_opts)
      assert conn.status == 200

      # 5. Check subscription state on user
      user =
        user
        |> Ash.load!(:subscriptions, domain: Domain)

      assert length(user.subscriptions) == 1
      assert AshBilling.subscribed?(user) == true
      assert AshBilling.subscribed?(user, "price_pro_annual") == true
      assert AshBilling.subscribed?(user, "price_hobby") == false

      # 6. Customer cancels subscription -> Stripe sends customer.subscription.deleted
      sub_deleted_event = %{
        "id" => "evt_" <> Ash.UUID.generate(),
        "type" => "customer.subscription.deleted",
        "data" => %{
          "object" => %{
            "id" => "sub_stripe_pro_100",
            "customer" => "cus_stripe_e2e_founder",
            "status" => "canceled"
          }
        }
      }

      conn = send_signed_webhook(sub_deleted_event, plug_opts)
      assert conn.status == 200

      # 7. Verify subscription is now canceled
      user =
        user
        |> Ash.load!(:subscriptions, domain: Domain)

      assert AshBilling.subscribed?(user) == false
    end
  end
end
