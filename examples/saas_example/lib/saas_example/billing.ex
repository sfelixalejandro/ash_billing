defmodule SaasExample.Billing do
  @moduledoc """
  Billing Ash domain and orchestration service for Stripe Checkout, Billing Portal,
  plan swaps, per-seat quantity updates, cancellations/resumes, and authoritative
  reconciliation against Stripe.
  """
  use Ash.Domain, otp_app: :saas_example

  require Ash.Query

  alias SaasExample.Accounts
  alias SaasExample.Accounts.User
  alias SaasExample.Billing.{Catalog, Subscription}
  alias SaasExample.Workspace

  resources do
    resource SaasExample.Billing.Subscription
    resource SaasExample.Billing.WebhookEvent
  end

  @doc """
  Returns runtime provider/HTTP options merged from application config and per-call overrides.
  """
  @spec provider_opts(keyword()) :: keyword()
  def provider_opts(extra \\ []) do
    req_opts =
      Keyword.merge(
        Application.get_env(:ash_billing, :req_opts, []),
        Keyword.get(extra, :req_opts, [])
      )

    base = [
      provider: Application.get_env(:ash_billing, :provider, AshBilling.Providers.Stripe),
      api_key: Application.get_env(:ash_billing, :api_key),
      req_opts: req_opts
    ]

    extra
    |> Keyword.drop([:req_opts])
    |> then(&Keyword.merge(base, &1))
  end

  @doc """
  Fetches a subscription authorized for the given user actor (fails closed if owned
  by another user).
  """
  @spec get_user_subscription(User.t(), String.t()) :: {:ok, Subscription.t()} | {:error, term()}
  def get_user_subscription(%User{} = user, subscription_id) when is_binary(subscription_id) do
    case Subscription
         |> Ash.Query.filter(id == ^subscription_id and user_id == ^user.id)
         |> Ash.read_one(domain: __MODULE__, actor: user, authorize?: true) do
      {:ok, %Subscription{} = sub} -> {:ok, sub}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_user_subscription(_, _), do: {:error, :not_found}

  @doc """
  Returns the active (or latest) subscription for a user.
  """
  @spec primary_subscription(User.t()) :: Subscription.t() | nil
  def primary_subscription(%User{} = user) do
    case AshBilling.subscription(user) do
      %Subscription{} = active ->
        active

      nil ->
        case Map.get(user, :subscriptions) do
          [first | _] -> first
          _ -> nil
        end
    end
  end

  @doc """
  Persists a Stripe Customer before initiating a single-item recurring Checkout session.
  Validates plan against the server-controlled `SaasExample.Billing.Catalog`.
  """
  @spec start_checkout(User.t(), atom() | String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_checkout(%User{} = user, plan_key, quantity, opts \\ []) do
    with {:ok, plan} <- Catalog.resolve_plan(plan_key),
         :ok <- validate_positive_quantity(quantity),
         {:ok, persisted_user} <- ensure_customer_persisted(user, opts) do
      success_url = Keyword.fetch!(opts, :success_url)
      cancel_url = Keyword.fetch!(opts, :cancel_url)

      checkout_opts =
        provider_opts(Keyword.drop(opts, [:success_url, :cancel_url])) ++
          [
            mode: "subscription",
            line_items: [%{price: plan.price_id, quantity: quantity}],
            success_url: success_url,
            cancel_url: cancel_url
          ]

      AshBilling.create_checkout_session(persisted_user, checkout_opts)
    end
  end

  @doc """
  Creates a Stripe Billing Portal session for an authenticated user with a Stripe customer ID.
  """
  @spec open_portal(User.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def open_portal(user, return_url, opts \\ [])

  def open_portal(%User{stripe_customer_id: id}, _return_url, _opts)
      when is_nil(id) or id == "" do
    {:error, :no_stripe_customer}
  end

  def open_portal(%User{} = user, return_url, opts) do
    portal_opts = provider_opts(opts) ++ [return_url: return_url]
    AshBilling.create_portal_session(user, portal_opts)
  end

  @doc """
  Swaps an owned subscription to another server-catalog plan, preserving seat quantity.
  """
  @spec swap_plan(User.t(), String.t(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def swap_plan(%User{} = user, subscription_id, target_plan_key, opts \\ []) do
    with {:ok, sub} <- get_user_subscription(user, subscription_id),
         {:ok, plan} <- Catalog.resolve_plan(target_plan_key) do
      swap_opts =
        provider_opts(opts)
        |> maybe_put(:subscription_item_id, sub.provider_subscription_item_id)

      AshBilling.swap_plan(sub, plan.price_id, swap_opts)
    end
  end

  @doc """
  Updates contracted seat quantity for an owned subscription.

  Refuses to lower `quantity` below currently active workspace seats before calling
  Stripe, and supplies the current `price_id` as an optimistic assertion to prevent
  accidental plan drift.
  """
  @spec update_quantity(User.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_quantity(%User{} = user, subscription_id, new_quantity, opts \\ []) do
    with :ok <- validate_positive_quantity(new_quantity),
         {:ok, sub} <- get_user_subscription(user, subscription_id),
         :ok <- ensure_quantity_covers_active_seats(user, new_quantity) do
      qty_opts =
        provider_opts(opts)
        |> maybe_put(:subscription_item_id, sub.provider_subscription_item_id)
        |> maybe_put(:price_id, sub.price_id)

      AshBilling.update_quantity(sub, new_quantity, qty_opts)
    end
  end

  @doc """
  Schedules cancellation at period end (or immediately when `at_period_end: false`).
  """
  @spec cancel_subscription(User.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def cancel_subscription(%User{} = user, subscription_id, opts \\ []) do
    with {:ok, sub} <- get_user_subscription(user, subscription_id) do
      cancel_opts =
        provider_opts(opts)
        |> Keyword.put_new(:at_period_end, true)

      AshBilling.cancel_subscription(sub, cancel_opts)
    end
  end

  @doc """
  Resumes a subscription scheduled to cancel at period end.
  """
  @spec resume_subscription(User.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resume_subscription(%User{} = user, subscription_id, opts \\ []) do
    with {:ok, sub} <- get_user_subscription(user, subscription_id) do
      AshBilling.resume_subscription(sub, provider_opts(opts))
    end
  end

  @doc """
  Performs authoritative PostgreSQL reconciliation against Stripe for an owned subscription.
  """
  @spec reconcile_user_subscription(User.t(), String.t(), keyword()) ::
          {:ok, Subscription.t()} | {:error, term()}
  def reconcile_user_subscription(%User{} = user, subscription_id, opts \\ []) do
    with {:ok, sub} <- get_user_subscription(user, subscription_id) do
      reconcile_opts =
        provider_opts(opts)
        |> Keyword.merge(
          domain: __MODULE__,
          customer_resource: User,
          subscription_resource: Subscription,
          authorize?: false
        )

      AshBilling.reconcile_subscription(sub, reconcile_opts)
    end
  end

  defp ensure_customer_persisted(%User{stripe_customer_id: id} = user, _opts)
       when is_binary(id) and id != "" do
    {:ok, user}
  end

  defp ensure_customer_persisted(%User{} = user, opts) do
    create_opts =
      provider_opts(Keyword.drop(opts, [:success_url, :cancel_url])) ++
        [persist: true, actor: user, authorize?: true]

    case AshBilling.create_customer(user, create_opts) do
      {:ok, _stripe_cust_id} ->
        Accounts.load_fresh_actor(user.id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_positive_quantity(q) when is_integer(q) and q >= 1, do: :ok
  defp validate_positive_quantity(_), do: {:error, :invalid_quantity}

  defp ensure_quantity_covers_active_seats(%User{} = user, new_quantity) do
    active_count = Workspace.active_seat_count(user)

    if new_quantity < active_count do
      {:error, {:seats_exceed_new_quantity, active_count}}
    else
      :ok
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
