defmodule AshBilling.PostgresSubscriptionTest do
  use ExUnit.Case, async: false

  alias AshBilling.Test.{PostgresCustomer, PostgresDomain, PostgresSubscription, Repo}
  alias AshBilling.WebhookSync

  @opts [domain: PostgresDomain, authorize?: false]
  @sync_opts @opts ++
               [customer_resource: PostgresCustomer, subscription_resource: PostgresSubscription]

  defmodule PendingProvider do
    def get_subscription(id, opts) do
      send(opts[:test_owner], {:reconciling, self(), id})

      receive do
        {:provider_reply, result} -> result
      after
        5000 -> {:error, :test_provider_timeout}
      end
    end
  end

  setup do
    assert Application.get_env(:ash_billing, :postgres_available),
           "PostgreSQL required for these regressions"

    Ecto.Adapters.SQL.query!(Repo, "TRUNCATE billing_test_subscriptions, billing_test_customers")
    user = Ash.create!(PostgresCustomer, %{stripe_customer_id: "cus_pg"}, @opts)
    %{user: user}
  end

  defp event(id, status, timestamp, price \\ "price_new") do
    %{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => "customer.subscription.updated",
      "created" => timestamp,
      "data" => %{
        "object" => %{
          "id" => id,
          "customer" => "cus_pg",
          "status" => status,
          "items" => %{"data" => [%{"price" => %{"id" => price}}]}
        }
      }
    }
  end

  test "pending reconciliation cannot overwrite a terminal commit at the same timestamp", %{
    user: user
  } do
    for terminal <- [:canceled, :incomplete_expired] do
      id = "sub_race_#{terminal}"

      sub =
        Ash.create!(
          PostgresSubscription,
          %{
            provider_subscription_id: id,
            status: :past_due,
            price_id: "price_old",
            user_id: user.id,
            last_event_created_at: DateTime.from_unix!(1_700_000_000)
          },
          @opts
        )

      owner = self()

      task =
        Task.async(fn ->
          WebhookSync.sync_event(
            event(id, "active", 1_700_000_001),
            [provider: PendingProvider, test_owner: owner] ++ @sync_opts
          )
        end)

      assert_receive {:reconciling, worker, ^id}, 2000

      Ash.update!(
        sub,
        %{status: terminal, last_event_created_at: DateTime.from_unix!(1_700_000_001)},
        @opts
      )

      send(worker, {:provider_reply, {:ok, event(id, "active", 1_700_000_001)["data"]["object"]}})
      assert {:ok, result} = Task.await(task)
      assert result.status == terminal
      persisted = Ash.get!(PostgresSubscription, sub.id, @opts)
      assert persisted.status == terminal
      refute AshBilling.subscribed?(%{subscriptions: [persisted]})
    end
  end

  test "Stripe terminal event takes precedence over a same-second nonterminal snapshot", %{
    user: user
  } do
    id = "sub_terminal_precedence"

    sub =
      Ash.create!(
        PostgresSubscription,
        %{
          provider_subscription_id: id,
          status: :active,
          user_id: user.id,
          price_id: "price_old",
          last_event_created_at: DateTime.from_unix!(1_700_000_000)
        },
        @opts
      )

    assert {:ok, result} =
             WebhookSync.sync_event(event(id, "canceled", 1_700_000_000), @sync_opts)

    assert result.status == :canceled
    assert Ash.get!(PostgresSubscription, sub.id, @opts).status == :canceled
  end

  test "custom provider can deliberately transition a previously read terminal state", %{
    user: user
  } do
    id = "sub_custom_reactivation"

    Ash.create!(
      PostgresSubscription,
      %{
        provider_subscription_id: id,
        status: :canceled,
        user_id: user.id,
        last_event_created_at: DateTime.from_unix!(1_700_000_000)
      },
      @opts
    )

    assert {:ok, result} =
             WebhookSync.sync_event(
               event(id, "active", 1_700_000_001),
               [provider: PendingProvider] ++ @sync_opts
             )

    assert result.status == :active
  end

  test "atomic state guard also protects events without timestamps and retries nonterminal races",
       %{user: user} do
    sub =
      Ash.create!(
        PostgresSubscription,
        %{provider_subscription_id: "sub_no_timestamp", status: :active, user_id: user.id},
        @opts
      )

    Ash.update!(sub, %{status: :past_due}, @opts)

    assert {:error, :subscription_changed_concurrently} =
             WebhookSync.update_subscription_safely(
               PostgresSubscription,
               sub,
               %{status: :active},
               nil,
               @opts
             )

    Ash.update!(sub, %{status: :canceled}, @opts)

    assert {:ok, result} =
             WebhookSync.update_subscription_safely(
               PostgresSubscription,
               sub,
               %{status: :active},
               nil,
               @opts
             )

    assert result.status == :canceled
  end

  test "a new subscription after cancellation is a separate record", %{user: user} do
    assert {:ok, old} =
             WebhookSync.sync_event(event("sub_old", "canceled", 1_700_000_000), @sync_opts)

    assert {:ok, new} =
             WebhookSync.sync_event(event("sub_new", "active", 1_700_000_001), @sync_opts)

    assert old.id != new.id
    assert new.user_id == user.id
    assert new.status == :active
  end
end
