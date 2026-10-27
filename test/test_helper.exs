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

        Ecto.Adapters.SQL.query!(AshBilling.Test.Repo, """
        CREATE TABLE IF NOT EXISTS billing_test_customers (
          id UUID PRIMARY KEY,
          email TEXT,
          stripe_customer_id TEXT
        )
        """)

        Ecto.Adapters.SQL.query!(AshBilling.Test.Repo, """
        CREATE TABLE IF NOT EXISTS billing_test_subscriptions (
          id UUID PRIMARY KEY,
          user_id UUID REFERENCES billing_test_customers(id),
          provider_subscription_id TEXT NOT NULL,
          status TEXT NOT NULL,
          price_id TEXT,
          current_period_end TIMESTAMP(6),
          trial_ends_at TIMESTAMP(6),
          cancel_at_period_end BOOLEAN DEFAULT FALSE,
          cancel_at TIMESTAMP(6),
          last_event_created_at TIMESTAMP(6)
        )
        """)

        true

      {:error, {:already_started, _}} ->
        true

      {:error, reason} ->
        if System.get_env("CI") do
          raise "PostgreSQL is required in CI environment but failed to start: #{inspect(reason)}"
        else
          IO.puts(
            "PostgreSQL not available: #{inspect(reason)}. PostgreSQL integration tests will be skipped."
          )

          false
        end
    end
  rescue
    e ->
      if System.get_env("CI") do
        reraise e, __STACKTRACE__
      else
        IO.puts(
          "PostgreSQL connection error: #{inspect(e)}. PostgreSQL integration tests will be skipped."
        )

        false
      end
  end

Application.put_env(:ash_billing, :postgres_available, postgres_available?)
