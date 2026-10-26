defmodule AshBilling.Subscription.Info do
  @moduledoc """
  Introspection helpers for resources using `AshBilling.Subscription`.
  """

  @doc """
  Gets the billing provider configured for the subscription resource.
  """
  def provider(resource) do
    Spark.Dsl.Extension.get_opt(
      resource,
      [:billing_subscription],
      :provider,
      AshBilling.Providers.Stripe
    )
  end

  @doc """
  Gets the customer relationship name configured for the subscription resource.
  """
  def customer_relationship(resource) do
    Spark.Dsl.Extension.get_opt(
      resource,
      [:billing_subscription],
      :customer_relationship
    )
  end
end
