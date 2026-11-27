<!--
SPDX-FileCopyrightText: 2026 Alejandro Felix <https://github.com/sfelixalejandro/ash_billing>

SPDX-License-Identifier: MIT
-->

# AshBilling

[![CI](https://github.com/sfelixalejandro/ash_billing/actions/workflows/ci.yml/badge.svg)](https://github.com/sfelixalejandro/ash_billing/actions)
[![Hex.pm](https://img.shields.io/hexpm/v/ash_billing.svg)](https://hex.pm/packages/ash_billing)
[![HexDocs](https://img.shields.io/badge/docs-hexdocs-purple)](https://hexdocs.pm/ash_billing)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**AshBilling** is an independent, community-maintained Elixir library that adds declarative Stripe billing, subscription lifecycle management, Ash policy checks, and PostgreSQL-backed webhook synchronization to applications built with the [Ash Framework](https://ash-hq.org) and Phoenix/Plug.

> `ash_billing` is developed independently for the Ash ecosystem and is not an official core package of the Ash Framework team. Full API and guide documentation is published on [HexDocs](https://hexdocs.pm/ash_billing).

---

## Why AshBilling?

Integrating Stripe directly into an Ash + Phoenix application requires wiring up customer persistence, idempotent Checkout flows, raw-body HMAC signature verification, distributed webhook deduplication, PostgreSQL lock ordering, out-of-order event protection, and Ash authorization checks. AshBilling provides those building blocks as composable Ash extensions and Plug/CLI primitives:

- **Declarative Spark DSL & Compile-Time Verifiers:** Extend your existing customer and subscription resources with `AshBilling.Resource`, `AshBilling.Subscription`, and `AshBilling.WebhookEvent`. Billing fields are automatically excluded from wildcard `accept :*` / `default_accept :*` actions.
- **Customers, Checkout & Billing Portal:** Idempotent customer creation and local persistence (`AshBilling.create_customer/2`), single-item recurring or one-time Stripe Checkout (`AshBilling.create_checkout_session/2`), and self-service Stripe Billing Portal (`AshBilling.create_portal_session/2`).
- **Subscriptions, Plan Swaps & Per-Seat Quantities:** Quantity-preserving plan changes (`AshBilling.swap_plan/3`), price-isolated seat updates (`AshBilling.update_quantity/3` with optional optimistic `:price_id` check), cancellation/resumption, and fail-closed local projection of `quantity` and `provider_subscription_item_id`.
- **Native Ash Policy Checks:** Gate actions declaratively with `AshBilling.Checks.Subscribed` and `AshBilling.Checks.HasPrice` alongside your application's ownership and tenant policies.
- **Verified Webhooks & PostgreSQL Deduplication:** `AshBilling.Plug` verifies constant-time HMAC-SHA256 signatures, enforces replay windows and `expected_livemode`, serializes PostgreSQL writes under `Customer -> Subscription` `FOR UPDATE` locks, tracks processed/in-flight leases in PostgreSQL (`AshBilling.WebhookEvent`), and returns HTTP `500` on sync failures so Stripe retries safely.
- **Drift Recovery & Operational Tooling:** Authoritative provider reconciliation (`AshBilling.reconcile_subscription/2`) with durable PostgreSQL `last_reconciled_at` checkpoints, live provider re-verification against delayed webhooks, `mix ash_billing.doctor`, `mix ash_billing.reconcile`, and `:telemetry` instrumentation.

### Current Provider Scope

- **Implemented provider:** `AshBilling.Providers.Stripe` (Stripe v1 snapshot APIs).
- **Extensible behaviour:** `AshBilling.Provider` defines the provider contract so custom providers can be built, **but Stripe is the only provider implemented in `0.7.0`**. Paddle, LemonSqueezy, and metered/usage-based billing engines are not currently implemented.

---

## Requirements

Verified against `mix.exs` for `v0.7.0`:

- **Elixir:** `~> 1.17`
- **Core dependencies:** `ash ~> 3.0`, `spark ~> 2.1`, `plug ~> 1.14`, `req ~> 0.5`, `jason ~> 1.4`, `telemetry ~> 1.0`
- **Database (recommended for production):** PostgreSQL 16+ with `ash_postgres ~> 2.15`. Distributed multi-node deduplication, `FOR UPDATE` row locking, and `pg_try_advisory_xact_lock` serialization are implemented and verified specifically for PostgreSQL. Non-PostgreSQL data layers (ETS, SQLite, MySQL) do not provide cross-node concurrency guarantees.
- **Web ingress:** Phoenix or Plug (required to mount `AshBilling.Plug` for Stripe webhooks).
- **Optional:** `igniter >= 0.5.0` for automated installation via `mix igniter.install ash_billing`.

---

## Installation

### Option 1: Automated Scaffolding with Igniter

```bash
mix igniter.install ash_billing
```

`mix igniter.install ash_billing` adds the dependency, attaches `AshBilling.Resource` and `AshBilling.Subscription` to your resources, registers their domains in `config/config.exs`, configures `:stripe_api_key` and `:stripe_webhook_secret` in `config/runtime.exs`, mounts `AshBilling.Plug` in your Phoenix router, and injects `body_reader: {AshBilling.Plug, :read_body, []}` into `Plug.Parsers` when detected.

**After running Igniter, you still need to:**
1. Supply `STRIPE_SECRET_KEY` (`sk_test_...` for development) and `STRIPE_WEBHOOK_SECRET` (`whsec_...`).
2. Add an `AshBilling.WebhookEvent` resource on the same PostgreSQL `Repo` for production multi-node deduplication, and configure `expected_livemode` and bounded `req_opts` on `AshBilling.Plug`.
3. Define Ash authorization policies on your customer, subscription, and domain resources.
4. Generate and apply PostgreSQL migrations (`mix ash.codegen` and `mix ash.migrate`).

### Option 2: Manual Installation

Add `ash_billing` to `deps/0` in `mix.exs`:

```elixir
def deps do
  [
    {:ash_billing, "~> 0.7.0"}
  ]
end
```

Run `mix deps.get`, then follow the Quickstart below or [Getting Started with AshBilling](documentation/tutorials/getting-started-with-ash-billing.md).

> **Upgrading from an earlier version?**
> - `0.6.0` → `0.7.0` requires a PostgreSQL migration adding nullable `quantity` and `provider_subscription_item_id` columns. Read [Upgrading to 0.7](documentation/topics/upgrading-to-0.7.md) before deploying.
> - Earlier upgrade guides: [Upgrading to 0.6](documentation/topics/upgrading-to-0.6.md), [Upgrading to 0.5](documentation/topics/upgrading-to-0.5.md), [Upgrading to 0.4](documentation/topics/upgrading-to-0.4.md).

---

## Quickstart

### Fastest Way to Evaluate: Runnable SaaS Reference App

If you want a complete, compiling, tested Phoenix + Ash + AshPostgres application you can boot locally in minutes (with Docker Compose PostgreSQL 16, migrations, demo seeds, authentication, Checkout, Portal, plan swaps, seat enforcement, signed webhooks, `mix ash_billing.doctor`, and `mix ash_billing.reconcile`), clone the repository and start [`examples/saas_example`](https://github.com/sfelixalejandro/ash_billing/tree/main/examples/saas_example):

```bash
git clone https://github.com/sfelixalejandro/ash_billing.git
cd ash_billing/examples/saas_example
docker compose up -d postgres
cp .env.example .env
# Edit .env with your Stripe Test Mode keys (`sk_test_...` and `whsec_...` from `stripe listen`)
set -a && source .env && set +a
mix deps.get
mix ecto.setup
mix billing.doctor
mix phx.server
```

### Conceptual Integration Walkthrough (Existing Phoenix + AshPostgres App)

> **Scope & Prerequisites:** This walkthrough is a **conceptual integration guide** verified against Ash 3 / AshPostgres conventions and [`examples/saas_example`](https://github.com/sfelixalejandro/ash_billing/tree/main/examples/saas_example) (the standalone compiled and test-verified application in this repository is `examples/saas_example`). It assumes an existing Phoenix + AshPostgres app with:
> - `MyApp.Repo` (`AshPostgres.Repo`), `MyAppWeb.Endpoint`, and `MyAppWeb.Router`.
> - Ash domains `MyApp.Accounts` (registering `MyApp.Accounts.User`) and `MyApp.Billing` (registering `MyApp.Billing.Subscription` and `MyApp.Billing.WebhookEvent`).
> - Your own authentication and Ash policies (`authorizers: [Ash.Policy.Authorizer]` + `policies do ... end`) added to `User` and `Subscription` before exposing actions to end users.

#### 1. Configure Ash, Test Mode credentials, and `req_opts`

> **Important (`v0.7.0` HTTP options behavior):** `config :ash_billing, req_opts: [...]` is inspected by `mix ash_billing.doctor`, **but `AshBilling.Providers.Stripe` does not automatically inherit global `Application.get_env(:ash_billing, :req_opts)` in `v0.7.0`**. Pass `:req_opts` explicitly on `AshBilling.Plug` and on each `AshBilling` provider call (e.g. Customer, Checkout, Portal, plan swaps, quantity updates, cancellations, and reconciliation) whenever explicit timeouts or `retry: false` are required—centralizing a helper such as [`SaasExample.Billing.provider_opts/1`](https://github.com/sfelixalejandro/ash_billing/blob/main/examples/saas_example/lib/saas_example/billing.ex#L27-L46) keeps call sites DRY.

```elixir
# config/config.exs
config :ash,
  default_string_length_count: :codepoints

config :my_app,
  ash_domains: [MyApp.Accounts, MyApp.Billing]

config :ash_billing,
  domain: MyApp.Billing,
  customer_resource: MyApp.Accounts.User,
  subscription_resource: MyApp.Billing.Subscription,
  deduplication_strategy: :resource,
  deduplication_resource: MyApp.Billing.WebhookEvent,
  # Inspected by `mix ash_billing.doctor`; pass explicitly per call and on `AshBilling.Plug` in v0.7.0.
  req_opts: [
    connect_options: [timeout: 3_000],
    receive_timeout: 5_000,
    retry: false
  ]
```

```elixir
# config/runtime.exs
# Use Stripe Test Mode credentials (`sk_test_...` and `whsec_...`) in development.
config :ash_billing,
  stripe_api_key: System.get_env("STRIPE_SECRET_KEY"),
  stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET")
```

#### 2. Define Customer, Subscription, and WebhookEvent resources

All three resources must share the **same PostgreSQL `Repo`** so webhook synchronization and deduplication commit in one transaction.

```elixir
# lib/my_app/accounts/user.ex
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.Resource]

  postgres do
    table "users"
    repo MyApp.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  relationships do
    has_many :subscriptions, MyApp.Billing.Subscription,
      destination_attribute: :user_id,
      domain: MyApp.Billing
  end

  actions do
    # AshBilling.Resource injects :stripe_customer_id and :billing_deleted_at
    # and excludes them from wildcard accepts automatically.
    default_accept :*
    defaults [:read, :create, :update]
  end

  billing do
    customer_id_attribute :stripe_customer_id
    provider AshBilling.Providers.Stripe
  end
end
```

```elixir
# lib/my_app/billing/subscription.ex
defmodule MyApp.Billing.Subscription do
  use Ash.Resource,
    domain: MyApp.Billing,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.Subscription]

  postgres do
    table "subscriptions"
    repo MyApp.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :user, MyApp.Accounts.User, domain: MyApp.Accounts
  end

  actions do
    # Protected financial attributes are excluded from wildcard accepts.
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end

  billing_subscription do
    customer_relationship :user
    provider AshBilling.Providers.Stripe
  end
end
```

`AshBilling.Subscription` injects `:provider_subscription_id` (with an unconditional unique identity), `:status`, `:price_id`, `:quantity` (`min: 0`, nullable), `:provider_subscription_item_id`, `:current_period_end`, `:trial_ends_at`, `:cancel_at_period_end`, `:cancel_at`, `:last_event_created_at`, and `:last_reconciled_at`, plus the `:active?`, `:on_trial?`, and `:canceling?` calculations.

```elixir
# lib/my_app/billing/webhook_event.ex
defmodule MyApp.Billing.WebhookEvent do
  use Ash.Resource,
    domain: MyApp.Billing,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.WebhookEvent]

  postgres do
    table "webhook_events"
    repo MyApp.Repo
  end

  # Internal deduplication ledger: never expose via AshJsonApi, AshGraphql, or public forms.
  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end
end
```

Register `MyApp.Accounts.User` in `MyApp.Accounts`, and `MyApp.Billing.Subscription` + `MyApp.Billing.WebhookEvent` in `MyApp.Billing`. When enabling `authorizers: [Ash.Policy.Authorizer]`, ensure `User` includes update/read policies allowing the actor (or execute internal customer persistence with `authorize?: false`), and lock down `Subscription` mutations to admins/system contexts (see [`SaasExample.Accounts.User`](https://github.com/sfelixalejandro/ash_billing/blob/main/examples/saas_example/lib/saas_example/accounts/user.ex) and [`SaasExample.Billing.Subscription`](https://github.com/sfelixalejandro/ash_billing/blob/main/examples/saas_example/lib/saas_example/billing/subscription.ex)).

#### 3. Generate and apply PostgreSQL migrations

```bash
mix ash.codegen create_billing_tables
mix ash.migrate
```

#### 4. Preserve raw webhook bytes and mount `AshBilling.Plug` (Test Mode)

Stripe HMAC verification requires the exact raw request body. Configure `body_reader` on `Plug.Parsers` in `endpoint.ex`:

```elixir
# lib/my_app_web/endpoint.ex
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  body_reader: {AshBilling.Plug, :read_body, []},
  json_decoder: Phoenix.json_library()
```

Mount `AshBilling.Plug` in your router with an explicit `:webhook_secret` (omitting `:webhook_secret` returns HTTP `500` `unconfigured_webhook_secret` fail-closed), `expected_livemode`, PostgreSQL deduplication, and bounded HTTP timeouts:

```elixir
# lib/my_app_web/router.ex (development / Stripe Test Mode)
scope "/webhooks" do
  forward "/stripe", AshBilling.Plug,
    provider: AshBilling.Providers.Stripe,
    webhook_secret: {Application, :get_env, [:ash_billing, :stripe_webhook_secret]},
    expected_livemode: false,
    customer_resource: MyApp.Accounts.User,
    subscription_resource: MyApp.Billing.Subscription,
    domain: MyApp.Billing,
    deduplication_resource: MyApp.Billing.WebhookEvent,
    return_500_on_sync_error: true,
    req_opts: [
      connect_options: [timeout: 3_000],
      receive_timeout: 5_000,
      retry: false
    ]
end
```

> **Production endpoint binding:** Set `expected_livemode: true` (literal boolean) in production so test-mode events cannot be accepted by a live endpoint. Because `AshBilling.Plug` reads `:expected_livemode` as a boolean rather than evaluating an MFA tuple, either split router configuration by environment or wrap `AshBilling.Plug` at runtime (see [`SaasExampleWeb.Plugs.StripeWebhookPlug`](https://github.com/sfelixalejandro/ash_billing/blob/main/examples/saas_example/lib/saas_example_web/plugs/stripe_webhook_plug.ex)).

#### 5. Persist a Customer, start Checkout, and verify in Test Mode

Recurring Checkout requires a persisted customer ID (`{:error, :no_customer_id}` is returned before calling Stripe if missing). Always resolve price IDs from a server-controlled catalog rather than trusting raw browser parameters, and pass `:req_opts` explicitly on each call when deterministic timeouts or `retry: false` are needed:

```elixir
# Conceptual controller snippet: `user` is an authenticated, persisted User struct.
req_opts = Application.get_env(:ash_billing, :req_opts, connect_options: [timeout: 3_000], receive_timeout: 5_000, retry: false)
billing_opts = [actor: user, authorize?: true, req_opts: req_opts]

with {:ok, _customer_id} <- AshBilling.create_customer(user, [persist: true] ++ billing_opts),
     {:ok, user} <- Ash.get(MyApp.Accounts.User, user.id, actor: user, authorize?: true),
     {:ok, session} <-
       AshBilling.create_checkout_session(user,
         mode: "subscription",
         line_items: [%{price: "price_pro_monthly", quantity: 1}],
         success_url: "http://localhost:4000/dashboard?billing=success",
         cancel_url: "http://localhost:4000/pricing?billing=canceled",
         req_opts: req_opts
       ) do
  # Redirect the browser to session.url
  {:ok, session.url}
end
```

Forward Stripe Test Mode webhooks to your local endpoint and run the built-in configuration doctor:

```bash
# Terminal 1: forward signed Stripe Test Mode webhooks (updates whsec_... for STRIPE_WEBHOOK_SECRET)
stripe listen --forward-to http://localhost:4000/webhooks/stripe

# Terminal 2: verify Test Mode resources, PostgreSQL migrations, indexes, and privacy boundaries (read-only)
mix ash_billing.doctor \
  --customer-resource MyApp.Accounts.User \
  --subscription-resource MyApp.Billing.Subscription \
  --deduplication-resource MyApp.Billing.WebhookEvent \
  --expected-livemode false \
  --strict
```

---

## Core API & Authorization Policies

### Billing Operations

> Because `AshBilling.Providers.Stripe` only reads `:req_opts` from the per-call options in `v0.7.0` (not `Application.get_env(:ash_billing, :req_opts)`), pass `req_opts` explicitly—or merge it via a shared wrapper—for Checkout, Customer, Portal, plan swaps, quantity updates, cancellations, and reconciliation whenever you require explicit HTTP timeouts or `retry: false` (default `Req` settings are `receive_timeout: 15_000` and `:safe_transient` retries).

```elixir
req_opts = [connect_options: [timeout: 3_000], receive_timeout: 5_000, retry: false]

# Customer Billing Portal
{:ok, portal} =
  AshBilling.create_portal_session(user,
    return_url: "https://myapp.com/settings",
    req_opts: req_opts
  )

# Subscription status checks (reload `user` with `:subscriptions` at trusted request boundaries)
AshBilling.subscribed?(user)
AshBilling.subscribed?(user, "price_pro_monthly")
AshBilling.canceling?(subscription)

# Swap plan (preserves current Stripe quantity)
{:ok, _remote} =
  AshBilling.swap_plan(subscription, "price_enterprise_monthly",
    proration_behavior: "create_prorations",
    req_opts: req_opts
  )

# Update per-seat quantity (Stripe sends only item ID + quantity; optional :price_id assertion)
{:ok, _remote} =
  AshBilling.update_quantity(subscription, 10,
    price_id: "price_pro_monthly",
    req_opts: req_opts
  )

# Schedule cancel at period end / resume
{:ok, _remote} = AshBilling.cancel_subscription(subscription, at_period_end: true, req_opts: req_opts)
{:ok, _remote} = AshBilling.resume_subscription(subscription, req_opts: req_opts)

# Authoritative reconciliation (fetches live Stripe state and commits under PostgreSQL FOR UPDATE locks)
{:ok, reconciled_sub} =
  AshBilling.reconcile_subscription(subscription,
    domain: MyApp.Billing,
    req_opts: req_opts
  )
```

### Declarative Ash Policies (`Subscribed` & `HasPrice`)

Always combine `AshBilling.Checks.Subscribed` and `AshBilling.Checks.HasPrice` with **ownership or tenant checks** using `forbid_unless` so a subscribed user cannot access another user's records:

```elixir
# Conceptual resource policy snippet (assumes `owner_id` attribute and actions exist).
policies do
  policy action_type(:read) do
    forbid_unless AshBilling.Checks.Subscribed
    authorize_if expr(owner_id == ^actor(:id))
  end

  policy action(:export_analytics) do
    forbid_unless {AshBilling.Checks.HasPrice, price: ["price_pro_monthly", "price_enterprise_monthly"]}
    authorize_if expr(owner_id == ^actor(:id))
  end
end
```

> **Actor Freshness:** Policy checks evaluate the loaded actor snapshot without running extra SQL queries per check. Reload the actor and `:subscriptions` from PostgreSQL at trusted request or job boundaries so cancellations and tombstones take effect immediately.

### Operational CLIs (`doctor` & `reconcile`)

#### Test Mode (`sk_test_...`, `whsec_...` from `stripe listen`, `expected_livemode: false`)

```bash
# Read-only configuration & PostgreSQL schema audit (text or --json; add --check-provider for live GET /v1/balance)
mix ash_billing.doctor \
  --customer-resource MyApp.Accounts.User \
  --subscription-resource MyApp.Billing.Subscription \
  --deduplication-resource MyApp.Billing.WebhookEvent \
  --expected-livemode false \
  --strict

# Read-only drift inspection (--dry-run is the default)
mix ash_billing.reconcile \
  --domain MyApp.Billing \
  --subscription-resource MyApp.Billing.Subscription \
  --older-than-hours 24 \
  --system

# Confirmed transactional reconciliation writes (keyset-paginated, globally rate-limited)
mix ash_billing.reconcile \
  --domain MyApp.Billing \
  --subscription-resource MyApp.Billing.Subscription \
  --missing-quantity \
  --concurrency 2 \
  --rate-limit-ms 100 \
  --system \
  --execute \
  --confirm
```

#### Production Configuration & Verification (`sk_live_...`, Stripe Dashboard `whsec_...`, `expected_livemode: true`)

In production deployments:

- Configure live credentials (`STRIPE_SECRET_KEY=sk_live_...` or restricted `rk_live_...`) and the production Stripe Dashboard webhook endpoint secret (`STRIPE_WEBHOOK_SECRET=whsec_...`). Never enable `stripe listen` or `sk_test_` keys in production.
- Bind `expected_livemode: true` on `AshBilling.Plug` (either in environment-specific router configuration or via a runtime wrapper Plug like [`SaasExampleWeb.Plugs.StripeWebhookPlug`](https://github.com/sfelixalejandro/ash_billing/blob/main/examples/saas_example/lib/saas_example_web/plugs/stripe_webhook_plug.ex)).
- Run the release preflight check with `--expected-livemode true --check-provider --strict` so `doctor` verifies both PostgreSQL schema invariants and live-key alignment against Stripe `GET /v1/balance`:

```bash
mix ash_billing.doctor \
  --customer-resource MyApp.Accounts.User \
  --subscription-resource MyApp.Billing.Subscription \
  --deduplication-resource MyApp.Billing.WebhookEvent \
  --expected-livemode true \
  --check-provider \
  --strict
```

---

## Security & Financial Consistency Model

AshBilling enforces strict local boundaries while remaining explicit about distributed-system limits. **There is no distributed atomic commit between Stripe and PostgreSQL.**

- **Eventual consistency & drift recovery:** `update_quantity/3` and `swap_plan/3` mutate Stripe immediately; local PostgreSQL state converges when Stripe's signed webhook is processed. Call `AshBilling.reconcile_subscription/2` (or `mix ash_billing.reconcile --execute --confirm`) when immediate local convergence is needed or after missed webhooks. If a local database commit fails after Stripe confirms a remote write, recover via read-only `GET` reconciliation rather than blindly repeating outbound writes.
- **Protected attributes & authorization boundaries:** Billing attributes (`stripe_customer_id`, `billing_deleted_at`, `status`, `price_id`, `quantity`, `provider_subscription_item_id`, `last_reconciled_at`, etc.) are excluded from wildcard accepts (`default_accept :*`), but explicit `accept` lists remain your application's authorization responsibility. Never expose `AshBilling.WebhookEvent` via `AshJsonApi`, `AshGraphql`, or public forms.
- **Single-item recurring scope:** Recurring Checkout and local subscription projection support **one** line item per subscription. Multi-item non-terminal updates fail closed (`:unsupported_subscription_items`) while retaining the last supported local snapshot; terminal events (`canceled`, `incomplete_expired`) still revoke access. One-time `mode: "payment"` Checkout supports multiple lines but does not include a fulfillment ledger.
- **Fail-closed quantity semantics:** Legitimately absent or `null` quantities remain `nil` (never defaulted to `1`); explicit `0` persists as `0`; negative or non-integer values fail closed with `{:error, :invalid_quantity}` without erasing valid persisted state.
- **Tenant & Stripe Connect isolation:** Bind one provider, Stripe account, and livemode per resource and tenant. `AshBilling.Reconciler` requires `--tenant` on multitenant resources and refuses unscoped bulk `--stripe-account` sweeps unless database-level isolation is provable (`--stripe-account-attribute` or explicit `--stripe-account-scope tenant` on 1:1 multitenant setups).
- **Webhook deduplication & bounded timeouts:** The default `:memory` ETS deduplication strategy is suitable only for single-node development. Production clusters must use `AshBilling.WebhookEvent` on the shared PostgreSQL `Repo` and pass bounded `req_opts` (`retry: false`) explicitly on `AshBilling.Plug` and outbound provider calls so Stripe degradation does not starve PostgreSQL pools while holding `FOR UPDATE` locks.
- **Stripe API baseline & compliance boundary:** Supports Stripe v1 snapshot events (thin events and non-nil v2 `context` envelopes are rejected). Tax calculation, invoicing rules, currency conversion, and PCI-DSS boundaries remain the responsibility of the consuming application.

See [Webhooks & Operational Resilience](documentation/topics/webhooks-and-resilience.md) for the complete Billing Invariants contract.

---

## Telemetry & Observability

`AshBilling` emits `:telemetry` events across billing operations. Note the distinction between **low-cardinality observability events** (safe to use directly as metric tags in Prometheus, OpenTelemetry, or Phoenix LiveDashboard) and **lifecycle spans** (which include request/entity identifiers intended for structured logging or tracing—do not attach raw IDs or URLs as metric dimensions):

### Low-Cardinality Observability Events (Metric-Tag Safe)

| Event | Measurements | Low-Cardinality Metadata |
| --- | --- | --- |
| `[:ash_billing, :reconcile, :start \| :stop \| :exception]` | `:system_time` / `:duration` | `:provider`, `:mode`, `:status`, `:drift_detected`, `:changed_fields`, `:error_category` |
| `[:ash_billing, :reverify, :start \| :stop \| :exception]` | `:system_time` / `:duration` | `:provider`, `:status`, `:drift_detected`, `:changed_fields`, `:error_category` |
| `[:ash_billing, :deduplication, :acquire \| :complete \| :release]` | `:count`, `:duration` (`:acquire`) | `:strategy`, `:outcome` / `:status`, `:error_category` |
| `[:ash_billing, :postgres, :contention]` | `:count` | `:operation`, `:reason` |
| `[:ash_billing, :reconciler, :batch]` | `:duration`, `:total`, `:drifted`, `:reconciled`, `:unchanged`, `:skipped`, `:failed`, `:pages` | `:mode` |

### Lifecycle Spans (Logging & Tracing)

`[:ash_billing, :webhook, ...]`, `[:ash_billing, :sync, ...]`, `[:ash_billing, :checkout, ...]`, `[:ash_billing, :portal, ...]`, `[:ash_billing, :swap_plan, ...]`, and `[:ash_billing, :update_quantity, ...]` include identifiers such as `:event_id`, `:subscription_id`, `:customer`, `:session_id`, `:url`, and `:conn`. Filter to low-cardinality keys (such as `:provider`, `:status`, `:mode`, `:event_type`) before exporting them as metric tags.

See [Diagnostics, Recovery CLI & Observability](documentation/topics/observability-and-diagnostics.md) for a complete `Telemetry.Metrics` dashboard example and alert guidelines.

---

## Testing & Stripe Test Mode Validation

- **Offline automated testing (no Stripe credentials required):** `AshBilling` supports credential-free unit and PostgreSQL integration tests using `Req.Test` stubs or custom provider modules alongside real HMAC-signed webhook payloads. See [`examples/saas_example/test/`](https://github.com/sfelixalejandro/ash_billing/tree/main/examples/saas_example/test) for reference test patterns covering auth, Checkout, webhooks, seat concurrency, and failure rollbacks.
- **Real Stripe Test Mode validation:** Live verification against Stripe's Test API (`sk_test_`, `livemode=false`) and `stripe listen` CLI webhook forwarding is isolated in [`examples/stripe_test_mode`](documentation/topics/stripe-test-mode.md) so real provider checks remain clearly separated from mock/stub tests.

---

## Documentation Map

### Guides & Examples
- [Getting Started with AshBilling](documentation/tutorials/getting-started-with-ash-billing.md)
- [Webhooks & Operational Resilience (Billing Invariants)](documentation/topics/webhooks-and-resilience.md)
- [Diagnostics, Recovery CLI & Observability](documentation/topics/observability-and-diagnostics.md)
- [Stripe Test Mode Validation](documentation/topics/stripe-test-mode.md)
- [Runnable SaaS Reference App (`examples/saas_example`)](https://github.com/sfelixalejandro/ash_billing/tree/main/examples/saas_example)

### Upgrade Guides
- [Upgrading to 0.7](documentation/topics/upgrading-to-0.7.md) — `quantity` & `provider_subscription_item_id` migration, partial-failure recovery, locked HTTP timeout ceilings
- [Upgrading to 0.6](documentation/topics/upgrading-to-0.6.md) — `last_reconciled_at` migration & `0.5.x` cursor healing
- [Upgrading to 0.5](documentation/topics/upgrading-to-0.5.md) — Customer persistence before Checkout, single-item scope, SQL rollback, handler returns
- [Upgrading to 0.4](documentation/topics/upgrading-to-0.4.md)

### DSL & Project Reference
- [AshBilling.Resource DSL](documentation/dsls/DSL-AshBilling.Resource.md)
- [AshBilling.Subscription DSL](documentation/dsls/DSL-AshBilling.Subscription.md)
- [AshBilling.WebhookEvent DSL](documentation/dsls/DSL-AshBilling.WebhookEvent.md)
- [HexDocs API Reference](https://hexdocs.pm/ash_billing)
- [Changelog](CHANGELOG.md)
- [Security Policy](SECURITY.md)
- [Contributing Guide](.github/CONTRIBUTING.md)

---

## Community & Support

- **Bug reports & feature proposals:** [GitHub Issues](https://github.com/sfelixalejandro/ash_billing/issues)
- **Security vulnerabilities:** Follow [SECURITY.md](SECURITY.md) (private reporting only)
- **Community discussions:** [Ash Discord](https://discord.gg/HTHRaaVPUc) and [Elixir Forum (`#ash`)](https://elixirforum.com/tag/ash)

## License

MIT License. Copyright (c) 2026 Alejandro Felix. See [LICENSE](https://github.com/sfelixalejandro/ash_billing/blob/main/LICENSE).
