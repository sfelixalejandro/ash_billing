defmodule AshBilling.WebhookSyncTest do
  use ExUnit.Case, async: true

  alias AshBilling.Test.{Domain, PolicySubscription, PolicyUser, Subscription, User}
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
        "created" => 1_735_689_600,
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

    test "resolves customer via metadata resource_id and auto-links stripe_customer_id" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "new_checkout_user@example.com"},
          domain: Domain
        )

      assert user.stripe_customer_id == nil

      # Subscription event arrives with metadata resource_id
      event = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_stripe_meta_400",
            "customer" => "cus_brand_new_stripe_id",
            "status" => "active",
            "cancel_at_period_end" => false,
            "current_period_end" => 1_735_689_600,
            "metadata" => %{
              "resource_id" => user.id
            },
            "items" => %{
              "data" => [
                %{"price" => %{"id" => "price_premium_monthly"}}
              ]
            }
          }
        }
      }

      assert {:ok, subscription} = WebhookSync.sync_event(event, @opts)
      assert subscription.provider_subscription_id == "sub_stripe_meta_400"
      assert subscription.user_id == user.id

      # Verify the user record was automatically updated with the stripe_customer_id
      {:ok, updated_user} = Ash.get(User, user.id, domain: Domain)
      assert updated_user.stripe_customer_id == "cus_brand_new_stripe_id"
    end

    test "syncs trial_end timestamp into trial_ends_at attribute" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "trial_sync_user@example.com", stripe_customer_id: "cus_trial_sync_100"},
          domain: Domain
        )

      trial_timestamp = 1_793_000_000

      event = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_stripe_trial_sync",
            "customer" => user.stripe_customer_id,
            "status" => "trialing",
            "cancel_at_period_end" => false,
            "current_period_end" => 1_795_000_000,
            "trial_end" => trial_timestamp,
            "items" => %{"data" => [%{"price" => %{"id" => "price_pro_trial"}}]}
          }
        }
      }

      assert {:ok, subscription} = WebhookSync.sync_event(event, @opts)
      assert subscription.provider_subscription_id == "sub_stripe_trial_sync"
      assert subscription.status == :trialing
      assert DateTime.to_unix(subscription.trial_ends_at) == trial_timestamp
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

    test "links stripe_customer_id via client_reference_id" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "client_ref_user@example.com"},
          domain: Domain
        )

      assert user.stripe_customer_id == nil

      checkout_event = %{
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "customer" => "cus_from_client_ref_777",
            "client_reference_id" => user.id
          }
        }
      }

      assert {:ok, updated_user} = WebhookSync.sync_event(checkout_event, @opts)
      assert updated_user.stripe_customer_id == "cus_from_client_ref_777"
    end
  end

  describe "sync_event/2 with Ash.Policy.Authorizer" do
    test "bypasses policies by default with authorize?: false" do
      # 1. Verify that PolicyUser strictly forbids unauthorized creation when authorize? is true
      assert_raise Ash.Error.Forbidden, fn ->
        Ash.create!(
          PolicyUser,
          %{email: "policy_fail@example.com"},
          domain: Domain,
          authorize?: true
        )
      end

      # 2. Create the policy-protected user with bypass
      {:ok, user} =
        Ash.create(
          PolicyUser,
          %{
            email: "policy_user@example.com",
            stripe_customer_id: "cus_policy_101"
          },
          domain: Domain,
          authorize?: false
        )

      policy_opts = [
        customer_resource: PolicyUser,
        subscription_resource: PolicySubscription,
        domain: Domain
      ]

      # 3. Simulate Stripe webhook syncing subscription without an active actor
      event = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_stripe_policy_999",
            "customer" => "cus_policy_101",
            "status" => "active",
            "cancel_at_period_end" => false,
            "current_period_end" => 1_735_689_600,
            "items" => %{
              "data" => [
                %{"price" => %{"id" => "price_enterprise_annual"}}
              ]
            }
          }
        }
      }

      assert {:ok, subscription} = WebhookSync.sync_event(event, policy_opts)
      assert subscription.provider_subscription_id == "sub_stripe_policy_999"
      assert subscription.user_id == user.id
      assert subscription.status == :active
    end
  end

  describe "sync_event/2 defensive handling and edge cases" do
    test "ignores unknown or unhandled event types cleanly" do
      event = %{"type" => "invoice.payment_succeeded", "data" => %{"object" => %{}}}
      assert {:ok, :ignored} = WebhookSync.sync_event(event, @opts)
    end

    test "handles subscription event when subscription_resource is nil" do
      event = %{
        "type" => "customer.subscription.created",
        "data" => %{"object" => %{"id" => "sub_1", "customer" => "cus_1"}}
      }

      opts_no_sub = Keyword.delete(@opts, :subscription_resource)
      assert {:ok, :no_subscription_resource} = WebhookSync.sync_event(event, opts_no_sub)
    end

    test "handles subscription event when object is nil" do
      event = %{"type" => "customer.subscription.created", "data" => %{"object" => nil}}
      assert {:ok, :ignored} = WebhookSync.sync_event(event, @opts)
    end

    test "handles checkout session when customer_resource is nil" do
      event = %{
        "type" => "checkout.session.completed",
        "data" => %{"object" => %{"customer" => "cus_1", "client_reference_id" => "user_1"}}
      }

      opts_no_cust = Keyword.delete(@opts, :customer_resource)
      assert {:ok, :no_customer_resource} = WebhookSync.sync_event(event, opts_no_cust)
    end

    test "handles checkout session when customer already has customer_id set" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "already_set@example.com", stripe_customer_id: "cus_existing_fixed"},
          domain: Domain
        )

      event = %{
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "customer" => "cus_new_attempt",
            "metadata" => %{"resource_id" => user.id}
          }
        }
      }

      assert {:ok, result_user} = WebhookSync.sync_event(event, @opts)
      assert result_user.stripe_customer_id == "cus_existing_fixed"
    end

    test "handles checkout session without customer or resource_id" do
      event = %{
        "type" => "checkout.session.completed",
        "data" => %{"object" => %{}}
      }

      assert {:ok, :ignored} = WebhookSync.sync_event(event, @opts)
    end

    test "extracts price_id from legacy plan object and normalizes statuses" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "plan_test@example.com", stripe_customer_id: "cus_plan_test"},
          domain: Domain
        )

      statuses = ["unpaid", "incomplete", "incomplete_expired", "unknown_status"]

      Enum.each(statuses, fn raw_status ->
        event = %{
          "type" => "customer.subscription.created",
          "data" => %{
            "object" => %{
              "id" => "sub_plan_#{raw_status}",
              "customer" => user.stripe_customer_id,
              "status" => raw_status,
              "plan" => %{"id" => "plan_legacy_tier"}
            }
          }
        }

        assert {:ok, sub} = WebhookSync.sync_event(event, @opts)
        assert sub.price_id == "plan_legacy_tier"
      end)
    end

    test "handles subscription with non-existent resource_id in metadata" do
      event = %{
        "type" => "customer.subscription.created",
        "data" => %{
          "object" => %{
            "id" => "sub_unlinked_123",
            "status" => "active",
            "metadata" => %{"resource_id" => Ash.UUID.generate()}
          }
        }
      }

      assert {:ok, sub} = WebhookSync.sync_event(event, @opts)
      assert sub.provider_subscription_id == "sub_unlinked_123"
      assert sub.user_id == nil
    end

    test "handles customer.deleted and clears stripe_customer_id from user" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "deleted_customer@example.com", stripe_customer_id: "cus_to_delete_999"},
          domain: Domain
        )

      assert user.stripe_customer_id == "cus_to_delete_999"

      event = %{
        "type" => "customer.deleted",
        "data" => %{
          "object" => %{
            "id" => "cus_to_delete_999"
          }
        }
      }

      assert {:ok, updated_user} = WebhookSync.sync_event(event, @opts)
      assert updated_user.stripe_customer_id == nil

      # Refresh from DB
      reloaded_user = Ash.get!(User, user.id, domain: Domain)
      assert reloaded_user.stripe_customer_id == nil
    end

    test "handles customer.deleted when customer does not exist in local database" do
      event = %{
        "type" => "customer.deleted",
        "data" => %{
          "object" => %{
            "id" => "cus_non_existent"
          }
        }
      }

      assert {:ok, :not_found} = WebhookSync.sync_event(event, @opts)
    end

    test "resolves customer via customer_email when stripe_customer_id and metadata are absent" do
      {:ok, user} =
        Ash.create(
          User,
          %{email: "lookup_by_email@example.com"},
          domain: Domain
        )

      event = %{
        "type" => "customer.subscription.created",
        "created" => "invalid_timestamp_format",
        "data" => %{
          "object" => %{
            "id" => "sub_stripe_email_resolved",
            "customer" => "cus_unknown_by_id",
            "customer_email" => "lookup_by_email@example.com",
            "status" => "active",
            "cancel_at_period_end" => false,
            "items" => %{
              "data" => [
                %{"price" => %{"id" => "price_basic"}}
              ]
            }
          }
        }
      }

      assert {:ok, sub} = WebhookSync.sync_event(event, @opts)
      assert sub.provider_subscription_id == "sub_stripe_email_resolved"
      assert sub.user_id == user.id
    end

    test "atomic conditional update protects against stale out-of-order writes on the same subscription" do
      {:ok, _user} =
        Ash.create(
          User,
          %{email: "atomic_race@example.com", stripe_customer_id: "cus_atomic_race"},
          domain: Domain
        )

      now_unix = System.system_time(:second)
      newer_unix = now_unix + 100
      older_unix = now_unix + 10

      # 1. First event creates subscription at newer_unix
      newer_event = %{
        "id" => "evt_newer_webhook",
        "type" => "customer.subscription.created",
        "created" => newer_unix,
        "data" => %{
          "object" => %{
            "id" => "sub_atomic_race_1",
            "customer" => "cus_atomic_race",
            "status" => "active",
            "cancel_at_period_end" => false,
            "items" => %{
              "data" => [%{"price" => %{"id" => "price_pro"}}]
            }
          }
        }
      }

      assert {:ok, sub} = WebhookSync.sync_event(newer_event, @opts)
      assert sub.status == :active
      assert sub.price_id == "price_pro"

      # 2. Older event arrives out of order with older timestamp
      older_event = %{
        "id" => "evt_older_webhook",
        "type" => "customer.subscription.updated",
        "created" => older_unix,
        "data" => %{
          "object" => %{
            "id" => "sub_atomic_race_1",
            "customer" => "cus_atomic_race",
            "status" => "past_due",
            "cancel_at_period_end" => false,
            "items" => %{
              "data" => [%{"price" => %{"id" => "price_basic"}}]
            }
          }
        }
      }

      # Syncing older event MUST NOT overwrite the active pro subscription
      assert {:ok, updated_sub} = WebhookSync.sync_event(older_event, @opts)
      assert updated_sub.status == :active
      assert updated_sub.price_id == "price_pro"
    end

    test "update_subscription_safely atomically rejects stale update when DB record has newer timestamp" do
      {:ok, user} =
        Ash.create(
          User,
          %{
            email: "stale_race@example.com",
            stripe_customer_id: "cus_stale_race"
          },
          domain: Domain
        )

      sub_id = "sub_stale_race_#{System.unique_integer([:positive])}"
      t1 = ~U[2026-10-27 10:00:00Z]
      t2 = ~U[2026-10-27 12:00:00Z]

      # Subscription created with older timestamp t1
      {:ok, existing} =
        Ash.create(
          Subscription,
          %{
            provider_subscription_id: sub_id,
            status: :active,
            user_id: user.id,
            price_id: "price_initial",
            last_event_created_at: t1
          },
          domain: Domain
        )

      # Another concurrent worker updates DB record to newer timestamp t2
      {:ok, newer_db_record} =
        Ash.update(
          existing,
          %{price_id: "price_authoritative_t2", last_event_created_at: t2},
          domain: Domain
        )

      # Stale worker attempts to execute update_subscription_safely with older timestamp t1
      stale_attrs = %{price_id: "price_stale_t1", status: :past_due}
      ash_opts = [domain: Domain, authorize?: false]

      assert {:ok, result} =
               WebhookSync.update_subscription_safely(
                 Subscription,
                 existing,
                 stale_attrs,
                 t1,
                 ash_opts
               )

      # The result must be the authoritative record from DB, not the stale write
      assert result.price_id == "price_authoritative_t2"
      assert DateTime.compare(result.last_event_created_at, t2) == :eq

      # When record no longer exists in DB during 0-records match, returns {:ok, existing}
      deleted_existing = %{
        existing
        | id: Ash.UUID.generate(),
          provider_subscription_id: "sub_missing_race"
      }

      assert {:ok, returned_existing} =
               WebhookSync.update_subscription_safely(
                 Subscription,
                 deleted_existing,
                 stale_attrs,
                 t1,
                 ash_opts
               )

      assert returned_existing.provider_subscription_id == "sub_missing_race"

      # When event_dt is nil, falls back to Ash.update
      assert {:ok, updated_fallback} =
               WebhookSync.update_subscription_safely(
                 Subscription,
                 newer_db_record,
                 %{status: :active},
                 nil,
                 ash_opts
               )

      assert updated_fallback.status == :active
    end
  end
end
