# SaaS Reference Implementation with AshBilling

This reference implementation demonstrates an end-to-end SaaS subscription lifecycle using `ash_billing` with Phoenix and PostgreSQL.

---

## 1. Resource Definitions

### 1.1 Customer (`MyApp.Accounts.User`)

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

  attributes do
    uuid_primary_key :id
    attribute :email, :string, allow_nil?: false, public?: true
    attribute :name, :string, public?: true
  end

  relationships do
    has_many :subscriptions, MyApp.Billing.Subscription, destination_attribute: :user_id
  end

  actions do
    defaults [:read, :create, :update]
  end

  billing do
    customer_id_attribute :stripe_customer_id
    provider AshBilling.Providers.Stripe
  end
end
```

### 1.2 Subscription (`MyApp.Billing.Subscription`)

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
    defaults [:read, :create, :update, :destroy]
  end

  billing_subscription do
    customer_relationship :user
    provider AshBilling.Providers.Stripe
  end
end
```

### 1.3 Persistent Deduplication Event (`MyApp.Billing.WebhookEvent`)

```elixir
defmodule MyApp.Billing.WebhookEvent do
  use Ash.Resource,
    domain: MyApp.Billing,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshBilling.WebhookEvent]

  postgres do
    table "webhook_events"
    repo MyApp.Repo
  end

  actions do
    defaults [:read, :create, :update, :destroy]
  end
end
```

---

## 2. Webhook Router Mounting (`MyAppWeb.Router`)

Mount `AshBilling.Plug` in your Phoenix router. In multi-node production clusters, configure the `:resource` deduplication strategy backed by your PostgreSQL `WebhookEvent` table:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/webhooks" do
    forward "/stripe", AshBilling.Plug,
      provider: AshBilling.Providers.Stripe,
      webhook_secret: {System, :get_env, ["STRIPE_WEBHOOK_SECRET"]},
      customer_resource: MyApp.Accounts.User,
      subscription_resource: MyApp.Billing.Subscription,
      domain: MyApp.Billing,
      deduplicate?: true,
      deduplication_strategy: :resource,
      deduplication_resource: MyApp.Billing.WebhookEvent,
      return_500_on_sync_error: true
  end
end
```

> **Note**: To ensure Stripe payload signatures can be verified, configure Phoenix's `Plug.Parsers` to preserve the raw body on webhook paths:
>
> ```elixir
> plug Plug.Parsers,
>   parsers: [:urlencoded, :multipart, :json],
>   pass: ["*/*"],
>   body_reader: {AshBilling.Plug, :read_body, []},
>   json_decoder: Phoenix.json_library()
> ```

---

## 3. Checkout and Billing Portal Sessions

### 3.1 Initiating Subscription Checkout

```elixir
defmodule MyAppWeb.BillingController do
  use MyAppWeb, :controller

  def subscribe(conn, %{"price_id" => price_id}) do
    user = conn.assigns.current_user

    case AshBilling.create_checkout_session(user,
      mode: "subscription",
      line_items: [%{price: price_id, quantity: 1}],
      success_url: url(~p"/dashboard?billing=success"),
      cancel_url: url(~p"/pricing?billing=canceled")
    ) do
      {:ok, session} ->
        redirect(conn, external: session.url)

      {:error, reason} ->
        conn
        |> put_flash(:error, "Failed to initiate checkout.")
        |> redirect(to: ~p"/pricing")
    end
  end

  def portal(conn, _params) do
    user = conn.assigns.current_user

    case AshBilling.create_portal_session(user, return_url: url(~p"/settings/billing")) do
      {:ok, session} ->
        redirect(conn, external: session.url)

      {:error, reason} ->
        conn
        |> put_flash(:error, "Failed to open billing portal.")
        |> redirect(to: ~p"/dashboard")
    end
  end
end
```

---

## 4. Policy-Protected Resources

Protect domain resources based on subscription status using native Ash policies:

```elixir
defmodule MyApp.Analytics.Report do
  use Ash.Resource,
    domain: MyApp.Analytics,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key :id
    attribute :title, :string, public?: true
    attribute :data, :map, public?: true
  end

  policies do
    # Only users with an active or trialing subscription can read analytics
    policy action_type(:read) do
      authorize_if AshBilling.Checks.Subscribed
    end

    # Only users on the Pro annual plan can export reports
    policy action(:export) do
      authorize_if {AshBilling.Checks.HasPrice, price: "price_pro_annual"}
    end
  end
end
```
