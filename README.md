# AshBilling

[![Hex.pm](https://img.shields.io/hexpm/v/ash_billing.svg)](https://hex.pm/packages/ash_billing)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ash_billing)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Declarative billing, subscriptions, and payment providers for the [Ash Framework](https://ash-hq.org).

Inspired by Laravel Cashier and Rails Pay, `ash_billing` provides a unified, declarative way to handle customers, checkout sessions, customer billing portals, and subscription lifecycles in Ash.

---

## Features

- **Declarative Spark DSL**: Add billing customer or subscription capabilities to any Ash resource with clean DSL blocks (`billing do ... end`).
- **Stripe Provider**: First-class support for Stripe Checkout Sessions, Customer Portal, and Subscriptions.
- **Secure Webhook Plug**: Phoenix/Plug endpoint with constant-time HMAC-SHA256 signature verification and replay attack protection.
- **Modular Provider Architecture**: Built with an extensible `AshBilling.Provider` behaviour, ready for Stripe, Paddle, LemonSqueezy, and more.
- **100% Testable**: Zero external HTTP calls needed during test suites thanks to plug-based stubs.

---

## Installation

The recommended way to install `ash_billing` is using Igniter:

```bash
mix igniter.install ash_billing
```

Igniter automatically adds the dependency to `mix.exs`, configures your customer and subscription resources, mounts the webhook route in your Phoenix router, and sets up runtime configuration.

Alternatively, you can install it manually by adding `ash_billing` to your `mix.exs`:

```elixir
def deps do
  [
    {:ash_billing, "~> 0.1.0"}
  ]
end
```

---

## Quickstart

### 1. Add Billing to your User Resource

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    extensions: [AshBilling.Resource]

  attributes do
    uuid_primary_key :id
    attribute :email, :string, public?: true
    attribute :name, :string, public?: true
  end

  billing do
    # Defaults to :stripe_customer_id
    customer_id_attribute :stripe_customer_id
    provider AshBilling.Providers.Stripe
  end
end
```

### 2. Define a Subscription Resource

```elixir
defmodule MyApp.Billing.Subscription do
  use Ash.Resource,
    domain: MyApp.Billing,
    extensions: [AshBilling.Subscription]

  attributes do
    uuid_primary_key :id
  end

  billing_subscription do
    customer_relationship :user
    provider AshBilling.Providers.Stripe
  end
end
```

The extension automatically manages attributes such as `:provider_subscription_id`, `:status`, `:price_id`, `:current_period_end`, and `:cancel_at_period_end`.

---

### 3. Mount the Webhook Handler in your Phoenix Router

```elixir
# router.ex
scope "/webhooks" do
  forward "/stripe", AshBilling.Plug,
    provider: AshBilling.Providers.Stripe,
    webhook_secret: {System, :get_env, ["STRIPE_WEBHOOK_SECRET"]},
    customer_resource: MyApp.Accounts.User,
    subscription_resource: MyApp.Billing.Subscription,
    domain: MyApp.Billing
end
```

`AshBilling.Plug` verifies the webhook signature and automatically creates, updates, or cancels records in your `Subscription` and `User` resources. You can also pass an optional `handler: MyApp.Billing.WebhookHandler` if you want to listen to custom Stripe events.

---

### 4. Use the High-Level API

#### Create a Customer
```elixir
{:ok, customer_id} = AshBilling.create_customer(user)
```

#### Start a Checkout Session
```elixir
{:ok, session} = AshBilling.create_checkout_session(user,
  price: "price_pro_monthly",
  success_url: "https://myapp.com/billing?success=true",
  cancel_url: "https://myapp.com/billing?canceled=true"
)

# Redirect the user to session.url
```

#### Open the Customer Billing Portal
```elixir
{:ok, portal} = AshBilling.create_portal_session(user,
  return_url: "https://myapp.com/dashboard"
)

# Redirect the user to portal.url
```

#### Check Subscription Status
```elixir
# Check if user has any active/trialing subscription
AshBilling.subscribed?(user)

# Check if user has a specific plan
AshBilling.subscribed?(user, "price_pro_monthly")
```

#### Swap Subscription Plans (Upgrades / Downgrades)
```elixir
# Upgrade to an annual or higher-tier plan with automatic proration
{:ok, updated_sub} = AshBilling.swap_plan(user_subscription, "price_enterprise_annual",
  proration_behavior: "create_prorations"
)

# Update seat quantities (per-seat billing)
{:ok, updated_sub} = AshBilling.update_quantity(user_subscription, 10)
```

#### Resume a Canceled Subscription
```elixir
# Reactivate a subscription that was scheduled to cancel at period end
{:ok, resumed_sub} = AshBilling.resume_subscription(user_subscription)
```

---

## Declarative Ash Policies

Protect any resource action declaratively based on billing status using native Ash policy checks:

```elixir
defmodule MyApp.AI.Prompt do
  use Ash.Resource,
    domain: MyApp.AI,
    authorizers: [Ash.Policy.Authorizer]

  policies do
    # Authorize any user with an active subscription or ongoing trial
    policy action(:generate) do
      authorize_if AshBilling.Checks.Subscribed
    end

    # Require a specific plan tier (e.g., Enterprise)
    policy action(:export_fine_tuned_weights) do
      authorize_if {AshBilling.Checks.HasPrice, price: "price_enterprise_annual"}
    end
  end
end
```

---

## Webhook Deduplication (Single-Node & Clustered)

`ash_billing` provides two deduplication strategies to prevent double-processing on Stripe webhook retries:

### 1. In-Memory ETS (`:memory`, default)
Zero-configuration in-memory ETS table with automatic 24-hour TTL cleanup. Ideal for single-server deployments and local development.

### 2. Database-Backed Resource (`:resource`)
Guarantees deduplication across multi-node clusters (e.g., Fly.io, Kubernetes, AWS ECS) using an Ash resource backed by your database (PostgreSQL, SQLite, MySQL).

Define a webhook event resource:

```elixir
defmodule MyApp.Billing.WebhookEvent do
  use Ash.Resource,
    domain: MyApp.Billing,
    extensions: [AshBilling.WebhookEvent]
end
```

Then configure it in your router or application config:

```elixir
forward "/webhooks/stripe", AshBilling.Plug,
  customer_resource: MyApp.Accounts.User,
  subscription_resource: MyApp.Billing.Subscription,
  deduplication_resource: MyApp.Billing.WebhookEvent
```

---

## Configuration

Configure your Stripe API credentials in `config/runtime.exs`:

```elixir
config :ash_billing,
  stripe_api_key: System.get_env("STRIPE_SECRET_KEY")
```

---

## Telemetry

`ash_billing` emits standard `:telemetry` spans across all critical operations, enabling real-time monitoring via Grafana, AppSignal, Datadog, or Prometheus:

| Event Prefix | Description | Measurements | Metadata |
|---|---|---|---|
| `[:ash_billing, :webhook, :start \| :stop \| :exception]` | Emitted during webhook receipt and signature verification in `AshBilling.Plug`. | `:system_time` / `:duration` | `:conn`, `:provider`, `:status`, `:event_type`, `:event_id` |
| `[:ash_billing, :sync, :start \| :stop \| :exception]` | Emitted during database synchronization in `AshBilling.WebhookSync`. | `:system_time` / `:duration` | `:event_type`, `:event_id`, `:customer_resource`, `:subscription_resource`, `:status` |
| `[:ash_billing, :checkout, :start \| :stop \| :exception]` | Emitted during Checkout session creation in `AshBilling.create_checkout_session/2`. | `:system_time` / `:duration` | `:provider`, `:mode`, `:customer`, `:status`, `:session_id`, `:url` |
| `[:ash_billing, :portal, :start \| :stop \| :exception]` | Emitted during Billing Portal session creation in `AshBilling.create_portal_session/2`. | `:system_time` / `:duration` | `:provider`, `:customer`, `:status`, `:url` |

---

## Supported Stripe API Baseline

`ash_billing` targets modern Stripe API versions (`2023-10-16` through current releases). Payloads are parsed defensively with polymorphic fallback resolvers for customer objects, plans, prices, and timestamps, ensuring backward and forward compatibility across API upgrades.

---

## Security, Financial Responsibility & Support Scope

`ash_billing` provides declarative primitives and synchronization logic for integrating Stripe with the Ash Framework. Please note the following architectural boundaries:

- **Financial Compliance**: Tax calculation, invoice finalization, currency conversion rules, and PCI-DSS compliance boundaries remain the architectural responsibility of the implementing application.
- **Webhook Resilience**: In production environments, always pair `AshBilling.Plug` with a database-backed deduplication resource (`AshBilling.WebhookEvent`) to ensure idempotency across multi-node deployments and automatic Stripe exponential retries.
- **Support & Issues**: The issue tracker is strictly reserved for reproducible bugs and targeted feature enhancements. For architecture questions and implementation advice, please participate in the [Ash Discord](https://discord.gg/HTHRaaVPUc) or [Elixir Forum](https://elixirforum.com/c/ash-framework-forum/).

---

## License

MIT License. Copyright (c) 2026 Alejandro Felix.
