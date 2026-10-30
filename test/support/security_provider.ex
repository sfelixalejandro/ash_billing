defmodule AshBilling.Test.SecurityProvider do
  @moduledoc false

  def start_repo do
    {:ok, pid} = AshBilling.Test.Repo.start_link()
    Process.unlink(pid)
    {:ok, pid}
  end

  def start_call(module, function, args) do
    owner = self()

    worker =
      spawn(fn ->
        AshBilling.Test.Repo.checkout(fn ->
          %{rows: [[backend]]} =
            Ecto.Adapters.SQL.query!(AshBilling.Test.Repo, "SELECT pg_backend_pid()", [])

          send(owner, {:ready, self(), backend})

          receive do
            :go -> :ok
          end

          result = apply(module, function, args)

          receive do
            {:result, receiver} -> send(receiver, {:result, self(), result})
          after
            5000 -> :ok
          end
        end)
      end)

    receive do
      {:ready, ^worker, backend} -> {worker, backend}
    after
      5000 -> raise "remote database worker did not start"
    end
  end

  def finish_call(worker) do
    send(worker, {:result, self()})

    receive do
      {:result, ^worker, result} -> result
    after
      5000 -> raise "remote database worker did not finish"
    end
  end

  def get_subscription(_id, opts), do: {:ok, Keyword.fetch!(opts, :snapshot)}
end
