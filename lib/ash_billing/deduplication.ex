defmodule AshBilling.Deduplication do
  @moduledoc """
  Deduplication engine for billing webhook events.

  Supports two strategies:
  * `:memory` (default) - High-performance in-memory ETS table with hourly TTL cleanup.
    Best for single-node deployments and local development.
  * `:resource` - Database-backed Ash resource deduplication with unique constraint enforcement.
    Guarantees cross-node deduplication across clustered environments (e.g. Fly.io, Kubernetes, ECS).

  ## Configuration

  Via application config:

      config :ash_billing,
        deduplication_strategy: :resource,
        deduplication_resource: MyApp.Billing.WebhookEvent

  Or per-Plug in Phoenix Router:

      forward "/webhooks/stripe", AshBilling.Plug,
        deduplication_resource: MyApp.Billing.WebhookEvent,
        domain: MyApp.Billing
  """

  use GenServer

  @table :ash_billing_processed_events
  @retention_seconds 86_400

  @doc """
  Starts the deduplication server and initializes the ETS table for memory strategy.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Atomically acquires an exclusive processing lease for an event ID.

  Returns:
  * `{:ok, :acquired}` - Lease secured; this process is the exclusive worker for the event.
  * `{:error, :already_processed}` - The event was already processed.
  * `{:error, :already_processing}` - The event is currently being processed by another worker.
  * `{:error, reason}` - Persistence error during acquisition.
  """
  @spec acquire(String.t() | nil, keyword()) ::
          {:ok, :acquired}
          | {:error, :already_processed}
          | {:error, :already_processing}
          | {:error, term()}
  def acquire(event_id, opts \\ [])
  def acquire(nil, _opts), do: {:ok, :acquired}

  def acquire(event_id, opts) when is_binary(event_id) do
    case resolve_strategy(opts) do
      :resource ->
        case resolve_resource(opts) do
          nil ->
            acquire_memory(event_id)

          resource ->
            acquire_resource(resource, event_id, opts)
        end

      :memory ->
        acquire_memory(event_id)
    end
  rescue
    e -> {:error, e}
  end

  defp acquire_resource(resource, event_id, opts) do
    domain = Keyword.get(opts, :domain)
    now = DateTime.utc_now()
    lease_ttl = Keyword.get(opts, :lease_ttl_seconds, 60)

    create_resource_lease(resource, event_id, domain, now, lease_ttl)
  end

  defp create_resource_lease(resource, event_id, domain, now, lease_ttl) do
    attrs =
      %{event_id: event_id}
      |> maybe_put_field(resource, :status, :processing)
      |> maybe_put_field(resource, :last_attempt_at, now)
      |> maybe_put_field(resource, :processed_at, now)
      |> maybe_put_field(resource, :attempts, 1)

    case Ash.create(resource, attrs, domain: domain, authorize?: false) do
      {:ok, _record} ->
        {:ok, :acquired}

      {:error, reason} ->
        if duplicate_key_error?(reason) do
          case Ash.get(resource, event_id, domain: domain, authorize?: false) do
            {:ok, record} when not is_nil(record) ->
              handle_existing_resource_lease(record, resource, domain, now, lease_ttl)

            _ ->
              {:error, :already_processing}
          end
        else
          {:error, reason}
        end
    end
  end

  defp handle_existing_resource_lease(record, resource, domain, now, lease_ttl) do
    has_status? = Ash.Resource.Info.attribute(resource, :status) != nil

    if has_status? do
      status = Map.get(record, :status)

      case status do
        :processed ->
          {:error, :already_processed}

        :failed ->
          reclaim_resource_lease(record, resource, domain, now)

        :processing ->
          attempt_dt = Map.get(record, :last_attempt_at) || Map.get(record, :processed_at)

          if attempt_dt && DateTime.diff(now, attempt_dt, :second) > lease_ttl do
            reclaim_resource_lease(record, resource, domain, now)
          else
            {:error, :already_processing}
          end

        _ ->
          {:error, :already_processed}
      end
    else
      {:error, :already_processed}
    end
  end

  defp reclaim_resource_lease(record, resource, domain, now) do
    if Ash.Resource.Info.action(resource, :update) do
      update_attrs =
        %{status: :processing, last_attempt_at: now, error: nil}
        |> maybe_increment_attempts(record, resource)

      case Ash.update(record, update_attrs, domain: domain, authorize?: false) do
        {:ok, _} -> {:ok, :acquired}
        {:error, reason} -> {:error, reason}
      end
    else
      if Ash.Resource.Info.action(resource, :destroy) do
        _ = Ash.destroy(record, domain: domain, authorize?: false)
      end

      {:ok, :acquired}
    end
  end

  defp maybe_put_field(attrs, resource, field, value) do
    if Ash.Resource.Info.attribute(resource, field) != nil do
      Map.put(attrs, field, value)
    else
      attrs
    end
  end

  defp maybe_increment_attempts(attrs, record, resource) do
    if Ash.Resource.Info.attribute(resource, :attempts) != nil do
      current = Map.get(record, :attempts) || 1
      Map.put(attrs, :attempts, current + 1)
    else
      attrs
    end
  end

  @doc """
  Completes processing for an acquired event lease.
  """
  @spec complete(String.t() | nil, keyword()) :: :ok
  def complete(event_id, opts \\ [])
  def complete(nil, _opts), do: :ok

  def complete(event_id, opts) when is_binary(event_id) do
    case resolve_strategy(opts) do
      :resource ->
        case resolve_resource(opts) do
          nil ->
            insert_memory(event_id)

          resource ->
            domain = Keyword.get(opts, :domain)
            now = DateTime.utc_now()

            case Ash.get(resource, event_id, domain: domain, authorize?: false) do
              {:ok, record} when not is_nil(record) ->
                if Ash.Resource.Info.attribute(resource, :status) != nil and
                     Ash.Resource.Info.action(resource, :update) != nil do
                  update_attrs =
                    %{status: :processed, error: nil}
                    |> maybe_put_field(resource, :processed_at, now)

                  case Ash.update(record, update_attrs, domain: domain, authorize?: false) do
                    {:ok, _} ->
                      :ok

                    {:error, reason} ->
                      require Logger

                      Logger.warning(
                        "AshBilling.Deduplication: Failed to mark event #{inspect(event_id)} as :processed: #{inspect(reason)}"
                      )

                      :ok
                  end
                else
                  :ok
                end

              _ ->
                :ok
            end
        end

      :memory ->
        insert_memory(event_id)
    end
  rescue
    _ -> :ok
  end

  @doc """
  Releases an acquired event lease on failure so retries can be processed.
  """
  @spec release(String.t() | nil, keyword()) :: :ok | {:error, term()}
  def release(event_id, opts \\ [])
  def release(nil, _opts), do: :ok

  def release(event_id, opts) when is_binary(event_id) do
    case resolve_strategy(opts) do
      :resource ->
        case resolve_resource(opts) do
          nil ->
            delete_memory(event_id)

          resource ->
            domain = Keyword.get(opts, :domain)
            err_msg = Keyword.get(opts, :error)

            case Ash.get(resource, event_id, domain: domain, authorize?: false) do
              {:ok, record} when not is_nil(record) ->
                cond do
                  Ash.Resource.Info.attribute(resource, :status) != nil and
                      Ash.Resource.Info.action(resource, :update) != nil ->
                    update_attrs = %{
                      status: :failed,
                      error: if(err_msg, do: String.slice(inspect(err_msg), 0, 500), else: nil)
                    }

                    case Ash.update(record, update_attrs, domain: domain, authorize?: false) do
                      {:ok, _} ->
                        :ok

                      {:error, update_error} ->
                        require Logger

                        Logger.warning(
                          "AshBilling.Deduplication: Failed to update event #{inspect(event_id)} to :failed: #{inspect(update_error)}. Falling back to destroy."
                        )

                        if Ash.Resource.Info.action(resource, :destroy) do
                          Ash.destroy(record, domain: domain, authorize?: false)
                        end

                        :ok
                    end

                  Ash.Resource.Info.action(resource, :destroy) != nil ->
                    case Ash.destroy(record, domain: domain, authorize?: false) do
                      :ok ->
                        :ok

                      {:ok, _} ->
                        :ok

                      {:error, destroy_err} ->
                        require Logger

                        Logger.error(
                          "AshBilling.Deduplication: Failed to destroy event record #{inspect(event_id)} on release: #{inspect(destroy_err)}"
                        )

                        {:error, destroy_err}
                    end

                  true ->
                    require Logger

                    Logger.error(
                      "AshBilling.Deduplication: Cannot release lease for event #{inspect(event_id)}. Resource #{inspect(resource)} lacks both update and destroy actions."
                    )

                    {:error, :cannot_release_lease}
                end

              _ ->
                :ok
            end
        end

      :memory ->
        delete_memory(event_id)
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Checks if an event ID has already been processed.
  """
  @spec processed?(String.t() | nil, keyword()) :: boolean()
  def processed?(event_id, opts \\ [])
  def processed?(nil, _opts), do: false

  def processed?(event_id, opts) when is_binary(event_id) do
    case resolve_strategy(opts) do
      :resource ->
        case resolve_resource(opts) do
          nil ->
            check_memory(event_id)

          resource ->
            domain = Keyword.get(opts, :domain)
            require Ash.Query

            query =
              if Ash.Resource.Info.attribute(resource, :status) != nil do
                resource
                |> Ash.Query.new()
                |> Ash.Query.filter(event_id == ^event_id and status == :processed)
              else
                resource
                |> Ash.Query.new()
                |> Ash.Query.filter(event_id == ^event_id)
              end

            Ash.exists?(query, domain: domain, authorize?: false)
        end

      :memory ->
        check_memory(event_id)
    end
  rescue
    _ -> false
  end

  @doc """
  Marks an event ID as processed directly.

  Returns `:ok` on success or when already recorded, or `{:error, reason}` if persistence fails.
  """
  @spec mark_processed(String.t() | nil, keyword()) :: :ok | {:error, term()}
  def mark_processed(event_id, opts \\ [])
  def mark_processed(nil, _opts), do: :ok

  def mark_processed(event_id, opts) when is_binary(event_id) do
    case acquire(event_id, opts) do
      {:ok, :acquired} ->
        complete(event_id, opts)
        :ok

      {:error, already} when already in [:already_processed, :already_processing] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp duplicate_key_error?(error) do
    error_str = inspect(error)

    String.contains?(error_str, "unique") or
      String.contains?(error_str, "already exists") or
      String.contains?(error_str, "already been taken") or
      String.contains?(error_str, "duplicate") or
      String.contains?(error_str, "constraint")
  end

  @doc """
  Clears all tracked events in memory (useful in tests).
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    _ -> :ok
  end

  defp resolve_strategy(opts) do
    cond do
      Keyword.has_key?(opts, :deduplication_resource) ->
        :resource

      Keyword.has_key?(opts, :deduplication_strategy) ->
        Keyword.get(opts, :deduplication_strategy)

      Application.get_env(:ash_billing, :deduplication_resource) != nil ->
        :resource

      true ->
        Application.get_env(:ash_billing, :deduplication_strategy, :memory)
    end
  end

  defp resolve_resource(opts) do
    Keyword.get(opts, :deduplication_resource) ||
      Application.get_env(:ash_billing, :deduplication_resource)
  end

  defp acquire_memory(event_id) do
    now = System.system_time(:second)

    if :ets.insert_new(@table, {event_id, :processing, now}) do
      {:ok, :acquired}
    else
      case :ets.lookup(@table, event_id) do
        [{^event_id, :processed, _}] ->
          {:error, :already_processed}

        [{^event_id, :processing, inserted_at}] ->
          # If a lease is held longer than 60s without completing, allow atomic reclamation
          if now - inserted_at > 60 do
            ms = [
              {
                {event_id, :processing, :"$1"},
                [{:>, {:-, now, :"$1"}, 60}],
                [{:const, {event_id, :processing, now}}]
              }
            ]

            if :ets.select_replace(@table, ms) == 1 do
              {:ok, :acquired}
            else
              {:error, :already_processing}
            end
          else
            {:error, :already_processing}
          end

        [{^event_id, :failed, _}] ->
          # Previous attempt failed; atomically reclaim for retry
          ms = [
            {
              {event_id, :failed, :_},
              [],
              [{:const, {event_id, :processing, now}}]
            }
          ]

          if :ets.select_replace(@table, ms) == 1 do
            {:ok, :acquired}
          else
            acquire_memory(event_id)
          end

        [{^event_id, _}] ->
          {:error, :already_processed}

        [] ->
          acquire_memory(event_id)
      end
    end
  rescue
    e -> {:error, {:ets_error, e}}
  end

  defp delete_memory(event_id) do
    now = System.system_time(:second)
    :ets.insert(@table, {event_id, :failed, now})
    :ok
  rescue
    _ -> :ok
  end

  defp check_memory(event_id) do
    case :ets.lookup(@table, event_id) do
      [{^event_id, :processed, _}] -> true
      [{^event_id, :processing, _}] -> false
      [{^event_id, :failed, _}] -> false
      [{^event_id, _timestamp}] -> true
      [] -> false
    end
  rescue
    _ -> false
  end

  defp insert_memory(event_id) do
    now = System.system_time(:second)
    :ets.insert(@table, {event_id, :processed, now})
    :ok
  rescue
    _ -> :ok
  end

  # Server Callbacks for ETS sweep

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  defp sweep_expired do
    cutoff = System.system_time(:second) - @retention_seconds

    match_spec = [
      {{:"$1", :"$2", :"$3"}, [{:<, :"$3", cutoff}], [true]},
      {{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [true]}
    ]

    :ets.select_delete(@table, match_spec)
  rescue
    _ -> 0
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, :timer.hours(1))
  end
end
