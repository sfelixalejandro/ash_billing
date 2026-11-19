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

Deploy the migration **before** rolling out `0.6.0` application nodes so `SELECT` and `UPDATE` queries against the subscription resource succeed across all workers. Existing rows remain valid with `last_reconciled_at = NULL` (no SQL backfill should be performed).

### 2. Recommended deployment order

Follow this sequence when upgrading an existing `0.5.x` deployment to `0.6.0`:

1. **Apply the PostgreSQL migration first:** Add the nullable `last_reconciled_at` column while leaving existing rows at `last_reconciled_at = NULL`.
2. **Roll out the `0.6.0` application nodes:** Deploy the upgraded application with bounded `req_opts` configured on `AshBilling.Plug` and reconciliation workers (see the operational evaluation section below).
3. **Reconcile legacy subscriptions against the real provider:** For subscriptions that may have been reconciled under `0.5.x` (or could have drifted), run `AshBilling.reconcile_subscription/2` in a rate-limited background sweep (for example, an Oban queue with bounded concurrency) so each subscription is verified against live Stripe state before `last_reconciled_at` is persisted.

## Behavioral Changes

### 1. `reconcile_subscription/2` no longer fabricates `last_event_created_at`

In `0.5.x`, `AshBilling.reconcile_subscription/2` populated synthetic `"created" => System.system_time(:second)` into `last_event_created_at`. Under local clock skew, a lagging clock could cause live reconciliation to be ignored and an ahead clock could advance `last_event_created_at` into the future.

In `0.6.0`:

- `reconcile_subscription/2` sets synthetic `"created" => nil`, keeping `last_event_created_at` strictly reserved for genuine provider event timestamps.
- Under the canonical `Customer -> Subscription` `FOR UPDATE` PostgreSQL lock, `reconcile_subscription/2` queries PostgreSQL's shared clock (`SELECT timezone('UTC', clock_timestamp())`), computes a monotonic checkpoint (`max(existing.last_reconciled_at, db_clock)`), and updates state and `last_reconciled_at` atomically in the same SQL transaction.

### 2. Compatibility with `0.5.3` synthetic `last_event_created_at` cursors

Because `0.5.2` and `0.5.3` wrote `System.system_time(:second)` into `last_event_created_at` during `reconcile_subscription/2`, an upgraded installation may contain rows whose `last_event_created_at` is ahead of genuine Stripe event timestamps (for example, due to forward host clock skew). Without healing that cursor, `existing_event_newer?/2` would ignore legitimate Stripe webhooks until Stripe's clock caught up.

`0.6.0` addresses this in two compatible ways without changing the schema further:

1. **Automatic healing during `reconcile_subscription/2`**: Whenever `reconcile_subscription/2` fetches live state from the provider and finds an existing `last_event_created_at` strictly greater than PostgreSQL's UTC `clock_timestamp()` (`existing.last_event_created_at > checkpoint_dt`), it logs a warning and atomically clears `last_event_created_at` to `NULL` in the exact same `UPDATE` that persists the verified provider state and sets `last_reconciled_at = checkpoint_dt`. Delayed webhooks arriving afterward are still verified against Stripe live state because `last_reconciled_at` is set, while legitimate real webhooks are no longer dropped.
2. **Controlled cursor reset for shared App + PostgreSQL clock skew (`reset_event_cursor?: true`)**: If both your `0.5.x` application nodes and PostgreSQL server ran with clocks ahead of Stripe (so a synthetic `last_event_created_at` could be `<= clock_timestamp()` yet still ahead of Stripe's clock), reconcile affected subscriptions against the live provider with `reset_event_cursor?: true` during step 3 of the upgrade rollout (with bounded concurrency and `req_opts`):

```elixir
{:ok, sub} =
  AshBilling.reconcile_subscription(subscription,
    domain: MyApp.Billing,
    reset_event_cursor?: true,
    req_opts: [
      connect_options: [timeout: 3_000],
      receive_timeout: 5_000,
      retry: false
    ]
  )
```

> **Do not backfill `last_reconciled_at` or clear `last_event_created_at` via raw SQL:**
>
> - **Never** run an `UPDATE` that sets `last_reconciled_at` (for example, to `clock_timestamp()`) without first fetching and persisting authoritative live state from Stripe. Doing so creates a **false reconciliation checkpoint** on unverified local data.
> - **Never** clear `last_event_created_at = NULL` directly in SQL outside `AshBilling.reconcile_subscription/2`, as doing so removes out-of-order timestamp protection before a real provider reconciliation has occurred.
> - Always heal legacy `0.5.x` rows through `AshBilling.reconcile_subscription/2` against the live provider (and use `reset_event_cursor?: true` only for targeted post-upgrade sweeps where shared clock skew is suspected).

### 3. Fail-safe re-verification of financial changes after reconciliation

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

## Scope of `quantity`

Subscription `quantity` **can be modified via the Stripe API** using `AshBilling.update_quantity/3`, `AshBilling.swap_plan/3`, and `AshBilling.create_checkout_session/2`. However, **`quantity` is not yet part of the synchronized attributes stored in PostgreSQL on `AshBilling.Subscription`** (`status`, `price_id`, `current_period_end`, `trial_ends_at`, `cancel_at_period_end`, `cancel_at`, `last_event_created_at`, `last_reconciled_at`).

Consequently:

- `WebhookSync` does not persist or diff `quantity` locally in PostgreSQL (multi-item non-terminal payloads remain rejected with `:unsupported_subscription_items`).
- Applications that enforce seat limits or require local quantity persistence must read the live quantity from Stripe or store it in a custom webhook handler.

## Operational Evaluation (Timeouts, Lock Hold Time & PostgreSQL Pool Sizing)

Once `last_reconciled_at` is populated on a subscription, every subsequent webhook that modifies any synchronized financial attribute performs **one synchronous `GET /v1/subscriptions/{id}` request** while holding the PostgreSQL transaction, the checked-out Repo connection, and the `Customer -> Subscription` `FOR UPDATE` row locks.

### 1. Default HTTP timeouts and why explicit `req_opts` are required

`AshBilling.Providers.Stripe` builds requests with `Req.new/1` (backed by `Finch`). By default in `Req` / `Finch`, when `req_opts` is not overridden:

| Option | Library Default | Operational Risk Inside `FOR UPDATE` |
| --- | --- | --- |
| `connect_options: [timeout: ...]` | `5_000 ms` (`Finch`) | Acceptable connect ceiling, but adds to total lock duration |
| `pool_timeout` | `5_000 ms` (`Finch`) | Wait time for an HTTP pool checkout while holding DB locks |
| `receive_timeout` | `15_000 ms` (`Req` / `Finch`) | Matches Ecto's default `15_000 ms` Repo transaction timeout on a single slow response |
| `retry` / `max_retries` | `:safe_transient`, `max_retries: 3` (up to **4 attempts** on `GET`, plus ~1s / ~2s / ~4s backoff or `Retry-After`) | **High risk:** Retrying `GET` inside an open SQL transaction can hold DB connections and `FOR UPDATE` locks for **>60 seconds**, triggering Ecto transaction timeouts and pool exhaustion |

**Recommended `req_opts` for `AshBilling.Plug` and `AshBilling.reconcile_subscription/2`:**

```elixir
req_opts: [
  connect_options: [timeout: 3_000],
  receive_timeout: 5_000,
  retry: false
]
```

*(Note: in `Req 0.7+`, `pool_timeout` defaults to `5_000 ms` in Finch and top-level `:pool_timeout` is deprecated in favor of `finch: [pool_timeout: ...]` if you manage a dedicated Finch pool.)*

Setting `retry: false` on webhook-path `GET` requests is intentional: if Stripe fails or times out, `WebhookSync` fails closed (`{:error, {:reconciliation_failed, reason}}`), rolls back the transaction immediately, releases the PostgreSQL connection and `FOR UPDATE` locks, and `AshBilling.Plug` returns **HTTP 500** so Stripe's webhook retry schedule retries outside any database lock.

### 2. Cost of the additional `GET` and lock hold duration

- **Fast-path webhooks (0 `GET` calls):** Duplicates, obsolete timestamps (`event.created < last_event_created_at`), post-terminal non-terminal Stripe events, and no-op webhooks execute purely in PostgreSQL (typically ~1–4 ms local DB time).
- **Financial-diff webhooks on reconciled subscriptions (1 `GET` call):** Lock hold time equals `PostgreSQL lock acquisition + Stripe GET RTT + clock_timestamp() + atomic UPDATE + COMMIT` (typically ~150–400 ms on healthy Stripe API responses; bounded to `<= ~10 s` worst-case with the recommended `req_opts` above).
- **Provider outage behavior:** Fails closed (HTTP 500 / rollback) without applying unverified payloads; no stale state overwrite occurs.

### 3. PostgreSQL pool and timeout recommendations

Because each in-flight financial re-verification or `reconcile_subscription/2` job holds one primary Repo connection for the duration of the Stripe HTTP round-trip:

- **Bound concurrent webhook/reconciliation workers below your Repo `pool_size`:** Reserve at least **30–50% of `pool_size`** for interactive user traffic (or cap concurrency of periodic `reconcile_subscription/2` jobs—e.g. Oban queue `limit: 2..5`—so bulk reconciliation sweeps cannot starve web requests).
- **Align Ecto transaction `:timeout` above the HTTP ceiling:** With `req_opts` bounded (`connect_options: [timeout: 3_000]`, `receive_timeout: 5_000`, `retry: false`, plus Finch's `5_000 ms` `pool_timeout` default), keep Ecto's default `timeout: 15_000` (or `20_000` if network RTT to Stripe is high) so normal retries fail cleanly at the HTTP layer rather than crashing the DBConnection checkout.
- **Set a bounded PostgreSQL `lock_timeout`:** Configure a session/transaction `lock_timeout` (e.g., `2_000ms`–`5_000ms`) so contending webhooks for the same customer fail fast and retry via Stripe HTTP 500 instead of queueing DB connections indefinitely behind a slow provider call.
- **Monitor pool queue pressure (`queue_target` / `queue_interval`) and telemetry:** Watch `[:ash_billing, :webhook, :stop]` and `[:ash_billing, :sync, :exception]` alongside Ecto Repo `queue_time` to detect Stripe latency spikes before they saturate `pool_size`.
