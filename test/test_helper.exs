ExUnit.start()

# Check and initialize PostgreSQL if available
postgres_available? =
  try do
    case AshBilling.Test.Repo.start_link() do
      {:ok, _pid} ->
        Ecto.Adapters.SQL.query!(AshBilling.Test.Repo, """
        CREATE TABLE IF NOT EXISTS webhook_events (
          event_id TEXT PRIMARY KEY,
          status TEXT NOT NULL DEFAULT 'processing',
          lease_token TEXT,
          attempts INTEGER NOT NULL DEFAULT 1,
          error TEXT,
          last_attempt_at TIMESTAMP(6) WITHOUT TIME ZONE,
          processed_at TIMESTAMP(6) WITHOUT TIME ZONE
        );
        """)

        true

      {:error, {:already_started, _}} ->
        true

      {:error, reason} ->
        IO.puts(
          "PostgreSQL not available: #{inspect(reason)}. PostgreSQL integration tests will be skipped."
        )

        false
    end
  rescue
    e ->
      IO.puts(
        "PostgreSQL connection error: #{inspect(e)}. PostgreSQL integration tests will be skipped."
      )

      false
  end

Application.put_env(:ash_billing, :postgres_available, postgres_available?)
