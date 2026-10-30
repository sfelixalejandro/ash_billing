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

Igniter configures your customer and subscription resources, registers their domains, adds the webhook route, and configures runtime credentials. It adds the raw-body reader when it finds the endpoint parser, preserving existing custom readers. Newly generated subscriptions inherit the customer's explicitly configured PostgreSQL repo. Review its notices, configure persistent webhook deduplication for production, and generate and apply your database migrations.

### Manual Installation

Add `ash_billing` to your `mix.exs`:

> Release preparation: 0.4.0 is not published yet; use a reviewed Git commit until publication.

```elixir
def deps do
  [
    {:ash_billing, "~> 0.4.0"}
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
  stripe_api_key: System.get_env("STRIPE_SECRET_KEY"),
  stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET")
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

  postgres do
    table "users"
    repo MyApp.Repo
  end

  relationships do
    has_many :subscriptions, MyApp.Billing.Subscription, destination_attribute: :user_id
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update]
  end

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

  postgres do
    table "subscriptions"
    repo MyApp.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :user_id, :uuid, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :user, MyApp.Accounts.User
  end

  actions do
    default_accept :*
    defaults [:read, :create, :update, :destroy]
  end

  billing_subscription do
    customer_relationship :user
    provider AshBilling.Providers.Stripe
  end
end
```

`AshBilling.Subscription` automatically manages:
- **Attributes**: `:provider_subscription_id`, `:status`, `:price_id`, `:current_period_end`, `:trial_ends_at`, `:cancel_at_period_end`, `:cancel_at`.
- **Calculations**: `:active?` is true for `active`, for `trialing` with no trial end or a future trial end, and for `past_due` with a future `trial_ends_at`. `:on_trial?` follows the trial rules. `:canceling?` is true for nonterminal subscriptions with `cancel_at_period_end: true` or a future `cancel_at`; terminal statuses always return false.
- **Identity**: provider subscription IDs are unique within the resource and its Ash tenant. Each scope must correspond to one provider/account/environment.

These examples assume an existing `MyApp.Repo` configured for AshPostgres and UUID customer primary keys. Register both resources in their respective domains and register those domains in application configuration. For example:

```elixir
defmodule MyApp.Accounts do
  use Ash.Domain, otp_app: :my_app
  resources do
    resource MyApp.Accounts.User
  end
end

defmodule MyApp.Billing do
  use Ash.Domain, otp_app: :my_app
  resources do
    resource MyApp.Billing.Subscription
  end
end
```

```elixir
# config/config.exs
config :my_app, ash_domains: [MyApp.Accounts, MyApp.Billing]
```

Generate and apply the tables and unique index:

```sh
mix ash.codegen create_billing_tables
mix ash.migrate
```

Existing installations must resolve duplicate provider subscription IDs before applying the new index. See [webhook identity and migration](../topics/webhooks-and-resilience.md#subscription-identity-and-migration).

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

If `Plug.Parsers` runs before your router, preserve the signed request bytes:

```elixir
# In endpoint.ex, update the existing Plug.Parsers configuration.
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Phoenix.json_library(),
  body_reader: {AshBilling.Plug, :read_body, []}
```

If you already have a custom body reader, preserve it and ensure it assigns the complete raw body to `conn.assigns[:raw_body]`. Configure database-backed webhook deduplication for production as described in the [resilience guide](../topics/webhooks-and-resilience.md).

The handler verifies signatures before synchronization. Initial customer association requires a server-generated local reference; contradictory ownership returns a retryable error.

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

Use built-in checks in your existing resource's `policies` block. The example assumes the resource already defines read and export actions:

```elixir
policies do
  policy action_type(:read) do
    authorize_if AshBilling.Checks.Subscribed
  end

  policy action(:export) do
    authorize_if {AshBilling.Checks.HasPrice, price: "price_enterprise_annual"}
  end
end
```

---

## 6. Pre-flight Diagnostics

Validate the supplied resource contracts and credential formats before booting your application. This diagnostic does not contact Stripe, verify database migrations, or require absent credentials:

```elixir
AshBilling.verify_configuration!(
  customer_resource: MyApp.Accounts.User,
  subscription_resource: MyApp.Billing.Subscription,
  api_key: System.get_env("STRIPE_SECRET_KEY"),
  webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET")
)
```
