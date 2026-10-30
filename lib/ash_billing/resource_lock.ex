defmodule AshBilling.ResourceLock do
  @moduledoc false

  # Local locks are only a single-node fallback for nontransactional data layers.
  # PostgreSQL correctness comes from transactions and FOR UPDATE reads, not :global.
  def run(resources, key, fun) do
    resources = Enum.reject(resources, &is_nil/1) |> Enum.uniq()
    transactional = Enum.filter(resources, &Ash.DataLayer.data_layer_can?(&1, :transact))

    transaction = fn ->
      case Ash.DataLayer.transaction(transactional, fun) do
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
