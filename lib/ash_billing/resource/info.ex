defmodule AshBilling.Resource.Info do
  @moduledoc """
  Introspection helpers for resources using `AshBilling.Resource`.
  """

  @doc """
  Gets the customer ID attribute name configured for the resource.
  """
  def customer_id_attribute(resource) do
    Spark.Dsl.Extension.get_opt(
      resource,
      [:billing],
      :customer_id_attribute,
      :stripe_customer_id
    )
  end

  @doc """
  Gets the billing provider configured for the resource.
  """
  def provider(resource) do
    Spark.Dsl.Extension.get_opt(
      resource,
      [:billing],
      :provider,
      AshBilling.Providers.Stripe
    )
  end
end
