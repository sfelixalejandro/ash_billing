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

### 2. Fail-safe re-verification of ambiguous delayed webhooks

Timestamps and clock windows do not establish an absolute total causal order against asynchronous Stripe event emitters. Instead, `AshBilling.WebhookSync` uses `last_reconciled_at` plus a configurable uncertainty horizon (`:reconciliation_skew_seconds`, default `60`) to detect **ambiguous scenarios** where a webhook payload may predate or overlap a reconciliation:

- Non-terminal or terminal (`canceled`, `incomplete_expired`) webhooks whose `event.created` is not older than `last_event_created_at` and falls at or before `last_reconciled_at + reconciliation_skew_seconds`.

When triggered, `WebhookSync` does **not** discard the webhook; it re-verifies against the provider via `get_subscription/2` under `FOR UPDATE` and commits the authoritative live state.

Configure the uncertainty horizon globally or per call:

```elixir
config :ash_billing, reconciliation_skew_seconds: 60
```

**Trade-offs & Limits:**

- Ambiguous webhooks incur one live `GET` call under the PostgreSQL row lock and fail closed (`{:error, {:reconciliation_failed, reason}}`) if Stripe is unavailable, triggering webhook retry.
- Delayed webhooks whose `event.created` exceeds `last_reconciled_at + reconciliation_skew_seconds` (while `last_event_created_at` was still older) fall outside this local heuristic window.
