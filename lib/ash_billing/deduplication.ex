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
  Marks an event ID as processed.
  """
  @spec mark_processed(String.t() | nil, keyword()) :: :ok
  def mark_processed(event_id, opts \\ [])
  def mark_processed(nil, _opts), do: :ok

  def mark_processed(event_id, opts) when is_binary(event_id) do
    case resolve_strategy(opts) do
      :resource ->
        case resolve_resource(opts) do
          nil ->
            insert_memory(event_id)

          resource ->
            domain = Keyword.get(opts, :domain)

            attrs = %{
              event_id: event_id,
              processed_at: DateTime.utc_now()
            }

            Ash.create(resource, attrs, domain: domain, authorize?: false)
            :ok
        end

      :memory ->
        insert_memory(event_id)
    end
  rescue
    _ -> :ok
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

  defp check_memory(event_id) do
    case :ets.lookup(@table, event_id) do
      [{^event_id, _timestamp}] -> true
      [] -> false
    end
  rescue
    _ -> false
  end

  defp insert_memory(event_id) do
    now = System.system_time(:second)
    :ets.insert(@table, {event_id, now})
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
    match_spec = [{{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [true]}]
    :ets.select_delete(@table, match_spec)
  rescue
    _ -> 0
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, :timer.hours(1))
  end
end
