defmodule AshBillingConsumer.ConvergenceTest do
  use ExUnit.Case, async: true
  alias AshBillingConsumer.Convergence

  defp remote(status \\ "active", canceling \\ false) do
    %{
      "id" => "sub_fixture",
      "status" => status,
      "cancel_at_period_end" => canceling,
      "items" => %{"data" => [%{"price" => %{"id" => "price_fixture"}, "quantity" => 20}]}
    }
  end

  defp authorization, do: %{subscribed: true, has_price: true, wrong_price: false}

  defp snapshot(object) do
    %{
      subscriptions: [
        %{
          provider_subscription_id: object["id"],
          status: if(object["status"] == "canceled", do: :canceled, else: :active),
          price_id: "price_fixture",
          cancel_at_period_end: object["cancel_at_period_end"]
        }
      ],
      authorization: authorization(),
      canceling: object["cancel_at_period_end"],
      processed_subscription_snapshots: [Convergence.subscription_fields(object)]
    }
  end

  defp wait(object, snapshot) do
    Convergence.await(object, authorization(), fn -> snapshot end, timeout: 0)
  end

  test "passes only after a processed snapshot, local state and policies agree" do
    object = remote()
    state = snapshot(object)
    assert {:ok, ^state} = wait(object, state)
  end

  test "a missing webhook cannot pass even when local state already matches" do
    object = remote()

    assert {:error, :subscription_not_converged} =
             wait(object, %{snapshot(object) | processed_subscription_snapshots: []})
  end

  test "quantity changes require a processed snapshot with the new quantity" do
    old = remote()
    changed = put_in(old, ["items", "data", Access.at(0), "quantity"], 10)
    assert {:error, :subscription_not_converged} = wait(changed, snapshot(old))
  end

  test "a processed event does not conceal stale PostgreSQL price" do
    object = remote()
    stale = put_in(snapshot(object), [:subscriptions, Access.at(0), :price_id], "price_old")
    assert {:error, :subscription_not_converged} = wait(object, stale)
  end

  test "a processed cancellation cannot pass while local subscription is active" do
    object = remote("canceled")
    stale = snapshot(object) |> put_in([:subscriptions, Access.at(0), :status], :active)
    revoked = %{subscribed: false, has_price: false, wrong_price: false}

    assert {:error, :subscription_not_converged} =
             Convergence.await(object, revoked, fn -> %{stale | authorization: revoked} end,
               timeout: 0
             )
  end

  test "cancellation cannot pass while actor policies still allow access" do
    object = remote("canceled")
    revoked = %{subscribed: false, has_price: false, wrong_price: false}

    assert {:error, :subscription_not_converged} =
             Convergence.await(object, revoked, fn -> snapshot(object) end, timeout: 0)
  end

  test "terminal state passes only with revoked access" do
    object = remote("canceled")
    revoked = %{subscribed: false, has_price: false, wrong_price: false}
    state = %{snapshot(object) | authorization: revoked}

    assert {:ok, ^state} =
             Convergence.await(object, revoked, fn -> state end, timeout: 0)
  end

  test "a different plan requires the original-price policy to deny" do
    object = put_in(remote(), ["items", "data", Access.at(0), "price", "id"], "price_other")
    allowed = %{subscribed: true, has_price: false, wrong_price: false}

    state =
      snapshot(object)
      |> put_in([:subscriptions, Access.at(0), :price_id], "price_other")
      |> Map.put(:authorization, allowed)

    assert {:ok, ^state} =
             Convergence.await(object, allowed, fn -> state end, timeout: 0)

    assert {:error, :subscription_not_converged} =
             Convergence.await(
               object,
               allowed,
               fn -> %{state | authorization: authorization()} end,
               timeout: 0
             )
  end

  test "wrong-price authorization fails closed" do
    object = remote()

    assert {:error, :subscription_not_converged} =
             wait(object, put_in(snapshot(object), [:authorization, :wrong_price], true))
  end

  test "scheduled cancellation requires the local flag and canceling check" do
    object = remote("active", true)
    assert {:ok, _} = wait(object, snapshot(object))

    assert {:error, :subscription_not_converged} =
             wait(object, %{snapshot(object) | canceling: false})

    stale = put_in(snapshot(object), [:subscriptions, Access.at(0), :cancel_at_period_end], false)
    assert {:error, :subscription_not_converged} = wait(object, stale)
  end

  test "missing local subscription and unexpected provider shape cannot pass" do
    object = remote()

    assert {:error, :subscription_not_converged} =
             wait(object, %{snapshot(object) | subscriptions: []})

    assert {:error, :subscription_not_converged} = wait(%{}, snapshot(object))
  end

  test "wait reloads until convergence without repeating a mutation" do
    object = remote()
    state = snapshot(object)
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    reader = fn ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> %{state | subscriptions: []}
        _ -> state
      end
    end

    assert {:ok, ^state} =
             Convergence.await(object, authorization(), reader, timeout: 500, interval: 1)

    assert Agent.get(counter, & &1) == 2
  end

  test "non-convergence expires instead of returning PASS" do
    object = remote()
    started = System.monotonic_time(:millisecond)

    assert {:error, :subscription_not_converged} =
             Convergence.await(
               object,
               authorization(),
               fn -> %{snapshot(object) | subscriptions: []} end,
               timeout: 10,
               interval: 1
             )

    assert System.monotonic_time(:millisecond) - started >= 10
  end
end
