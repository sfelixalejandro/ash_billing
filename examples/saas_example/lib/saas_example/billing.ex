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
  alias SaasExample.{Repo, Workspace}

  @max_locked_connect_timeout_ms 3_000
  @max_locked_receive_timeout_ms 5_000

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
      api_key:
        Application.get_env(:ash_billing, :stripe_api_key) ||
          Application.get_env(:ash_billing, :api_key),
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

  ## Concurrency & Lock Protocol

  Participates in the same canonical PostgreSQL lock order used by
  `SaasExample.Workspace.assign_seat/3`, `AshBilling.WebhookSync`, and
  `AshBilling.reconcile_subscription/2`:

      1. `SELECT id FROM users WHERE id = $1 FOR UPDATE` (owner/customer row)
      2. `SELECT id FROM subscriptions WHERE id = $1 AND user_id = $2 FOR UPDATE`

  This strict `Customer -> Subscription` hierarchy prevents deadlocks with
  concurrent webhooks/reconciliation while serializing seat downsizing against
  concurrent seat assignments. Inside the transaction:

    * Verifies `new_quantity >= active_seat_count(user)` before calling Stripe.
    * Invokes `AshBilling.update_quantity/3` with `retry: false` and bounded
      timeouts (`connect_timeout <= 3_000ms`, `receive_timeout <= 5_000ms`) plus
      an optimistic `:price_id` assertion.
    * Atomically persists the updated `quantity` (and `provider_subscription_item_id`)
      to PostgreSQL before committing so any waiting `assign_seat` transaction
      observes the new seat cap immediately upon lock release.

  > #### Lock Hold Ceiling & PostgreSQL Pool Sizing Note
  > Because `:price_id` is passed as an optimistic price assertion,
  > `AshBilling.update_quantity/3` performs **2 sequential Stripe HTTP calls**
  > (`GET /v1/subscriptions/{id}` + `POST /v1/subscriptions/{id}`) while holding
  > the `FOR UPDATE` locks. With `connect_timeout <= 3_000ms`,
  > `receive_timeout <= 5_000ms`, and `retry: false`, the combined worst-case
  > lock hold time is **up to 16 seconds** (`2 × 8s`), which exceeds Ecto's
  > default `15_000ms` transaction timeout; this transaction therefore sets
  > `timeout: 20_000`. Size `SaasExample.Repo` `pool_size` accordingly and never
  > enable HTTP retries inside locked billing transactions.
  >
  > If Stripe confirms the `POST` mutation and PostgreSQL fails before commit,
  > the local transaction rolls back cleanly and subsequent reconciliation
  > (`reconcile_user_subscription/3` or Stripe's signed webhook) converges
  > PostgreSQL via read-only `GET` without duplicating financial changes.
  """
  @spec update_quantity(User.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_quantity(%User{} = user, subscription_id, new_quantity, opts \\ []) do
    with :ok <- validate_positive_quantity(new_quantity),
         {:ok, _owned_sub} <- get_user_subscription(user, subscription_id) do
      on_before_commit = Keyword.get(opts, :on_before_commit)
      provider_call_opts = Keyword.delete(opts, :on_before_commit)

      case Repo.transaction(
             fn ->
               # Canonical lock order: Customer (users) -> Subscription (subscriptions)
               Repo.query!("SELECT id FROM users WHERE id = $1 FOR UPDATE", [
                 Ecto.UUID.dump!(user.id)
               ])

               Repo.query!(
                 "SELECT id FROM subscriptions WHERE id = $1 AND user_id = $2 FOR UPDATE",
                 [Ecto.UUID.dump!(subscription_id), Ecto.UUID.dump!(user.id)]
               )

               with {:ok, fresh_sub} <- get_user_subscription(user, subscription_id),
                    :ok <- ensure_quantity_covers_active_seats(user, new_quantity),
                    qty_opts = build_locked_quantity_opts(fresh_sub, provider_call_opts),
                    {:ok, remote_sub} <-
                      AshBilling.update_quantity(fresh_sub, new_quantity, qty_opts),
                    {:ok, _updated_sub} <-
                      persist_updated_quantity(user, fresh_sub, remote_sub, new_quantity),
                    :ok <- run_before_commit_hook(on_before_commit) do
                 remote_sub
               else
                 {:error, reason} -> Repo.rollback(reason)
               end
             end,
             timeout: 20_000
           ) do
        {:ok, remote_sub} -> {:ok, remote_sub}
        {:error, reason} -> {:error, reason}
      end
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

  defp build_locked_quantity_opts(sub, opts) do
    base = provider_opts(opts)

    bounded_req_opts =
      base
      |> Keyword.get(:req_opts, [])
      |> Keyword.put(:retry, false)
      |> Keyword.update(
        :receive_timeout,
        @max_locked_receive_timeout_ms,
        &Kernel.min(&1, @max_locked_receive_timeout_ms)
      )
      |> Keyword.update(
        :connect_options,
        [timeout: @max_locked_connect_timeout_ms],
        fn connect_opts ->
          Keyword.update(
            connect_opts,
            :timeout,
            @max_locked_connect_timeout_ms,
            &Kernel.min(&1, @max_locked_connect_timeout_ms)
          )
        end
      )

    base
    |> Keyword.put(:req_opts, bounded_req_opts)
    |> maybe_put(:subscription_item_id, sub.provider_subscription_item_id)
    |> maybe_put(:price_id, sub.price_id)
  end

  defp persist_updated_quantity(user, sub, remote_sub, requested_quantity) do
    with {:ok, persisted_qty, item_id} <-
           extract_persisted_quantity(remote_sub, requested_quantity),
         :ok <- ensure_quantity_covers_active_seats(user, persisted_qty) do
      changes =
        %{quantity: persisted_qty}
        |> then(fn map ->
          if is_binary(item_id) and item_id != "" do
            Map.put(map, :provider_subscription_item_id, item_id)
          else
            map
          end
        end)

      sub
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attributes(changes)
      |> Ash.update(domain: __MODULE__, authorize?: false)
    end
  end

  defp extract_persisted_quantity(remote_sub, requested_quantity) when is_map(remote_sub) do
    if Map.has_key?(remote_sub, "items") do
      case AshBilling.WebhookSync.extract_live_snapshot(remote_sub) do
        {:ok, %{quantity: qty, provider_subscription_item_id: item_id}}
        when is_integer(qty) and qty >= 0 ->
          {:ok, qty, item_id}

        {:ok, _snapshot} ->
          {:ok, requested_quantity, nil}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, requested_quantity, nil}
    end
  end

  defp extract_persisted_quantity(_remote_sub, requested_quantity),
    do: {:ok, requested_quantity, nil}

  defp run_before_commit_hook(nil), do: :ok
  defp run_before_commit_hook(fun) when is_function(fun, 0), do: fun.()

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)
end
