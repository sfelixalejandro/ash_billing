defmodule AshBilling.ResourceLock do
  @moduledoc false

  # Local locks are only a single-node fallback for nontransactional data layers.
  # PostgreSQL correctness comes from transactions and FOR UPDATE reads, not :global.
  def run(resources, key, fun, opts \\ []) do
    resources = Enum.reject(resources, &is_nil/1) |> Enum.uniq()
    transactional = Enum.filter(resources, &Ash.DataLayer.data_layer_can?(&1, :transact))

    with :ok <- validate_repos(resources) do
      transaction = fn ->
        case Ash.DataLayer.transaction(
               transactional,
               fun,
               nil,
               %{type: :custom, metadata: %{}},
               opts
             ) do
          {:ok, result} -> result
          {:error, reason} -> {:error, reason}
        end
      end

      lockable? = Enum.all?(resources, &Ash.DataLayer.data_layer_can?(&1, {:lock, :for_update}))

      if lockable? and length(transactional) == length(resources) and resources != [] do
        transaction.()
      else
        local(key, transaction)
      end
    end
  catch
    :error, %{__struct__: module} = error
    when module in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, {:transaction_failed, error}}
  end

  # HTTP adapters cannot defer a sent response to a caller-owned transaction.
  def http_boundary(resources) do
    resources = Enum.reject(resources, &is_nil/1) |> Enum.uniq()

    with :ok <- validate_repos(resources) do
      if external_ecto_transaction?() or Enum.any?(resources, &Ash.DataLayer.in_transaction?/1),
        do: {:error, :external_transaction},
        else: :ok
    end
  end

  defp external_ecto_transaction? do
    if Code.ensure_loaded?(Ecto.Repo) and Process.whereis(Ecto.Repo.Registry) do
      Ecto.Repo
      |> apply(:all_running, [])
      |> Enum.any?(fn repo ->
        %{adapter: adapter} = meta = apply(Ecto.Adapter, :lookup_meta, [repo])

        function_exported?(adapter, :in_transaction?, 1) and
          apply(adapter, :in_transaction?, [meta])
      end)
    else
      false
    end
  end

  defp validate_repos(resources) do
    repos =
      resources
      |> Enum.filter(&(Ash.DataLayer.data_layer(&1) == AshPostgres.DataLayer))
      |> Enum.map(fn resource ->
        repo = apply(AshPostgres.DataLayer.Info, :repo, [resource, :mutate])
        apply(repo, :get_dynamic_repo, [])
      end)
      |> Enum.uniq()

    if length(repos) > 1, do: {:error, {:multiple_transaction_repos, repos}}, else: :ok
  end

  # :global monitors the owning process. Track reentrancy so an inner
  # operation cannot release its caller's fence prematurely.
  def local(key, fun) do
    marker = {__MODULE__, :held, key}

    if Process.get(marker) do
      fun.()
    else
      :global.trans(
        {{__MODULE__, key}, self()},
        fn ->
          Process.put(marker, true)

          try do
            fun.()
          after
            Process.delete(marker)
          end
        end,
        [node()]
      )
    end
  end

  def try_local(key, fun) do
    marker = {__MODULE__, :held, key}
    lock = {{__MODULE__, key}, self()}

    cond do
      Process.get(marker) ->
        fun.()

      :global.set_lock(lock, [node()], 0) ->
        Process.put(marker, true)

        try do
          fun.()
        after
          Process.delete(marker)
          :global.del_lock(lock, [node()])
        end

      true ->
        {:error, :already_processing}
    end
  end

  def query(query) do
    query = Ash.Query.new(query)

    if Ash.DataLayer.data_layer_can?(query.resource, {:lock, :for_update}) and
         Ash.DataLayer.in_transaction?(query.resource) do
      Ash.Query.lock(query, :for_update)
    else
      query
    end
  end
end
