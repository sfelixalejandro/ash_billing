defmodule AshBilling.Checks.HasPrice do
  @moduledoc """
  An Ash policy check that authorizes if the current actor has an active subscription to a specific price.

  ## Usage

      policies do
        policy action(:pro_feature) do
          authorize_if {AshBilling.Checks.HasPrice, price: "price_pro_tier"}
        end
      end
  """

  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, opts) do
    AshBilling.Checks.Subscribed.match?(actor, context, opts)
  end

  @impl Ash.Policy.Check
  def describe(opts) do
    price = Keyword.get(opts, :price, "<unspecified>")
    "actor has an active subscription to price #{price}"
  end
end
