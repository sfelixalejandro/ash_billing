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
        AshBilling.ResourceLock.run(
          [customer_resource, subscription_resource],
          {customer_resource || subscription_resource, Keyword.get(opts, :tenant)},
          fn ->
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
                sync_checkout_session(
                  event["data"]["object"],
                  customer_resource,
                  domain,
                  event_opts
                )

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
          end
        )

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

  defp sync_subscription(
         object,
         customer_resource,
         subscription_resource,
         domain,
         opts,
         retry_create? \\ true
       )

  defp sync_subscription(nil, _cust_res, _sub_res, _domain, _opts, _retry), do: {:ok, :ignored}

  defp sync_subscription(
         object,
         customer_resource,
         subscription_resource,
         domain,
         opts,
         retry_create?
       ) do
    if is_nil(subscription_resource) do
      {:ok, :no_subscription_resource}
    else
      sub_id = object["id"]
      stripe_cust_id = extract_customer_id(Map.take(object, ["customer"]))
      status = normalize_status(object["status"])
      price_id = extract_price_id(object)
      current_period_end = extract_current_period_end(object)
      trial_ends_at = extract_trial_ends_at(object)
      cancel_at_period_end = Map.get(object, "cancel_at_period_end", false)
      cancel_at = extract_cancel_at(object)
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
           {:ok, existing} <-
             fetch_existing_subscription(subscription_resource, sub_id, ash_opts),
           :ok <- validate_subscription_customer(existing, customer, subscription_resource) do
        attrs =
          %{
            provider_subscription_id: sub_id,
            status: status,
            price_id: price_id,
            current_period_end: current_period_end,
            cancel_at_period_end: cancel_at_period_end
          }
          |> then(fn a ->
            if Ash.Resource.Info.attribute(subscription_resource, :cancel_at) != nil do
              Map.put(a, :cancel_at, cancel_at)
            else
              a
            end
          end)
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
          customer && Map.get(customer, :billing_deleted_at) && not terminal_status?(status) ->
            {:ok, :customer_deleted}

          # Out-of-order event protection:
          # Terminal states in Stripe (canceled, incomplete_expired) can never legitimately
          # transition back to active/past_due. If a delayed webhook arrives out of order, ignore it.
          existing && terminal_status?(existing.status) && !terminal_status?(status) &&
              Keyword.get(opts, :provider, SubscriptionInfo.provider(subscription_resource)) ==
                AshBilling.Providers.Stripe ->
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

          # A terminal notification must not be replaced by a same-second live snapshot.
          existing && terminal_status?(status) ->
            update_subscription_safely(subscription_resource, existing, attrs, event_dt, ash_opts)

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

            case AshBilling.Transformers.ProtectBillingAttributes.create(
                   subscription_resource,
                   attrs,
                   ash_opts
                 ) do
              {:ok, created} ->
                {:ok, created}

              {:error, error} ->
                # Only a real identity conflict is retried. Re-read through the normal
                # lifecycle and ownership guards; never update blindly after a failed create.
                if retry_create? and subscription_identity_conflict?(error) do
                  sync_subscription(
                    object,
                    customer_resource,
                    subscription_resource,
                    domain,
                    opts,
                    false
                  )
                else
                  {:error, error}
                end
            end
        end
      end
    end
  end

  defp subscription_identity_conflict?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &subscription_identity_conflict?/1)

  defp subscription_identity_conflict?(%Ash.Error.Changes.InvalidAttribute{
         field: :provider_subscription_id,
         private_vars: vars
       })
       when is_list(vars),
       do: Keyword.get(vars, :constraint_type) == :unique

  defp subscription_identity_conflict?(_), do: false

  defp sync_checkout_session(session, customer_resource, domain, opts) do
    if is_nil(customer_resource) do
      {:ok, :no_customer_resource}
    else
      ash_opts = ash_options(domain, opts)
      stripe_customer_id = extract_customer_id(Map.take(session, ["customer"]))

      if stripe_customer_id do
        find_customer(customer_resource, stripe_customer_id, session, ash_opts)
      else
        {:ok, :ignored}
      end
    end
  end

  defp sync_customer_deleted(nil, _cust_res, _sub_res, _domain, _opts), do: {:ok, :ignored}

  defp sync_customer_deleted(object, customer_resource, subscription_resource, domain, opts) do
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
        |> AshBilling.ResourceLock.query()
        |> Ash.read_one(ash_opts)
        |> case do
          {:ok, cust} when not is_nil(cust) ->
            with {:ok, deleted} <- mark_customer_deleted(cust, stripe_cust_id, attr, ash_opts),
                 :ok <- revoke_customer_subscriptions(deleted, subscription_resource, ash_opts) do
              {:ok, deleted}
            end

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

  defp mark_customer_deleted(%resource{} = customer, customer_id, attr, ash_opts) do
    AshBilling.ResourceLock.run([resource], {resource, Keyword.get(ash_opts, :tenant)}, fn ->
      do_mark_customer_deleted(customer, customer_id, attr, ash_opts)
    end)
  end

  defp do_mark_customer_deleted(%resource{} = customer, customer_id, attr, ash_opts) do
    action = primary_update_action(resource)
    query = Ash.Query.filter(resource, id == ^customer.id)
    query = Ash.Query.filter(query, ^[{attr, customer_id}])

    if action do
      case Ash.bulk_update(
             query,
             action.name,
             %{},
             Keyword.merge(ash_opts,
               atomic_update: %{
                 billing_deleted_at: Map.get(customer, :billing_deleted_at) || DateTime.utc_now()
               },
               strategy: [:atomic],
               return_records?: true,
               return_errors?: true
             )
           ) do
        %Ash.BulkResult{status: :success, records: [deleted]} -> {:ok, deleted}
        %Ash.BulkResult{status: :success, records: []} -> {:error, :customer_identity_conflict}
        %Ash.BulkResult{errors: [error | _]} -> {:error, error}
        other -> {:error, other}
      end
    else
      {:error, :update_action_required}
    end
  end

  defp revoke_customer_subscriptions(_customer, nil, _ash_opts), do: :ok

  defp revoke_customer_subscriptions(customer, resource, ash_opts) do
    attr =
      find_relationship_source_attribute(
        resource,
        SubscriptionInfo.customer_relationship(resource)
      )

    query = Ash.Query.filter(resource, ^[{attr, customer.id}]) |> AshBilling.ResourceLock.query()

    with {:ok, subscriptions} <- Ash.read(query, ash_opts) do
      Enum.reduce_while(subscriptions, :ok, fn subscription, :ok ->
        if terminal_status?(subscription.status) do
          {:cont, :ok}
        else
          case update_subscription_safely(
                 resource,
                 subscription,
                 %{status: :canceled},
                 nil,
                 ash_opts
               ) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
      end)
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
    provider = Keyword.get(opts, :provider, SubscriptionInfo.provider(subscription_resource))

    case provider.get_subscription(sub_id, opts) do
      {:ok, live_sub} when is_map(live_sub) ->
        live_status = normalize_status(live_sub["status"])
        live_price_id = extract_price_id(live_sub)
        live_current_period_end = extract_current_period_end(live_sub)
        live_trial_ends_at = extract_trial_ends_at(live_sub)
        live_cancel_at_period_end = Map.get(live_sub, "cancel_at_period_end", false)
        live_cancel_at = extract_cancel_at(live_sub)

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
            if Ash.Resource.Info.attribute(subscription_resource, :cancel_at) != nil do
              Map.put(a, :cancel_at, live_cancel_at)
            else
              a
            end
          end)
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
    |> AshBilling.ResourceLock.query()
    |> Ash.read_one(ash_opts)
  end

  @doc false
  def update_subscription_safely(subscription_resource, existing, attrs, event_dt, ash_opts) do
    has_timestamp? =
      Ash.Resource.Info.attribute(subscription_resource, :last_event_created_at) != nil

    update_action = primary_update_action(subscription_resource)

    if update_action do
      require Ash.Query

      # Compare at commit time, including when the provider request was in flight.
      # Nonterminal writes may only replace the status that this worker actually read.
      # This still permits an intentional transition from an already-read terminal state
      # for providers whose lifecycle supports it; Stripe rejects those earlier.
      query = Ash.Query.filter(subscription_resource, id == ^existing.id)

      query =
        if has_timestamp? and not is_nil(event_dt) do
          Ash.Query.filter(
            query,
            is_nil(last_event_created_at) or last_event_created_at <= ^event_dt
          )
        else
          query
        end

      query =
        if terminal_status?(attrs[:status]) do
          query
        else
          Enum.reduce(
            [
              :status,
              :price_id,
              :trial_ends_at,
              :current_period_end,
              :cancel_at_period_end,
              :cancel_at,
              :last_event_created_at
            ],
            query,
            fn field, query ->
              if Ash.Resource.Info.attribute(subscription_resource, field) do
                case Map.get(existing, field) do
                  nil -> Ash.Query.filter(query, ^[{field, [is_nil: true]}])
                  value -> Ash.Query.filter(query, ^[{field, value}])
                end
              else
                query
              end
            end
          )
        end

      bulk_opts =
        ash_opts
        |> Keyword.put(:strategy, [:atomic])
        |> Keyword.put(:return_records?, true)
        |> Keyword.put(:return_errors?, true)

      case Ash.bulk_update(
             query,
             update_action.name,
             %{},
             Keyword.put(bulk_opts, :atomic_update, attrs)
           ) do
        %Ash.BulkResult{status: :success, records: [updated | _]} ->
          {:ok, updated}

        %Ash.BulkResult{status: :success, records: []} ->
          require Logger

          Logger.warning(
            "AshBilling.WebhookSync: Atomic conditional update matched 0 records for subscription #{inspect(existing.provider_subscription_id)}. The subscription changed concurrently or a newer event was applied."
          )

          case fetch_existing_subscription(
                 subscription_resource,
                 existing.provider_subscription_id,
                 ash_opts
               ) do
            {:ok, latest} when not is_nil(latest) ->
              if terminal_status?(latest.status) or existing_event_newer?(latest, event_dt) do
                {:ok, latest}
              else
                {:error, :subscription_changed_concurrently}
              end

            {:error, reason} ->
              {:error, reason}

            _ ->
              {:error, :subscription_not_found}
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
      {:error, :update_action_required}
    end
  end

  defp primary_update_action(resource) do
    Ash.Resource.Info.primary_action(resource, :update) ||
      Ash.Resource.Info.action(resource, :update)
  end

  defp find_customer(nil, _stripe_cust_id, _object, _ash_opts), do: {:ok, nil}

  defp find_customer(_resource, nil, _object, _ash_opts), do: {:error, :missing_customer_id}

  defp find_customer(customer_resource, stripe_cust_id, object, ash_opts) do
    attr = ResourceInfo.customer_id_attribute(customer_resource)

    result =
      customer_resource
      |> Ash.Query.filter(^[{attr, stripe_cust_id}])
      |> AshBilling.ResourceLock.query()
      |> Ash.read_one(ash_opts)

    case result do
      {:ok, customer} when not is_nil(customer) ->
        {:ok, customer}

      {:error, reason} ->
        {:error, reason}

      {:ok, nil} ->
        find_unassociated_customer(customer_resource, stripe_cust_id, object, ash_opts)
    end
  end

  defp find_unassociated_customer(resource, customer_id, object, ash_opts) do
    resource_id = get_in(object, ["metadata", "resource_id"]) || object["client_reference_id"]

    metadata_id = get_in(object, ["metadata", "resource_id"])
    reference_id = object["client_reference_id"]

    cond do
      metadata_id && reference_id && metadata_id != reference_id ->
        {:error, :customer_identity_conflict}

      resource_id ->
        query =
          resource |> Ash.Query.filter(id == ^resource_id) |> AshBilling.ResourceLock.query()

        case Ash.read_one(query, ash_opts) do
          {:ok, customer} when not is_nil(customer) ->
            associate_customer(customer, customer_id, ash_opts)

          {:ok, nil} ->
            {:error, :customer_not_found}

          {:error, reason} ->
            if not_found_error?(reason), do: {:error, :customer_not_found}, else: {:error, reason}
        end

      true ->
        # Email is not proof of ownership. It may identify a conflict, but cannot
        # establish a new billing association or grant subscription access.
        email = object["customer_email"] || get_in(object, ["customer_details", "email"])

        if email && Ash.Resource.Info.attribute(resource, :email) do
          case resource |> Ash.Query.filter(email == ^email) |> Ash.read_one(ash_opts) do
            {:ok, nil} ->
              {:error, :customer_not_found}

            {:ok, customer} ->
              if is_nil(Map.get(customer, ResourceInfo.customer_id_attribute(resource))),
                do: {:error, :customer_identity_unverified},
                else: {:error, :customer_identity_conflict}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:error, :customer_not_found}
        end
    end
  end

  @doc false
  def associate_customer(%resource{} = customer, customer_id, ash_opts) do
    AshBilling.ResourceLock.run([resource], {resource, Keyword.get(ash_opts, :tenant)}, fn ->
      if Map.get(customer, :billing_deleted_at) do
        {:error, :customer_deleted}
      else
        do_associate_customer(customer, customer_id, ash_opts)
      end
    end)
  end

  defp do_associate_customer(%resource{} = customer, customer_id, ash_opts) do
    attr = ResourceInfo.customer_id_attribute(resource)

    case Map.get(customer, attr) do
      ^customer_id ->
        {:ok, customer}

      nil ->
        # Only the first successful writer may establish the association.
        query = Ash.Query.filter(resource, id == ^customer.id)
        query = Ash.Query.filter(query, ^[{attr, [is_nil: true]}])

        query =
          if Ash.Resource.Info.attribute(resource, :billing_deleted_at),
            do: Ash.Query.filter(query, is_nil(billing_deleted_at)),
            else: query

        case primary_update_action(resource) do
          nil ->
            {:error, :update_action_required}

          update_action ->
            case Ash.bulk_update(
                   query,
                   update_action.name,
                   %{},
                   Keyword.merge(ash_opts,
                     atomic_update: %{attr => customer_id},
                     strategy: [:atomic],
                     return_records?: true,
                     return_errors?: true
                   )
                 ) do
              %Ash.BulkResult{status: :success, records: [updated]} ->
                {:ok, updated}

              %Ash.BulkResult{status: :success, records: []} ->
                case Ash.get(resource, customer.id, ash_opts) do
                  {:ok, latest} when not is_nil(latest) ->
                    cond do
                      Map.get(latest, :billing_deleted_at) -> {:error, :customer_deleted}
                      Map.get(latest, attr) == customer_id -> {:ok, latest}
                      true -> {:error, :customer_identity_conflict}
                    end

                  {:error, reason} ->
                    {:error, reason}

                  _ ->
                    {:error, :customer_not_found}
                end

              %Ash.BulkResult{errors: [error | _]} ->
                {:error, error}

              other ->
                {:error, other}
            end
        end

      _ ->
        {:error, :customer_identity_conflict}
    end
  end

  defp validate_subscription_customer(nil, _customer, _resource), do: :ok
  defp validate_subscription_customer(_existing, nil, _resource), do: :ok

  defp validate_subscription_customer(existing, customer, resource) do
    attr =
      find_relationship_source_attribute(
        resource,
        SubscriptionInfo.customer_relationship(resource)
      )

    if Map.get(existing, attr) == customer.id,
      do: :ok,
      else: {:error, :subscription_customer_conflict}
  end

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &not_found_error?/1)

  defp not_found_error?(_), do: false

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

  defp extract_cancel_at(object) do
    parse_unix_timestamp(object["cancel_at"])
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
        DateTime.compare(recorded_dt, inc_dt) == :eq and
          Enum.any?(
            [
              :status,
              :price_id,
              :trial_ends_at,
              :current_period_end,
              :cancel_at_period_end,
              :cancel_at
            ],
            fn field ->
              Map.has_key?(existing, field) and Map.has_key?(attrs, field) and
                not same_value?(Map.get(existing, field), Map.get(attrs, field))
            end
          )

      _ ->
        false
    end
  end

  defp same_value?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp same_value?(a, b), do: a == b

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
