# Diagnostics, Recovery CLI & Observability

`AshBilling` provides read-only configuration diagnostics (`AshBilling.Diagnostics` and `mix ash_billing.doctor`), a safe drift-inspection and reconciliation CLI (`AshBilling.Reconciler` and `mix ash_billing.reconcile`), and low-cardinality `:telemetry` instrumentation for production monitoring.

---

## 1. Layered Configuration Diagnostics (`check_configuration/1` & `mix ash_billing.doctor`)

`AshBilling.Diagnostics.run/1` separates checks into three independent layers:

1. **Structural (`:structural`)**: Ash resource definitions, required attributes (`0.6.0` `last_reconciled_at` and `0.7.0` `quantity`/`provider_subscription_item_id`), unconditional unique identities, primary `:update` actions, single shared PostgreSQL Repo, multitenancy alignment, `WebhookEvent` privacy (fails if exposed via `AshJsonApi.Resource` or `AshGraphql.Resource`), deduplication strategy, credential prefixes (never echoing secret values), `expected_livemode` binding, and bounded `req_opts` timeouts.
2. **Database (`:database`, `check_database?: true`)**: Read-only PostgreSQL connectivity (`SELECT 1`), `information_schema.columns` verification for customer, subscription (`0.6.0` & `0.7.0` migrations), and webhook event tables, unconditional unique index verification, and `quantity` check constraint inspection.
3. **Provider (`:provider`, `check_provider?: true`)**: Optional read-only provider probe (Stripe `GET /v1/balance`) verifying connectivity and `livemode` alignment.

`configuration_valid` and `production_ready` are intentionally distinct:

- `configuration_valid: true` means no check returned `:fail`.
- `production_ready: true` requires zero failures, zero warnings (such as `:memory` deduplication, unbounded `Req` defaults, or missing `expected_livemode`), and verified PostgreSQL schema readiness.

### Running `mix ash_billing.doctor`

```bash
# Human-readable PASS / WARN / FAIL report (read-only by default)
mix ash_billing.doctor \
  --customer-resource MyApp.Accounts.User \
  --subscription-resource MyApp.Billing.Subscription \
  --deduplication-resource MyApp.Billing.WebhookEvent \
  --expected-livemode true

# Machine-readable JSON output for CI or deployment gates
mix ash_billing.doctor \
  --customer-resource MyApp.Accounts.User \
  --subscription-resource MyApp.Billing.Subscription \
  --deduplication-resource MyApp.Billing.WebhookEvent \
  --json

# Include optional read-only Stripe connectivity check and fail on warnings
mix ash_billing.doctor \
  --customer-resource MyApp.Accounts.User \
  --subscription-resource MyApp.Billing.Subscription \
  --deduplication-resource MyApp.Billing.WebhookEvent \
  --check-provider \
  --strict
```

---

## 2. Drift Inspection & Safe Reconciliation CLI (`mix ash_billing.reconcile`)

`mix ash_billing.reconcile` (backed by `AshBilling.Reconciler`) inspects financial drift between PostgreSQL and Stripe or runs transactional reconciliation through `AshBilling.reconcile_subscription/2`.

- **Read-only by default (`--dry-run`)**: Reports per-subscription field diffs (`status`, `price_id`, `quantity`, `provider_subscription_item_id`, `current_period_end`, `trial_ends_at`, `cancel_at_period_end`, `cancel_at`) without touching PostgreSQL.
- **Explicit confirmation for writes**: Writing requires `--execute` plus `--confirm` (or interactive prompt approval).
- **Fail-closed selection filters**: Refuses to run without a valid target (`--subscription-id` or `--id`) or explicit bulk filter (`--older-than-hours`, `--status`, `--missing-quantity`, or `--all`). Invalid filters (`--older-than-hours 0`, negative hours, empty/unknown statuses, `--missing-quantity` on a resource lacking `:quantity`) fail before executing any database query or provider HTTP call — never degrading into an unfiltered scan.
- **Authorization, multitenant & Stripe Connect isolation**:
  - Preserves Ash authorization by default (pass `--system` only for trusted CLI maintenance).
  - Multitenant resources require `--tenant`; non-multitenant resources reject `--tenant` rather than silently ignoring it.
  - Passing `--stripe-account` never assumes Stripe headers filter PostgreSQL rows: if the subscription resource defines `:stripe_account_id` or `:stripe_account` (or `--stripe-account-attribute`), PostgreSQL queries are automatically scoped to that account (and `IS NULL` for platform runs). Bulk Connect sweeps without a per-row Connect column fail closed unless a multitenant resource explicitly declares 1:1 tenant-to-account binding with `--stripe-account-scope tenant`.
- **Keyset batch streaming & global rate limiting**: Streams one keyset-paginated batch (`ORDER BY pk ASC`, `pk > cursor`, no `OFFSET`) at a time to bound memory and prevent omissions/duplicates during live updates, with bounded worker concurrency (`1..10`, default `2`), a global cross-worker rate limiter (`--rate-limit-ms`), and bounded HTTP timeouts (`connect_options: [timeout: 3_000], receive_timeout: 5_000, retry: false`).

```bash
# 1. Dry-run drift check for a single subscription
mix ash_billing.reconcile \
  --domain MyApp.Billing \
  --subscription-resource MyApp.Billing.Subscription \
  --subscription-id sub_123 \
  --system

# 2. Dry-run sweep for 0.6.0 rows missing quantity (JSON output)
mix ash_billing.reconcile \
  --domain MyApp.Billing \
  --subscription-resource MyApp.Billing.Subscription \
  --missing-quantity \
  --limit 100 \
  --system \
  --json

# 3. Execute rate-limited reconciliation for subscriptions stale > 24h in a specific tenant
mix ash_billing.reconcile \
  --domain MyApp.Billing \
  --subscription-resource MyApp.Billing.Subscription \
  --older-than-hours 24 \
  --tenant acme_corp \
  --concurrency 2 \
  --rate-limit-ms 100 \
  --system \
  --execute \
  --confirm
```

---

## 3. Telemetry Events & Low-Cardinality Guarantees

All new observability events avoid high-cardinality identifiers (`customer_id`, `subscription_id`, `event_id`, emails, or secrets) in metric tags so they are safe to aggregate in Prometheus, OpenTelemetry, or Phoenix LiveDashboard.

| Event | Measurements | Low-Cardinality Metadata | Description |
| --- | --- | --- | --- |
| `[:ash_billing, :reconcile, :start \| :stop \| :exception]` | `:system_time` / `:duration` | `:provider`, `:mode`, `:status`, `:drift_detected`, `:changed_fields`, `:error_category` | Emitted once per logical `AshBilling.reconcile_subscription/2` call. |
| `[:ash_billing, :reverify, :start \| :stop \| :exception]` | `:system_time` / `:duration` | `:provider`, `:status`, `:drift_detected`, `:changed_fields`, `:error_category` | Emitted once per live provider `GET` re-verification triggered inside `AshBilling.WebhookSync`. |
| `[:ash_billing, :deduplication, :acquire]` | `:count`, `:duration` | `:strategy` (`:resource \| :memory`), `:outcome` (`:acquired \| :duplicate \| :already_processing \| :error`), `:error_category` | Emitted once per logical `AshBilling.Deduplication.acquire/2`. |
| `[:ash_billing, :deduplication, :complete]` | `:count` | `:strategy`, `:status` (`:ok \| :error`) | Emitted once per `AshBilling.Deduplication.complete/2`. |
| `[:ash_billing, :deduplication, :release]` | `:count` | `:strategy`, `:status` (`:ok \| :error`) | Emitted once per `AshBilling.Deduplication.release/2`. |
| `[:ash_billing, :postgres, :contention]` | `:count` | `:operation`, `:reason` (`:lock_timeout \| :lock_not_available \| :deadlock \| :serialization_failure \| :connection_error \| :database_error`) | Emitted when PostgreSQL lock or connection contention aborts a billing transaction. |
| `[:ash_billing, :reconciler, :batch]` | `:duration`, `:total`, `:drifted`, `:reconciled`, `:unchanged`, `:skipped`, `:failed`, `:pages` | `:mode` (`:dry_run \| :execute`) | Emitted once per `AshBilling.Reconciler.run/1` batch. |

Existing spans (`[:ash_billing, :webhook, ...]`, `[:ash_billing, :sync, ...]`, `[:ash_billing, :checkout, ...]`, `[:ash_billing, :portal, ...]`, `[:ash_billing, :swap_plan, ...]`, `[:ash_billing, :update_quantity, ...]`) remain unchanged.

---

## 4. Example Production Metrics Dashboard (`Telemetry.Metrics`)

```elixir
defmodule MyAppWeb.Telemetry do
  import Telemetry.Metrics

  def billing_metrics do
    [
      # Reconciliation latency & drift rate
      summary("ash_billing.reconcile.stop.duration",
        unit: {:native, :millisecond},
        tags: [:provider, :status, :drift_detected]
      ),
      counter("ash_billing.reconcile.stop.count",
        tags: [:provider, :status, :drift_detected, :error_category]
      ),

      # Post-reconciliation live provider GET re-verification latency & failures
      summary("ash_billing.reverify.stop.duration",
        unit: {:native, :millisecond},
        tags: [:provider, :status]
      ),
      counter("ash_billing.reverify.stop.count",
        tags: [:provider, :status, :drift_detected, :error_category]
      ),

      # Webhook deduplication hit rate, in-flight contention & failures
      counter("ash_billing.deduplication.acquire.count",
        tags: [:strategy, :outcome, :error_category]
      ),
      summary("ash_billing.deduplication.acquire.duration",
        unit: {:native, :millisecond},
        tags: [:strategy, :outcome]
      ),
      counter("ash_billing.deduplication.release.count",
        tags: [:strategy, :status]
      ),

      # PostgreSQL lock/connection contention alerts
      counter("ash_billing.postgres.contention.count",
        tags: [:operation, :reason]
      ),

      # Webhook end-to-end processing latency
      summary("ash_billing.webhook.stop.duration",
        unit: {:native, :millisecond},
        tags: [:status]
      )
    ]
  end
end
```

Recommended production alerts:

- **`ash_billing.postgres.contention.count > 0` (sustained)**: Inspect `pool_size`, `lock_timeout`, and `req_opts` (`retry: false`, bounded `receive_timeout`).
- **`ash_billing.reverify.stop.count` with `status: :error`**: Indicates Stripe API degradation causing fail-closed HTTP 500 webhook retries.
- **`ash_billing.reconcile.stop.count` with `drift_detected: true` spiking**: Indicates dropped or delayed webhooks on your ingress endpoint.
