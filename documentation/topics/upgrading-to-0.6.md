# Upgrading to 0.6

Version **0.6.0** introduces durable cross-node reconciliation checkpoints (`last_reconciled_at`) persisted in PostgreSQL so `AshBilling.reconcile_subscription/2` preserves Stripe's live state across restarts, multi-node clusters, and delayed webhooks without fabricating `last_event_created_at` timestamps.

## Schema Migration Required

`AshBilling.Subscription` now injects an additional protected nullable attribute on every subscription resource:

- `last_reconciled_at` (`:utc_datetime_usec`, `allow_nil?: true`)

### 1. Generate and apply Ash / Ecto migrations

```bash
mix ash.codegen add_last_reconciled_at
mix ecto.migrate
```

Or if you maintain manual migrations, add the nullable column to your subscriptions table(s):

```elixir
def change do
  alter table(:subscriptions) do
    add :last_reconciled_at, :utc_datetime_usec
  end
end
```

Deploy the migration **before** rolling out `0.6.0` application nodes so `SELECT` and `UPDATE` queries against the subscription resource succeed across all workers. Existing rows remain valid with `last_reconciled_at = NULL` (no backfill required).

## Behavioral Changes

### 1. `reconcile_subscription/2` no longer fabricates `last_event_created_at`

In `0.5.x`, `AshBilling.reconcile_subscription/2` populated synthetic `"created" => System.system_time(:second)` into `last_event_created_at`. Under local clock skew, a lagging clock could cause live reconciliation to be ignored and an ahead clock could advance `last_event_created_at` into the future.

In `0.6.0`:

- `reconcile_subscription/2` sets synthetic `"created" => nil`, keeping `last_event_created_at` strictly reserved for genuine provider event timestamps.
- Under the canonical `Customer -> Subscription` `FOR UPDATE` PostgreSQL lock, `reconcile_subscription/2` queries PostgreSQL's shared clock (`SELECT timezone('UTC', clock_timestamp())`), computes a monotonic checkpoint (`max(existing.last_reconciled_at, db_clock)`), and updates state and `last_reconciled_at` atomically in the same SQL transaction.

### 2. Fail-safe re-verification of financial changes after reconciliation

Time-window heuristics alone cannot prevent a delayed older webhook with `event.created > last_reconciled_at + window` from overwriting a reconciled subscription when `last_event_created_at` is still older.

In `0.6.0`, whenever a persisted subscription already has `last_reconciled_at` set:

- **Safe fast paths (0 provider API calls):**
  - Already-terminated Stripe subscriptions receiving non-terminal events.
  - Clearly obsolete events where `event.created < last_event_created_at`.
  - Duplicate event IDs filtered by `AshBilling.Deduplication`.
  - No-op webhooks whose critical synchronized financial attributes (`status`, `price_id`, `current_period_end`, `trial_ends_at`, `cancel_at_period_end`, `cancel_at`) are already identical to the persisted snapshot.
- **Live provider re-verification (`GET` under `FOR UPDATE`):**
  - Any non-terminal or delayed terminal webhook that proposes changing one or more critical financial attributes compared to the persisted snapshot triggers `get_subscription/2` under the PostgreSQL row lock **regardless of whether `event.created` falls inside or outside a 60-second window**.
  - The persisted snapshot is then updated only with the provider's authoritative live state.

**Costs & Limits:**

- Subscriptions with `last_reconciled_at` set incur one synchronous provider `GET` call under the PostgreSQL row lock for each subsequent webhook that mutates synchronized financial attributes (`status`, `price_id`, `current_period_end`, `trial_ends_at`, `cancel_at_period_end`, `cancel_at`). Use bounded `Req` HTTP timeouts and appropriate DB pool sizing.
- If the provider `GET` fails during re-verification, `WebhookSync` rolls back the transaction (`{:error, {:reconciliation_failed, reason}}`), never falls back to applying the unverified webhook payload, and triggers webhook retry.
- `AshBilling.Subscription` does not store a persisted `quantity` attribute; quantity mutations are not compared locally in `WebhookSync` (multi-item payloads remain rejected).
