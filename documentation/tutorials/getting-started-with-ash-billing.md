# Getting Started with AshBilling

`AshBilling` brings declarative billing, subscription lifecycles, and payment providers to the [Ash Framework](https://ash-hq.org).

Inspired by Laravel Cashier and Rails Pay, it provides unified DSL extensions, native Ash authorization policies, and an automated synchronization engine for payment providers like Stripe.

---

## 1. Installation

### Automated Installation via Igniter (Recommended)

If you are using [Igniter](https://hexdocs.pm/igniter), install `ash_billing` with a single command:

```bash
mix igniter.install ash_billing
```

Igniter automatically configures your customer and subscription resources, adds the required router scope, and configures runtime environment variables.

### Manual Installation

Add `ash_billing` to your `mix.exs`:

```elixir
def deps do
  [
    {:ash_billing, "~> 0.1.10"}
  ]
end
```

Then fetch your dependencies:

```bash
mix deps.get
```

Configure your credentials in `config/runtime.exs`:

```elixir
config :ash_billing,
  stripe_api_key: System.get_env("STRIPE_SECRET_KEY")
```

---

## 2. Resource Setup

### 2.1 The Customer Resource (e.g. User or Organization)

Add `AshBilling.Resource` to your user or account resource:

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: AshPostgres.DataLayer,
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

The extension injects `:stripe_customer_id` into your resource attributes automatically.

### 2.2 The Subscription Resource

Define a dedicated subscription resource with `AshBilling.Subscription`:

```elixir
defmodule MyApp.Billing.Subscription do
  use Ash.Resource,
    domain: MyApp.Billing,
    data_layer: AshPostgres.DataLayer,
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

`AshBilling.Subscription` automatically manages:
- **Attributes**: `:provider_subscription_id`, `:status`, `:price_id`, `:current_period_end`, `:trial_ends_at`, `:cancel_at_period_end`.
- **Calculations**: `:active?` (boolean, true if status is active, trialing, or past_due with remaining period) and `:on_trial?`.

---

## 3. Webhook Integration

Mount `AshBilling.Plug` in your Phoenix router:

```elixir
# lib/my_app_web/router.ex
scope "/webhooks" do
  forward "/stripe", AshBilling.Plug,
    provider: AshBilling.Providers.Stripe,
    webhook_secret: {System, :get_env, ["STRIPE_WEBHOOK_SECRET"]},
    customer_resource: MyApp.Accounts.User,
    subscription_resource: MyApp.Billing.Subscription
end
```

All incoming webhooks will have their HMAC-SHA256 signature verified and their customer and subscription records updated idempotently in real time.

---

## 4. Checkout Sessions and Billing Portal

### 4.1 Initiating Checkout

Redirect users to Stripe Checkout to collect payment details:

```elixir
{:ok, session} =
  AshBilling.create_checkout_session(user,
    mode: :subscription,
    line_items: [
      %{price: "price_pro_monthly", quantity: 1}
    ],
    success_url: "https://myapp.com/billing?status=success",
    cancel_url: "https://myapp.com/billing?status=cancelled"
  )

# Redirect the user to session.url
```

### 4.2 Customer Billing Portal

Generate a link to the self-service Stripe Customer Portal where users can update payment cards or view invoices:

```elixir
{:ok, portal} =
  AshBilling.create_portal_session(user,
    return_url: "https://myapp.com/settings"
  )

# Redirect the user to portal.url
```

---

## 5. Authorizing with Native Ash Policies

Use built-in Ash policy checks to restrict access to paying subscribers:

```elixir
defmodule MyApp.Content.Document do
  use Ash.Resource,
    domain: MyApp.Content,
    authorizers: [Ash.Policy.Authorizer]

  policies do
    # Only active subscribers or trialing users can read premium documents
    policy action_type(:read) do
      authorize_if AshBilling.Checks.Subscribed
    end

    # Only users subscribed to the Enterprise price tier can export
    policy action(:export) do
      authorize_if {AshBilling.Checks.HasPrice, price: "price_enterprise_annual"}
    end
  end
end
```

---

## 6. Pre-flight Diagnostics

Before booting your application, you can verify that all API credentials, webhook secrets, and registered resources are properly configured:

```elixir
# Raises an informative error if configuration is incomplete
AshBilling.verify_configuration!(MyApp.Accounts.User)
```
