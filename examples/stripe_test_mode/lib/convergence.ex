defmodule AshBillingConsumer.Convergence do
  @moduledoc false

  # The reader must reload SQL and the actor on every attempt. Only local reads
  # are retried: provider mutations must never be repeated by this wait loop.
  def await(remote, expected_authorization, read_snapshot, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 15_000)
    interval = Keyword.get(opts, :interval, 100)
    expected = subscription_fields(remote)
    poll(expected, expected_authorization, read_snapshot, deadline, interval)
  end

  def subscription_fields(object) do
    item = get_in(object, ["items", "data"]) || []

    case item do
      [%{"price" => %{"id" => price}, "quantity" => quantity}] ->
        %{
          id: object["id"],
          status: object["status"],
          price: price,
          quantity: quantity,
          cancel_at_period_end: object["cancel_at_period_end"]
        }

      _ ->
        nil
    end
  end

  defp poll(expected, authorization, read_snapshot, deadline, interval) do
    snapshot = read_snapshot.()

    cond do
      matches?(snapshot, expected, authorization) ->
        {:ok, snapshot}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :subscription_not_converged}

      true ->
        remaining = deadline - System.monotonic_time(:millisecond)
        Process.sleep(max(0, min(interval, remaining)))
        poll(expected, authorization, read_snapshot, deadline, interval)
    end
  end

  defp matches?(_snapshot, nil, _authorization), do: false

  defp matches?(snapshot, expected, authorization) do
    local =
      Enum.find(snapshot.subscriptions, fn sub ->
        sub.provider_subscription_id == expected.id
      end)

    expected_canceling = expected.status == "active" and expected.cancel_at_period_end == true

    not is_nil(local) and
      to_string(local.status) == expected.status and
      local.price_id == expected.price and
      local.cancel_at_period_end === expected.cancel_at_period_end and
      snapshot.canceling === expected_canceling and
      snapshot.authorization == authorization and
      expected in snapshot.processed_subscription_snapshots
  end
end
