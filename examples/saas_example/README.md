# AshBilling Runnable SaaS Reference Application (`examples/saas_example`)

A complete, runnable **Phoenix + Ash + AshPostgres + AshBilling (0.7.0)** SaaS application demonstrating end-to-end subscription billing, per-seat quantity enforcement, Ash policy authorization (`Subscribed` & `HasPrice`), HMAC-verified webhooks with PostgreSQL deduplication, authoritative reconciliation, and operational CLIs (`mix ash_billing.doctor` & `mix ash_billing.reconcile`).

---

## Features Included

- **Authentication & Actor Freshness (`SaasExample.Accounts`):**
  - Public registration (`Accounts.register_user/1` / `POST /register`) always assigns `role: :member` and ignores any caller-supplied role; administrative provisioning is isolated to `Accounts.create_admin_user/1` (and Ash `:create_admin` policy).
  - PBKDF2-SHA256 password hashing (native OTP `:crypto.pbkdf2_hmac` + `Plug.Crypto.secure_compare`), CSRF protection, session renewal, and fresh actor + `:subscriptions` reloading on every HTTP request (`SaasExampleWeb.Plugs.AuthPlug`).
- **Stripe Billing Lifecycle (`SaasExample.Billing`):**
  - Server-controlled plan catalog (`SaasExample.Billing.Catalog`: `starter`, `pro`, `enterprise`) — never trusts arbitrary browser-supplied `price_id`.
  - Stripe Customer persistence prior to Checkout (`AshBilling.create_customer/2` with `persist: true`).
  - Stripe Checkout (`AshBilling.create_checkout_session/2`) and Billing Portal (`AshBilling.create_portal_session/2`).
  - Plan Swaps (`AshBilling.swap_plan/3`) preserving contracted seat quantities.
  - Per-seat Quantity Updates (`AshBilling.update_quantity/3`) with optimistic `:price_id` assertion, canonical `Customer (users) -> Subscription (subscriptions)` `FOR UPDATE` locking serialized with seat assignments (preventing concurrent downsize/assign races without deadlocking webhooks or reconciliation), bounded HTTP timeouts (`connect_timeout <= 3_000ms`, `receive_timeout <= 5_000ms`, `retry: false`), and immediate atomic local persistence before lock release.
    - **Lock hold & pool sizing trade-off:** because `:price_id` optimistic verification triggers **2 sequential Stripe HTTP calls** (`GET /v1/subscriptions/{id}` + `POST /v1/subscriptions/{id}`), each concurrent seat-quantity mutation holds its `FOR UPDATE` lock and one `SaasExample.Repo` pool connection for **up to 16 seconds worst case** (`2 × (3s connect + 5s receive)` with `retry: false`; `Repo.transaction` uses `timeout: 20_000` so Ecto does not abort mid-flight before the 16s HTTP ceiling). If PostgreSQL rolls back after Stripe confirms the `POST`, `reconcile_user_subscription/3` (or the Stripe webhook) recovers local consistency via read-only `GET` without duplicating financial mutations. Size `POOL_SIZE` accordingly in deployments with high concurrent billing mutations.
  - Cancellation at period end (`AshBilling.cancel_subscription/2`) and Resume (`AshBilling.resume_subscription/2`).
  - Authoritative Reconciliation (`AshBilling.reconcile_subscription/2`) with `0.6.0` `last_reconciled_at` checkpoints and `0.7.0` `quantity` / `provider_subscription_item_id` sync.
- **Security & Demo Environment Guards (`SaasExample.Security`, `SaasExample.DemoSeeds`):**
  - `config/config.exs` contains no hardcoded `secret_key_base`; `:prod` requires a cryptographically random `SECRET_KEY_BASE` (`>= 64` bytes, rejecting dev/placeholder values) at both `config/runtime.exs` and application startup.
  - Demo seeds with well-known passwords (`password1234`) are strictly blocked in `:prod` and non-dev environments (`SaasExample.DemoSeeds.run!/1`).
- **Authorization Policies & Transactional Seat Limits (`SaasExample.Workspace`):**
  - `SaasExample.Workspace.Seat`: protected by `AshBilling.Checks.Subscribed` + ownership, with PostgreSQL `FOR UPDATE` row-locked seat enforcement against `subscription.quantity` (fails closed when `quantity` is `nil`, `0`, or full).
  - `SaasExample.Workspace.Report`: protected by `AshBilling.Checks.Subscribed` (`:read`, `:create_for_owner`) and `AshBilling.Checks.HasPrice` (`:export_analytics` for Pro/Enterprise; `:enterprise_audit` for Enterprise only) combined with strict owner isolation.
- **Signed Webhooks & PostgreSQL Deduplication (`/webhooks/stripe`):**
  - Raw body capture via `Plug.Parsers` `body_reader: {AshBilling.Plug, :read_body, []}`.
  - HMAC signature verification, `expected_livemode: false` guard, persistent PostgreSQL deduplication via `SaasExample.Billing.WebhookEvent`, bounded HTTP timeouts (`retry: false`), and fail-closed HTTP `500` on sync or Stripe re-verification outages.
- **Operational CLIs & Telemetry:**
  - Pre-configured for `mix ash_billing.doctor` and `mix ash_billing.reconcile`.
  - Low-cardinality `Telemetry.Metrics` definitions in `SaasExampleWeb.Telemetry`.

---

## Quick Start (Docker Compose + PostgreSQL 16)

### 1. Start PostgreSQL 16

```bash
cd examples/saas_example
docker compose up -d postgres
```

### 2. Configure Stripe Test Mode environment

```bash
cp .env.example .env
# Edit .env with your Stripe Test Mode keys (sk_test_... and whsec_...)
# Never use sk_live_ keys in local development (runtime.exs refuses sk_live_ by default)
set -a && source .env && set +a
```

### 3. Install dependencies, run migrations, and load demo data

```bash
mix deps.get
mix ecto.setup
```

`mix ecto.setup` creates the PostgreSQL database, applies the `0.6.0` + `0.7.0` schema migration (`priv/repo/migrations/20261119000001_create_saas_billing_schema.exs`), and seeds four demo accounts (password for all: `password1234`):

| Email | Plan | Seats (used / contracted) | Notes |
| --- | --- | --- | --- |
| `free@example.com` | None | `0 / 0` | Denied by `Subscribed` |
| `starter@example.com` | Starter | `1 / 2` | Allowed by `Subscribed`; denied Pro/Enterprise `HasPrice` |
| `pro@example.com` | Pro | `2 / 5` | Allowed Pro Export `HasPrice`; denied Enterprise Audit |
| `enterprise@example.com` | Enterprise | `2 / 20` | Allowed all actions (`admin` role) |

### 4. Run the Phoenix server

```bash
mix phx.server
# Open http://localhost:4000
# Health check: curl http://localhost:4000/health
```

### 5. Forward Stripe Test Mode webhooks locally (optional, requires Stripe CLI)

```bash
stripe listen --forward-to http://localhost:4000/webhooks/stripe
# Copy the printed whsec_... into STRIPE_WEBHOOK_SECRET in .env and restart mix phx.server
```

---

## Diagnostics & Reconciliation CLI Examples

### Run `mix ash_billing.doctor` (read-only)

```bash
# Text report (structural + PostgreSQL schema/migration/index checks)
mix billing.doctor

# Machine-readable JSON report (CI/deployment gate)
mix ash_billing.doctor \
  --customer-resource SaasExample.Accounts.User \
  --subscription-resource SaasExample.Billing.Subscription \
  --deduplication-resource SaasExample.Billing.WebhookEvent \
  --expected-livemode false \
  --json

# Include optional read-only Stripe connectivity check (requires valid STRIPE_API_KEY)
mix ash_billing.doctor \
  --customer-resource SaasExample.Accounts.User \
  --subscription-resource SaasExample.Billing.Subscription \
  --deduplication-resource SaasExample.Billing.WebhookEvent \
  --expected-livemode false \
  --check-provider \
  --strict
```

### Run `mix ash_billing.reconcile`

```bash
# 1. Dry-run (default, read-only): inspect drift for stale subscriptions (>24h)
mix billing.reconcile.dry_run

# 2. Dry-run single subscription in JSON format
mix ash_billing.reconcile \
  --domain SaasExample.Billing \
  --subscription-resource SaasExample.Billing.Subscription \
  --customer-resource SaasExample.Accounts.User \
  --subscription-id sub_demo_pro \
  --system \
  --json

# 3. Execute confirmed reconciliation for subscriptions missing quantity
mix ash_billing.reconcile \
  --domain SaasExample.Billing \
  --subscription-resource SaasExample.Billing.Subscription \
  --customer-resource SaasExample.Accounts.User \
  --missing-quantity \
  --concurrency 2 \
  --rate-limit-ms 100 \
  --system \
  --execute \
  --confirm
```

---

## Running the Automated Test Suite

Tests run against real PostgreSQL 16 (with `Req.Test` stubbing Stripe HTTP calls and real HMAC signatures on `/webhooks/stripe` — zero Stripe credentials required):

```bash
cd examples/saas_example
mix test
```

Covered suites:
- `test/saas_example/auth_and_isolation_test.exs` — Auth lifecycle, session handling, `/health`, cross-user isolation on subscriptions, seats, reports, and HTTP endpoints.
- `test/saas_example/billing_lifecycle_test.exs` — Checkout, Customer persistence, signed webhook sync, Billing Portal, Plan Swap, Quantity Update, Cancel/Resume, and Reconcile.
- `test/saas_example/policies_and_seats_test.exs` — `Subscribed` & `HasPrice` enforcement across Free/Starter/Pro/Enterprise/Canceled, seat limits (`nil`/`0`/full), downsize protection, and concurrent PostgreSQL `FOR UPDATE` race safety.
- `test/saas_example/webhooks_and_resilience_test.exs` — HMAC verification, `expected_livemode` guard, PostgreSQL deduplication, Stripe `503` outage fail-closed HTTP `500` + lease release/retry, and PostgreSQL lock contention rollback safety.
- `test/saas_example/doctor_and_reconcile_cli_test.exs` — Real `mix ash_billing.doctor` (`production_ready: true`, zero secret leaks) and `mix ash_billing.reconcile` (`--dry-run`, fail-closed invalid filters, confirmed `--execute`).
