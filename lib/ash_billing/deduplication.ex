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
  * `{:ok, lease_token}` - Lease secured; this process is the exclusive worker for the event.
  * `{:error, :already_processed}` - The event was already processed.
  * `{:error, :already_processing}` - The event is currently being processed by another worker.
  * `{:error, reason}` - Persistence error during acquisition.
  """
  @spec acquire(String.t() | nil, keyword()) ::
          {:ok, String.t()}
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
    token = generate_lease_token()

    attrs =
      %{event_id: event_id}
      |> maybe_put_field(resource, :status, :processing)
      |> maybe_put_field(resource, :last_attempt_at, now)
      |> maybe_put_field(resource, :processed_at, now)
      |> maybe_put_field(resource, :attempts, 1)
      |> maybe_put_field(resource, :lease_token, token)

    case Ash.create(resource, attrs, domain: domain, authorize?: false) do
      {:ok, _record} ->
        {:ok, token}

      {:error, reason} ->
        if duplicate_key_error?(reason) do
          reclaim_atomic_resource_lease(resource, event_id, domain, now, lease_ttl, token)
        else
          {:error, reason}
        end
    end
  end

  defp reclaim_atomic_resource_lease(resource, event_id, domain, now, lease_ttl, token) do
    lock_key = {:reclaim_lock, event_id}

    if try_acquire_lock(lock_key) do
      try do
        do_reclaim_atomic_resource_lease(resource, event_id, domain, now, lease_ttl, token)
      after
        release_lock(lock_key)
      end
    else
      {:error, :already_processing}
    end
  end

  defp try_acquire_lock(lock_key) do
    :ets.insert_new(@table, {lock_key, self()})
  rescue
    _ -> true
  end

  defp release_lock(lock_key) do
    :ets.delete(@table, lock_key)
  rescue
    _ -> :ok
  end

  defp do_reclaim_atomic_resource_lease(resource, event_id, domain, now, lease_ttl, token) do
    has_status? = Ash.Resource.Info.attribute(resource, :status) != nil

    if has_status? do
      case Ash.get(resource, event_id, domain: domain, authorize?: false) do
        {:ok, record} when not is_nil(record) ->
          case Map.get(record, :status) do
            :processed ->
              {:error, :already_processed}

            :processing ->
              attempt_dt = Map.get(record, :last_attempt_at) || Map.get(record, :processed_at)

              if attempt_dt && DateTime.diff(now, attempt_dt, :second) <= lease_ttl do
                {:error, :already_processing}
              else
                perform_atomic_reclaim(
                  resource,
                  event_id,
                  domain,
                  now,
                  lease_ttl,
                  token,
                  record
                )
              end

            _failed ->
              perform_atomic_reclaim(resource, event_id, domain, now, lease_ttl, token, record)
          end

        _ ->
          {:error, :already_processing}
      end
    else
      {:error, :already_processed}
    end
  end

  defp perform_atomic_reclaim(resource, event_id, domain, now, lease_ttl, token, record) do
    if Ash.Resource.Info.action(resource, :update) do
      cutoff = DateTime.add(now, -lease_ttl, :second)
      require Ash.Query

      # Atomic conditional filter: ensure record is still :failed or expired :processing during the write
      query =
        resource
        |> Ash.Query.filter(
          event_id == ^event_id and
            (status == :failed or
               (status == :processing and
                  ((not is_nil(last_attempt_at) and last_attempt_at < ^cutoff) or
                     (is_nil(last_attempt_at) and not is_nil(processed_at) and
                        processed_at < ^cutoff))))
        )

      current_attempts = Map.get(record, :attempts) || 1

      update_attrs =
        %{status: :processing, last_attempt_at: now, error: nil}
        |> maybe_put_field(resource, :lease_token, token)
        |> maybe_put_field(resource, :attempts, current_attempts + 1)

      case Ash.bulk_update(query, :update, update_attrs,
             domain: domain,
             authorize?: false,
             strategy: [:atomic],
             return_records?: true,
             return_errors?: true
           ) do
        %Ash.BulkResult{status: :success, records: [_updated | _]} ->
          {:ok, token}

        %Ash.BulkResult{status: :success, records: []} ->
          # Another concurrent worker acquired it first or marked it processed
          case Ash.get(resource, event_id, domain: domain, authorize?: false) do
            {:ok, %{status: :processed}} -> {:error, :already_processed}
            _ -> {:error, :already_processing}
          end

        %Ash.BulkResult{errors: [err | _]} ->
          {:error, err}

        {:error, reason} ->
          {:error, reason}
      end
    else
      if Ash.Resource.Info.action(resource, :destroy) do
        _ = Ash.destroy(record, domain: domain, authorize?: false)
      end

      {:ok, token}
    end
  end

  defp maybe_put_field(attrs, resource, field, value) do
    if Ash.Resource.Info.attribute(resource, field) != nil do
      Map.put(attrs, field, value)
    else
      attrs
    end
  end

  defp generate_lease_token do
    "lt_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  @doc """
  Completes processing for an acquired event lease.

  Returns `:ok` if successfully marked as `:processed`, or `{:error, reason}` on failure.
  """
  @spec complete(String.t() | nil, keyword()) :: :ok | {:error, term()}
  def complete(event_id, opts \\ [])
  def complete(nil, _opts), do: :ok

  def complete(event_id, opts) when is_binary(event_id) do
    case resolve_strategy(opts) do
      :resource ->
        case resolve_resource(opts) do
          nil ->
            complete_memory(event_id, opts)

          resource ->
            complete_resource(resource, event_id, opts)
        end

      :memory ->
        complete_memory(event_id, opts)
    end
  rescue
    e -> {:error, e}
  end

  defp complete_resource(resource, event_id, opts) do
    has_status? = Ash.Resource.Info.attribute(resource, :status) != nil
    has_update? = Ash.Resource.Info.action(resource, :update) != nil

    if has_status? and has_update? do
      domain = Keyword.get(opts, :domain)
      now = DateTime.utc_now()
      lease_token = Keyword.get(opts, :lease_token)
      require Ash.Query

      query =
        if lease_token do
          resource
          |> Ash.Query.filter(
            event_id == ^event_id and status == :processing and lease_token == ^lease_token
          )
        else
          resource
          |> Ash.Query.filter(event_id == ^event_id and status == :processing)
        end

      update_attrs =
        %{status: :processed, error: nil}
        |> maybe_put_field(resource, :processed_at, now)

      case Ash.bulk_update(query, :update, update_attrs,
             domain: domain,
             authorize?: false,
             strategy: [:atomic],
             return_records?: true,
             return_errors?: true
           ) do
        %Ash.BulkResult{status: :success, records: [_updated | _]} ->
          :ok

        %Ash.BulkResult{status: :success, records: []} ->
          case Ash.get(resource, event_id, domain: domain, authorize?: false) do
            {:ok, record} when not is_nil(record) ->
              cond do
                Map.get(record, :status) == :processed ->
                  :ok

                lease_token != nil and Map.get(record, :lease_token) != nil and
                    Map.get(record, :lease_token) != lease_token ->
                  {:error, :lease_token_mismatch}

                true ->
                  {:error, :lease_not_acquired}
              end

            {:error, reason} ->
              if not_found_error?(reason) do
                {:error, :not_found}
              else
                {:error, reason}
              end

            _ ->
              {:error, :not_found}
          end

        %Ash.BulkResult{errors: [err | _]} ->
          require Logger

          Logger.error(
            "AshBilling.Deduplication: Failed to mark event #{inspect(event_id)} as :processed: #{inspect(err)}"
          )

          {:error, err}

        {:error, reason} ->
          require Logger

          Logger.error(
            "AshBilling.Deduplication: Failed to mark event #{inspect(event_id)} as :processed: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      :ok
    end
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
            delete_memory(event_id, opts)

          resource ->
            release_resource(resource, event_id, opts)
        end

      :memory ->
        delete_memory(event_id, opts)
    end
  rescue
    e -> {:error, e}
  end

  defp release_resource(resource, event_id, opts) do
    has_status? = Ash.Resource.Info.attribute(resource, :status) != nil
    has_update? = Ash.Resource.Info.action(resource, :update) != nil

    cond do
      has_status? and has_update? ->
        domain = Keyword.get(opts, :domain)
        err_msg = Keyword.get(opts, :error)
        lease_token = Keyword.get(opts, :lease_token)
        require Ash.Query

        query =
          if lease_token do
            resource
            |> Ash.Query.filter(
              event_id == ^event_id and status == :processing and lease_token == ^lease_token
            )
          else
            resource
            |> Ash.Query.filter(event_id == ^event_id)
          end

        update_attrs = %{
          status: :failed,
          error: if(err_msg, do: String.slice(inspect(err_msg), 0, 500), else: nil)
        }

        case Ash.bulk_update(query, :update, update_attrs,
               domain: domain,
               authorize?: false,
               strategy: [:atomic],
               return_records?: true,
               return_errors?: true
             ) do
          %Ash.BulkResult{status: :success, records: [_updated | _]} ->
            :ok

          %Ash.BulkResult{status: :success, records: []} ->
            case Ash.get(resource, event_id, domain: domain, authorize?: false) do
              {:ok, record} when not is_nil(record) ->
                cond do
                  Map.get(record, :status) == :failed ->
                    :ok

                  lease_token != nil and Map.get(record, :lease_token) != nil and
                      Map.get(record, :lease_token) != lease_token ->
                    {:error, :lease_token_mismatch}

                  true ->
                    {:error, :lease_not_acquired}
                end

              {:error, reason} ->
                if not_found_error?(reason) do
                  :ok
                else
                  {:error, reason}
                end

              _ ->
                :ok
            end

          %Ash.BulkResult{errors: [err | _]} ->
            atomic_bulk_destroy(resource, event_id, lease_token, domain, err)

          {:error, reason} ->
            atomic_bulk_destroy(resource, event_id, lease_token, domain, reason)
        end

      Ash.Resource.Info.action(resource, :destroy) != nil ->
        domain = Keyword.get(opts, :domain)
        lease_token = Keyword.get(opts, :lease_token)
        atomic_bulk_destroy(resource, event_id, lease_token, domain, :cannot_release_lease)

      true ->
        {:error, :cannot_release_lease}
    end
  end

  defp atomic_bulk_destroy(resource, event_id, lease_token, domain, default_err) do
    if Ash.Resource.Info.action(resource, :destroy) != nil do
      require Ash.Query
      has_status? = Ash.Resource.Info.attribute(resource, :status) != nil

      query =
        if lease_token && has_status? do
          resource
          |> Ash.Query.filter(
            event_id == ^event_id and status == :processing and lease_token == ^lease_token
          )
        else
          resource
          |> Ash.Query.filter(event_id == ^event_id)
        end

      case Ash.bulk_destroy(query, :destroy, %{},
             domain: domain,
             authorize?: false,
             strategy: [:atomic],
             return_records?: true,
             return_errors?: true
           ) do
        %Ash.BulkResult{status: :success, records: [_destroyed | _]} ->
          :ok

        %Ash.BulkResult{status: :success, records: []} ->
          case Ash.get(resource, event_id, domain: domain, authorize?: false) do
            {:ok, record} when not is_nil(record) ->
              if lease_token != nil and Map.get(record, :lease_token) != nil and
                   Map.get(record, :lease_token) != lease_token do
                {:error, :lease_token_mismatch}
              else
                :ok
              end

            _ ->
              :ok
          end

        _ ->
          {:error, default_err}
      end
    else
      {:error, default_err}
    end
  end

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found_error?(_), do: false

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
      {:ok, lease_token} ->
        complete(event_id, [lease_token: lease_token] ++ opts)

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

  defp acquire_memory(event_id, token \\ nil) do
    token = token || generate_lease_token()
    now = System.system_time(:second)

    if :ets.insert_new(@table, {event_id, :processing, now, token}) do
      {:ok, token}
    else
      case :ets.lookup(@table, event_id) do
        [{^event_id, :processed, _, _}] ->
          {:error, :already_processed}

        [{^event_id, :processed, _}] ->
          {:error, :already_processed}

        [{^event_id, :processing, inserted_at, _current_token}] ->
          # If a lease is held longer than 60s without completing, allow atomic reclamation
          if now - inserted_at > 60 do
            ms = [
              {
                {event_id, :processing, :"$1", :_},
                [{:>, {:-, now, :"$1"}, 60}],
                [{:const, {event_id, :processing, now, token}}]
              }
            ]

            if :ets.select_replace(@table, ms) == 1 do
              {:ok, token}
            else
              {:error, :already_processing}
            end
          else
            {:error, :already_processing}
          end

        [{^event_id, :processing, inserted_at}] ->
          if now - inserted_at > 60 do
            ms = [
              {
                {event_id, :processing, :"$1"},
                [{:>, {:-, now, :"$1"}, 60}],
                [{:const, {event_id, :processing, now, token}}]
              }
            ]

            if :ets.select_replace(@table, ms) == 1 do
              {:ok, token}
            else
              {:error, :already_processing}
            end
          else
            {:error, :already_processing}
          end

        [{^event_id, :failed, _, _}] ->
          # Previous attempt failed; atomically reclaim for retry
          ms = [
            {
              {event_id, :failed, :_, :_},
              [],
              [{:const, {event_id, :processing, now, token}}]
            }
          ]

          if :ets.select_replace(@table, ms) == 1 do
            {:ok, token}
          else
            acquire_memory(event_id, token)
          end

        [{^event_id, :failed, _}] ->
          ms = [
            {
              {event_id, :failed, :_},
              [],
              [{:const, {event_id, :processing, now, token}}]
            }
          ]

          if :ets.select_replace(@table, ms) == 1 do
            {:ok, token}
          else
            acquire_memory(event_id, token)
          end

        [{^event_id, _}] ->
          {:error, :already_processed}

        [] ->
          acquire_memory(event_id, token)
      end
    end
  rescue
    e -> {:error, {:ets_error, e}}
  end

  defp complete_memory(event_id, opts) do
    lease_token = Keyword.get(opts, :lease_token)
    now = System.system_time(:second)

    ms =
      if lease_token do
        [
          {
            {event_id, :processing, :_, lease_token},
            [],
            [{:const, {event_id, :processed, now, lease_token}}]
          },
          {
            {event_id, :processing, :_},
            [],
            [{:const, {event_id, :processed, now, lease_token}}]
          }
        ]
      else
        [
          {
            {event_id, :processing, :_, :"$1"},
            [],
            [{:const, {event_id, :processed, now, :"$1"}}]
          },
          {
            {event_id, :processing, :_},
            [],
            [{:const, {event_id, :processed, now, nil}}]
          }
        ]
      end

    if :ets.select_replace(@table, ms) == 1 do
      :ok
    else
      case :ets.lookup(@table, event_id) do
        [{^event_id, :processed, _, _}] ->
          :ok

        [{^event_id, :processed, _}] ->
          :ok

        [{^event_id, :processing, _, current_token}] ->
          if lease_token != nil and current_token != lease_token do
            {:error, :lease_token_mismatch}
          else
            {:error, :lease_not_acquired}
          end

        [{^event_id, :failed, _, _}] ->
          {:error, :lease_failed}

        [{^event_id, :failed, _}] ->
          {:error, :lease_failed}

        [] ->
          :ets.insert(@table, {event_id, :processed, now, lease_token})
          :ok

        _ ->
          :ok
      end
    end
  rescue
    e -> {:error, {:ets_error, e}}
  end

  defp delete_memory(event_id, opts) do
    lease_token = Keyword.get(opts, :lease_token)
    now = System.system_time(:second)

    ms =
      if lease_token do
        [
          {
            {event_id, :processing, :_, lease_token},
            [],
            [{:const, {event_id, :failed, now, lease_token}}]
          },
          {
            {event_id, :processing, :_},
            [],
            [{:const, {event_id, :failed, now, lease_token}}]
          }
        ]
      else
        [
          {
            {event_id, :_, :_, :_},
            [],
            [{:const, {event_id, :failed, now, nil}}]
          },
          {
            {event_id, :_, :_},
            [],
            [{:const, {event_id, :failed, now, nil}}]
          },
          {
            {event_id, :_},
            [],
            [{:const, {event_id, :failed, now, nil}}]
          }
        ]
      end

    if :ets.select_replace(@table, ms) >= 1 do
      :ok
    else
      case :ets.lookup(@table, event_id) do
        [{^event_id, :processing, _, current_token}] ->
          if lease_token != nil and current_token != lease_token do
            {:error, :lease_token_mismatch}
          else
            {:error, :lease_not_acquired}
          end

        [{^event_id, :failed, _, _}] ->
          :ok

        [{^event_id, :failed, _}] ->
          :ok

        [{^event_id, :processed, _, _}] ->
          if lease_token == nil do
            :ets.insert(@table, {event_id, :failed, now, nil})
            :ok
          else
            :ok
          end

        [{^event_id, :processed, _}] ->
          if lease_token == nil do
            :ets.insert(@table, {event_id, :failed, now, nil})
            :ok
          else
            :ok
          end

        [] ->
          :ok

        _ ->
          :ok
      end
    end
  rescue
    e -> {:error, {:ets_error, e}}
  end

  defp check_memory(event_id) do
    case :ets.lookup(@table, event_id) do
      [{^event_id, :processed, _, _}] -> true
      [{^event_id, :processed, _}] -> true
      [{^event_id, :processing, _, _}] -> false
      [{^event_id, :processing, _}] -> false
      [{^event_id, :failed, _, _}] -> false
      [{^event_id, :failed, _}] -> false
      [{^event_id, _timestamp}] -> true
      [] -> false
    end
  rescue
    _ -> false
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
      {{:"$1", :"$2", :"$3", :"$4"}, [{:<, :"$3", cutoff}], [true]},
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
