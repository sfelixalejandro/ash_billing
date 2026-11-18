# AshBilling — Next Engineering Phase Plan (`0.5.x` → `0.6.x`)

**Baseline**: `v0.5.2` (`main`, commit `fed6821`)  
**Guiding Principle**: Convert existing safety guarantees into verifiable contracts, eliminate silent CI/reconciliation blind spots, and establish a reproducible integration experience without breaking `0.5.x` public APIs.

---

## 1. Roadmap Separation: `0.5.x` Patches vs `0.6.x` Features

| Track | Scope | Compatibility | Target |
|---|---|---|---|
| **0.5.x (Hardening & Contracts)** | Canary CI PostgreSQL 16 + failure classification; `reconcile_subscription/2` concurrency & timestamp fix; formal Billing Invariants specification; Stripe Test Mode integration plan & SaaS example gap analysis. | 100% backward-compatible; no new public APIs or breaking DSL/schema changes. | Immediate PR (`0.5.3` / `main`) |
| **0.6.x (DX, Observability & Reference App)** | Runnable Phoenix + AshPostgres SaaS reference application (`examples/saas_example`); Stripe Test Clocks automated E2E scenario runner; expanded `:telemetry` spans (`reconcile`, `deduplication`); `check_configuration/1` repo-pool & `WebhookEvent` checks; `mix ash_billing.doctor` / `mix ash_billing.reconcile` repair CLI tasks; optional `Invoice` sync or metered usage helpers (only if justified). | Additive minor release; optional Mix tasks and new telemetry events documented in upgrade guide. | Next minor (`0.6.0`) |

---

## 2. Prioritized Workstreams, Risks & Acceptance Criteria

### P0 — Fix Canary CI Infrastructure & Failure Visibility (`0.5.x`)
- **Problem**: `.github/workflows/canary.yml` runs `mix test` against `ash@main` and `spark@main` without a PostgreSQL 16 service or `POSTGRES_*` env vars, causing guaranteed infrastructure failures. Furthermore, `continue-on-error: true` on the job masks real compatibility regressions behind a green workflow badge.
- **Risks**:
  - Upstream `ash`/`spark` breaking changes go unnoticed until a release.
  - Transient GitHub/Hex fetch outages look identical to Ash/Spark API incompatibilities.
- **Proposed Design**:
  1. Add `services: postgres` (`postgres:16` with `pg_isready` healthcheck) and `POSTGRES_*` env vars matching `.github/workflows/ci.yml`.
  2. Remove `continue-on-error: true` from the job so `Canary CI` fails loudly when `ash@main` or `spark@main` breaks `AshBilling` (since `canary.yml` runs only on `schedule` and `workflow_dispatch`, it remains non-blocking for PRs).
  3. Add explicit step IDs (`deps`, `postgres`, `compile`, `test`) and an `if: always()` classification step writing `INFRASTRUCTURE_FAILURE` vs `COMPATIBILITY_FAILURE` vs `PASS` to `$GITHUB_STEP_SUMMARY`.
- **Acceptance Criteria**:
  - `canary.yml` provisions PostgreSQL 16 and verifies `pg_isready` before compiling/testing.
  - A failed `compile` or `test` step fails the workflow run instead of reporting success.
  - Workflow summary clearly separates `deps`/`postgres` infra failures from `compile`/`test` compatibility failures.

### P0 — `reconcile_subscription/2` Concurrency & Lock Error Propagation (`0.5.3`)
- **Problem**: In `v0.5.2`, `AshBilling.reconcile_subscription/2` called `get_subscription/2` **outside** `ResourceLock.run` and silently discarded read/lock errors with `_ =` during lock acquisition:
  1. **TOCTOU Race**: If a real webhook commits a newer state (`price_pro` or `past_due`) while `get_subscription/2` is in-flight with an older snapshot (`price_basic`), `reconcile_subscription/2` ran Afterward and overwrote the newer database state with the stale snapshot.
  2. **Silent Lock/Query Errors**: Failed initial lookups or PostgreSQL `FOR UPDATE` lock acquisitions were discarded via `_ =`, allowing reconciliation to proceed unlocked or mask DB errors.
- **0.5.3 Trade-off & Preserved `v0.5.2` Timestamp Behavior**:
  - Holding `Customer -> Subscription` `FOR UPDATE` locks during `get_subscription/2` prevents the in-flight TOCTOU race and serializes concurrent webhooks (requiring bounded HTTP timeouts on `Req`, matching `reconcile_subscription_with_provider/7`).
  - Rather than setting `"created" => nil` (which would leave delayed older webhooks `t_old > last_event_created_at` unprotected without a schema migration) or introducing temporary node-local ETS state, `0.5.3` retains `v0.5.2`'s `"created" => System.system_time(:second)` inside the lock boundary and documents its existing host-clock-skew limitation.
- **Acceptance Criteria (`0.5.3`)**:
  - Deterministic concurrent test verifies PostgreSQL `pg_locks` contention and proves a concurrent webhook is serialized rather than overwritten by an in-flight stale snapshot.
  - Lock/query errors (`lock_timeout`, missing scoped tenant) propagate `{:error, _}` without calling the provider; missing local records (`{:ok, nil}`) succeed cleanly.
  - Zero causality regression vs `v0.5.2`: delayed older webhooks (`event.created < reconciled_at`) are still rejected by `existing_event_newer?/2` without relying on in-memory ETS.

### P1 — Formal Billing Invariants Specification (`0.5.x`)
- **Problem**: Financial and concurrency guarantees are scattered across `README.md`, `AUDIT_REPORT.md` (local only), and test comments rather than a single public engineering contract.
- **Proposed Design**: Add a concise, verifiable **Billing Invariants** section to `documentation/topics/webhooks-and-resilience.md` covering:
  1. Authoritative State (Provider vs PostgreSQL projection).
  2. Local Synchronization Boundaries (`ProtectBillingAttributes`, `ResourceLock`, atomic `WebhookEvent` `:processed` transitions).
  3. Entitlements / Access Control (`Subscribed`, `HasPrice`, fail-closed statuses, `current_period_end` non-enforcement).
  4. Event Ordering & Causality (terminal immutability, `last_event_created_at`, same-second/backward conflict reconciliation, serialized `reconcile_subscription/2`).
  5. Expirations & Webhook Drift (dependency on webhooks + periodic `reconcile_subscription/2`).
  6. Idempotency (remote `idempotency_key`, `:memory` vs PostgreSQL `:resource` lease fencing, at-least-once external handlers).
- **Acceptance Criteria**:
  - Every stated invariant maps directly to verified code paths and existing/new tests, and `mix docs --warnings-as-errors` passes.

### P1 — Real Stripe Test Mode Integration Plan (`0.5.x` plan → `0.6.x` automation)
- **Scope**: Extend `examples/stripe_test_mode` with a deterministic scenario matrix using **Stripe Test Clocks** (`v1/test_helpers/test_clocks`) and Stripe CLI forwarding:
  1. **Customer & Persistence**: `create_customer/2` with `persist: true` + idempotent retry.
  2. **Checkout & First Invoice**: `mode: "subscription"`, test card `4242...`, verify `checkout.session.completed` + `customer.subscription.created` + `invoice.paid` -> `Subscribed` authorizes.
  3. **Renewal via Test Clock**: Bind customer to a Test Clock, advance +32 days, wait for `invoice.payment_succeeded` + `customer.subscription.updated`, assert `current_period_end` advances and access remains authorized. Also test renewal failure (declining card / `past_due` -> `unpaid` -> access revoked).
  4. **Cancellation**: `cancel_subscription(sub, at_period_end: true)`, verify `canceling?/1` is `true` while `Subscribed` remains `true`; advance Test Clock past `current_period_end`, verify `customer.subscription.deleted` revokes access. Test immediate cancellation separately.
  5. **Plan Swap**: `swap_plan/3` with `proration_behavior: "create_prorations"` -> verify `price_id` updated, `HasPrice` switches plans, and item quantity is preserved.
  6. **Quantity Update**: `update_quantity/3` to 20 seats -> read subscription back from Stripe to verify `quantity == 20` and `price_id` unchanged; test stale `:price_id` returns `{:error, {:price_mismatch, actual}}`.
  7. **Webhook Loss Recovery**: Stop webhook forwarder, cancel or swap plan via Stripe API, restart forwarder without replay, run `AshBilling.reconcile_subscription/2`, and assert PostgreSQL converges to Stripe's live state.
- **Safety Constraint**: Strictly `sk_test_` keys with `livemode=false` assertion; never commit credentials or raw event dumps.

### P2 — Reference SaaS Example Gap Analysis (`0.5.x` plan → `0.6.x` implementation)
- **Current State (`examples/saas_example`)**: Contains only a single `README.md` with static code snippets. It has no `mix.exs`, no `Ash.Domain` definitions, no Ecto `Repo` or migrations, no Phoenix Endpoint/Plug parser setup, no tests, and no examples of `reconcile_subscription/2`, `update_quantity/3`, or `swap_plan/3`.
- **What is needed to make it reproducible for third parties (`0.6.0`)**:
  1. Convert `examples/saas_example` into a standalone compilable Mix/Phoenix project (or AshPostgres + Plug runnable app) pinned to `{:ash_billing, "~> 0.5.3"}` (or `{:ash_billing, path: "../.."}` in repo CI).
  2. Include `docker-compose.yml` for PostgreSQL 16, `mix ash.migrate` / SQL migrations for `users`, `subscriptions`, and `webhook_events`.
  3. Implement full controller/LiveView flows: Subscribe (Checkout), Manage Seats (`update_quantity/3`), Change Plan (`swap_plan/3`), Billing Portal, Policy-protected endpoint (`Subscribed` + `HasPrice`), and a sample Oban reconciliation worker calling `reconcile_subscription/2`.
  4. Include an offline ExUnit suite (`Req.Test` + signed webhook Plug tests) executed in CI so the example never rots.

### P2 — Observability, Diagnostics & Manual Repair (`0.6.x`)
- **Telemetry**:
  - Add `:telemetry.span` for `[:ash_billing, :reconcile]` (including `drift_detected?: boolean()` metadata) and `[:ash_billing, :deduplication]` (lease acquired, duplicate hit, stale lease reclaimed, failed release).
  - Document all telemetry metrics/metadata and provide a sample `Telemetry.Metrics` dashboard definition.
- **Configuration Diagnostics (`check_configuration/1`)**:
  - Extend `check_configuration/1` to accept optional `:deduplication_resource` and verify:
    1. All configured resources (`customer`, `subscription`, `deduplication`) share the same `AshPostgres` `Repo` pool.
    2. `Subscription` includes recommended hardening attributes (`:last_event_created_at`, `:cancel_at`, `:trial_ends_at`).
    3. `WebhookEvent` is not exposed via public `AshJsonApi` / `AshGraphql` extensions if present.
- **Sync Errors & Manual Repair Tools**:
  - Provide `mix ash_billing.doctor` (runs `check_configuration/1` + checks DB connectivity/indexes).
  - Provide `mix ash_billing.reconcile` (e.g., `--subscription sub_...` or `--stale-hours 24`) and a helper to inspect `:failed` / stale `:processing` rows in `WebhookEvent`.

---

## 3. Execution Order for This Phase

1. **Commit & PR Scope (`0.5.3` — PR #13)**:
   - `NEXT_PHASE_PLAN.md` (architecture & phase split).
   - `.github/workflows/canary.yml` (PostgreSQL 16 + failure classification + no hidden failures).
   - `lib/ash_billing.ex`: `reconcile_subscription/2` lock-serialized fetch (`Customer -> Subscription` `FOR UPDATE`), lookup/lock error propagation, and preserved `v0.5.2` `"created" => now` semantics (zero ETS state), plus deterministic `pg_locks`, error-propagation, and non-regression tests in `test/ash_billing/hardening_remediation_test.exs`.
   - `documentation/topics/webhooks-and-resilience.md` (Billing Invariants section & `0.5.x` clock-skew boundary).
2. **Deferred to `0.6.0` (separate PR)**:
   - **Durable PostgreSQL reconciliation checkpoint (`last_reconciled_at`)**: Add `last_reconciled_at` (`Ash.Type.UtcDatetimeUsec`, nullable) to `AddSubscriptionAttributes` (with Ecto migration and `upgrading-to-0.6.md`), updated atomically inside the same PostgreSQL `FOR UPDATE` transaction as `reconcile_subscription/2` (`clock_timestamp()` + monotonic `max`). Once `last_reconciled_at` is present, duplicate, obsolete (`event.created < last_event_created_at`), or financially identical webhooks skip provider calls, while any non-terminal or terminal webhook changing synchronized financial attributes (`status`, `price_id`, `current_period_end`, `trial_ends_at`, `cancel_at_period_end`, `cancel_at`) re-verifies live provider state under `FOR UPDATE` regardless of `event.created` age (including outside a 60s window), failing closed on Stripe outages (`reconciliation_failed`). Cost/limits: one live `GET` under lock per financial mutation on reconciled subscriptions; local `quantity` is not stored on `Subscription`.
   - Acceptance suite for `0.6.0`: restart durability, real 2-node Erlang `:peer` tests sharing PostgreSQL, multi-day delayed webhooks, concurrent commit races (`pg_locks`), clock skew, terminal-event re-verification, and Stripe/PostgreSQL error rollbacks.
   - Runnable `examples/saas_example` Phoenix app.
   - Automated Stripe Test Clocks E2E suite.
   - New telemetry spans (`:reconcile`, `:deduplication`), `check_configuration/1` extensions, and `mix ash_billing.doctor` / `mix ash_billing.reconcile` tasks.
