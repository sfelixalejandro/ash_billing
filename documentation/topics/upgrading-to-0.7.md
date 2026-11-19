# Upgrading to 0.7

Version **0.7.0** adds PostgreSQL persistence and synchronization for subscription item `quantity` and `provider_subscription_item_id`, closing the `0.6.0` gap where seat/quantity changes were sent to Stripe without being projected onto `AshBilling.Subscription`.

## Schema Migration Required

`AshBilling.Subscription` now injects two additional protected nullable attributes on every subscription resource:

- `quantity` (`:integer`, `constraints: [min: 1]`, `allow_nil?: true`, `public?: true`)
- `provider_subscription_item_id` (`:string`, `allow_nil?: true`, `public?: true`)

### 1. Generate and apply Ash / Ecto migrations

```bash
mix ash.codegen add_subscription_quantity
mix ecto.migrate
```

Or if you maintain manual Ecto migrations, add both nullable columns and a positive-integer check constraint:

```elixir
def change do
  alter table(:subscriptions) do
    add :quantity, :integer
    add :provider_subscription_item_id, :text
  end

  create constraint(:subscriptions, :subscriptions_quantity_positive,
           check: "quantity IS NULL OR quantity >= 1"
         )
end
```

### 2. Recommended deployment order

1. **Apply the PostgreSQL migration first:** Add the nullable `quantity` and `provider_subscription_item_id` columns. Existing `0.6.0` rows remain valid with `quantity = NULL` and `provider_subscription_item_id = NULL`.
   - **Never backfill `quantity = 1` via SQL:** Historical rows, metered/usage-based prices, and incomplete custom provider payloads legitimately have `quantity = NULL`.
2. **Roll out `0.7.0` application nodes:** Incoming single-item webhooks (`customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`) will automatically project `quantity` and `provider_subscription_item_id` into PostgreSQL.
3. **Optional post-upgrade reconciliation sweep:** If you want existing `0.6.0` rows with `quantity = NULL` to populate their live Stripe quantities before their next webhook arrives, run a rate-limited sweep using `AshBilling.reconcile_subscription/2` with bounded `req_opts`:

```elixir
{:ok, sub} =
  AshBilling.reconcile_subscription(subscription,
    domain: MyApp.Billing,
    req_opts: [
      connect_options: [timeout: 3_000],
      receive_timeout: 5_000,
      retry: false
    ]
  )
```

## Behavioral Changes

### 1. Quantity and subscription item synchronization

- `AshBilling.WebhookSync` extracts `quantity` (positive integer only; `nil` when omitted, metered, or invalid) and `provider_subscription_item_id` from single-item subscription payloads.
- A webhook that mutates **only** `quantity` (with identical `status`, `price_id`, billing period, and cancellation flags) is detected as a critical financial difference:
  - Updates `quantity` atomically in PostgreSQL.
  - Triggers live provider re-verification (`GET /v1/subscriptions/{id}`) under `FOR UPDATE` when `last_reconciled_at` is set or when two conflicting events share the exact same `created` second.
  - Protects against delayed webhooks carrying stale quantities from overwriting newer reconciled quantities.
- `AshBilling.reconcile_subscription/2` persists `quantity` and `provider_subscription_item_id` atomically alongside `status`, `price_id`, billing period fields, and `last_reconciled_at`.
- Multi-item non-terminal subscriptions (`length(items.data) > 1` or `has_more: true`) remain explicitly rejected with `{:error, :unsupported_subscription_items}` without silently enabling multi-item billing. Terminal multi-item events (`canceled`, `incomplete_expired`) revoke access and persist `price_id: nil`, `quantity: nil`, and `provider_subscription_item_id: nil`.

### 2. Write protection

Both `quantity` and `provider_subscription_item_id` are automatically excluded from wildcard `accept :*` / `default_accept :*` actions by AshBilling's billing attribute protection transformer. Clients cannot mutate seat counts directly via Ash actions; mutations must go through verified provider webhooks or `AshBilling.reconcile_subscription/2`.

### 3. Remote mutation vs. local projection (eventual consistency)

`AshBilling.update_quantity/3` and `AshBilling.swap_plan/3` mutate the subscription remotely in Stripe and return `{:ok, provider_response}`. They do **not** directly write to PostgreSQL:

- **Normal flow (eventual consistency):** Stripe emits a signed `customer.subscription.updated` webhook, which `AshBilling.Plug` / `AshBilling.WebhookSync` processes transactionally to update PostgreSQL `quantity` and `price_id`.
- **When explicit reconciliation is required:** If your application needs immediate read-after-write convergence in PostgreSQL (for example, before allowing a newly purchased seat to be assigned) or when webhooks are delayed/dropped, call `AshBilling.reconcile_subscription/2` explicitly after the provider mutation.
- **Custom providers without `@callback update_quantity/3`:** Legacy fallback to `swap_plan/3` remains unchanged for backwards compatibility; implement `@callback update_quantity/3` in custom providers to avoid price-clobbering risks if a stale `:price_id` is passed.
