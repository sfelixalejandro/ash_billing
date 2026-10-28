# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed

- Make Igniter register generated resources and domains, configure credentials at runtime, pass the configured webhook secret, and preserve raw webhook bodies through the endpoint parser. Newly generated PostgreSQL subscriptions inherit the customer's explicitly configured repo; existing custom relationships and body readers are preserved.

- Implement the documented `AshBilling.Plug.read_body/2` parser callback, preserving exact webhook bytes across chunks for signature verification after `Plug.Parsers`.

- Redact API key values from configuration diagnostics and raised verification errors.

- Add a tenant-scoped subscription identity backed by a PostgreSQL unique index after migration. Concurrent create conflicts retry through the normal ownership and lifecycle checks; unrelated persistence errors are preserved. Existing applications must generate and apply the index migration after resolving any duplicate provider subscription IDs.

- Reject contradictory customer and subscription ownership, establish initial metadata-based customer associations atomically, and keep identity failures retryable. Email alone no longer establishes a billing identity; missing customers cannot be replaced by subscription or Checkout session IDs.

- Guard subscription writes atomically against concurrent status changes, including same-second terminal commits during provider reconciliation. Stripe terminal notifications take precedence over same-second snapshots; custom providers may explicitly transition an already-read terminal state. Missing or concurrently changed records return controlled retryable errors.

- Terminal subscriptions (`canceled` and `incomplete_expired`) now return `false` from both the `:canceling?` calculation and `AshBilling.canceling?/1`, even when cancellation fields remain set. The helper accepts both atom and string statuses.

---

## [v0.2.1] - 2026-10-27

### Added

- **Scheduled Cancellation Tracking (`:cancel_at` & `:canceling?`)**:
  - Injected `cancel_at: :utc_datetime_usec` attribute into `AshBilling.Subscription` extension, allowing applications to preserve and display exact future cancellation dates (such as cancellations scheduled from the modern Stripe Customer Portal).
  - Injected `:canceling?` calculation into `AshBilling.Subscription` evaluating whether `cancel_at_period_end == true` or `cancel_at` is scheduled for a future timestamp (`cancel_at > now()`).
  - Added public helper function `AshBilling.canceling?/1` supporting both loaded structs and raw maps.
  - Extended `AshBilling.WebhookSync` to extract `cancel_at` from subscription payloads and authoritative live provider reconciliations.
  - Added `cancel_at` conflict detection to `same_second_conflict?/3` to ensure divergent cancellation timestamps arriving in the same second trigger authoritative live provider reconciliation.

---

## [v0.2.0] - 2026-10-27

Production-grade hardening release delivering distributed multi-node deduplication, atomic conditional webhook synchronization, live provider conflict reconciliation, and distributed PostgreSQL contention testing.

### Added

- **Multi-Node Distributed Deduplication Engine (`AshBilling.Deduplication`)**:
  - Cryptographically secure `lease_token` generated on every lease acquisition.
  - Zombie worker rejection: workers completing (`complete/2`) or releasing (`release/2`) after lease expiration or reclamation are strictly rejected with `{:error, :lease_token_mismatch}`, preventing state corruption from delayed workers.
  - Automatic stale lease reclamation: abandoned leases exceeding configurable TTL (default 60s) or left in `:failed` state are atomically reclaimed with attempt counter incrementing.
  - Fail-fast configuration validation: `:resource` strategy strictly fails with `{:error, :deduplication_resource_not_configured}` rather than silently falling back to local memory, ensuring multi-node deployments fail safely.
  - Resource contract enforcement: validating upfront that persistent deduplication resources have both `:status` and an atomic `:update` action, failing fast with `{:error, :resource_lacks_update_action}`.
  - Immutable `:processed` events: once marked `:processed`, records cannot be released or mutated back to `:failed`.
- **Atomic Conditional Webhook Synchronization (`AshBilling.WebhookSync`)**:
  - `update_subscription_safely/5`: executes conditional updates via `Ash.bulk_update` (`strategy: [:atomic]`) filtering on `(is_nil(last_event_created_at) or last_event_created_at <= ^event_dt)`. Out-of-order older webhooks are discarded without overwriting newer state.
  - Same-second conflict resolution (`same_second_conflict?/3`): detects divergent subscription attributes arriving within the same second and queries the payment provider for authoritative live state.
  - Safe live reconciliation (`reconcile_subscription_with_provider/7`): updates derived from authoritative live provider queries are written through atomic conditional bulk updates, preventing race conditions if newer events arrive during live API calls.
  - Terminal state protection: subscription records in terminal states (`:canceled`, `:incomplete_expired`) cannot be resurrected by delayed or reordered incoming webhooks.
- **Enterprise Webhook Ingestion Protocol (`AshBilling.Plug`)**:
  - Explicit HTTP 503 with `Retry-After: 5` header when an incoming webhook is currently being processed by another worker (`already_processing`), instructing Stripe to back off and retry.
  - HTTP 500 fail-closed semantics for unconfigured deduplication resources, persistence failures, database sync errors, or missing webhook secrets.
  - Zero-downtime secret rotation: verifies all `v1` signatures present in `Stripe-Signature` header using constant-time comparison.
- **PostgreSQL Distributed Contention Test Suite**:
  - Real integration tests (`AshBilling.PostgresDeduplicationTest`) verifying multi-process lease contention, atomic completion, stale lease reclamation, and zombie worker protection against PostgreSQL 16.
  - Automated PostgreSQL 16 service container in GitHub Actions CI with strict CI enforcement (`raise` if PostgreSQL is unavailable when `CI=true`).
- **Spark DSL Compile-Time Verifiers**:
  - `VerifyCustomerRelationship`: validates at compile time that configured customer relationships exist on the target resource.
  - `VerifyCustomerIdAttribute`: validates that custom customer ID attributes are string-compatible.
- **Modernized Stripe API Compatibility**:
  - Recursive payload extraction for nested `items.data[].current_period_end` and `trial_settings` alongside legacy root timestamps.
  - Parameter normalization for `mode` in Checkout Sessions (accepting both `:subscription` and `"subscription"`).
  - Deterministic idempotency keys (`ash_cust_<id>`) on customer creation.

### Changed

- Updated minimum test coverage gate to >= 90.00% in CI.
- Updated documentation and tutorials to `{:ash_billing, "~> 0.2.0"}`.

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
