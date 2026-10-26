defmodule AshBilling.Checks.Subscribed do
  @moduledoc """
  An Ash policy check that authorizes if the current actor has an active billing subscription.

  Can be used as a simple check without options, or with a `:price` option to require a specific tier.

  ## Usage

      policies do
        # Authorize any active subscription
        policy action(:generate_report) do
          authorize_if AshBilling.Checks.Subscribed
        end

        # Authorize only users subscribed to a specific price/tier
        policy action(:export_enterprise_data) do
          authorize_if {AshBilling.Checks.Subscribed, price: "price_enterprise_annual"}
        end
      end

  ## Options

    * `:price` - An optional price identifier to require.
    * `:domain` - The Ash domain to use when lazy-loading subscriptions (defaults to the domain in context).
  """

  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.SimpleCheck
  def match?(actor, context, opts) do
    price = Keyword.get(opts, :price)
    domain = Keyword.get(opts, :domain) || Map.get(context, :domain)

    case actor do
      %_resource{} = record ->
        check_record(record, price, domain)

      _ ->
        false
    end
  end

  @impl Ash.Policy.Check
  def describe(opts) do
    case Keyword.get(opts, :price) do
      nil -> "actor has an active subscription"
      price -> "actor has an active subscription to #{price}"
    end
  end

  defp check_record(record, price, domain) do
    case record do
      %{subscriptions: subs} when is_list(subs) ->
        AshBilling.subscribed?(record, price)

      %{subscriptions: %Ash.NotLoaded{}} when not is_nil(domain) ->
        case Ash.load(record, :subscriptions, domain: domain, authorize?: false) do
          {:ok, loaded} -> AshBilling.subscribed?(loaded, price)
          _ -> false
        end

      _ ->
        AshBilling.subscribed?(record, price)
    end
  end
end
