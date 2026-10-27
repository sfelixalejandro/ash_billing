# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v0.1.3] - 2026-10-27

### Added

- **Atomic Deduplication Leases**:
  - Implemented `AshBilling.Deduplication.acquire/2`, `complete/2`, and `release/2`. Uses unique primary key insertion for `:resource` and `:ets.insert_new` for `:memory` to guarantee strictly single-worker execution across concurrent requests and clustered nodes.
- **Multiple Stripe `v1` Signature Verification**:
  - `AshBilling.Providers.Stripe.verify_webhook/4` now parses and validates all `v1` signatures present in `Stripe-Signature` headers using constant-time comparison, allowing zero-downtime webhook secret rotation.
- **Webhook Timestamp Ordering & Live Stripe Reconciliation**:
  - Injected `last_event_created_at` timestamp tracking into `AshBilling.Subscription` DSL. Incoming webhooks older than the recorded event are safely rejected.
  - Added live status reconciliation against Stripe (`provider.get_subscription/2`) to resolve backward or conflicting status transitions (e.g. from `:past_due` to `:active`).
- **Automatic Customer Persistence by Default**:
  - `AshBilling.create_customer/2` now automatically persists generated provider customer IDs onto loaded Ash customer records by default.

### Fixed

- **Custom Handler Failure & Retry Safety**:
  - In `AshBilling.Plug`, custom handlers now run inside the deduplication transaction pipeline. Handlers returning `{:error, reason}` or raising exceptions now trigger lease release and return HTTP 500 so Stripe automatically retries.
- **DSL and Public API Authorization Parity**:
  - Unified evaluation rules across `AshBilling.active_subscription?/1`, `AshBilling.on_trial?/1`, and the DSL calculation `active?`. Terminated or incomplete states (`:unpaid`, `:incomplete`, `:incomplete_expired`, `:canceled`, `:paused`) are strictly prevented from evaluating to active, even when future `trial_ends_at` timestamps exist.

---

## [v0.1.2] - 2026-10-27

### Added

- **Modern Stripe API Payloads (2025/2026)**:
  - Added recursive payload extraction and fallback for nested `items.data[].current_period_end` and `trial_settings` alongside legacy root-level timestamps.
- **Out-of-Order Webhook Protection**:
  - Implemented terminal state guards (`:canceled`, `:incomplete_expired`). Delayed or reordered incoming webhooks cannot resurrect terminated subscriptions.
- **Customer Creation Idempotency & Persistence**:
  - `AshBilling.create_customer/2` now automatically injects a deterministic `Idempotency-Key: "ash_cust_<id>"` header on provider calls.
  - Added `persist: true` option to optionally update customer records immediately in the local data layer.
- **Resilience and Edge Case Test Suite**:
  - Expanded test suite to 171 tests across 36 scenarios covering Spark compile-time verifiers, network/transport outages, out-of-order deliveries, and configuration auditing. Test coverage now stands at 91.32%.
  - Added automated coverage gate in CI (`mix test --cover`).

### Fixed

- **Canceled Subscription Authorization Flaw**:
  - Hardened `AshBilling.Subscription.Transformers.AddSubscriptionAttributes` and `AshBilling.active_subscription?/1` so that terminated subscriptions (`status in [:canceled, "canceled"]`) evaluate strictly to `active? == false`, preventing unauthorized access even if `trial_ends_at` is set in the future.
- **Deduplication Error Propagation**:
  - Hardened `AshBilling.Deduplication.mark_processed/2` to return `{:error, reason}` on storage failures instead of swallowing them. Duplicate key conflicts on `event_id` remain cleanly idempotent (`:ok`), while unexpected errors cause `AshBilling.Plug` to return HTTP 500 to trigger Stripe retry backoff.
- **Database Read Failure Propagation**:
  - Hardened `AshBilling.WebhookSync` to propagate unexpected read failures during customer and subscription lookups back to `AshBilling.Plug` as HTTP 500, preventing duplicate records from silent query misses.

---

## [v0.1.1] - 2026-10-27

### Added

- **Spark DSL Compile-Time Verifiers**:
  - `VerifyCustomerRelationship`: Validates at compile time that the relationship configured via `customer_relationship` actually exists on the resource.
  - `VerifyCustomerIdAttribute`: Validates at compile time that custom `customer_id_attribute` types are string-compatible (`:string` or `:ci_string`).

### Fixed

- **Router and Igniter Option Consistency**:
  - Standardized `customer_resource` option across `AshBilling.Plug`, `AshBilling.WebhookSync`, `Mix.Tasks.AshBilling.Install`, and all documentation.
  - Added transparent backwards-compatible normalization for `:resource` in `AshBilling.Plug` and `AshBilling.WebhookSync`.
- **Test Resources and Multi-Version CI Stability**:
  - Pruned unsupported actions on `AshBilling.Test.WebhookEvent` to ensure clean compile-time validation under `Ash.DataLayer.Ets` across Elixir 1.17 and 1.18.
  - Refactored live Stripe integration test suites to provision dynamic test customers on Stripe instead of relying on static accounts.

---

## [v0.1.0] - 2026-10-26

Initial release of `ash_billing`: Declarative billing, subscription, and payment extensions for the Ash Framework.

### Added

- **Spark DSL Extensions**:
  - `AshBilling.Resource`: Configures customer resources (`customer_id_attribute`, `provider`).
  - `AshBilling.Subscription`: Injects subscription attributes (`provider_subscription_id`, `status`, `price_id`, `current_period_end`, `trial_ends_at`, `cancel_at_period_end`) and calculations (`active?`, `on_trial?`).
  - `AshBilling.WebhookEvent`: Database-backed resource extension for cluster-wide webhook deduplication.
- **Stripe Provider**:
  - `AshBilling.create_customer/2`: Generates Stripe customer records with metadata.
  - `AshBilling.create_checkout_session/2`: Creates Stripe Checkout sessions with pre-filled customer email, metadata, and success/cancel URLs.
  - `AshBilling.create_portal_session/2`: Generates Stripe Customer Billing Portal sessions with defensive configuration checks.
  - `AshBilling.cancel_subscription/2` and `AshBilling.resume_subscription/2`: Subscription cancellation and period-end resumption.
  - `AshBilling.swap_plan/3`: Plan upgrades and downgrades with automatic proration and multi-item resolution.
  - `AshBilling.update_quantity/3`: Per-seat quantity scaling with automatic item resolution.
- **Secure Webhook Plug**:
  - `AshBilling.Plug`: Endpoint with constant-time HMAC-SHA256 signature verification and replay attack protection.
  - HTTP 500 retry protocol: Responds with status 500 on database synchronization failure to trigger Stripe automatic exponential retries.
  - Multi-node deduplication strategies: in-memory ETS (`:memory`) and database-backed Ash resource (`:resource`).
- **Resilient Webhook Synchronization (`AshBilling.WebhookSync`)**:
  - Polymorphic extraction for customer IDs and pricing objects (supporting both string IDs and expanded Stripe maps).
  - Exception-safe UNIX timestamp conversions (`DateTime.from_unix/2`).
  - Idempotent concurrency race resolution: automatic update fallback when duplicate creation arrives concurrently.
- **Native Ash Policies**:
  - `AshBilling.Checks.Subscribed`: Policy check that verifies if the actor has an active subscription or ongoing trial.
  - `AshBilling.Checks.HasPrice`: Policy check restricting access to specified price tiers.
- **Developer Diagnostics & Tooling**:
  - `AshBilling.check_configuration/1` and `AshBilling.verify_configuration!/1`: Pre-flight diagnostics for API keys, secrets, and registered resources.
  - Automated installer task: `mix igniter.install ash_billing` (`Mix.Tasks.Igniter.Install.AshBilling`).
  - Standard `:telemetry` spans across checkout, billing portal, webhook ingestion, and database synchronization.
  - Built-in Spark cheat sheets and ExDoc documentation.
  - Multi-version CI matrix across Elixir 1.17, 1.18 and Erlang/OTP 26, 27.
  - Weekly Canary CI workflow testing against `ash-project/ash@main` and `ash-project/spark@main`.
