# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v0.1.9] - 2026-10-27

### Fixed

- **Persistent Atomic Reclaim for Custom/Degraded Resources**:
  - In `perform_atomic_reclaim/7`, resources lacking `:update` actions no longer perform unpersisted destroys with orphaned tokens. Reclaiming now executes atomic conditional bulk destruction and immediately persists a new lease record with `Ash.create/4`.
  - Propagates errors when resources lack both update and destroy capabilities (`{:error, :resource_lacks_update_action}`).
- **Exhaustive Plug Error Handling & Unconditional Lease Release**:
  - In `AshBilling.Plug`, synchronization, custom handler, deduplication, and completion errors now handle both `return_500_on_sync_error: true` (HTTP 500) and `return_500_on_sync_error: false` (HTTP 200 with error details).
  - Webhooks that fail database synchronization are strictly prevented from executing custom handlers or marking the event as completed/processed, releasing the lease unconditionally to unblock retry delivery.
- **PostgreSQL Fallback Race Integration Test**:
  - Added test case in `postgres_deduplication_test.exs` verifying that a worker attempting fallback release with an obsolete token cannot delete a lease concurrently reclaimed by another worker in PostgreSQL.

---

## [v0.1.8] - 2026-10-27

### Fixed

- **Atomic Conditional Fallback Destruction**:
  - Replaced non-atomic read-then-destroy sequences in `AshBilling.Deduplication.release/2` with strictly conditional `Ash.bulk_destroy/4` (`strategy: [:atomic]`).
  - Destruction queries enforce simultaneous matching of `event_id`, `status == :processing`, and `lease_token` at the SQL level, preventing race conditions where another worker reclaiming an event could have its record deleted by an earlier worker.
- **Strict PostgreSQL CI Enforcement**:
  - `test/test_helper.exs` and `test/ash_billing/postgres_deduplication_test.exs` fail loudly (`raise` / `flunk`) if PostgreSQL is unavailable when `CI=true`.
  - Ensures continuous integration pipelines never silently skip distributed database tests.

---

## [v0.1.7] - 2026-10-27

### Added

- **PostgreSQL Distributed Integration Test Suite**:
  - Added `{:ash_postgres, "~> 2.15", only: [:dev, :test]}` and `{:postgrex, ">= 0.0.0", only: [:dev, :test]}`.
  - Implemented real integration tests (`AshBilling.PostgresDeduplicationTest`) verifying multi-process lease contention, atomic completion, stale lease reclamation, and zombie worker protection directly against PostgreSQL.
  - Configured PostgreSQL 16 service container in GitHub Actions CI across all test matrix environments.

### Fixed

- **Atomic Conditional `complete/2` and `release/2`**:
  - `Deduplication.complete/2` and `Deduplication.release/2` execute single atomic conditional queries via `Ash.bulk_update/4` with `strategy: [:atomic]`, verifying that `event_id`, `status == :processing`, and `lease_token` match simultaneously during write.
  - Zero-record updates distinguish between terminal `:processed` state, `:lease_token_mismatch`, and unacquired leases, preventing zombie or delayed workers from altering records after their lease has been reclaimed.
  - In-memory strategy (`:memory`) refactored with atomic `:ets.select_replace/2` operations, eliminating check-then-act race conditions between lookup and insert.
- **Explicit HTTP 503 on `already_processing`**:
  - `AshBilling.Plug` distinguishes between `already_processed` (HTTP 200) and `already_processing` (HTTP 503 with `Retry-After: 5` header).
  - Webhooks delivered while another worker is actively processing return HTTP 503, instructing Stripe to back off and retry later without prematurely considering the webhook as permanently delivered.

---

## [v0.1.6] - 2026-10-27

### Fixed

- **Atomic Conditional Lease Reclamation**:
  - `AshBilling.Deduplication` implements atomic conditional updates during lease reclamation via `Ash.bulk_update` with an atomic filter ensuring the target record is strictly in `:failed` status or expired `:processing` status during the write operation.
  - Node-level and clustered atomic locking prevents concurrent processes from racing during lease acquisition or reclamation.
- **Unique Acquisition Lease Tokens & Zombie Worker Protection**:
  - Each acquired lease generates a cryptographically secure unique `lease_token`.
  - Reclaiming workers overwrite the `lease_token`. Workers completing (`Deduplication.complete/2`) or releasing (`Deduplication.release/2`) after their lease has expired or been reclaimed receive `{:error, :lease_token_mismatch}`, preventing expired workers from corrupting active processing states or overwriting active leases.
- **Fail-Closed Plug Completion Verification**:
  - `Deduplication.complete/2` contract updated to `@spec complete(String.t() | nil, keyword()) :: :ok | {:error, term()}`.
  - Persistence errors during event completion are no longer silently masked. `AshBilling.Plug` verifies completion success and halts with HTTP 500 (`completion_failed`) if marking `:processed` fails, ensuring Stripe and payment providers retry unconfirmed events.
- **Real Multi-Process Concurrency Test Coverage**:
  - Added parallel concurrency test suites verifying that exactly 1 worker succeeds in winning initial acquisition or reclaiming expired/failed leases across concurrent `Task.async` processes.
  - Added zombie worker rejection tests and persistence failure simulations verifying Plug HTTP 500 fail-closed semantics.

---

## [v0.1.5] - 2026-10-27

### Fixed

- **Persistent Multi-Node Deduplication State Machine & Lease Reclamation**:
  - `AshBilling.WebhookEvent` expanded with persistent lifecycle states: `:status` (`:processing`, `:processed`, `:failed`), `:processed_at`, `:last_attempt_at`, `:attempts`, and `:error`.
  - Abandoned leases held longer than configurable TTL (default 60s) or left in `:failed` state are atomically reclaimed with attempt counter incrementing, preventing event loss and unblocking retries during server restarts or transient crashes.
  - Resource actions in README and DSL now standardise on `defaults [:read, :create, :update, :destroy]` with fallback action handling.
- **Fail-Closed Webhook Secret Resolution**:
  - `AshBilling.Plug` immediately rejects requests with HTTP 500 without computing HMAC signatures when `webhook_secret` is unset, nil, or empty string.
  - `AshBilling.Providers.Stripe.verify_webhook/4` explicitly validates secrets and returns `{:error, :missing_webhook_secret}` rather than calculating hashes against empty strings.
- **Fail-Closed & Atomic ETS Memory Concurrency**:
  - `AshBilling.Deduplication.acquire_memory/1` now executes atomic `:ets.select_replace` with guard expressions for 60s lease reclamation and failed attempt retry.
  - Failures in ETS operations fail closed with `{:error, {:ets_error, reason}}` rather than granting lease.
- **Live Reconciliation Consistency & Retry Triggering**:
  - Webhook synchronization now aborts with `{:error, {:reconciliation_failed, reason}}` when live provider retrieval fails during conflicting status transitions, returning HTTP 500 and triggering provider webhook retry rather than persisting stale payload data.
  - When live reconciliation succeeds, all authoritative attributes (`status`, `price_id`, `current_period_end`, `cancel_at_period_end`, `trial_ends_at`) are extracted directly from the authoritative live subscription record.
- **Public API Function Signature Parity**:
  - `AshBilling.create_customer/2` now defines `def create_customer(record_or_params, opts \\ [])` function head with default empty keyword list.
  - Stripe provider supports both `:req_opts` and `:req_options` for enhanced HTTP client configuration flexibility.

---

## [v0.1.4] - 2026-10-27

### Fixed

- **Spark DSL Transformer Topological Ordering for WebhookEvent**:
  - Declared explicit transformer ordering constraints (`before?`) for `AshBilling.WebhookEvent.Transformers.AddWebhookEventAttributes`, ensuring it executes ahead of `Ash.Resource.Transformers.CachePrimaryKey`, `CacheUniqueKeys`, `AttributesByName`, and `CacheActionInputs`. Guarantees consistent primary key caching across all compiler environments and Elixir versions.
- **Deduplication Error Predicate Generalization**:
  - Relaxed `duplicate_key_error?/1` predicate to match standard uniqueness and constraint error descriptors across PostgreSQL, MySQL, SQLite, and ETS data layers.
- **Application Environment Test Isolation**:
  - Ensured deterministic test isolation by resetting `Application` environment keys in ExUnit `setup` and `on_exit` handlers.

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
