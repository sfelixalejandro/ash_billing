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
    * `:authorize?` - Whether to perform authorization checks. Defaults to `false` so webhooks run without requiring an active actor.
    * `:actor` - Optional system actor to run actions on behalf of.
    * `:tenant` - Optional tenant identifier for multitenant deployments.
  """
  def sync_event(event, opts) do
    event_type = Map.get(event, "type")
    event_id = Map.get(event, "id")
    domain = Keyword.get(opts, :domain)
    customer_resource = Keyword.get(opts, :customer_resource) || Keyword.get(opts, :resource)
    subscription_resource = Keyword.get(opts, :subscription_resource)

    Logger.debug("AshBilling.WebhookSync: Processing event #{inspect(event_type)}")

    start_meta = %{
      event_type: event_type,
      event_id: event_id,
      customer_resource: customer_resource,
      subscription_resource: subscription_resource
    }

    event_opts =
      opts
      |> Keyword.put(:event, event)
      |> Keyword.put(:event_created, Map.get(event, "created"))
      |> Keyword.put(:event_type, event_type)

    :telemetry.span([:ash_billing, :sync], start_meta, fn ->
      result =
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
              event_opts
            )

          "checkout.session.completed" ->
            sync_checkout_session(event["data"]["object"], customer_resource, domain, event_opts)

          "customer.deleted" ->
            sync_customer_deleted(
              event["data"]["object"],
              customer_resource,
              subscription_resource,
              domain,
              event_opts
            )

          _ ->
            {:ok, :ignored}
        end

      case result do
        {:ok, record} when is_struct(record) ->
          {result, %{status: :ok, record: record}}

        {:ok, status} ->
          {result, %{status: status}}

        {:error, reason} ->
          {result, %{status: :error, error: reason}}
      end
    end)
  end

  defp sync_subscription(nil, _cust_res, _sub_res, _domain, _opts), do: {:ok, :ignored}

  defp sync_subscription(object, customer_resource, subscription_resource, domain, opts) do
    if is_nil(subscription_resource) do
      {:ok, :no_subscription_resource}
    else
      sub_id = object["id"]
      stripe_cust_id = extract_customer_id(object)
      status = normalize_status(object["status"])
      price_id = extract_price_id(object)
      current_period_end = extract_current_period_end(object)
      trial_ends_at = extract_trial_ends_at(object)
      cancel_at_period_end = Map.get(object, "cancel_at_period_end", false)
      event_created = Keyword.get(opts, :event_created)

      event_dt =
        case event_created do
          ts when is_integer(ts) ->
            case DateTime.from_unix(ts) do
              {:ok, dt} -> dt
              _ -> nil
            end

          %DateTime{} = dt ->
            dt

          _ ->
            nil
        end

      ash_opts = ash_options(domain, opts)

      with {:ok, customer} <- find_customer(customer_resource, stripe_cust_id, object, ash_opts),
           {:ok, existing} <- fetch_existing_subscription(subscription_resource, sub_id, ash_opts) do
        attrs =
          %{
            provider_subscription_id: sub_id,
            status: status,
            price_id: price_id,
            current_period_end: current_period_end,
            cancel_at_period_end: cancel_at_period_end
          }
          |> then(fn a ->
            if Ash.Resource.Info.attribute(subscription_resource, :trial_ends_at) != nil do
              Map.put(a, :trial_ends_at, trial_ends_at)
            else
              a
            end
          end)
          |> then(fn a ->
            if Ash.Resource.Info.attribute(subscription_resource, :last_event_created_at) != nil and
                 not is_nil(event_dt) do
              Map.put(a, :last_event_created_at, event_dt)
            else
              a
            end
          end)

        cond do
          # Out-of-order event protection:
          # Terminal states in Stripe (canceled, incomplete_expired) can never legitimately
          # transition back to active/past_due. If a delayed webhook arrives out of order, ignore it.
          existing && terminal_status?(existing.status) && !terminal_status?(status) ->
            require Logger

            Logger.warning(
              "AshBilling.WebhookSync: Ignored out-of-order event for terminated subscription #{inspect(sub_id)}. DB status: #{inspect(existing.status)}, Incoming status: #{inspect(status)}"
            )

            {:ok, existing}

          # Out-of-order timestamp check:
          # If recorded subscription has a newer event timestamp than the incoming event, ignore it.
          existing && existing_event_newer?(existing, event_dt) ->
            require Logger

            Logger.warning(
              "AshBilling.WebhookSync: Ignored older out-of-order event for subscription #{inspect(sub_id)}. Recorded event timestamp (#{inspect(existing.last_event_created_at)}) is newer than incoming event (#{inspect(event_dt)})."
            )

            {:ok, existing}

          # Conflicting status transition protection:
          # If transitioning backwards from :past_due / :unpaid to :active, reconcile with provider.
          existing && conflicting_status_transition?(existing.status, status) ->
            reconcile_subscription_with_provider(
              subscription_resource,
              existing,
              sub_id,
              attrs,
              event_dt,
              opts,
              ash_opts
            )

          # Same-second conflicting event protection:
          # If two distinct events arrive with the exact same second timestamp and conflicting state,
          # reconcile with provider to establish authoritative ground truth.
          existing && same_second_conflict?(existing, event_dt, attrs) ->
            reconcile_subscription_with_provider(
              subscription_resource,
              existing,
              sub_id,
              attrs,
              event_dt,
              opts,
              ash_opts
            )

          existing ->
            update_subscription_safely(
              subscription_resource,
              existing,
              attrs,
              event_dt,
              ash_opts
            )

          true ->
            cust_rel_name = SubscriptionInfo.customer_relationship(subscription_resource)
            rel_attr = find_relationship_source_attribute(subscription_resource, cust_rel_name)

            attrs =
              if customer && rel_attr do
                Map.put(attrs, rel_attr, customer.id)
              else
                attrs
              end

            case Ash.create(subscription_resource, attrs, ash_opts) do
              {:ok, created} ->
                {:ok, created}

              {:error, error} ->
                # Concurrency race resolution:
                # If another concurrent process just inserted this provider_subscription_id,
                # retry as an update to guarantee idempotency across nodes.
                case fetch_existing_subscription(subscription_resource, sub_id, ash_opts) do
                  {:ok, newly_created} when not is_nil(newly_created) ->
                    update_subscription_safely(
                      subscription_resource,
                      newly_created,
                      attrs,
                      event_dt,
                      ash_opts
                    )

                  _ ->
                    {:error, error}
                end
            end
        end
      end
    end
  end

  defp sync_checkout_session(session, customer_resource, domain, opts) do
    if is_nil(customer_resource) do
      {:ok, :no_customer_resource}
    else
      ash_opts = ash_options(domain, opts)
      stripe_customer_id = extract_customer_id(session)

      resource_id =
        get_in(session, ["metadata", "resource_id"]) ||
          session["client_reference_id"]

      email =
        session["customer_email"] ||
          get_in(session, ["customer_details", "email"])

      customer_result =
        cond do
          stripe_customer_id && resource_id ->
            Ash.get(customer_resource, resource_id, ash_opts)

          stripe_customer_id && email && Ash.Resource.Info.attribute(customer_resource, :email) ->
            customer_resource
            |> Ash.Query.new()
            |> Ash.Query.filter(email == ^email)
            |> Ash.read_one(ash_opts)

          true ->
            {:ok, nil}
        end

      case customer_result do
        {:ok, user} when not is_nil(user) ->
          attr = ResourceInfo.customer_id_attribute(customer_resource)

          if is_nil(Map.get(user, attr)) do
            Ash.update(user, %{attr => stripe_customer_id}, ash_opts)
          else
            {:ok, user}
          end

        {:ok, nil} ->
          {:ok, :ignored}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp sync_customer_deleted(nil, _cust_res, _sub_res, _domain, _opts), do: {:ok, :ignored}

  defp sync_customer_deleted(object, customer_resource, _subscription_resource, domain, opts) do
    if is_nil(customer_resource) do
      {:ok, :no_customer_resource}
    else
      ash_opts = ash_options(domain, opts)
      stripe_cust_id = extract_customer_id(object)

      if stripe_cust_id do
        attr = ResourceInfo.customer_id_attribute(customer_resource)

        customer_resource
        |> Ash.Query.new()
        |> Ash.Query.filter(^[{attr, stripe_cust_id}])
        |> Ash.read_one(ash_opts)
        |> case do
          {:ok, cust} when not is_nil(cust) ->
            Ash.update(cust, %{attr => nil}, ash_opts)

          {:ok, nil} ->
            {:ok, :not_found}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:ok, :ignored}
      end
    end
  end

  defp reconcile_subscription_with_provider(
         subscription_resource,
         existing,
         sub_id,
         attrs,
         event_dt,
         opts,
         ash_opts
       ) do
    provider = Keyword.get(opts, :provider, AshBilling.Providers.Stripe)

    case provider.get_subscription(sub_id, opts) do
      {:ok, live_sub} when is_map(live_sub) ->
        live_status = normalize_status(live_sub["status"])
        live_price_id = extract_price_id(live_sub)
        live_current_period_end = extract_current_period_end(live_sub)
        live_trial_ends_at = extract_trial_ends_at(live_sub)
        live_cancel_at_period_end = Map.get(live_sub, "cancel_at_period_end", false)

        require Logger

        Logger.info(
          "AshBilling.WebhookSync: Reconciled subscription #{inspect(sub_id)} with provider. Authoritative live status: #{inspect(live_status)}"
        )

        reconciled_attrs =
          attrs
          |> Map.put(:status, live_status)
          |> Map.put(:price_id, live_price_id)
          |> Map.put(:current_period_end, live_current_period_end)
          |> Map.put(:cancel_at_period_end, live_cancel_at_period_end)
          |> then(fn a ->
            if Ash.Resource.Info.attribute(subscription_resource, :trial_ends_at) != nil do
              Map.put(a, :trial_ends_at, live_trial_ends_at)
            else
              a
            end
          end)

        update_subscription_safely(
          subscription_resource,
          existing,
          reconciled_attrs,
          event_dt,
          ash_opts
        )

      {:error, reconcile_reason} ->
        require Logger

        Logger.error(
          "AshBilling.WebhookSync: Failed to reconcile subscription #{inspect(sub_id)} with provider: #{inspect(reconcile_reason)}. Aborting sync to trigger retry."
        )

        {:error, {:reconciliation_failed, reconcile_reason}}

      _ ->
        require Logger

        Logger.error(
          "AshBilling.WebhookSync: Unexpected response while reconciling subscription #{inspect(sub_id)} with provider. Aborting sync to trigger retry."
        )

        {:error, :reconciliation_failed}
    end
  end

  defp fetch_existing_subscription(subscription_resource, sub_id, ash_opts) do
    subscription_resource
    |> Ash.Query.new()
    |> Ash.Query.filter(provider_subscription_id == ^sub_id)
    |> Ash.read_one(ash_opts)
  end

  @doc false
  def update_subscription_safely(subscription_resource, existing, attrs, event_dt, ash_opts) do
    has_timestamp? =
      Ash.Resource.Info.attribute(subscription_resource, :last_event_created_at) != nil

    has_update? = Ash.Resource.Info.action(subscription_resource, :update) != nil

    if has_timestamp? and has_update? and not is_nil(event_dt) do
      require Ash.Query

      # Atomic condition: only update if record currently has NULL timestamp
      # or a timestamp less than or equal to incoming event_dt
      query =
        subscription_resource
        |> Ash.Query.filter(
          id == ^existing.id and
            (is_nil(last_event_created_at) or last_event_created_at <= ^event_dt)
        )

      bulk_opts =
        ash_opts
        |> Keyword.put(:strategy, [:atomic])
        |> Keyword.put(:return_records?, true)
        |> Keyword.put(:return_errors?, true)

      case Ash.bulk_update(query, :update, attrs, bulk_opts) do
        %Ash.BulkResult{status: :success, records: [updated | _]} ->
          {:ok, updated}

        %Ash.BulkResult{status: :success, records: []} ->
          require Logger

          Logger.warning(
            "AshBilling.WebhookSync: Atomic conditional update matched 0 records for subscription #{inspect(existing.provider_subscription_id)}. A newer event was already applied. Discarding out-of-order write."
          )

          case fetch_existing_subscription(
                 subscription_resource,
                 existing.provider_subscription_id,
                 ash_opts
               ) do
            {:ok, latest} when not is_nil(latest) -> {:ok, latest}
            _ -> {:ok, existing}
          end

        %Ash.BulkResult{errors: [err | _]} ->
          require Logger

          Logger.error(
            "AshBilling.WebhookSync: Atomic conditional update failed for subscription #{inspect(existing.provider_subscription_id)}: #{inspect(err)}. Aborting sync to trigger retry."
          )

          {:error, err}

        {:error, reason} ->
          require Logger

          Logger.error(
            "AshBilling.WebhookSync: Atomic conditional update failed for subscription #{inspect(existing.provider_subscription_id)}: #{inspect(reason)}. Aborting sync to trigger retry."
          )

          {:error, reason}

        other_error ->
          require Logger

          Logger.error(
            "AshBilling.WebhookSync: Atomic conditional update failed for subscription #{inspect(existing.provider_subscription_id)}: #{inspect(other_error)}. Aborting sync to trigger retry."
          )

          {:error, other_error}
      end
    else
      Ash.update(existing, attrs, ash_opts)
    end
  end

  defp find_customer(nil, _stripe_cust_id, _object, _ash_opts), do: {:ok, nil}

  defp find_customer(customer_resource, stripe_cust_id, object, ash_opts) do
    attr = ResourceInfo.customer_id_attribute(customer_resource)

    lookup_result =
      if stripe_cust_id do
        customer_resource
        |> Ash.Query.new()
        |> Ash.Query.filter(^[{attr, stripe_cust_id}])
        |> Ash.read_one(ash_opts)
      else
        {:ok, nil}
      end

    case lookup_result do
      {:ok, cust} when not is_nil(cust) ->
        {:ok, cust}

      {:error, reason} ->
        {:error, reason}

      {:ok, nil} ->
        resource_id =
          get_in(object, ["metadata", "resource_id"]) ||
            object["client_reference_id"]

        if resource_id do
          case Ash.get(customer_resource, resource_id, ash_opts) do
            {:ok, cust} ->
              if stripe_cust_id && is_nil(Map.get(cust, attr)) do
                case Ash.update(cust, %{attr => stripe_cust_id}, ash_opts) do
                  {:ok, updated} -> {:ok, updated}
                  {:error, reason} -> {:error, reason}
                end
              else
                {:ok, cust}
              end

            {:error, reason} ->
              if not_found_error?(reason) do
                find_customer_by_email(customer_resource, object, ash_opts)
              else
                {:error, reason}
              end
          end
        else
          find_customer_by_email(customer_resource, object, ash_opts)
        end
    end
  end

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &not_found_error?/1)
  end

  defp not_found_error?(error) do
    error_str = inspect(error)
    String.contains?(error_str, "NotFound") or String.contains?(error_str, "not found")
  end

  defp find_customer_by_email(customer_resource, object, ash_opts) do
    email = object["customer_email"] || get_in(object, ["customer_details", "email"])

    if email && Ash.Resource.Info.attribute(customer_resource, :email) do
      customer_resource
      |> Ash.Query.new()
      |> Ash.Query.filter(email == ^email)
      |> Ash.read_one(ash_opts)
    else
      {:ok, nil}
    end
  end

  defp extract_current_period_end(object) do
    ts =
      cond do
        is_integer(object["current_period_end"]) ->
          object["current_period_end"]

        is_binary(object["current_period_end"]) ->
          object["current_period_end"]

        # Stripe modern API 2025-03-31.basil+ item-level period
        is_list(get_in(object, ["items", "data"])) ->
          Enum.find_value(object["items"]["data"], fn item ->
            item["current_period_end"]
          end)

        true ->
          nil
      end

    parse_unix_timestamp(ts)
  end

  defp extract_trial_ends_at(object) do
    ts =
      object["trial_end"] ||
        get_in(object, ["trial_settings", "end"]) ||
        get_in(object, ["items", "data", Access.at(0), "trial_end"])

    parse_unix_timestamp(ts)
  end

  defp terminal_status?(status)
       when status in [:canceled, "canceled", :incomplete_expired, "incomplete_expired"],
       do: true

  defp terminal_status?(_), do: false

  defp existing_event_newer?(existing, incoming_dt) do
    case {Map.get(existing, :last_event_created_at), incoming_dt} do
      {%DateTime{} = existing_dt, %DateTime{} = in_dt} ->
        DateTime.compare(in_dt, existing_dt) == :lt

      _ ->
        false
    end
  end

  defp conflicting_status_transition?(current_status, new_status) do
    current_status in [:past_due, "past_due", :unpaid, "unpaid"] and
      new_status in [:active, "active", :trialing, "trialing"]
  end

  defp same_second_conflict?(existing, incoming_dt, attrs) do
    case {Map.get(existing, :last_event_created_at), incoming_dt} do
      {%DateTime{} = recorded_dt, %DateTime{} = inc_dt} ->
        if DateTime.compare(recorded_dt, inc_dt) == :eq do
          status_diff? =
            attrs[:status] != nil and to_string(existing.status) != to_string(attrs[:status])

          price_diff? =
            attrs[:price_id] != nil and
              existing.price_id != nil and
              to_string(existing.price_id) != to_string(attrs[:price_id])

          cancel_diff? =
            attrs[:cancel_at_period_end] != nil and
              Map.get(existing, :cancel_at_period_end) != nil and
              existing.cancel_at_period_end != attrs[:cancel_at_period_end]

          status_diff? or price_diff? or cancel_diff?
        else
          false
        end

      _ ->
        false
    end
  end

  defp ash_options(domain, opts) do
    base = [domain: domain, authorize?: Keyword.get(opts, :authorize?, false)]

    Enum.reduce([:actor, :tenant], base, fn key, acc ->
      if Keyword.has_key?(opts, key) do
        Keyword.put(acc, key, Keyword.get(opts, key))
      else
        acc
      end
    end)
  end

  defp find_relationship_source_attribute(subscription_resource, cust_rel_name) do
    case Ash.Resource.Info.relationship(subscription_resource, cust_rel_name) do
      %{source_attribute: source_attr} -> source_attr
      _ -> :user_id
    end
  end

  defp extract_customer_id(%{"customer" => %{"id" => id}}) when is_binary(id), do: id
  defp extract_customer_id(%{"customer" => id}) when is_binary(id), do: id
  defp extract_customer_id(%{"id" => id}) when is_binary(id), do: id
  defp extract_customer_id(id) when is_binary(id), do: id
  defp extract_customer_id(_), do: nil

  defp extract_price_id(%{"items" => %{"data" => [%{"price" => %{"id" => id}} | _]}})
       when is_binary(id),
       do: id

  defp extract_price_id(%{"items" => %{"data" => [%{"plan" => %{"id" => id}} | _]}})
       when is_binary(id),
       do: id

  defp extract_price_id(%{"items" => %{"data" => [%{"price" => id} | _]}})
       when is_binary(id),
       do: id

  defp extract_price_id(%{"plan" => %{"id" => id}}) when is_binary(id), do: id
  defp extract_price_id(%{"plan" => id}) when is_binary(id), do: id
  defp extract_price_id(%{"price" => %{"id" => id}}) when is_binary(id), do: id
  defp extract_price_id(%{"price" => id}) when is_binary(id), do: id
  defp extract_price_id(_), do: nil

  defp parse_unix_timestamp(ts) when is_integer(ts) do
    case DateTime.from_unix(ts, :second) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp parse_unix_timestamp(_), do: nil

  defp normalize_status("active"), do: :active
  defp normalize_status("trialing"), do: :trialing
  defp normalize_status("past_due"), do: :past_due
  defp normalize_status("canceled"), do: :canceled
  defp normalize_status("unpaid"), do: :unpaid
  defp normalize_status("incomplete"), do: :incomplete
  defp normalize_status("incomplete_expired"), do: :incomplete_expired
  defp normalize_status("paused"), do: :paused
  defp normalize_status(:paused), do: :paused
  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status(_), do: :incomplete
end
