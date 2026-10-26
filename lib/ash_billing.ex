defmodule AshBilling do
  @moduledoc """
  Top-level API for `AshBilling`.

  Provides functions for managing billing customers, checkout sessions,
  customer portals, and subscriptions.
  """

  alias AshBilling.Providers.Stripe
  alias AshBilling.Resource.Info, as: ResourceInfo

  @doc """
  Extracts the customer ID from a record configured with `AshBilling.Resource`.
  """
  @spec customer_id(struct()) :: String.t() | nil
  def customer_id(%resource{} = record) do
    attr = ResourceInfo.customer_id_attribute(resource)
    Map.get(record, attr)
  end

  def customer_id(_), do: nil

  @doc """
  Creates a billing customer in the configured provider.

  If the record already has a customer ID, returns `{:ok, existing_customer_id}` without calling the provider.
  """
  @spec create_customer(struct() | map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_customer(%resource{} = record, opts) do
    provider = Keyword.get(opts, :provider, ResourceInfo.provider(resource))
    existing_id = customer_id(record)

    if existing_id do
      {:ok, existing_id}
    else
      params =
        opts
        |> Keyword.get(:params, %{})
        |> Map.merge(%{
          email: Map.get(record, :email),
          name: Map.get(record, :name),
          metadata: %{
            resource_id: to_string(Map.get(record, :id))
          }
        })
        |> remove_nil_values()

      provider.create_customer(params, opts)
    end
  end

  def create_customer(params, opts) when is_map(params) do
    provider = Keyword.get(opts, :provider, Stripe)
    provider.create_customer(params, opts)
  end

  @doc """
  Creates a checkout session for a customer.

  ## Options

    * `:price` - The price ID to subscribe to or purchase (shortcut for `:line_items`).
    * `:quantity` - The quantity of the price (defaults to 1).
    * `:line_items` - Explicit list of line items (e.g. `[%{price: "price_123", quantity: 1}]`).
    * `:success_url` - The URL to redirect to upon success (required).
    * `:cancel_url` - The URL to redirect to if the user cancels (required).
    * `:mode` - `"subscription"` (default) or `"payment"`.
    * `:provider` - The billing provider module.
  """
  @spec create_checkout_session(struct() | String.t(), keyword()) ::
          {:ok, %{url: String.t(), id: String.t()}} | {:error, term()}
  def create_checkout_session(record_or_customer_id, opts) do
    cust_id = resolve_customer_id(record_or_customer_id)
    provider = resolve_provider(record_or_customer_id, opts)

    line_items =
      case Keyword.get(opts, :line_items) do
        items when is_list(items) ->
          items

        nil ->
          price = Keyword.fetch!(opts, :price)
          quantity = Keyword.get(opts, :quantity, 1)
          [%{price: price, quantity: quantity}]
      end

    resource_id =
      case record_or_customer_id do
        %{id: id} when not is_nil(id) -> to_string(id)
        _ -> nil
      end

    custom_metadata = Keyword.get(opts, :metadata, %{}) |> Enum.into(%{})

    metadata =
      if resource_id do
        Map.put_new(custom_metadata, "resource_id", resource_id)
      else
        custom_metadata
      end

    client_ref_id = Keyword.get(opts, :client_reference_id, resource_id)

    params =
      %{
        line_items: line_items,
        success_url: Keyword.fetch!(opts, :success_url),
        cancel_url: Keyword.fetch!(opts, :cancel_url),
        mode: Keyword.get(opts, :mode, "subscription")
      }
      |> then(fn p -> if cust_id, do: Map.put(p, :customer, cust_id), else: p end)
      |> then(fn p ->
        if client_ref_id, do: Map.put(p, :client_reference_id, client_ref_id), else: p
      end)
      |> then(fn p -> if map_size(metadata) > 0, do: Map.put(p, :metadata, metadata), else: p end)
      |> then(fn p ->
        if p.mode == "subscription" and map_size(metadata) > 0 do
          existing_sub_data = Keyword.get(opts, :subscription_data, %{}) |> Enum.into(%{})
          sub_metadata = Map.get(existing_sub_data, :metadata, %{}) |> Map.merge(metadata)
          sub_data = Map.put(existing_sub_data, :metadata, sub_metadata)
          Map.put(p, :subscription_data, sub_data)
        else
          p
        end
      end)

    provider.create_checkout_session(params, opts)
  end

  @doc """
  Creates a billing portal session for a customer to manage subscriptions and payment methods.

  ## Options

    * `:return_url` - The URL to return to after leaving the portal (required).
    * `:provider` - The billing provider module.
  """
  @spec create_portal_session(struct() | String.t(), keyword()) ::
          {:ok, %{url: String.t()}} | {:error, term()}
  def create_portal_session(record_or_customer_id, opts) do
    cust_id = resolve_customer_id(record_or_customer_id)
    provider = resolve_provider(record_or_customer_id, opts)

    params = %{
      customer: cust_id,
      return_url: Keyword.fetch!(opts, :return_url)
    }

    provider.create_portal_session(params, opts)
  end

  @doc """
  Retrieves a subscription from the billing provider.
  """
  @spec get_subscription(struct() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_subscription(subscription_or_id, opts \\ []) do
    sub_id = resolve_subscription_id(subscription_or_id)
    provider = Keyword.get(opts, :provider, Stripe)
    provider.get_subscription(sub_id, opts)
  end

  @doc """
  Cancels a subscription.

  ## Options

    * `:at_period_end` - If `true` (default), cancels at the end of the current billing cycle.
    * `:provider` - The billing provider module.
  """
  @spec cancel_subscription(struct() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def cancel_subscription(subscription_or_id, opts \\ []) do
    sub_id = resolve_subscription_id(subscription_or_id)
    provider = Keyword.get(opts, :provider, Stripe)
    provider.cancel_subscription(sub_id, opts)
  end

  @doc """
  Checks if a record has an active subscription.

  Checks loaded subscriptions associated with the record for `:active` or `:trialing` status.
  If a `price_id` is passed as the second argument, verifies that the subscription matches the price.
  """
  @spec subscribed?(struct(), String.t() | nil) :: boolean()
  def subscribed?(record, price_id \\ nil)

  def subscribed?(%{subscriptions: subscriptions}, price_id) when is_list(subscriptions) do
    Enum.any?(subscriptions, fn sub ->
      active_status?(sub.status) and (is_nil(price_id) or sub.price_id == price_id)
    end)
  end

  def subscribed?(_record, _price_id), do: false

  defp active_status?(status) when status in [:active, "active", :trialing, "trialing"], do: true
  defp active_status?(_), do: false

  defp resolve_customer_id(%_resource{} = record), do: customer_id(record)
  defp resolve_customer_id(id) when is_binary(id), do: id

  defp resolve_subscription_id(%{provider_subscription_id: id}) when is_binary(id), do: id
  defp resolve_subscription_id(%{stripe_subscription_id: id}) when is_binary(id), do: id
  defp resolve_subscription_id(%{id: id}) when is_binary(id), do: id
  defp resolve_subscription_id(id) when is_binary(id), do: id

  defp resolve_provider(%resource{}, opts),
    do: Keyword.get(opts, :provider, ResourceInfo.provider(resource))

  defp resolve_provider(_id, opts), do: Keyword.get(opts, :provider, Stripe)

  defp remove_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
