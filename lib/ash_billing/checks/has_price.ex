defmodule AshBilling.Checks.HasPrice do
  @moduledoc """
  An Ash policy check that authorizes if the current actor has an active subscription to a specific price.

  Requires a valid, non-empty `:price` identifier. If `:price` is missing, nil, empty,
  whitespace-only, or not a string, authorization fails closed (denies access).

  ## Usage

      policies do
        policy action(:pro_feature) do
          authorize_if {AshBilling.Checks.HasPrice, price: "price_pro_tier"}
        end
      end
  """

  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def init(opts) do
    case Keyword.get(opts, :price) do
      price when is_binary(price) ->
        if String.trim(price) == "" do
          {:error, ":price in AshBilling.Checks.HasPrice must not be empty or whitespace-only"}
        else
          {:ok, opts}
        end

      nil ->
        {:error, ":price option is required for AshBilling.Checks.HasPrice"}

      other ->
        {:error,
         ":price in AshBilling.Checks.HasPrice must be a non-empty string, got: #{inspect(other)}"}
    end
  end

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, opts) do
    case Keyword.get(opts, :price) do
      price when is_binary(price) ->
        trimmed = String.trim(price)

        if trimmed == "" do
          false
        else
          AshBilling.Checks.Subscribed.match?(actor, context, Keyword.put(opts, :price, trimmed))
        end

      _ ->
        false
    end
  end

  @impl Ash.Policy.Check
  def describe(opts) do
    case Keyword.get(opts, :price) do
      price when is_binary(price) and price != "" ->
        "actor has an active subscription to price #{price}"

      _ ->
        "actor has an active subscription to <unspecified/invalid price>"
    end
  end
end
