defmodule AshBilling do
  @moduledoc """
  Top-level API for `AshBilling`.

  Provides functions for managing billing customers, checkout sessions,
  customer portals, and subscriptions. Customer and subscription records use
  their resource's configured provider; explicit `:provider` takes precedence.
  Raw IDs/maps without resource configuration default to Stripe.
  """

  alias AshBilling.Providers.Stripe
  alias AshBilling.Resource.Info, as: ResourceInfo
  alias AshBilling.Subscription.Info, as: SubscriptionInfo
  alias AshBilling.WebhookSync

  @doc """
  Extracts the customer ID from a record configured with `AshBilling.Resource`.
  """
  @spec customer_id(struct()) :: String.t() | nil
  def customer_id(%resource{} = record) do
    attr = ResourceInfo.customer_id_attribute(resource)
    if Map.get(record, :billing_deleted_at), do: nil, else: Map.get(record, attr)
  end

  def customer_id(_), do: nil

  @doc """
  Creates a billing customer in the configured provider.

  If the record already has a customer ID, returns `{:ok, existing_customer_id}` without calling the provider.
  Automatic idempotency keys include the resource, canonical tenant and record ID.
  An explicit `:idempotency_key` is preserved. Callers must authorize the record
  and supply tenant/actor options for persistence as appropriate to their application.

  `persist: true` requires a loaded Ash record and an update action; missing
  prerequisites return an error before contacting the provider. A later write
  failure returns `{:error, {:persistence_failed, customer_id, reason}}` so the
  remote identity can be reconciled. `persist: false` only creates remotely.
  Reload the record before using it for recurring Checkout. Existing IDs are
  returned without a provider call; callers remain responsible for authorization.
  """
  @spec create_customer(term(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_customer(record_or_params, opts \\ [])

  def create_customer(%resource{} = record, opts) do
    with :ok <- validate_customer_tenant(record, opts) do
      do_create_customer(resource, record, opts)
    end
  end

  def create_customer(params, opts) when is_map(params) do
    if Keyword.get(opts, :persist, Keyword.get(opts, :persist?)) == true do
      {:error, :invalid_customer_resource}
    else
      provider = Keyword.get(opts, :provider, Stripe)
      provider.create_customer(params, opts)
    end
  end

  def create_customer(_record_or_params, _opts) do
    {:error, :invalid_customer}
  end

  defp do_create_customer(resource, record, opts) do
    provider = Keyword.get(opts, :provider, ResourceInfo.provider(resource))
    existing_id = customer_id(record)

    cond do
      Map.get(record, :billing_deleted_at) ->
        {:error, :customer_deleted}

      existing_id ->
        {:ok, existing_id}

      true ->
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

        opts =
          if Map.get(record, :id) && !Keyword.has_key?(opts, :idempotency_key) do
            Keyword.put(opts, :idempotency_key, customer_idempotency_key(resource, record, opts))
          else
            opts
          end

        persist_opt = Keyword.get(opts, :persist, Keyword.get(opts, :persist?))

        should_persist? =
          persist_opt == true or (persist_opt != false and persisted_record?(record))

        with :ok <- validate_customer_persistence(resource, record, should_persist?),
             {:ok, customer_id} <- provider.create_customer(params, opts) do
          if should_persist? do
            ash_opts =
              opts
              |> Keyword.take([:actor, :tenant])
              |> Keyword.put(:tenant, customer_tenant(record, opts))
              |> Keyword.merge(
                domain: Keyword.get(opts, :domain, Ash.Resource.Info.domain(resource)),
                authorize?: Keyword.get(opts, :authorize?, false)
              )

            case AshBilling.WebhookSync.associate_customer(record, customer_id, ash_opts) do
              {:ok, _updated} -> {:ok, customer_id}
              {:error, reason} -> {:error, {:persistence_failed, customer_id, reason}}
            end
          else
            {:ok, customer_id}
          end
        end
    end
  end

  @doc """
  Creates a checkout session for a customer.

  Recurring Checkout requires an existing customer ID and exactly one line item.
  Create and persist the customer first with `create_customer/2`, then reload
  the record (or pass the returned ID with trusted ownership metadata). Missing
  customer IDs return `{:error, :no_customer_id}` before any provider call.
  Multiple subscription lines return `{:error, :unsupported_subscription_items}`.
  Payment Checkout can have several lines and no Customer; it does not itself
  confirm payment or fulfill an order. Record ownership metadata and client
  references are bound to that record and cannot be replaced by options.

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
    mode = Keyword.get(opts, :mode, "subscription")

    with :ok <- validate_customer_tenant(record_or_customer_id, opts),
         {:ok, line_items} <- checkout_line_items(opts),
         :ok <- validate_checkout(mode, line_items, record_or_customer_id, opts) do
      do_create_checkout_session(
        record_or_customer_id,
        Keyword.put(opts, :line_items, line_items)
      )
    end
  end

  defp checkout_line_items(opts) do
    case Keyword.get(opts, :line_items) do
      nil ->
        case Keyword.get(opts, :price) do
          price when is_binary(price) and price != "" ->
            {:ok, [%{price: price, quantity: Keyword.get(opts, :quantity, 1)}]}

          _ ->
            {:error, :invalid_price}
        end

      [_ | _] = items ->
        {:ok, items}

      _ ->
        {:error, :invalid_line_items}
    end
  end

  defp validate_checkout(mode, items, record, opts) do
    cond do
      mode not in [:subscription, "subscription", :payment, "payment"] ->
        {:error, :invalid_mode}

      not is_binary(Keyword.get(opts, :success_url)) or Keyword.get(opts, :success_url) == "" ->
        {:error, :invalid_success_url}

      not is_binary(Keyword.get(opts, :cancel_url)) or Keyword.get(opts, :cancel_url) == "" ->
        {:error, :invalid_cancel_url}

      mode in [:subscription, "subscription"] and length(items) != 1 ->
        {:error, :unsupported_subscription_items}

      mode in [:subscription, "subscription"] and resolve_customer_id(record) in [nil, ""] ->
        {:error, :no_customer_id}

      true ->
        :ok
    end
  end

  defp do_create_checkout_session(record_or_customer_id, opts) do
    cust_id = resolve_customer_id(record_or_customer_id)
    provider = resolve_provider(record_or_customer_id, opts)

    line_items = Keyword.fetch!(opts, :line_items)

    resource_id =
      case record_or_customer_id do
        %{id: id} when not is_nil(id) -> to_string(id)
        _ -> nil
      end

    user_email =
      case record_or_customer_id do
        %{email: email} when is_binary(email) -> email
        _ -> Keyword.get(opts, :customer_email)
      end

    custom_metadata = Keyword.get(opts, :metadata, %{}) |> Enum.into(%{})

    metadata =
      if resource_id do
        custom_metadata |> Map.delete(:resource_id) |> Map.put("resource_id", resource_id)
      else
        custom_metadata
      end

    client_ref_id = resource_id || Keyword.get(opts, :client_reference_id)

    params =
      %{
        line_items: line_items,
        success_url: Keyword.fetch!(opts, :success_url),
        cancel_url: Keyword.fetch!(opts, :cancel_url),
        mode: to_string(Keyword.get(opts, :mode, "subscription"))
      }
      |> then(fn p -> if cust_id, do: Map.put(p, :customer, cust_id), else: p end)
      |> then(fn p ->
        if is_nil(cust_id) and user_email, do: Map.put(p, :customer_email, user_email), else: p
      end)
      |> then(fn p ->
        if client_ref_id, do: Map.put(p, :client_reference_id, client_ref_id), else: p
      end)
      |> then(fn p -> if map_size(metadata) > 0, do: Map.put(p, :metadata, metadata), else: p end)
      |> then(fn p ->
        if to_string(p.mode) == "subscription" do
          existing_sub_data = Keyword.get(opts, :subscription_data, %{}) |> Enum.into(%{})

          sub_metadata =
            existing_sub_data
            |> Map.get(:metadata, Map.get(existing_sub_data, "metadata", %{}))
            |> Enum.into(%{})
            |> then(fn values ->
              if resource_id, do: Map.delete(values, :resource_id), else: values
            end)
            |> Map.merge(metadata)

          sub_data =
            existing_sub_data |> Map.delete("metadata") |> Map.put(:metadata, sub_metadata)

          Map.put(p, :subscription_data, sub_data)
        else
          p
        end
      end)

    start_meta = %{
      provider: provider,
      mode: params.mode,
      customer: cust_id
    }

    :telemetry.span([:ash_billing, :checkout], start_meta, fn ->
      case provider.create_checkout_session(params, opts) do
        {:ok, %{url: url, id: id}} = success ->
          {success, %{status: :ok, session_id: id, url: url}}

        {:error, reason} = error ->
          {error, %{status: :error, error: reason}}
      end
    end)
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

    return_url = Keyword.get(opts, :return_url)

    cond do
      is_nil(cust_id) or cust_id == "" ->
        {:error, :no_customer_id}

      is_nil(return_url) or not is_binary(return_url) or String.trim(return_url) == "" ->
        {:error, :missing_return_url}

      true ->
        provider = resolve_provider(record_or_customer_id, opts)
        extra_params = Keyword.get(opts, :params, %{})

        params =
          extra_params
          |> Map.merge(%{
            customer: cust_id,
            return_url: return_url
          })

        start_meta = %{
          provider: provider,
          customer: cust_id
        }

        :telemetry.span([:ash_billing, :portal], start_meta, fn ->
          case provider.create_portal_session(params, opts) do
            {:ok, %{url: url}} = success ->
              {success, %{status: :ok, url: url}}

            {:error, reason} = error ->
              {error, %{status: :error, error: reason}}
          end
        end)
    end
  end

  @doc """
  Retrieves a subscription from the billing provider.
  """
  @spec get_subscription(struct() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_subscription(subscription_or_id, opts \\ []) do
    case resolve_subscription_id(subscription_or_id) do
      sub_id when is_binary(sub_id) and sub_id != "" ->
        provider = resolve_subscription_provider(subscription_or_id, opts)
        provider.get_subscription(sub_id, opts)

      _ ->
        {:error, :invalid_subscription_id}
    end
  end

  @doc """
  Reconciles a subscription against the authoritative provider state and persists updates.

  Unlike `get_subscription/2` which only queries the provider without modifying local
  data, `reconcile_subscription/2` fetches the live subscription from the provider and
  passes it to `AshBilling.WebhookSync.sync_event/2` as a synthetic event. This ensures
  that any status, plan, period, or cancellation changes are safely persisted to
  PostgreSQL inside advisory locks and transaction boundaries.

  This provides a safe, on-demand or periodic reconciliation procedure to heal local database
  drift when webhooks are permanently lost or delayed, without requiring an in-library
  background daemon.

  ## Options

  Requires the synchronization options needed by `AshBilling.WebhookSync.sync_event/2`:
    * `:subscription_resource` - Ash resource for subscriptions (inferred automatically if `subscription_or_id` is a record).
    * `:customer_resource` - Ash resource for customers (e.g. `MyApp.Accounts.User`). Inferred from `subscription_resource` relationship if available.
    * `:domain` - The Ash domain module to execute actions with.
    * `:tenant` - Optional tenant identifier for multitenant deployments.
    * `:actor` - Optional system actor to run actions on behalf of.
    * `:authorize?` - Whether to perform authorization checks. Defaults to `false`.
    * `:provider` - Billing provider module (defaults to configured provider).

  ## Example

      # In an Oban worker or scheduled task:
      {:ok, updated_sub} =
        AshBilling.reconcile_subscription(subscription,
          domain: MyApp.Billing
        )
  """
  @spec reconcile_subscription(struct() | String.t(), keyword()) ::
          {:ok, struct() | :ignored} | {:error, term()}
  def reconcile_subscription(subscription_or_id, opts \\ []) do
    with {:ok, live_sub} <- get_subscription(subscription_or_id, opts) do
      subscription_resource =
        cond do
          Keyword.has_key?(opts, :subscription_resource) ->
            Keyword.get(opts, :subscription_resource)

          is_struct(subscription_or_id) ->
            subscription_or_id.__struct__

          true ->
            nil
        end

      customer_resource =
        opts[:customer_resource] ||
          (subscription_resource &&
             case Ash.Resource.Info.relationship(
                    subscription_resource,
                    SubscriptionInfo.customer_relationship(subscription_resource)
                  ) do
               %{destination: dest} -> dest
               _ -> nil
             end)

      if is_nil(subscription_resource) do
        {:error, :missing_subscription_resource}
      else
        event_type =
          if live_sub["status"] in ["canceled", "incomplete_expired"],
            do: "customer.subscription.deleted",
            else: "customer.subscription.updated"

        now = System.system_time(:second)

        synthetic_event = %{
          "id" => "reconcile_#{live_sub["id"]}_#{now}",
          "type" => event_type,
          "created" => now,
          "data" => %{"object" => live_sub}
        }

        sync_opts =
          opts
          |> Keyword.put(:subscription_resource, subscription_resource)
          |> then(fn o ->
            if customer_resource,
              do: Keyword.put_new(o, :customer_resource, customer_resource),
              else: o
          end)

        WebhookSync.sync_event(synthetic_event, sync_opts)
      end
    end
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
    case resolve_subscription_id(subscription_or_id) do
      sub_id when is_binary(sub_id) and sub_id != "" ->
        provider = resolve_subscription_provider(subscription_or_id, opts)
        provider.cancel_subscription(sub_id, opts)

      _ ->
        {:error, :invalid_subscription_id}
    end
  end

  @doc """
  Resumes a subscription that was scheduled to cancel at period end.

  Sets `cancel_at_period_end` to `false` in the billing provider.
  """
  @spec resume_subscription(struct() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resume_subscription(subscription_or_id, opts \\ []) do
    case resolve_subscription_id(subscription_or_id) do
      sub_id when is_binary(sub_id) and sub_id != "" ->
        provider = resolve_subscription_provider(subscription_or_id, opts)
        provider.resume_subscription(sub_id, opts)

      _ ->
        {:error, :invalid_subscription_id}
    end
  end

  @doc """
  Swaps a subscription to a new price/plan in the billing provider.

  Stripe preserves the current quantity unless an explicit positive integer is
  supplied. Multiple items require an explicit item ID; missing quantities and
  ambiguous or truncated item collections return errors instead of guessing.

  ## Options

    * `:proration_behavior` - `"create_prorations"` (default), `"none"`, or `"always_invoice"`.
    * `:subscription_item_id` - Explicit Stripe item ID. Avoids GET only with an explicit quantity.
    * `:quantity` - Positive integer override; otherwise the current quantity is fetched and preserved.
    * `:proration_date` - Unix timestamp to use for calculating prorations.
    * `:provider` - The billing provider module.
  """
  @spec swap_plan(struct() | String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def swap_plan(subscription_or_id, new_price_id, opts \\ []) do
    case resolve_subscription_id(subscription_or_id) do
      sub_id when is_binary(sub_id) and sub_id != "" ->
        if not is_binary(new_price_id) or String.trim(new_price_id) == "" do
          {:error, :invalid_price_id}
        else
          provider = resolve_subscription_provider(subscription_or_id, opts)

          :telemetry.span(
            [:ash_billing, :swap_plan],
            %{provider: provider, subscription_id: sub_id, new_price_id: new_price_id},
            fn ->
              case provider.swap_plan(sub_id, new_price_id, opts) do
                {:ok, result} ->
                  {{:ok, result}, %{status: :ok}}

                {:error, reason} = error ->
                  {error, %{status: :error, error: reason}}
              end
            end
          )
        end

      _ ->
        {:error, :invalid_subscription_id}
    end
  end

  @doc """
  Updates the quantity of a subscription (e.g. per-seat billing).

  ### Provider Implementation Note & Legacy Fallback

  * **Stripe Provider (`AshBilling.Providers.Stripe`)**: Implements `@callback update_quantity/3`
    natively. The HTTP request to Stripe sends only `items[0][id]` and `items[0][quantity]`,
    omitting `items[0][price]` entirely. This guarantees at the provider level that Stripe cannot
    accidentally change the plan price during a quantity update, avoiding race conditions with
    concurrent plan changes. If `:price_id` is supplied, it acts as an optimistic assertion
    against the live price; if the remote price differs, the update is safely aborted with
    `{:error, {:price_mismatch, actual_price_id}}`.

  * **Legacy / Custom Providers**: If a custom provider does not implement `@callback update_quantity/3`,
    `AshBilling` falls back to `swap_plan/3`. If `:price_id` is provided, `swap_plan/3` is called
    directly with that price ID; if the caller passes a stale price ID, the legacy provider will
    unintentionally execute a plan swap to that stale price. If `:price_id` is omitted, the fallback
    retrieves the active price via `get_subscription/2` before swapping, which carries a theoretical
    race window under concurrent plan modifications. Custom providers must implement
    `@callback update_quantity/3` to achieve the same price isolation and atomicity guarantees as Stripe.

  ## Options

    * `:proration_behavior` - `"create_prorations"` (default), `"none"`, or `"always_invoice"`.
    * `:subscription_item_id` - Explicit subscription item ID (avoids an extra GET call if known).
    * `:price_id` - Expected active price ID assertion (aborts if Stripe has a different price).
    * `:proration_date` - Unix timestamp to use for calculating prorations.
    * `:provider` - The billing provider module.
  """
  @spec update_quantity(struct() | String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_quantity(subscription_or_id, quantity, opts \\ [])

  def update_quantity(_subscription_or_id, quantity, _opts)
      when not is_integer(quantity) or quantity <= 0 do
    {:error, :invalid_quantity}
  end

  def update_quantity(subscription_or_id, quantity, opts) do
    case resolve_subscription_id(subscription_or_id) do
      sub_id when is_binary(sub_id) and sub_id != "" ->
        opts =
          Keyword.put_new(
            opts,
            :provider,
            resolve_subscription_provider(subscription_or_id, opts)
          )

        provider = Keyword.fetch!(opts, :provider)

        if Code.ensure_loaded?(provider) and function_exported?(provider, :update_quantity, 3) do
          execute_provider_update_quantity(provider, sub_id, quantity, opts)
        else
          fallback_update_quantity(sub_id, quantity, opts)
        end

      _ ->
        {:error, :invalid_subscription_id}
    end
  end

  defp execute_provider_update_quantity(provider, sub_id, quantity, opts) do
    expected_price_id = Keyword.get(opts, :price_id)
    requested_item_id = Keyword.get(opts, :subscription_item_id)

    case verify_expected_price(provider, sub_id, expected_price_id, requested_item_id, opts) do
      {:ok, resolved_opts} ->
        :telemetry.span(
          [:ash_billing, :update_quantity],
          %{provider: provider, subscription_id: sub_id, quantity: quantity},
          fn ->
            case provider.update_quantity(sub_id, quantity, resolved_opts) do
              {:ok, result} ->
                {{:ok, result}, %{status: :ok}}

              {:error, reason} = error ->
                {error, %{status: :error, error: reason}}
            end
          end
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_expected_price(_provider, _sub_id, nil, _requested_item_id, opts) do
    {:ok, opts}
  end

  defp verify_expected_price(provider, sub_id, expected_price_id, requested_item_id, opts)
       when is_binary(expected_price_id) and expected_price_id != "" do
    case provider.get_subscription(sub_id, opts) do
      {:ok, body} ->
        case Stripe.select_subscription_item(body, requested_item_id) do
          {:ok, %{"id" => item_id} = item} ->
            actual_price = get_in(item, ["price", "id"]) || item["price"]

            if actual_price == expected_price_id do
              {:ok, Keyword.put(opts, :subscription_item_id, item_id)}
            else
              {:error, {:price_mismatch, actual_price}}
            end

          {:error, reason} ->
            {:error, reason}

          _ ->
            {:error, {:missing_subscription_item, body}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_expected_price(_provider, _sub_id, _invalid_price, _requested_item_id, _opts) do
    {:error, :invalid_price_id}
  end

  defp fallback_update_quantity(sub_id, quantity, opts) do
    case Keyword.get(opts, :price_id) do
      price_id when is_binary(price_id) and price_id != "" ->
        swap_plan(sub_id, price_id, Keyword.put(opts, :quantity, quantity))

      _ ->
        provider = Keyword.fetch!(opts, :provider)

        case provider.get_subscription(sub_id, opts) do
          {:ok, %{"items" => %{"data" => items}} = body} when is_list(items) ->
            requested_item_id = Keyword.get(opts, :subscription_item_id)

            case Stripe.select_subscription_item(body, requested_item_id) do
              {:ok, %{"id" => item_id, "price" => %{"id" => price_id}}} ->
                swap_plan(
                  sub_id,
                  price_id,
                  opts
                  |> Keyword.put(:subscription_item_id, item_id)
                  |> Keyword.put(:quantity, quantity)
                )

              {:error, reason} ->
                {:error, reason}

              _ ->
                {:error, {:missing_subscription_item, body}}
            end

          {:ok, body} ->
            {:error, {:missing_subscription_item, body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Returns the active subscription record for a customer, or `nil` if none is active.

  If a `price_id` is passed as the second argument, returns the active subscription matching that price.
  Expects the `:subscriptions` relationship to be loaded on the record.
  """
  @spec subscription(struct(), String.t() | nil) :: struct() | nil
  def subscription(record, price_id \\ nil)

  def subscription(%{billing_deleted_at: deleted_at}, _price_id) when not is_nil(deleted_at),
    do: nil

  def subscription(%{subscriptions: subscriptions}, price_id) when is_list(subscriptions) do
    Enum.find(subscriptions, fn sub ->
      active_subscription?(sub) and
        (is_nil(price_id) or sub.price_id == price_id)
    end)
  end

  def subscription(_record, _price_id), do: nil

  @doc """
  Checks if a record has an active subscription.

  Checks loaded subscriptions associated with the record for `:active` or valid `:trialing` status.
  If a `price_id` is passed as the second argument, verifies that the subscription matches the price.
  """
  @spec subscribed?(struct(), String.t() | nil) :: boolean()
  def subscribed?(record, price_id \\ nil) do
    not is_nil(subscription(record, price_id))
  end

  @doc """
  Checks if a subscription is scheduled for cancellation (either via `cancel_at_period_end: true`
  or an unexpired future `cancel_at` timestamp).

  Terminal subscriptions (`:canceled` or `:incomplete_expired`, including string statuses)
  always return `false`, even if cancellation fields are still set.
  For non-terminal subscriptions, `cancel_at_period_end: true` takes precedence over
  a past `cancel_at`; this helper uses the supplied state and does not fetch provider updates.
  """
  @spec canceling?(struct() | map() | nil) :: boolean()
  def canceling?(nil), do: false

  def canceling?(%{status: status})
      when status in [:canceled, :incomplete_expired, "canceled", "incomplete_expired"],
      do: false

  def canceling?(%{cancel_at_period_end: true}), do: true

  def canceling?(%{cancel_at: %DateTime{} = cancel_at}) do
    DateTime.compare(cancel_at, DateTime.utc_now()) == :gt
  end

  def canceling?(_), do: false

  defp active_subscription?(%{status: status}) when status in [:active, "active"], do: true

  defp active_subscription?(%{status: status} = sub) when status in [:trialing, "trialing"] do
    on_trial?(sub)
  end

  defp active_subscription?(%{status: status} = sub) when status in [:past_due, "past_due"] do
    on_trial?(sub)
  end

  defp active_subscription?(_), do: false

  defp on_trial?(%{status: status, trial_ends_at: %DateTime{} = trial_ends_at})
       when status in [:trialing, "trialing", :past_due, "past_due"] do
    DateTime.compare(trial_ends_at, DateTime.utc_now()) == :gt
  end

  defp on_trial?(%{status: status, trial_ends_at: nil})
       when status in [:trialing, "trialing"],
       do: true

  defp on_trial?(%{status: status})
       when status in [:trialing, "trialing"],
       do: true

  defp on_trial?(_), do: false

  defp customer_idempotency_key(resource, record, opts) do
    tenant = customer_tenant(record, opts)
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({resource, tenant, record.id}))
    "ash_cust_" <> Base.encode16(digest, case: :lower)
  end

  defp persisted_record?(%_resource{__meta__: %{state: :loaded}}), do: true
  defp persisted_record?(_), do: false

  defp resolve_customer_id(%_resource{} = record), do: customer_id(record)
  defp resolve_customer_id(id) when is_binary(id), do: id
  defp resolve_customer_id(_), do: nil

  defp resolve_subscription_id(%{provider_subscription_id: id}) when is_binary(id),
    do: clean_id(id)

  defp resolve_subscription_id(%{stripe_subscription_id: id}) when is_binary(id),
    do: clean_id(id)

  defp resolve_subscription_id(%{id: id}) when is_binary(id), do: clean_id(id)
  defp resolve_subscription_id(id) when is_binary(id), do: clean_id(id)
  defp resolve_subscription_id(_), do: nil

  defp clean_id(id) do
    case String.trim(id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp resolve_subscription_provider(%resource{}, opts),
    do: Keyword.get(opts, :provider, SubscriptionInfo.provider(resource))

  defp resolve_subscription_provider(_id, opts), do: Keyword.get(opts, :provider, Stripe)

  defp resolve_provider(%resource{}, opts),
    do: Keyword.get(opts, :provider, ResourceInfo.provider(resource))

  defp resolve_provider(_id, opts), do: Keyword.get(opts, :provider, Stripe)

  defp remove_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Performs partial structural configuration diagnostics.

  Absent credentials remain accepted for compatibility. This does not establish
  production readiness, contact Stripe, or verify migrations, database access,
  authorization, persistence actions, or account/tenant routing.

  Verifies that billing customer resources, subscription resources, and API credentials
  are properly configured and compliant with AshBilling requirements.

  Returns `{:ok, %{status: :valid}}` or `{:error, [reasons]}`.

  ## Options

    * `:customer_resource` - The Ash resource representing billing customers.
    * `:subscription_resource` - The Ash resource representing subscriptions.
    * `:api_key` - Stripe API key to validate format (defaults to application env).
    * `:webhook_secret` - Stripe webhook secret to validate format (defaults to application env).
  """
  @spec check_configuration(keyword()) :: {:ok, map()} | {:error, [String.t()]}
  def check_configuration(opts \\ []) do
    customer_res = Keyword.get(opts, :customer_resource)
    sub_res = Keyword.get(opts, :subscription_resource)

    errors =
      []
      |> check_customer_resource(customer_res)
      |> check_subscription_resource(sub_res)
      |> check_api_key(opts)
      |> check_webhook_secret(opts)

    if errors == [] do
      {:ok, %{status: :valid}}
    else
      {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Same as `check_configuration/1`, but raises `ArgumentError` if any misconfiguration is found.
  Ideal for calling in `Application.start/2` or `config/runtime.exs`.
  """
  @spec verify_configuration!(keyword()) :: :ok
  def verify_configuration!(opts \\ []) do
    case check_configuration(opts) do
      {:ok, _} ->
        :ok

      {:error, errors} ->
        raise ArgumentError,
              "AshBilling configuration verification failed:\n" <>
                Enum.map_join(errors, "\n", &"  * #{&1}")
    end
  end

  defp check_customer_resource(errors, nil), do: errors

  defp check_customer_resource(errors, res) do
    if is_atom(res) and Spark.Dsl.is?(res, Ash.Resource) do
      attr = ResourceInfo.customer_id_attribute(res)

      errors =
        if Ash.Resource.Info.attribute(res, attr) do
          errors
        else
          ["Customer resource #{inspect(res)} is missing attribute #{inspect(attr)}" | errors]
        end

      if Ash.Resource.Info.relationship(res, :subscriptions) do
        errors
      else
        ["Customer resource #{inspect(res)} is missing :subscriptions relationship" | errors]
      end
    else
      ["Customer resource #{inspect(res)} is not a valid Ash.Resource" | errors]
    end
  end

  defp check_subscription_resource(errors, nil), do: errors

  defp check_subscription_resource(errors, res) do
    if is_atom(res) and Spark.Dsl.is?(res, Ash.Resource) do
      required_attrs = [:provider_subscription_id, :status, :price_id]

      missing_attrs =
        Enum.reject(required_attrs, fn a -> Ash.Resource.Info.attribute(res, a) != nil end)

      errors =
        if missing_attrs == [] do
          errors
        else
          [
            "Subscription resource #{inspect(res)} is missing required attributes: #{inspect(missing_attrs)}"
            | errors
          ]
        end

      if Ash.Resource.Info.calculation(res, :active?) do
        errors
      else
        ["Subscription resource #{inspect(res)} is missing :active? calculation" | errors]
      end
    else
      ["Subscription resource #{inspect(res)} is not a valid Ash.Resource" | errors]
    end
  end

  defp check_api_key(errors, opts) do
    key =
      Keyword.get(
        opts,
        :api_key,
        Application.get_env(:ash_billing, :stripe_api_key) ||
          System.get_env("STRIPE_SECRET_KEY")
      )

    case key do
      nil ->
        errors

      k when is_binary(k) ->
        if String.starts_with?(k, "sk_") or String.starts_with?(k, "rk_") do
          errors
        else
          [
            "Stripe API key does not start with standard prefix 'sk_' or 'rk_'"
            | errors
          ]
        end

      _ ->
        errors
    end
  end

  defp check_webhook_secret(errors, opts) do
    secret =
      Keyword.get(
        opts,
        :webhook_secret,
        Application.get_env(:ash_billing, :stripe_webhook_secret) ||
          System.get_env("STRIPE_WEBHOOK_SECRET")
      )

    case secret do
      nil ->
        errors

      s when is_binary(s) ->
        if String.starts_with?(s, "whsec_") do
          errors
        else
          ["Stripe webhook secret does not start with standard prefix 'whsec_'" | errors]
        end

      _ ->
        errors
    end
  end

  defp customer_tenant(%resource{} = record, opts) do
    tenant =
      case Keyword.get(opts, :tenant) do
        nil -> Ash.Resource.get_metadata(record, :tenant)
        tenant -> tenant
      end

    Ash.ToTenant.to_tenant(tenant, resource)
  end

  defp validate_customer_tenant(%resource{} = record, opts) do
    loaded_tenant = Ash.Resource.get_metadata(record, :tenant)
    requested_tenant = Keyword.get(opts, :tenant)

    if not is_nil(loaded_tenant) and not is_nil(requested_tenant) and
         Ash.ToTenant.to_tenant(loaded_tenant, resource) !=
           Ash.ToTenant.to_tenant(requested_tenant, resource),
       do: {:error, :customer_tenant_mismatch},
       else: :ok
  end

  defp validate_customer_tenant(_id, _opts), do: :ok

  defp validate_customer_persistence(_resource, _record, false), do: :ok

  defp validate_customer_persistence(resource, record, true) do
    cond do
      not Ash.Resource.Info.resource?(resource) ->
        {:error, :invalid_customer_resource}

      not persisted_record?(record) ->
        {:error, :persisted_customer_required}

      Ash.Resource.Info.primary_action(resource, :update) == nil and
          Ash.Resource.Info.action(resource, :update) == nil ->
        {:error, :update_action_required}

      true ->
        :ok
    end
  end
end
