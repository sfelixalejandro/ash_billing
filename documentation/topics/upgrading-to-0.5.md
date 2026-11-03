# Upgrading to 0.5

Version **0.5.0** changes several public contracts from 0.4.x. Requiring a Customer
before recurring Checkout, tightening handler returns and propagating raw lease
errors affect previously valid callers. The minor increment communicates this
compatibility boundary within the pre-1.0 series.

There is no new schema migration. Existing 0.4.0 migrations and shared-Repo
requirements still apply.

## Customer creation before recurring Checkout

Previously, subscription Checkout could omit `customer` and let Stripe create one
per session. Concurrent sessions could produce incompatible identities. It now
returns `{:error, :no_customer_id}` before a provider call unless an ID is present.
Reuse `create_customer/2`; no new customer-management API is required:

```elixir
# user is an authenticated, authorized, persisted resource.
# Add trusted tenant/Stripe account/API options for this deployment scope.
billing_opts = [actor: user, authorize?: true]

with {:ok, _id} <- AshBilling.create_customer(user, [persist: true] ++ billing_opts),
     {:ok, current_user} <- Ash.get(MyApp.Accounts.User, user.id, billing_opts),
     {:ok, session} <- AshBilling.create_checkout_session(current_user,
       Keyword.merge(billing_opts,
         price: "price_pro_monthly",
         success_url: "https://example.com/billing/success",
         cancel_url: "https://example.com/billing/cancel")) do
  {:ok, session.url}
end
```

Creation uses the existing automatic key scoped by resource, canonical tenant and
record ID, and a conditional association. Concurrent requests use the same remote
identity or fail with a recoverable error. A Stripe idempotency conflict while the
first call executes should be retried; it is not permission to generate a fresh key.
The provider's idempotency retention is finite. If creation succeeded remotely but
persistence failed, reconcile the supplied remote ID before creating a replacement,
especially after the provider's retention window. No distributed Stripe/SQL commit
is promised. Existing historical split identities need manual reconciliation.

A loaded record with a different explicitly requested tenant now fails with
`:customer_tenant_mismatch`. One provider/account/environment per resource and tenant
remains required; changing arbitrary credential options does not rebind an existing
customer. Raw IDs and maps are trusted low-level inputs, not authorization tokens.
Never expose their selection to untrusted request parameters.

For resource Checkout, `resource_id` metadata and `client_reference_id` are generated
from that resource; caller overrides no longer replace them. Raw customer-ID callers
can still supply server-generated local references. Record loading and authorization
remain application responsibilities.

## Required persistence

`persist: true` requires a loaded Ash resource and an update action. Missing local
prerequisites fail before remote creation (`:persisted_customer_required`,
`:update_action_required`). Previously, no update action could silently skip the
write. Automatic persistence of loaded records follows the same rule.

A later write/policy/constraint failure returns
`{:error, {:persistence_failed, customer_id, reason}}`. Preserve the remote ID and
reconcile; the error does not mean Stripe creation was undone. Actor, tenant and
domain still apply to the local action. Authorization and validations requiring the
new remote ID run at persistence time. `persist: false` explicitly creates only the
remote customer. An existing loaded ID is returned without contacting the provider.

## Quantities and item selection

Changing price now preserves quantity rather than relying on Stripe's quantity
default. Missing explicit quantity triggers a GET even with `subscription_item_id`.
An explicit item ID and positive integer quantity can still skip GET. There is no
silent quantity fallback. Missing items/quantities, ambiguous selections and truncated
collections return controlled errors. Multiple remote items require an explicit item
ID for mutations; that does not imply multi-item local entitlement support.

`update_quantity/3` validates a positive integer and rejects ambiguous item selection.
Providing `price_id` is still a trusted instruction to use that price; provide the
correct item ID as well when multiple items exist. API success does not confirm that
an upgrade invoice was paid. Existing provider/account credentials and product rules
continue to apply. Quantity preservation uses the fetched snapshot: Stripe does not
provide a compare-and-swap update here. Serialize simultaneous application mutations
of the same item and reconcile external/dashboard changes; this patch cannot make
an external concurrent price/quantity change atomic with its GET/POST pair.

## One local recurring item per subscription

Introducing item resources and migrations in this release would expand
the public model substantially. The supported scope is therefore explicit: exactly
one line in recurring Checkout; multiple payment-mode lines remain supported.
Subscription Checkout with multiple lines returns `:unsupported_subscription_items`.
This deliberately also rejects recurring Checkout with additional one-time lines.

Multi-item nonterminal webhook snapshots and live reconciliation responses are
rejected without storing a partial representation or running the handler. New
unsupported subscriptions receive no local entitlement. Existing subscriptions retain
the last supported snapshot and its entitlements. This is a deliberate compatibility
policy, not a claim that the old snapshot describes current Stripe state: monitor
failures and apply an application access restriction or repair the external subscription.
Line order cannot decide which new price is saved. Terminal snapshots still revoke
access and clear the selected price. A retry alone cannot fix an unsupported model.

## SQL rollback and webhook handlers

Returned synchronization errors now roll back PostgreSQL mutations. The Plug runs
synchronization, synchronous handler SQL and persistent completion in the shared
primary Repo transaction. On failure it rolls back first, then records/releases the
lease in a separate transaction. HTTP responses follow commit/failure recording.
No exception or commit failure should be acknowledged as successful processing.
The legacy `return_500_on_sync_error: false` only opts out for business errors after
successful failure recording; this does not make the event processed.

Handlers must return `:ok`, `{:ok, value}`, or `{:error, reason}`. Previously, any
other value except an error tuple was treated as success. Replace implicit returns
from `send/2`, logging or client calls with an explicit success return after checking
the operation result. Unexpected values and exceptions now return 5xx and remain
retryable. SQL changes through the configured Repo participate; other pools, spawned
work and external services do not. External effects still need idempotency by
stable event/effect IDs or a transactional outbox.

Raw `with_lease/4` callbacks returning `{:error, reason}` now return that error directly
instead of `{:ok, {:error, reason}}` and roll back PostgreSQL work. Raw callers must
release the lease after rollback. If used inside a caller-owned transaction, the caller
owns its commit/acknowledgment; an explicit synchronization rollback rolls back that
owning transaction. The HTTP Plug still rejects external transactions.

Memory completion waits for billing commit but cannot be atomically durable with
PostgreSQL. Use the persistent shared-Repo strategy for durable deduplication.

## Actor freshness, payments and diagnostics

Policy checks reuse a loaded actor snapshot. Refresh both the actor record (including
its deletion tombstone) and subscriptions at a trusted request/job boundary when
revocation freshness is required. Reuse that snapshot for the operation; no per-check
SQL refresh is introduced. Target-resource ownership/tenant policies remain necessary.

Payment-mode Checkout may have no Customer. Its completion event is not necessarily
proof of settled payment: fulfillment must check payment status and support delayed
payment success/failure events. This release adds no payment ledger or fulfillment engine.

`check_configuration/1` remains a partial structural diagnostic. Missing credentials
are still allowed; it does not verify database migrations, readiness, provider access,
or consumer authorization. Deployments should check required environment/configuration
separately. Checkout validates its mode, line-item container and required URLs before
effects; missing prices and malformed containers now return explicit error tuples.

## Release validation

Documentation source links target `v0.5.0`. Require passing CI on the proposed
release commit, inspect the built package, and keep Stripe Test Mode evidence
distinct from local simulations. See the optional
[Stripe Test Mode guide](stripe-test-mode.md) in the repository.
