defmodule AshBilling.Deduplication do
  @moduledoc """
  In-memory ETS-backed deduplication store for billing webhook events.

  Prevents double-processing when Stripe or other providers retry webhook deliveries.
  """

  use GenServer

  @table :ash_billing_processed_events
  @retention_seconds 86_400

  @doc """
  Starts the deduplication server and initializes the ETS table.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if an event ID has already been processed.
  """
  @spec processed?(String.t() | nil) :: boolean()
  def processed?(nil), do: false

  def processed?(event_id) when is_binary(event_id) do
    case :ets.lookup(@table, event_id) do
      [{^event_id, _timestamp}] -> true
      [] -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Marks an event ID as processed.
  """
  @spec mark_processed(String.t() | nil) :: :ok
  def mark_processed(nil), do: :ok

  def mark_processed(event_id) when is_binary(event_id) do
    now = System.system_time(:second)
    :ets.insert(@table, {event_id, now})
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Clears all tracked events (useful in tests).
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    _ -> :ok
  end

  # Server Callbacks

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
