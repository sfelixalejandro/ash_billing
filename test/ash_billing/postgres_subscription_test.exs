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

  test "contradictory metadata never grants access to another customer's user", %{user: user} do
    incoming = event("sub_wrong_customer", "active", 1_700_000_001)
    incoming = put_in(incoming, ["data", "object", "customer"], "cus_other")
    incoming = put_in(incoming, ["data", "object", "metadata"], %{"resource_id" => user.id})
    assert {:error, :customer_identity_conflict} = WebhookSync.sync_event(incoming, @sync_opts)
    assert Ash.read!(PostgresSubscription, @opts) == []
    loaded = Ash.load!(user, :subscriptions, @opts)
    refute AshBilling.subscribed?(loaded)
    refute AshBilling.Checks.Subscribed.match?(loaded, %{domain: PostgresDomain}, [])
  end

  test "initial metadata association is atomic under competing customers" do
    user = Ash.create!(PostgresCustomer, %{email: "initial@example.invalid"}, @opts)
    owner = self()

    tasks =
      for customer <- ["cus_initial_a", "cus_initial_b"] do
        Task.async(fn ->
          send(owner, {:ready, self()})

          receive do
            :go -> :ok
          end

          incoming = event("sub_#{customer}", "active", 1_700_000_001)
          incoming = put_in(incoming, ["data", "object", "customer"], customer)
          incoming = put_in(incoming, ["data", "object", "metadata"], %{"resource_id" => user.id})
          {customer, WebhookSync.sync_event(incoming, @sync_opts)}
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, _}, 2000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks)
    assert Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end) == 1
    assert Enum.count(results, fn {_, r} -> r == {:error, :customer_identity_conflict} end) == 1
    persisted = Ash.get!(PostgresCustomer, user.id, @opts)
    [sub] = Ash.read!(PostgresSubscription, @opts)

    assert Enum.any?(results, fn
             {customer_id, {:ok, result}} ->
               customer_id == persisted.stripe_customer_id and result.id == sub.id

             _ ->
               false
           end)
  end

  test "unknown metadata is retryable and can succeed after the correct association exists" do
    id = Ash.UUID.generate()
    incoming = event("sub_recover_identity", "active", 1_700_000_001)
    incoming = put_in(incoming, ["data", "object", "customer"], "cus_recover")
    incoming = put_in(incoming, ["data", "object", "metadata"], %{"resource_id" => id})
    assert {:error, :customer_not_found} = WebhookSync.sync_event(incoming, @sync_opts)

    user =
      PostgresCustomer
      |> Ash.Changeset.for_create(:create, %{stripe_customer_id: "cus_recover"})
      |> Ash.Changeset.force_change_attribute(:id, id)
      |> Ash.create!(@opts)

    assert {:ok, sub} = WebhookSync.sync_event(incoming, @sync_opts)
    assert sub.user_id == user.id
  end

  test "email alone cannot claim an unassociated user" do
    user = Ash.create!(PostgresCustomer, %{email: "email_only@example.invalid"}, @opts)
    incoming = event("sub_email_only", "active", 1_700_000_001)
    incoming = put_in(incoming, ["data", "object", "customer"], "cus_email_only")
    incoming = put_in(incoming, ["data", "object", "customer_email"], user.email)
    assert {:error, :customer_identity_unverified} = WebhookSync.sync_event(incoming, @sync_opts)
    refute AshBilling.subscribed?(Ash.load!(user, :subscriptions, @opts))
  end

  test "checkout cannot replace a conflicting customer association", %{user: user} do
    incoming = %{
      "type" => "checkout.session.completed",
      "data" => %{
        "object" => %{
          "customer" => "cus_checkout_other",
          "client_reference_id" => user.id
        }
      }
    }

    assert {:error, :customer_identity_conflict} = WebhookSync.sync_event(incoming, @sync_opts)
    assert Ash.get!(PostgresCustomer, user.id, @opts).stripe_customer_id == "cus_pg"
  end

  test "persisted customer ownership wins over misleading metadata", %{user: user} do
    incoming =
      put_in(
        event("sub_known_customer", "active", 1_700_000_001),
        ["data", "object", "metadata"],
        %{"resource_id" => Ash.UUID.generate()}
      )

    assert {:ok, sub} = WebhookSync.sync_event(incoming, @sync_opts)
    assert sub.user_id == user.id
  end

  test "existing subscription cannot be updated on behalf of a different customer", %{user: user} do
    sub =
      Ash.create!(
        PostgresSubscription,
        %{provider_subscription_id: "sub_existing_owner", status: :canceled, user_id: user.id},
        @opts
      )

    Ash.create!(PostgresCustomer, %{stripe_customer_id: "cus_different_owner"}, @opts)

    incoming =
      put_in(
        event(sub.provider_subscription_id, "active", 1_700_000_001),
        ["data", "object", "customer"],
        "cus_different_owner"
      )

    assert {:error, :subscription_customer_conflict} =
             WebhookSync.sync_event(incoming, @sync_opts)

    assert Ash.get!(PostgresSubscription, sub.id, @opts).status == :canceled
  end

  test "conflicting local references and unknown customers are controlled errors", %{user: user} do
    incoming =
      put_in(
        event("sub_unknown_customer", "active", 1_700_000_001),
        ["data", "object", "customer"],
        "cus_unassociated"
      )

    assert {:error, :customer_not_found} = WebhookSync.sync_event(incoming, @sync_opts)

    conflicting =
      incoming
      |> put_in(["data", "object", "metadata"], %{"resource_id" => user.id})
      |> put_in(["data", "object", "client_reference_id"], Ash.UUID.generate())

    assert {:error, :customer_identity_conflict} = WebhookSync.sync_event(conflicting, @sync_opts)
    invalid = put_in(incoming, ["data", "object", "metadata"], %{"resource_id" => "not-a-uuid"})
    assert {:error, _} = WebhookSync.sync_event(invalid, @sync_opts)
    refute AshBilling.subscribed?(Ash.load!(user, :subscriptions, @opts))
  end

  test "identity conflicts return HTTP 500 and the exact event can recover after remediation", %{
    user: user
  } do
    incoming =
      event("sub_identity_retry", "active", 1_700_000_001)
      |> put_in(["data", "object", "customer"], "cus_remediated")
      |> put_in(["data", "object", "metadata"], %{"resource_id" => user.id})

    payload = Jason.encode!(incoming)
    secret = "whsec_test_identity_retry"
    timestamp = System.system_time(:second)

    signature =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

    opts =
      [webhook_secret: secret, deduplication_resource: AshBilling.Test.PostgresWebhookEvent] ++
        @sync_opts

    request = fn ->
      Plug.Test.conn(:post, "/stripe", payload)
      |> Plug.Conn.put_req_header("stripe-signature", "t=#{timestamp},v1=#{signature}")
      |> AshBilling.Plug.call(opts)
    end

    assert request.().status == 500
    refute AshBilling.Deduplication.processed?(incoming["id"], opts)
    refute AshBilling.subscribed?(Ash.load!(user, :subscriptions, @opts))
    Ash.update!(user, %{stripe_customer_id: "cus_remediated"}, @opts)
    assert request.().status == 200
    assert AshBilling.Deduplication.processed?(incoming["id"], opts)
    assert AshBilling.subscribed?(Ash.load!(user, :subscriptions, @opts))
  end

  test "missing customer cannot bind a subscription ID as a customer", %{user: user} do
    unassociated = Ash.create!(PostgresCustomer, %{}, @opts)
    incoming = event("sub_missing_customer", "active", 1_700_000_001)
    incoming = update_in(incoming, ["data", "object"], &Map.delete(&1, "customer"))

    incoming =
      put_in(incoming, ["data", "object", "metadata"], %{"resource_id" => unassociated.id})

    assert {:error, :missing_customer_id} = WebhookSync.sync_event(incoming, @sync_opts)
    assert Ash.get!(PostgresCustomer, unassociated.id, @opts).stripe_customer_id == nil
    assert Ash.read!(PostgresSubscription, @opts) == []
    refute AshBilling.subscribed?(Ash.load!(user, :subscriptions, @opts))
  end

  test "email fallback cannot override an existing customer", %{user: user} do
    Ash.update!(user, %{email: "persisted@example.invalid"}, @opts)

    incoming =
      event("sub_conflicting_email", "active", 1_700_000_001)
      |> put_in(["data", "object", "customer"], "cus_email_attacker")
      |> put_in(["data", "object", "customer_email"], "persisted@example.invalid")

    assert {:error, :customer_identity_conflict} = WebhookSync.sync_event(incoming, @sync_opts)
    assert Ash.read!(PostgresSubscription, @opts) == []
  end

  test "concurrent deliveries can establish the same initial customer idempotently" do
    user = Ash.create!(PostgresCustomer, %{}, @opts)

    incoming = %{
      "type" => "checkout.session.completed",
      "data" => %{
        "object" => %{
          "customer" => "cus_same_initial",
          "client_reference_id" => user.id
        }
      }
    }

    results =
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> WebhookSync.sync_event(incoming, @sync_opts) end) end)
      |> Task.await_many()

    assert Enum.all?(results, fn
             {:ok, customer} ->
               customer.id == user.id and customer.stripe_customer_id == "cus_same_initial"

             _ ->
               false
           end)

    assert Ash.get!(PostgresCustomer, user.id, @opts).stripe_customer_id == "cus_same_initial"
  end

  test "consumers managing customers separately can update an existing subscription", %{
    user: user
  } do
    sub =
      Ash.create!(
        PostgresSubscription,
        %{provider_subscription_id: "sub_external_customer", user_id: user.id, status: :paused},
        @opts
      )

    assert {:ok, updated} =
             WebhookSync.sync_event(
               event(sub.provider_subscription_id, :active, 1_700_000_001),
               Keyword.delete(@sync_opts, :customer_resource)
             )

    assert updated.status == :active
    assert updated.user_id == user.id
  end
end
