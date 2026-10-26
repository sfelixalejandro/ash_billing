defmodule AshBilling.WebhookSync do
  @moduledoc """
  Synchronizes incoming billing webhook events with Ash resources.
  """

  require Ash.Query
  require Logger

  alias AshBilling.Resource.Info, as: ResourceInfo
  alias AshBilling.Subscription.Info, as: SubscriptionInfo

  @doc """
  Processes a verified billing webhook event and synchronizes database state.

  ## Options

    * `:customer_resource` - The Ash resource for customers (e.g., `MyApp.Accounts.User`).
    * `:subscription_resource` - The Ash resource for subscriptions (e.g., `MyApp.Billing.Subscription`).
    * `:domain` - The Ash domain module to execute actions with.
  """
  def sync_event(event, opts) do
    event_type = Map.get(event, "type")
    domain = Keyword.get(opts, :domain)
    customer_resource = Keyword.get(opts, :customer_resource)
    subscription_resource = Keyword.get(opts, :subscription_resource)

    Logger.debug("AshBilling.WebhookSync: Processing event #{inspect(event_type)}")

    case event_type do
      type
      when type in [
             "customer.subscription.created",
             "customer.subscription.updated",
             "customer.subscription.deleted"
           ] ->
        sync_subscription(
          event["data"]["object"],
          customer_resource,
          subscription_resource,
          domain,
          opts
        )

      "checkout.session.completed" ->
        sync_checkout_session(event["data"]["object"], customer_resource, domain, opts)

      _ ->
        {:ok, :ignored}
    end
  end

  defp sync_subscription(nil, _cust_res, _sub_res, _domain, _opts), do: {:ok, :ignored}

  defp sync_subscription(object, customer_resource, subscription_resource, domain, opts) do
    if is_nil(subscription_resource) do
      {:ok, :no_subscription_resource}
    else
      sub_id = object["id"]
      stripe_cust_id = object["customer"]
      status = normalize_status(object["status"])
      price_id = extract_price_id(object)
      current_period_end = parse_unix_timestamp(object["current_period_end"])
      cancel_at_period_end = Map.get(object, "cancel_at_period_end", false)

      customer = find_customer(customer_resource, stripe_cust_id, object, domain, opts)

      existing =
        subscription_resource
        |> Ash.Query.new()
        |> Ash.Query.filter(provider_subscription_id == ^sub_id)
        |> Ash.read_one(domain: domain, authorize?: false)
        |> case do
          {:ok, record} -> record
          _ -> nil
        end

      attrs = %{
        provider_subscription_id: sub_id,
        status: status,
        price_id: price_id,
        current_period_end: current_period_end,
        cancel_at_period_end: cancel_at_period_end
      }

      if existing do
        Ash.update(existing, attrs, domain: domain, authorize?: false)
      else
        cust_rel_name = SubscriptionInfo.customer_relationship(subscription_resource)
        rel_attr = find_relationship_source_attribute(subscription_resource, cust_rel_name)

        attrs =
          if customer && rel_attr do
            Map.put(attrs, rel_attr, customer.id)
          else
            attrs
          end

        Ash.create(subscription_resource, attrs, domain: domain, authorize?: false)
      end
    end
  end

  defp sync_checkout_session(session, customer_resource, domain, _opts) do
    if is_nil(customer_resource) do
      {:ok, :no_customer_resource}
    else
      stripe_customer_id = session["customer"]

      resource_id =
        get_in(session, ["metadata", "resource_id"]) ||
          session["client_reference_id"]

      if stripe_customer_id && resource_id do
        attr = ResourceInfo.customer_id_attribute(customer_resource)

        case Ash.get(customer_resource, resource_id, domain: domain, authorize?: false) do
          {:ok, user} ->
            if is_nil(Map.get(user, attr)) do
              Ash.update(user, %{attr => stripe_customer_id}, domain: domain, authorize?: false)
            else
              {:ok, user}
            end

          error ->
            error
        end
      else
        {:ok, :ignored}
      end
    end
  end

  defp find_customer(nil, _stripe_cust_id, _object, _domain, _opts), do: nil

  defp find_customer(customer_resource, stripe_cust_id, object, domain, _opts) do
    attr = ResourceInfo.customer_id_attribute(customer_resource)

    customer_by_stripe_id =
      if stripe_cust_id do
        customer_resource
        |> Ash.Query.new()
        |> Ash.Query.filter(^[{attr, stripe_cust_id}])
        |> Ash.read_one(domain: domain, authorize?: false)
        |> case do
          {:ok, cust} -> cust
          _ -> nil
        end
      end

    if customer_by_stripe_id do
      customer_by_stripe_id
    else
      resource_id =
        get_in(object, ["metadata", "resource_id"]) ||
          object["client_reference_id"]

      if resource_id do
        case Ash.get(customer_resource, resource_id, domain: domain, authorize?: false) do
          {:ok, cust} ->
            if stripe_cust_id && is_nil(Map.get(cust, attr)) do
              case Ash.update(cust, %{attr => stripe_cust_id},
                     domain: domain,
                     authorize?: false
                   ) do
                {:ok, updated} -> updated
                _ -> cust
              end
            else
              cust
            end

          _ ->
            nil
        end
      end
    end
  end

  defp find_relationship_source_attribute(subscription_resource, cust_rel_name) do
    case Ash.Resource.Info.relationship(subscription_resource, cust_rel_name) do
      %{source_attribute: source_attr} -> source_attr
      _ -> :user_id
    end
  end

  defp extract_price_id(%{
         "items" => %{"data" => [%{"price" => %{"id" => price_id}} | _]}
       }),
       do: price_id

  defp extract_price_id(%{"plan" => %{"id" => plan_id}}), do: plan_id
  defp extract_price_id(_), do: nil

  defp parse_unix_timestamp(nil), do: nil
  defp parse_unix_timestamp(ts) when is_integer(ts), do: DateTime.from_unix!(ts, :second)
  defp parse_unix_timestamp(_), do: nil

  defp normalize_status("active"), do: :active
  defp normalize_status("trialing"), do: :trialing
  defp normalize_status("past_due"), do: :past_due
  defp normalize_status("canceled"), do: :canceled
  defp normalize_status("unpaid"), do: :unpaid
  defp normalize_status("incomplete"), do: :incomplete
  defp normalize_status("incomplete_expired"), do: :incomplete_expired
  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status(_), do: :incomplete
end
