defmodule AshBilling.HardeningTest do
  use ExUnit.Case, async: true

  alias AshBilling.Test.{Domain, Subscription, User}
  alias AshBilling.WebhookSync

  @opts [
    customer_resource: User,
    subscription_resource: Subscription,
    domain: Domain
  ]

  describe "Payload polymorphism resilience" do
    test "processes expanded customer map object" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "expanded_cust@example.com", stripe_customer_id: "cus_expanded_100"},
          domain: Domain
        )

      # Stripe sending expanded customer object: %{"id" => "cus_...", "email" => ...}
      event = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_poly_expanded",
            "customer" => %{
              "id" => user.stripe_customer_id,
              "email" => user.email,
              "object" => "customer"
            },
            "status" => "active",
            "cancel_at_period_end" => false,
            "items" => %{"data" => [%{"price" => %{"id" => "price_poly_1"}}]}
          }
        }
      }

      assert {:ok, sub} = WebhookSync.sync_event(event, @opts)
      assert sub.provider_subscription_id == "sub_poly_expanded"
      assert sub.user_id == user.id
    end

    test "extracts price from plan object and direct price string" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "plan_test@example.com", stripe_customer_id: "cus_plan_poly"},
          domain: Domain
        )

      # 1. Price from plan.id inside items
      event1 = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_poly_plan_item",
            "customer" => user.stripe_customer_id,
            "status" => "active",
            "items" => %{"data" => [%{"plan" => %{"id" => "plan_legacy_pro"}}]}
          }
        }
      }

      assert {:ok, sub1} = WebhookSync.sync_event(event1, @opts)
      assert sub1.price_id == "plan_legacy_pro"

      # 2. Direct string price inside items
      event2 = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_poly_direct_price",
            "customer" => user.stripe_customer_id,
            "status" => "active",
            "items" => %{"data" => [%{"price" => "price_direct_str"}]}
          }
        }
      }

      assert {:ok, sub2} = WebhookSync.sync_event(event2, @opts)
      assert sub2.price_id == "price_direct_str"

      # 3. Root plan.id fallback
      event3 = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_poly_root_plan",
            "customer" => user.stripe_customer_id,
            "status" => "active",
            "plan" => %{"id" => "plan_root_legacy"}
          }
        }
      }

      assert {:ok, sub3} = WebhookSync.sync_event(event3, @opts)
      assert sub3.price_id == "plan_root_legacy"

      # 4. Root plan direct string fallback
      event4 = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_poly_root_plan_str",
            "customer" => user.stripe_customer_id,
            "status" => "active",
            "plan" => "plan_str_direct"
          }
        }
      }

      assert {:ok, sub4} = WebhookSync.sync_event(event4, @opts)
      assert sub4.price_id == "plan_str_direct"

      # 5. Root price.id fallback
      event5 = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_poly_root_price_id",
            "customer" => user.stripe_customer_id,
            "status" => "active",
            "price" => %{"id" => "price_root_obj"}
          }
        }
      }

      assert {:ok, sub5} = WebhookSync.sync_event(event5, @opts)
      assert sub5.price_id == "price_root_obj"

      # 6. Root price direct string fallback
      event6 = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_poly_root_price_str",
            "customer" => user.stripe_customer_id,
            "status" => "active",
            "price" => "price_root_str_direct"
          }
        }
      }

      assert {:ok, sub6} = WebhookSync.sync_event(event6, @opts)
      assert sub6.price_id == "price_root_str_direct"
    end

    test "handles :paused subscription status" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "paused_user@example.com", stripe_customer_id: "cus_paused_888"},
          domain: Domain
        )

      event = %{
        "type" => "customer.subscription.updated",
        "data" => %{
          "object" => %{
            "id" => "sub_paused_123",
            "customer" => user.stripe_customer_id,
            "status" => "paused",
            "items" => %{"data" => [%{"price" => %{"id" => "price_paused"}}]}
          }
        }
      }

      assert {:ok, sub} = WebhookSync.sync_event(event, @opts)
      assert sub.status == :paused
    end

    test "safely parses corrupted or invalid timestamps without crashing" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "corrupt_ts@example.com", stripe_customer_id: "cus_corrupt_ts"},
          domain: Domain
        )

      # Huge/invalid integer timestamp and non-integer strings
      event = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_corrupt_ts",
            "customer" => user.stripe_customer_id,
            "status" => "active",
            "current_period_end" => "not_a_valid_number",
            "trial_end" => 999_999_999_999_999_999
          }
        }
      }

      assert {:ok, sub} = WebhookSync.sync_event(event, @opts)
      assert sub.current_period_end == nil
      assert sub.trial_ends_at == nil
    end
  end

  describe "Pre-flight configuration diagnostics" do
    test "passes valid configuration" do
      assert {:ok, %{status: :valid}} =
               AshBilling.check_configuration(
                 customer_resource: User,
                 subscription_resource: Subscription,
                 api_key: "sk_test_valid_key_123",
                 webhook_secret: "whsec_valid_secret_456"
               )

      assert :ok =
               AshBilling.verify_configuration!(
                 customer_resource: User,
                 subscription_resource: Subscription,
                 api_key: "sk_test_valid_key_123",
                 webhook_secret: "whsec_valid_secret_456"
               )
    end

    test "detects invalid API key and webhook secret prefixes" do
      assert {:error, errors} =
               AshBilling.check_configuration(
                 api_key: "invalid_key_without_prefix",
                 webhook_secret: "invalid_secret_prefix"
               )

      assert Enum.any?(errors, &(&1 =~ "Stripe API key"))
      assert Enum.any?(errors, &(&1 =~ "Stripe webhook secret"))

      assert_raise ArgumentError, ~r/configuration verification failed/, fn ->
        AshBilling.verify_configuration!(api_key: "bad_prefix")
      end
    end

    test "detects resource missing required billing definitions" do
      assert {:error, errors} =
               AshBilling.check_configuration(
                 customer_resource: AshBilling.Test.IncompleteResource,
                 subscription_resource: AshBilling.Test.IncompleteResource
               )

      assert Enum.any?(errors, &(&1 =~ "missing attribute :stripe_customer_id"))
      assert Enum.any?(errors, &(&1 =~ "missing :subscriptions relationship"))
      assert Enum.any?(errors, &(&1 =~ "missing required attributes"))
      assert Enum.any?(errors, &(&1 =~ "missing :active? calculation"))
    end
  end

  describe "Concurrency race and edge-case resilience" do
    test "resolves concurrency race when creating subscription by falling back to update" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "race_user@example.com", stripe_customer_id: "cus_race_100"},
          domain: Domain
        )

      # Pre-create the subscription so that if create is called on it, it conflicts
      {:ok, existing_sub} =
        Ash.create(
          Subscription,
          %{
            user_id: user.id,
            provider_subscription_id: "sub_race_conflict_1",
            status: :incomplete,
            price_id: "price_old"
          },
          domain: Domain
        )

      # Now simulate an incoming webhook that triggers sync
      event = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_race_conflict_1",
            "customer" => user.stripe_customer_id,
            "status" => "active",
            "items" => %{"data" => [%{"price" => %{"id" => "price_race_won"}}]}
          }
        }
      }

      assert {:ok, sub} = WebhookSync.sync_event(event, @opts)
      assert sub.id == existing_sub.id
      assert sub.status == :active
      assert sub.price_id == "price_race_won"
    end

    test "handles customer.deleted when customer is not found or resource is nil" do
      event = %{
        "type" => "customer.deleted",
        "data" => %{"object" => %{"id" => "cus_unknown_999"}}
      }

      assert {:ok, :not_found} = WebhookSync.sync_event(event, @opts)

      opts_no_cust = Keyword.put(@opts, :customer_resource, nil)
      assert {:ok, :no_customer_resource} = WebhookSync.sync_event(event, opts_no_cust)

      # Nil object
      assert {:ok, :ignored} =
               WebhookSync.sync_event(
                 %{"type" => "customer.deleted", "data" => %{"object" => nil}},
                 @opts
               )

      # Subscription sync without customer resource
      sub_event = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_no_cust_res",
            "customer" => "cus_any",
            "status" => "active"
          }
        }
      }

      assert {:ok, _} = WebhookSync.sync_event(sub_event, opts_no_cust)
    end
  end
end
