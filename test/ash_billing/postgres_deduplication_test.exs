defmodule AshBilling.PostgresDeduplicationTest do
  use ExUnit.Case, async: false

  alias AshBilling.Deduplication
  alias AshBilling.Test.PostgresDomain
  alias AshBilling.Test.PostgresWebhookEvent
  alias AshBilling.Test.Repo

  @opts [
    deduplication_strategy: :resource,
    deduplication_resource: PostgresWebhookEvent,
    domain: PostgresDomain
  ]

  setup do
    unless Application.get_env(:ash_billing, :postgres_available, false) do
      if System.get_env("CI") do
        flunk("PostgreSQL is required in CI but is not available or running")
      else
        {:skip, "PostgreSQL not running or available"}
      end
    else
      # Checkout sandbox or cleanup table
      Ecto.Adapters.SQL.query!(Repo, "TRUNCATE TABLE webhook_events;")
      :ok
    end
  end

  describe "PostgreSQL Distributed Deduplication" do
    test "acquires a lease atomically in PostgreSQL" do
      event_id = "evt_pg_#{System.unique_integer([:positive])}"

      assert {:ok, lease_token} = Deduplication.acquire(event_id, @opts)
      assert is_binary(lease_token)
      assert String.starts_with?(lease_token, "lt_")

      # Second acquire for same in-flight event returns :already_processing
      assert {:error, :already_processing} = Deduplication.acquire(event_id, @opts)
    end

    test "resolves concurrent contention: exactly one worker acquires lease in PostgreSQL" do
      event_id = "evt_pg_race_#{System.unique_integer([:positive])}"
      worker_count = 10

      results =
        1..worker_count
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Deduplication.acquire(event_id, @opts)
          end)
        end)
        |> Task.await_many(5000)

      successes = Enum.filter(results, fn res -> match?({:ok, _token}, res) end)
      rejections = Enum.filter(results, fn res -> match?({:error, :already_processing}, res) end)

      assert length(successes) == 1
      assert length(rejections) == worker_count - 1
    end

    test "atomic completion with strategy: [:atomic] transitions event to :processed" do
      event_id = "evt_pg_complete_#{System.unique_integer([:positive])}"

      assert {:ok, lease_token} = Deduplication.acquire(event_id, @opts)

      # Complete marks processed
      assert :ok = Deduplication.complete(event_id, [lease_token: lease_token] ++ @opts)
      assert Deduplication.processed?(event_id, @opts) == true

      # Subsequent acquire recognizes already_processed
      assert {:error, :already_processed} = Deduplication.acquire(event_id, @opts)

      # Idempotent complete call succeeds
      assert :ok = Deduplication.complete(event_id, [lease_token: lease_token] ++ @opts)
    end

    test "zombie worker protection: rejects complete and release when lease_token mismatches" do
      event_id = "evt_pg_zombie_#{System.unique_integer([:positive])}"

      assert {:ok, original_token} = Deduplication.acquire(event_id, @opts)

      # Simulate another worker taking over the lease by updating lease_token in DB
      new_token = "lt_stolen_#{System.unique_integer([:positive])}"

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE webhook_events SET lease_token = $1 WHERE event_id = $2",
        [new_token, event_id]
      )

      # Original zombie worker attempting to complete must be rejected
      assert {:error, :lease_token_mismatch} =
               Deduplication.complete(event_id, [lease_token: original_token] ++ @opts)

      # Original zombie worker attempting to release must also be rejected
      assert {:error, :lease_token_mismatch} =
               Deduplication.release(event_id, [lease_token: original_token] ++ @opts)

      # The current owner with new_token can complete successfully
      assert :ok = Deduplication.complete(event_id, [lease_token: new_token] ++ @opts)
      assert Deduplication.processed?(event_id, @opts) == true
    end

    test "reclaims expired lease (> 60s) atomically" do
      event_id = "evt_pg_stale_#{System.unique_integer([:positive])}"

      assert {:ok, _stale_token} = Deduplication.acquire(event_id, @opts)

      # Age the lease in PostgreSQL beyond 60s cutoff
      two_minutes_ago = DateTime.add(DateTime.utc_now(), -120, :second)

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE webhook_events SET last_attempt_at = $1 WHERE event_id = $2",
        [two_minutes_ago, event_id]
      )

      # New worker can atomically reclaim the expired lease
      assert {:ok, new_token} = Deduplication.acquire(event_id, @opts)
      assert is_binary(new_token)

      assert :ok = Deduplication.complete(event_id, [lease_token: new_token] ++ @opts)
      assert Deduplication.processed?(event_id, @opts) == true
    end

    test "releases lease on failure and allows immediate retry" do
      event_id = "evt_pg_retry_#{System.unique_integer([:positive])}"

      assert {:ok, lease_token} = Deduplication.acquire(event_id, @opts)

      # Release on failure
      assert :ok =
               Deduplication.release(
                 event_id,
                 [lease_token: lease_token, error: :stripe_timeout] ++ @opts
               )

      # Event is not marked as processed
      assert Deduplication.processed?(event_id, @opts) == false

      # Next retry can acquire immediately
      assert {:ok, retry_token} = Deduplication.acquire(event_id, @opts)
      assert is_binary(retry_token)
      assert retry_token != lease_token

      assert :ok = Deduplication.complete(event_id, [lease_token: retry_token] ++ @opts)
      assert Deduplication.processed?(event_id, @opts) == true
    end

    test "atomic fallback destruction race: worker attempting fallback destruction with stale token cannot delete a reclaimed lease" do
      event_id = "evt_pg_destroy_race_#{System.unique_integer([:positive])}"

      # Worker A acquires lease
      assert {:ok, token_a} = Deduplication.acquire(event_id, @opts)

      # Age the lease in PostgreSQL beyond 60s cutoff so Worker B can reclaim it
      two_minutes_ago = DateTime.add(DateTime.utc_now(), -120, :second)

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE webhook_events SET last_attempt_at = $1 WHERE event_id = $2",
        [two_minutes_ago, event_id]
      )

      # Worker B reclaims the lease atomically with a new token
      assert {:ok, token_b} = Deduplication.acquire(event_id, @opts)
      assert token_b != token_a

      # Worker A, having encountered a failure, attempts to release/destroy the lease with stale token_a
      assert {:error, :lease_token_mismatch} =
               Deduplication.release(
                 event_id,
                 [lease_token: token_a, error: :worker_a_failed] ++ @opts
               )

      # Ensure Worker B's active lease record was NOT destroyed from PostgreSQL
      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT lease_token, status FROM webhook_events WHERE event_id = $1",
          [event_id]
        )

      assert [[^token_b, "processing"]] = result.rows

      # Worker B can successfully complete the event
      assert :ok = Deduplication.complete(event_id, [lease_token: token_b] ++ @opts)
      assert Deduplication.processed?(event_id, @opts) == true
    end

    test "release strictly refuses to mutate an already :processed event in PostgreSQL" do
      event_id = "evt_pg_immutable_proc_#{System.unique_integer([:positive])}"

      assert {:ok, lease_token} = Deduplication.acquire(event_id, @opts)
      assert :ok = Deduplication.complete(event_id, [lease_token: lease_token] ++ @opts)
      assert Deduplication.processed?(event_id, @opts) == true

      # Calling release without token must return {:error, :already_processed} and not alter status in PG
      assert {:error, :already_processed} = Deduplication.release(event_id, @opts)

      # Calling release with token must also return {:error, :already_processed}
      assert {:error, :already_processed} =
               Deduplication.release(event_id, [lease_token: lease_token] ++ @opts)

      result =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT status FROM webhook_events WHERE event_id = $1",
          [event_id]
        )

      assert [["processed"]] = result.rows
    end
  end
end
