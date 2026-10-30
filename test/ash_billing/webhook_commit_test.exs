defmodule AshBilling.WebhookCommitTest do
  use ExUnit.Case, async: false
  require Ash.Query

  alias AshBilling.Test.{
    Repo,
    PostgresDomain,
    PostgresCustomer,
    PostgresSubscription,
    PostgresWebhookEvent
  }

  @ash [domain: PostgresDomain, authorize?: false]
  @opts [
    domain: PostgresDomain,
    customer_resource: PostgresCustomer,
    subscription_resource: PostgresSubscription,
    deduplication_resource: PostgresWebhookEvent
  ]

  defmodule FailedHandler do
    def handle_event(_), do: {:error, :intentional_handler_failure}
  end

  defp id(prefix), do: prefix <> String.replace(Ash.UUID.generate(), "-", "")

  defp event(type, object) do
    %{
      "id" => id("evt_commit_"),
      "type" => type,
      "created" => System.system_time(:second),
      "data" => %{"object" => object}
    }
  end

  defp failure_event(:sync) do
    event("customer.subscription.updated", %{
      "id" => id("sub_missing_"),
      "customer" => id("cus_missing_"),
      "status" => "active"
    })
  end

  defp failure_event(:handler), do: event("audit.test", %{})

  defp request(ev, opts \\ @opts) do
    payload = Jason.encode!(ev)
    ts = System.system_time(:second)
    secret = "whsec_commit_test"
    sig = :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{payload}") |> Base.encode16(case: :lower)
    owner = self()

    Plug.Test.conn(:post, "/webhooks/stripe", payload)
    |> Plug.Conn.put_req_header("stripe-signature", "t=#{ts},v1=#{sig}")
    |> Plug.Conn.register_before_send(fn conn ->
      send(owner, {:sending, conn.status})

      if conn.status in 200..299 and opts[:deduplication_resource] == PostgresWebhookEvent do
        rows =
          Task.async(fn ->
            Ecto.Adapters.SQL.query!(
              Repo,
              "SELECT status FROM webhook_events WHERE event_id = $1",
              [ev["id"]]
            ).rows
          end)
          |> Task.await()

        send(owner, {:durable_at_send, rows})
      end

      conn
    end)
    |> AshBilling.Plug.call([webhook_secret: secret] ++ opts)
  end

  # PostgreSQL sequences are intentionally nontransactional: only the first
  # matching COMMIT fails, without mutating a production lease or clock.
  defp fail_first_commit(event_id, status, table \\ "webhook_events", key \\ "event_id") do
    name = id("commit_fault_")
    Ecto.Adapters.SQL.query!(Repo, "CREATE SEQUENCE #{name}")

    Ecto.Adapters.SQL.query!(Repo, """
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.#{key} = '#{event_id}' AND NEW.status = '#{status}' THEN
        IF nextval('#{name}') = 1 THEN
          RAISE EXCEPTION 'injected deferred commit failure' USING ERRCODE = '23514';
        END IF;
      END IF;
      RETURN NEW;
    END $$;
    """)

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE CONSTRAINT TRIGGER #{name} AFTER UPDATE ON #{table} DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION #{name}()"
    )

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER #{name} ON #{table}")
      Ecto.Adapters.SQL.query!(Repo, "DROP FUNCTION #{name}()")
      Ecto.Adapters.SQL.query!(Repo, "DROP SEQUENCE #{name}")
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM webhook_events WHERE event_id = $1", [event_id])
    end)
  end

  test "failed COMMIT sends no 2xx and immediate retry commits cancellation exactly once" do
    cus = id("cus_commit_")
    user = Ash.create!(PostgresCustomer, %{stripe_customer_id: cus}, @ash)

    sub =
      Ash.create!(
        PostgresSubscription,
        %{user_id: user.id, provider_subscription_id: id("sub_commit_"), status: :active},
        @ash
      )

    journal = id("cancel_journal_")
    Ecto.Adapters.SQL.query!(Repo, "CREATE TABLE #{journal} (subscription_id UUID)")

    Ecto.Adapters.SQL.query!(Repo, """
    CREATE FUNCTION #{journal}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.id = '#{sub.id}' AND NEW.status = 'canceled' THEN
        INSERT INTO #{journal} VALUES (NEW.id);
      END IF;
      RETURN NEW;
    END $$;
    """)

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER #{journal} AFTER UPDATE ON billing_test_subscriptions FOR EACH ROW EXECUTE FUNCTION #{journal}()"
    )

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER #{journal} ON billing_test_subscriptions")
      Ecto.Adapters.SQL.query!(Repo, "DROP FUNCTION #{journal}()")
      Ecto.Adapters.SQL.query!(Repo, "DROP TABLE #{journal}")
      Ash.destroy!(sub, @ash)
      Ash.destroy!(user, @ash)
    end)

    ev =
      event("customer.subscription.deleted", %{
        "id" => sub.provider_subscription_id,
        "customer" => cus,
        "status" => "canceled"
      })

    fail_first_commit(ev["id"], "processed")

    assert request(ev).status >= 500
    assert_receive {:sending, status} when status >= 500
    refute_receive {:sending, 200}
    assert Ash.get!(PostgresSubscription, sub.id, @ash).status == :active
    assert Ash.get!(PostgresWebhookEvent, ev["id"], @ash).status == :failed
    assert Ecto.Adapters.SQL.query!(Repo, "SELECT count(*) FROM #{journal}", []).rows == [[0]]

    assert request(ev).status == 200
    assert_receive {:sending, 200}
    assert_receive {:durable_at_send, [["processed"]]}
    assert Ash.get!(PostgresSubscription, sub.id, @ash).status == :canceled
    assert AshBilling.Deduplication.processed?(ev["id"], @opts)
    assert Ecto.Adapters.SQL.query!(Repo, "SELECT count(*) FROM #{journal}", []).rows == [[1]]
    assert request(ev).status == 200
    assert_receive {:sending, 200}
    assert Ecto.Adapters.SQL.query!(Repo, "SELECT count(*) FROM #{journal}", []).rows == [[1]]
  end

  for kind <- [:sync, :handler] do
    test "#{kind} error cannot send legacy 200 if recording the failure fails to commit" do
      ev = failure_event(unquote(kind))

      fail_first_commit(ev["id"], "failed")
      opts = [handler: FailedHandler, return_500_on_sync_error: false] ++ @opts
      assert request(ev, opts).status >= 500
      refute_receive {:sending, 200}
      assert Ash.get!(PostgresWebhookEvent, ev["id"], @ash).status == :failed
    end
  end

  test "a failed lease reclaim commit sends no 200 and preserves the retryable record" do
    ev = event("audit.test", %{})
    assert {:ok, token} = AshBilling.Deduplication.acquire(ev["id"], @opts)
    assert :ok = AshBilling.Deduplication.release(ev["id"], [lease_token: token] ++ @opts)
    fail_first_commit(ev["id"], "processing")
    assert request(ev, [return_500_on_sync_error: false] ++ @opts).status >= 500
    refute_receive {:sending, 200}
    record = Ash.get!(PostgresWebhookEvent, ev["id"], @ash)
    assert record.status == :failed
    assert record.lease_token == token
    assert request(ev).status == 200
    assert_receive {:durable_at_send, [["processed"]]}
  end

  test "external transactions reject both new events and already-processed shortcuts" do
    ev = event("audit.test", %{})

    assert {:error, :outer_abort} =
             Repo.transaction(fn ->
               assert request(ev).status == 503
               refute_receive {:sending, 200}
               Repo.rollback(:outer_abort)
             end)

    assert Ash.read!(Ash.Query.filter(PostgresWebhookEvent, event_id == ^ev["id"]), @ash) == []
    assert request(ev).status == 200
    assert_receive {:sending, 200}

    assert {:ok, _} =
             Repo.transaction(fn ->
               assert request(ev).status == 503
               refute_receive {:sending, 200}
             end)

    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM webhook_events WHERE event_id = $1", [ev["id"]])
  end

  test "deduplication and completion failures never use the legacy acknowledgment opt-out" do
    for resource <- [AshBilling.Test.NoUpdateEvent, AshBilling.Test.FailingUpdateEvent] do
      opts = [
        deduplication_resource: resource,
        domain: AshBilling.Test.Domain,
        return_500_on_sync_error: false
      ]

      assert request(event("audit.test", %{}), opts).status == 500
      refute_receive {:sending, 200}
    end
  end

  test "different primary Repos are rejected before leases, foreign keys or writes" do
    ev =
      event("customer.subscription.created", %{
        "id" => id("sub_cross_"),
        "customer" => id("cus_cross_"),
        "status" => "active"
      })

    opts =
      Keyword.merge(@opts,
        subscription_resource: AshBilling.Test.CrossRepoSubscription,
        domain: AshBilling.Test.TransactionDomain
      )

    assert request(ev, opts).status == 503
    refute_receive {:sending, 200}

    assert {:error, {:multiple_transaction_repos, _}} =
             AshBilling.WebhookSync.sync_event(ev, opts)

    assert Ecto.Adapters.SQL.query!(
             Repo,
             "SELECT count(*) FROM webhook_events WHERE event_id = $1",
             [ev["id"]]
           ).rows == [[0]]
  end

  test "ambient transactions are rejected even without configured billing resources" do
    ev = event("audit.test", %{})

    assert {:error, :outer_abort} =
             Repo.transaction(fn ->
               assert request(ev, []).status == 503
               refute_receive {:sending, 200}
               Repo.rollback(:outer_abort)
             end)

    refute AshBilling.Deduplication.processed?(ev["id"])
  end

  test "expired duplicates leave a two-connection pool available while effects remain fenced" do
    alias AshBilling.Test.{TransactionRepo, TransactionWebhookEvent, TransactionDomain}

    config =
      Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({TransactionRepo, config})
    opts = [deduplication_resource: TransactionWebhookEvent, domain: TransactionDomain]
    event_id = id("evt_pool_")

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM webhook_events WHERE event_id = $1", [event_id])
    end)

    assert {:ok, token} = AshBilling.Deduplication.acquire(event_id, opts)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE webhook_events SET last_attempt_at = $1 WHERE event_id = $2",
      [DateTime.add(DateTime.utc_now(), -120), event_id]
    )

    owner = self()

    first =
      Task.async(fn ->
        AshBilling.Deduplication.with_lease(event_id, token, opts, fn ->
          send(owner, {:fenced, self()})

          receive do
            :finish -> :ok
          end

          AshBilling.Deduplication.complete(event_id, [lease_token: token] ++ opts)
        end)
      end)

    assert_receive {:fenced, worker}, 2000

    duplicates =
      for _ <- 1..10, do: Task.async(fn -> AshBilling.Deduplication.acquire(event_id, opts) end)

    for duplicate <- duplicates,
        do: assert(Task.await(duplicate) == {:error, :already_processing})

    assert {:ok, %{rows: [[1]]}} = TransactionRepo.query("SELECT 1", [], queue: false)
    # Same physical row through a different Repo/resource must share the fence.
    assert {:error, :already_processing} = AshBilling.Deduplication.acquire(event_id, @opts)
    send(worker, :finish)
    assert {:ok, :ok} = Task.await(first)
    assert {:error, :already_processed} = AshBilling.Deduplication.acquire(event_id, opts)
  end

  test "an independent row lock returns busy without waiting or replacing the token" do
    event_id = id("evt_rowlock_")
    assert {:ok, token} = AshBilling.Deduplication.acquire(event_id, @opts)

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM webhook_events WHERE event_id = $1", [event_id])
    end)

    owner = self()

    writer =
      Task.async(fn ->
        Repo.transaction(fn ->
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT event_id FROM webhook_events WHERE event_id = $1 FOR UPDATE",
            [event_id]
          )

          send(owner, {:row_locked, self()})

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive {:row_locked, worker}, 2000
    assert {:error, :already_processing} = AshBilling.Deduplication.acquire(event_id, @opts)
    send(worker, :finish)
    assert {:ok, :ok} = Task.await(writer)
    assert Ash.get!(PostgresWebhookEvent, event_id, @ash).lease_token == token

    assert :ok =
             AshBilling.Deduplication.release(
               event_id,
               [lease_token: token, error: :retry] ++ @opts
             )

    assert {:ok, next_token} = AshBilling.Deduplication.acquire(event_id, @opts)
    refute token == next_token
  end

  test "Repo modules explicitly sharing a primary pool can commit a foreign-key insert" do
    alias AshBilling.Test.{TransactionRepo, CrossRepoSubscription, TransactionDomain}
    previous = TransactionRepo.put_dynamic_repo(Repo)
    cus = id("cus_shared_")
    user = Ash.create!(PostgresCustomer, %{stripe_customer_id: cus}, @ash)

    ev =
      event("customer.subscription.created", %{
        "id" => id("sub_shared_"),
        "customer" => cus,
        "status" => "active"
      })

    opts =
      Keyword.merge(@opts,
        subscription_resource: CrossRepoSubscription,
        domain: TransactionDomain
      )

    try do
      assert request(ev, opts).status == 200
      assert_receive {:durable_at_send, [["processed"]]}

      [sub] =
        Ash.read!(
          Ash.Query.filter(
            PostgresSubscription,
            provider_subscription_id == ^ev["data"]["object"]["id"]
          ),
          @ash
        )

      assert sub.user_id == user.id
      Ash.destroy!(sub, @ash)
    after
      TransactionRepo.put_dynamic_repo(previous)
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM webhook_events WHERE event_id = $1", [ev["id"]])
      Ash.destroy!(user, @ash)
    end
  end

  test "missing event IDs cannot bypass durable deduplication" do
    for missing <- [nil, ""] do
      assert request(Map.put(event("audit.test", %{}), "id", missing)).status >= 400
      refute_receive {:sending, 200}
    end
  end

  for mode <- [:memory, :disabled] do
    test "#{mode} mode never acknowledges a failed billing commit with the legacy opt-out" do
      cus = id("cus_nonpersistent_")
      user = Ash.create!(PostgresCustomer, %{stripe_customer_id: cus}, @ash)

      sub =
        Ash.create!(
          PostgresSubscription,
          %{
            user_id: user.id,
            provider_subscription_id: id("sub_nonpersistent_"),
            status: :active
          },
          @ash
        )

      on_exit(fn ->
        Ash.destroy!(sub, @ash)
        Ash.destroy!(user, @ash)
      end)

      ev =
        event("customer.subscription.deleted", %{
          "id" => sub.provider_subscription_id,
          "customer" => cus,
          "status" => "canceled"
        })

      fail_first_commit(sub.id, "canceled", "billing_test_subscriptions", "id")

      opts =
        Keyword.merge(Keyword.delete(@opts, :deduplication_resource),
          deduplication_strategy: :memory,
          deduplicate?: unquote(mode != :disabled),
          return_500_on_sync_error: false
        )

      assert request(ev, opts).status >= 500
      refute_receive {:sending, 200}
      assert Ash.get!(PostgresSubscription, sub.id, @ash).status == :active
      assert request(ev, opts).status == 200
      assert Ash.get!(PostgresSubscription, sub.id, @ash).status == :canceled
    end
  end
end
