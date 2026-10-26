# AshBilling

[![Hex.pm](https://img.shields.io/hexpm/v/ash_billing.svg)](https://hex.pm/packages/ash_billing)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ash_billing)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Declarative billing, subscriptions, and payment providers for the [Ash Framework](https://ash-hq.org).

Inspired by Laravel Cashier and Rails Pay, `ash_billing` provides a unified, declarative way to handle customers, checkout sessions, customer billing portals, and subscription lifecycles in Ash.

---

## Features

- ⚡ **Declarative Spark DSL**: Add billing customer or subscription capabilities to any Ash resource with clean DSL blocks (`billing do ... end`).
- 💳 **Stripe Provider**: First-class support for Stripe Checkout Sessions, Customer Portal, and Subscriptions.
- 🔌 **Secure Webhook Plug**: Phoenix/Plug endpoint with constant-time HMAC-SHA256 signature verification and replay attack protection.
- 🔄 **Modular Provider Architecture**: Built with an extensible `AshBilling.Provider` behaviour, ready for Stripe, Paddle, LemonSqueezy, and more.
- 🧪 **100% Testable**: Zero external HTTP calls needed during test suites thanks to plug-based stubs.

---

## Installation

Add `ash_billing` to your `mix.exs` dependencies:

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
    handler: MyApp.Billing.WebhookHandler
end
```

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

---

## Configuration

Configure your Stripe API credentials in `config/runtime.exs`:

```elixir
config :ash_billing,
  stripe_api_key: System.get_env("STRIPE_SECRET_KEY")
```

---

## License

MIT License. Copyright (c) 2026 Alejandro Felix.
