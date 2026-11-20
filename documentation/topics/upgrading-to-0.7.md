# Upgrading to 0.7

Version **0.7.0** adds PostgreSQL persistence and synchronization for subscription item `quantity` and `provider_subscription_item_id`, closing the `0.6.0` gap where seat/quantity changes were sent to Stripe without being projected onto `AshBilling.Subscription`.

## Schema Migration Required

`AshBilling.Subscription` now injects two additional protected nullable attributes on every subscription resource:

- `quantity` (`:integer`, `constraints: [min: 0]`, `allow_nil?: true`, `public?: true`)
- `provider_subscription_item_id` (`:string`, `allow_nil?: true`, `public?: true`)

### 1. Generate and apply Ash / Ecto migrations

```bash
mix ash.codegen add_subscription_quantity
mix ecto.migrate
```

Or if you maintain manual Ecto migrations, add both nullable columns and a non-negative check constraint:

```elixir
def change do
  alter table(:subscriptions) do
    add :quantity, :integer
    add :provider_subscription_item_id, :text
  end

  create constraint(:subscriptions, :subscriptions_quantity_non_negative,
           check: "quantity IS NULL OR quantity >= 0"
         )
end
```

### 2. Recommended deployment order

1. **Apply the PostgreSQL migration first:** Add the nullable `quantity` and `provider_subscription_item_id` columns. Existing `0.6.0` rows remain valid with `quantity = NULL` and `provider_subscription_item_id = NULL`.
   - **Never backfill `quantity = 1` via SQL:** Historical rows, metered/usage-based prices, and incomplete custom provider payloads legitimately have `quantity = NULL`.
2. **Roll out `0.7.0` application nodes:** Incoming single-item webhooks (`customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`) will automatically project `quantity` and `provider_subscription_item_id` into PostgreSQL.
3. **Optional post-upgrade reconciliation sweep:** If you want existing `0.6.0` rows with `quantity = NULL` to populate their live Stripe quantities before their next webhook arrives, run a rate-limited sweep using `AshBilling.reconcile_subscription/2` with bounded `req_opts`:

```elixir
{:ok, sub} =
  AshBilling.reconcile_subscription(subscription,
    domain: MyApp.Billing,
    req_opts: [
      connect_options: [timeout: 3_000],
      receive_timeout: 5_000,
      retry: false
    ]
  )
```

## Behavioral Changes

### 1. Quantity and subscription item synchronization

- `AshBilling.WebhookSync` extracts `quantity` and `provider_subscription_item_id` from single-item subscription payloads with strict fail-closed validation:
  1. **Legitimately absent or `nil`** (historical rows, metered/usage-based prices, or custom providers omitting quantity): persisted as `nil` (never defaults to `1`).
  2. **Legitimately `0`** (e.g. a provider-reported zero-seat licensed subscription): persisted as exact `0` contracted seats (never invents `1` seat and never silently clears to `nil`). Note that outbound `AshBilling.update_quantity/3` and `AshBilling.swap_plan/3` still validate positive integers (`>= 1`) for client-initiated seat mutations.
  3. **Present with an invalid type or negative value** (e.g. `-5`, `"10"`, `2.5`, `true`, map): fails closed with `{:error, :invalid_quantity}` before any database write or provider call, rolling back the transaction (HTTP 500 in `AshBilling.Plug`) so an existing valid persisted `quantity` is never silently erased. The same fail-closed validation runs on live provider snapshots during `reconcile_subscription/2` and post-reconciliation re-verification.
- A webhook that mutates **only** `quantity` (with identical `status`, `price_id`, billing period, and cancellation flags) is detected as a critical financial difference:
  - Updates `quantity` atomically in PostgreSQL.
  - Triggers live provider re-verification (`GET /v1/subscriptions/{id}`) under `FOR UPDATE` when `last_reconciled_at` is set or when two conflicting events share the exact same `created` second.
  - Protects against delayed webhooks carrying stale quantities from overwriting newer reconciled quantities.
- `AshBilling.reconcile_subscription/2` persists `quantity` and `provider_subscription_item_id` atomically alongside `status`, `price_id`, billing period fields, and `last_reconciled_at`.
- Multi-item non-terminal subscriptions (`length(items.data) > 1` or `has_more: true`) remain explicitly rejected with `{:error, :unsupported_subscription_items}` without silently enabling multi-item billing. Terminal multi-item events (`canceled`, `incomplete_expired`) revoke access and persist `price_id: nil`, `quantity: nil`, and `provider_subscription_item_id: nil`.

### 2. Write protection (wildcard boundary vs. explicit consumer actions)

Both `quantity` and `provider_subscription_item_id` are automatically excluded from **wildcard** `accept :*` / `default_accept :*` actions by AshBilling's billing attribute protection transformer. This protection does **not** make the attributes globally immutable: if your application explicitly lists `:quantity` or `:provider_subscription_item_id` in an action's `accept` list or mutates them via custom Ash changes, AshBilling does not block those writes. Consuming applications must audit any explicit `accept` lists, custom changes, and Ash authorization policies so client-facing actions cannot modify billing attributes directly.

### 3. Remote mutation vs. local projection (eventual consistency)

`AshBilling.update_quantity/3` and `AshBilling.swap_plan/3` mutate the subscription remotely in Stripe and return `{:ok, provider_response}`. They do **not** directly write to PostgreSQL:

- **Normal flow (eventual consistency):** Stripe emits a signed `customer.subscription.updated` webhook, which `AshBilling.Plug` / `AshBilling.WebhookSync` processes transactionally to update PostgreSQL `quantity` and `price_id`.
- **When explicit reconciliation is required:** If your application needs immediate read-after-write convergence in PostgreSQL (for example, before allowing a newly purchased seat to be assigned) or when webhooks are delayed/dropped, call `AshBilling.reconcile_subscription/2` explicitly after the provider mutation.
- **Custom providers without `@callback update_quantity/3`:** Legacy fallback to `swap_plan/3` remains unchanged for backwards compatibility; implement `@callback update_quantity/3` in custom providers to avoid price-clobbering risks if a stale `:price_id` is passed.

### 4. Partial Failure Recovery (Stripe Confirmed, PostgreSQL Failed Before Commit)

When an application wraps `AshBilling.update_quantity/3` and a local PostgreSQL write inside the same transaction (as demonstrated in `examples/saas_example` to serialize seat downsizing against concurrent seat assignments), a PostgreSQL failure or rollback **after** Stripe has already returned HTTP `200` leaves an intentional temporary divergence:

- **Stripe** holds the confirmed new quantity (authoritative source of truth).
- **PostgreSQL** rolled back cleanly to the pre-mutation snapshot without partial writes or corruption.

**Recovery protocol (no duplicate mutations):**

1. **Do NOT blindly repeat the outbound Stripe `POST`** without an idempotency key or prior state check.
2. Either let Stripe's signed `customer.subscription.updated` webhook converge PostgreSQL automatically, or run `AshBilling.reconcile_subscription/2` (or `mix ash_billing.reconcile --execute --confirm`).
3. Reconciliation executes a read-only `GET /v1/subscriptions/{id}` against Stripe under canonical `Customer -> Subscription` `FOR UPDATE` locks and commits the authoritative `quantity`, `provider_subscription_item_id`, and `last_reconciled_at` atomically. Subsequent reconciliations or delayed webhooks are strictly idempotent and never invent or duplicate financial mutations.

### 5. Locked `update_quantity/3` HTTP Requests & Maximum Lock Hold Time

When calling `AshBilling.update_quantity/3` while holding a PostgreSQL `FOR UPDATE` lock (for example, to serialize seat downsizing against seat assignment), count **all** sequential HTTP requests executed by `update_quantity/3`:

| Call pattern | Outbound Stripe HTTP calls | Worst-case HTTP hold (`connect: 3s, receive: 5s, retry: false`) |
| --- | --- | --- |
| With `:price_id` optimistic assertion (or without `:subscription_item_id`) | **2 sequential requests:** `GET /v1/subscriptions/{id}` + `POST /v1/subscriptions/{id}` | **Up to 16 seconds** (`2 × (3s + 5s)`) |
| With `:subscription_item_id` and **without** `:price_id` | **1 request:** `POST /v1/subscriptions/{id}` | **Up to 8 seconds** (`3s + 5s`) |

Operational consequences for PostgreSQL:

- **Transaction timeout alignment:** Ecto's default `Repo.transaction/2` timeout is `15_000ms` (15s), which is shorter than the **16s** combined worst-case timeout of 2 sequential HTTP requests (`GET` + `POST`). Set an explicit transaction timeout above the combined HTTP ceiling (e.g., `timeout: 20_000`) or tighten `receive_timeout` (e.g., `3_000ms`) so Ecto does not abort a transaction mid-flight while waiting on the second response.
- **Connection pool sizing:** Always enforce `retry: false` inside locked transactions and size `Repo` `pool_size` so concurrent billing mutations cannot starve normal web/webhook traffic during Stripe latency spikes.

### 6. Post-Upgrade Verification with CLI Tools

After deploying `0.7.0`, verify schema migrations, unique indexes, `WebhookEvent` privacy, and bounded HTTP timeouts with:

```bash
mix ash_billing.doctor \
  --customer-resource MyApp.Accounts.User \
  --subscription-resource MyApp.Billing.Subscription \
  --deduplication-resource MyApp.Billing.WebhookEvent \
  --expected-livemode true \
  --strict
```

To inspect `0.6.0` rows with `quantity IS NULL` safely before writing, run:

```bash
mix ash_billing.reconcile \
  --domain MyApp.Billing \
  --subscription-resource MyApp.Billing.Subscription \
  --missing-quantity \
  --system
```

See [Diagnostics, Recovery CLI & Observability](observability-and-diagnostics.md) for full CLI flags and `Telemetry.Metrics` dashboards.
