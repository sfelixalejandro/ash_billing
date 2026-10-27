defmodule AshBilling.SubscriptionTest do
  use ExUnit.Case, async: true

  alias AshBilling.Subscription.Info, as: SubscriptionInfo
  alias AshBilling.Test.Subscription

  describe "AshBilling.Subscription extension" do
    test "injects subscription attributes into resource" do
      provider_id = Ash.Resource.Info.attribute(Subscription, :provider_subscription_id)
      assert provider_id != nil
      assert provider_id.type == Ash.Type.String
      assert provider_id.allow_nil? == false

      status = Ash.Resource.Info.attribute(Subscription, :status)
      assert status != nil
      assert status.type == Ash.Type.Atom
      assert status.allow_nil? == false

      price_id = Ash.Resource.Info.attribute(Subscription, :price_id)
      assert price_id != nil
      assert price_id.type == Ash.Type.String
      assert price_id.allow_nil? == true

      current_period_end = Ash.Resource.Info.attribute(Subscription, :current_period_end)
      assert current_period_end != nil
      assert current_period_end.type == Ash.Type.UtcDatetimeUsec

      cancel_at_period_end = Ash.Resource.Info.attribute(Subscription, :cancel_at_period_end)
      assert cancel_at_period_end != nil
      assert cancel_at_period_end.type == Ash.Type.Boolean
      assert cancel_at_period_end.default == false

      cancel_at = Ash.Resource.Info.attribute(Subscription, :cancel_at)
      assert cancel_at != nil
      assert cancel_at.type == Ash.Type.UtcDatetimeUsec
      assert cancel_at.allow_nil? == true

      trial_ends_at = Ash.Resource.Info.attribute(Subscription, :trial_ends_at)
      assert trial_ends_at != nil
      assert trial_ends_at.type == Ash.Type.UtcDatetimeUsec
      assert trial_ends_at.allow_nil? == true
    end

    test "injects active?, on_trial?, and canceling? calculations into resource" do
      calc = Ash.Resource.Info.calculation(Subscription, :active?)
      assert calc != nil
      assert calc.type == Ash.Type.Boolean
      assert calc.filterable? == true
      assert calc.public? == true

      trial_calc = Ash.Resource.Info.calculation(Subscription, :on_trial?)
      assert trial_calc != nil
      assert trial_calc.type == Ash.Type.Boolean
      assert trial_calc.filterable? == true
      assert trial_calc.public? == true

      canceling_calc = Ash.Resource.Info.calculation(Subscription, :canceling?)
      assert canceling_calc != nil
      assert canceling_calc.type == Ash.Type.Boolean
      assert canceling_calc.filterable? == true
      assert canceling_calc.public? == true
    end

    test "evaluates on_trial? and active? during trials" do
      future = DateTime.utc_now() |> DateTime.add(10, :day)
      past = DateTime.utc_now() |> DateTime.add(-1, :day)

      # Active trial
      sub_trial = %Subscription{
        provider_subscription_id: "sub_trial_1",
        status: :trialing,
        trial_ends_at: future
      }

      assert {:ok, true} = Ash.calculate(sub_trial, :on_trial?)
      assert {:ok, true} = Ash.calculate(sub_trial, :active?)

      # Expired trial with canceled status
      sub_expired = %Subscription{
        provider_subscription_id: "sub_trial_2",
        status: :canceled,
        trial_ends_at: past
      }

      assert {:ok, false} = Ash.calculate(sub_expired, :on_trial?)
      assert {:ok, false} = Ash.calculate(sub_expired, :active?)

      # Past due but trial still ongoing (grace period)
      sub_grace = %Subscription{
        provider_subscription_id: "sub_trial_3",
        status: :past_due,
        trial_ends_at: future
      }

      assert {:ok, true} = Ash.calculate(sub_grace, :on_trial?)
      assert {:ok, true} = Ash.calculate(sub_grace, :active?)
    end

    test "evaluates canceling? calculation" do
      future = DateTime.utc_now() |> DateTime.add(10, :day)
      past = DateTime.utc_now() |> DateTime.add(-1, :day)

      sub_normal = %Subscription{
        provider_subscription_id: "sub_c_1",
        status: :active,
        cancel_at_period_end: false,
        cancel_at: nil
      }

      assert {:ok, false} = Ash.calculate(sub_normal, :canceling?)

      sub_period_end = %Subscription{
        provider_subscription_id: "sub_c_2",
        status: :active,
        cancel_at_period_end: true,
        cancel_at: nil
      }

      assert {:ok, true} = Ash.calculate(sub_period_end, :canceling?)

      sub_future_cancel = %Subscription{
        provider_subscription_id: "sub_c_3",
        status: :active,
        cancel_at_period_end: false,
        cancel_at: future
      }

      assert {:ok, true} = Ash.calculate(sub_future_cancel, :canceling?)

      sub_past_cancel = %Subscription{
        provider_subscription_id: "sub_c_4",
        status: :active,
        cancel_at_period_end: false,
        cancel_at: past
      }

      assert {:ok, false} = Ash.calculate(sub_past_cancel, :canceling?)
    end

    test "provides correct introspection helpers" do
      assert SubscriptionInfo.provider(Subscription) == AshBilling.Providers.Stripe
      assert SubscriptionInfo.customer_relationship(Subscription) == :user
    end

    test "Spark DSL extension defines sections, transformers, and verifiers" do
      assert is_list(AshBilling.Subscription.sections())
      assert is_list(AshBilling.Subscription.transformers())
      assert is_list(AshBilling.Subscription.verifiers())

      assert AshBilling.Subscription.Verifiers.VerifyCustomerRelationship in AshBilling.Subscription.verifiers()
    end
  end
end
