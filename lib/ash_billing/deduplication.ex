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
            domain = Keyword.get(opts, :domain)

            attrs = %{
              event_id: event_id,
              processed_at: DateTime.utc_now()
            }

            case Ash.create(resource, attrs, domain: domain, authorize?: false) do
              {:ok, _record} ->
                {:ok, :acquired}

              {:error, reason} ->
                if duplicate_key_error?(reason) do
                  {:error, :already_processed}
                else
                  {:error, reason}
                end
            end
        end

      :memory ->
        acquire_memory(event_id)
    end
  rescue
    e -> {:error, e}
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
        :ok

      :memory ->
        insert_memory(event_id)
    end
  rescue
    _ -> :ok
  end

  @doc """
  Releases an acquired event lease on failure so retries can be processed.
  """
  @spec release(String.t() | nil, keyword()) :: :ok
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

            case Ash.get(resource, event_id, domain: domain, authorize?: false) do
              {:ok, record} when not is_nil(record) ->
                if Ash.Resource.Info.action(resource, :destroy) do
                  Ash.destroy(record, domain: domain, authorize?: false)
                end

                :ok

              _ ->
                :ok
            end
        end

      :memory ->
        delete_memory(event_id)
    end
  rescue
    _ -> :ok
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

            resource
            |> Ash.Query.new()
            |> Ash.Query.filter(event_id == ^event_id)
            |> Ash.exists?(domain: domain, authorize?: false)
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

  defp duplicate_key_error?(%Ash.Error.Invalid{} = error) do
    error_str = inspect(error)

    String.contains?(error_str, "unique") or
      String.contains?(error_str, "already exists") or
      String.contains?(error_str, "already been taken") or
      String.contains?(error_str, "duplicate")
  end

  defp duplicate_key_error?(_), do: false

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
          # If a lease is held longer than 60s without completing, allow reclamation
          if now - inserted_at > 60 do
            :ets.insert(@table, {event_id, :processing, now})
            {:ok, :acquired}
          else
            {:error, :already_processing}
          end

        [{^event_id, _}] ->
          {:error, :already_processed}

        [] ->
          {:ok, :acquired}
      end
    end
  rescue
    _ -> {:ok, :acquired}
  end

  defp delete_memory(event_id) do
    :ets.delete(@table, event_id)
    :ok
  rescue
    _ -> :ok
  end

  defp check_memory(event_id) do
    case :ets.lookup(@table, event_id) do
      [{^event_id, :processed, _}] -> true
      [{^event_id, :processing, _}] -> true
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
