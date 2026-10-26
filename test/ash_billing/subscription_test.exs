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
    end

    test "injects active? calculation into resource" do
      calc = Ash.Resource.Info.calculation(Subscription, :active?)
      assert calc != nil
      assert calc.type == Ash.Type.Boolean
      assert calc.filterable? == true
      assert calc.public? == true
    end

    test "provides correct introspection helpers" do
      assert SubscriptionInfo.provider(Subscription) == AshBilling.Providers.Stripe
      assert SubscriptionInfo.customer_relationship(Subscription) == :user
    end

    test "Spark DSL extension defines sections and transformers" do
      assert is_list(AshBilling.Subscription.sections())
      assert is_list(AshBilling.Subscription.transformers())
    end
  end
end
