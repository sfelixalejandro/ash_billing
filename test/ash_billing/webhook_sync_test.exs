defmodule AshBilling.WebhookSyncTest do
  use ExUnit.Case, async: true

  alias AshBilling.Test.{Domain, Subscription, User}
  alias AshBilling.WebhookSync

  @opts [
    customer_resource: User,
    subscription_resource: Subscription,
    domain: Domain
  ]

  describe "sync_event/2 for customer.subscription events" do
    test "creates subscription and links to customer on customer.subscription.created" do
      {:ok, user} =
        Ash.create(
          User,
          %{
            email: "subscriber@example.com",
            name: "Subscriber",
            stripe_customer_id: "cus_auto_sync_1"
          },
          domain: Domain
        )

      event = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_stripe_100",
            "customer" => "cus_auto_sync_1",
            "status" => "active",
            "cancel_at_period_end" => false,
            "current_period_end" => 1_735_689_600,
            "items" => %{
              "data" => [
                %{"price" => %{"id" => "price_premium_monthly"}}
              ]
            }
          }
        }
      }

      assert {:ok, subscription} = WebhookSync.sync_event(event, @opts)
      assert subscription.provider_subscription_id == "sub_stripe_100"
      assert subscription.status == :active
      assert subscription.price_id == "price_premium_monthly"
      assert subscription.user_id == user.id
      assert subscription.cancel_at_period_end == false
    end

    test "updates existing subscription on customer.subscription.updated" do
      {:ok, user} =
        Ash.create(
          User,
          %{
            email: "update@example.com",
            stripe_customer_id: "cus_auto_sync_2"
          },
          domain: Domain
        )

      {:ok, _sub} =
        Ash.create(
          Subscription,
          %{
            provider_subscription_id: "sub_stripe_200",
            status: :active,
            user_id: user.id
          },
          domain: Domain
        )

      update_event = %{
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "id" => "sub_stripe_200",
            "customer" => "cus_auto_sync_2",
            "status" => "past_due",
            "cancel_at_period_end" => true,
            "current_period_end" => 1_735_689_600,
            "items" => %{"data" => []}
          }
        }
      }

      assert {:ok, updated_sub} = WebhookSync.sync_event(update_event, @opts)
      assert updated_sub.provider_subscription_id == "sub_stripe_200"
      assert updated_sub.status == :past_due
      assert updated_sub.cancel_at_period_end == true
    end

    test "sets status to canceled on customer.subscription.deleted" do
      {:ok, user} =
        Ash.create(
          User,
          %{
            email: "cancel@example.com",
            stripe_customer_id: "cus_auto_sync_3"
          },
          domain: Domain
        )

      {:ok, _sub} =
        Ash.create(
          Subscription,
          %{
            provider_subscription_id: "sub_stripe_300",
            status: :active,
            user_id: user.id
          },
          domain: Domain
        )

      cancel_event = %{
        "type" => "customer.subscription.deleted",
        "data" => %{
          "object" => %{
            "id" => "sub_stripe_300",
            "customer" => "cus_auto_sync_3",
            "status" => "canceled",
            "cancel_at_period_end" => false
          }
        }
      }

      assert {:ok, canceled_sub} = WebhookSync.sync_event(cancel_event, @opts)
      assert canceled_sub.provider_subscription_id == "sub_stripe_300"
      assert canceled_sub.status == :canceled
    end
  end

  describe "sync_event/2 for checkout.session.completed" do
    test "links stripe_customer_id to customer if not already present" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "checkout_user@example.com"},
          domain: Domain
        )

      assert user.stripe_customer_id == nil

      checkout_event = %{
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "customer" => "cus_from_stripe_session_999",
            "metadata" => %{
              "resource_id" => user.id
            }
          }
        }
      }

      assert {:ok, updated_user} = WebhookSync.sync_event(checkout_event, @opts)
      assert updated_user.stripe_customer_id == "cus_from_stripe_session_999"
    end
  end
end
