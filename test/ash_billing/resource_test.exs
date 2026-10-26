defmodule AshBilling.ResourceTest do
  use ExUnit.Case, async: true

  alias AshBilling.Resource.Info, as: ResourceInfo
  alias AshBilling.Test.{CustomUser, User}

  describe "AshBilling.Resource extension" do
    test "injects default stripe_customer_id attribute into resource" do
      attribute = Ash.Resource.Info.attribute(User, :stripe_customer_id)
      assert attribute != nil
      assert attribute.name == :stripe_customer_id
      assert attribute.type == Ash.Type.String
      assert attribute.allow_nil? == true
      assert attribute.public? == true
    end

    test "respects custom customer_id_attribute" do
      attribute = Ash.Resource.Info.attribute(CustomUser, :custom_stripe_id)
      assert attribute != nil
      assert attribute.name == :custom_stripe_id
      assert attribute.type == Ash.Type.String

      assert ResourceInfo.customer_id_attribute(CustomUser) == :custom_stripe_id
      assert Ash.Resource.Info.attribute(CustomUser, :stripe_customer_id) == nil
    end

    test "provides correct provider introspection" do
      assert ResourceInfo.provider(User) == AshBilling.Providers.Stripe
    end
  end
end
