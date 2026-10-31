# Upgrading to ash_billing 0.4

## Release status and version choice

`ash_billing` 0.4.0 is published on Hex.pm. The pre-1.0 minor increment signals
required consumer changes: wildcard inputs, Connect scope, supported Repo topology,
migrations and retry-key semantics. Public function names largely remain stable;
deployment behavior is not patch-compatible with 0.3.x. Pin `{:ash_billing, "~> 0.4.0"}`
in `mix.exs`.

## Billing inputs and authorization

Customer identity, `billing_deleted_at`, subscription identity/ownership, status,
price, trial, period, cancellation and ordering attributes are excluded from
`accept :*` / `default_accept :*`. Reading them is unchanged. Calculated entitlements
are not writable action inputs. Explicitly accepted fields remain a consumer choice;
review every such action and protect maintenance operations with system/ownership
policies. Remove sensitive inputs from ordinary user actions. Do not fix failures
by exposing a broad public billing update or by disabling authorization.

Internal webhook writes preserve action validations, constraints and policy checks.
Trusted test setup may construct explicit system changesets; ordinary public inputs
must remain rejected. Verify custom actions and relationships for unintended grants.

## Schema and migration order

Generate and inspect consumer migrations, back up data and apply them before new
workers start. Customer resources require nullable `billing_deleted_at`. Deletion
retains the Stripe customer ID plus this tombstone to process later cancellations;
do not clear either automatically or reattach a deleted identity. Previously lost
associations require application-specific reconciliation, not a guessed backfill.
Retain subscription provider-ID uniqueness and event lease/status/token fields.

For attribute tenants that share event IDs, the event table must have a tenant-scoped
key such as `(tenant_id, event_id)`, not a global unique event ID. Review existing
rows and constraints before changing the key; never assign historical events to an
arbitrary tenant. Customer/subscription uniqueness and ownership must also match
that tenant. Pass the trusted `tenant:` to the Plug and raw deduplication operations.
It is propagated through acquire/reclaim/read/with_lease/complete/release/retry.
The library does not migrate consumer tables or route accounts to tenants for you.
Schema/context tenancy needs separate consumer validation; automated PostgreSQL
coverage here exercises attribute tenancy.

## Stripe platform, Connect and environments

Use the signing secret for the actual endpoint, not a different CLI listener.
Bind `expected_livemode: false` for test and `true` for live. When omitted, a
recognizable sk_/rk_ key supplies mode; an unbound platform endpoint retains legacy
compatibility, so explicitly bind production. The platform default rejects an
account-bearing Connect envelope. Connect snapshot endpoints must set the exact
`stripe_account: "acct_..."` and a verifiable mode. The account also scopes outbound
API/reconciliation requests. Use the matching API key, account, secret and trusted
tenant for that route. Never derive credentials/tenant from untrusted parameters.
V2 context/thin-event envelopes are unsupported and rejected. There is no automatic
multi-account aggregation or account/mode identity migration.

Custom-provider subscription APIs now resolve the resource's provider; explicit
`provider:` overrides take priority. Raw IDs without resource context default to
Stripe. Review integrations that previously relied on that accidental routing.

## Transactions, workers and fencing

Customer, subscription and durable event resources must share one primary Repo
pool. Different primary pools fail closed with HTTP 503, even on one database.
Repo aliases are supported only when explicitly sharing a dynamic Repo target in
the calling process. Do not wrap the HTTP Plug in a caller-owned transaction: the
response must follow the outermost durable commit. Failed commits remain retryable.

Pause new delivery/creators, drain existing webhook handlers, retry workers and
customer creators on every node, then switch all binaries before resuming delivery.
Drain is required because older workers do not acquire the new advisory fences and
tenant lock/key namespaces changed. Let Stripe retry during the pause; do not
acknowledge queued work prematurely. Apply schema changes before new workers and
review rollback carefully: old binaries do not preserve the new security contract.

PostgreSQL execution uses transaction locks plus persistent token CAS. Contending
duplicates can return 503; expired time alone cannot authorize concurrent effects
while the old transaction owns the fence. Memory mode is single-node/non-durable.
Handlers must be bounded and synchronous. External effects remain at-least-once:
use provider idempotency keys or a transactional outbox with unique event/effect IDs.

## Customer idempotency-key transition

Automatic keys now hash resource module, canonical tenant and local ID rather than
only local ID. Explicit caller keys are unchanged. Inventory old in-flight or failed
creates whose remote result was not persisted. Reconcile them with Stripe and, when
retrying the same operation, explicitly supply its original idempotency key; do not
blindly retry with the new automatic key. It can create an orphan customer for an
old unpersisted operation. Existing persisted mappings remain authoritative through
CAS, but CAS cannot undo an already-created remote orphan. Drain old creators first.
Do not clear mappings or tombstones to force recreation.

## Evidence and remaining gates

Historical acceptance on 2026-10-30 used main/PR #5 commit
`fc5d38c5d131a20ab338ab362e083922dce04ff5` in the existing WhiteRoom consumer.
It exercised real Stripe Test Mode platform Checkout, Portal, customer retry,
scheduled cancel/resume/immediate cancel, Test Clock renewal/expiry and payment
failure/recovery. Local currently signed replays separately exercised duplicate,
concurrent and old payloads; a controlled PostgreSQL commit fault returned 503.
These are historical results, not new release-branch Stripe executions.

No real Connect, tenant, live-payment or public HTTPS resend validation is claimed.
Automated PostgreSQL tenant/multi-node tests are separate from real Stripe evidence.
Before publication: review this contract, consumer migrations and worker/key plan;
require CI on the exact PR head; inspect `mix hex.build`; and complete the consumer's
registered HTTPS test endpoint resend procedure. Do not equate local HMAC replays
or `stripe listen` with a resend initiated by Stripe to a registered endpoint.
Never publish test payloads, signing secrets, cookies or Checkout/Portal access URLs.

See [webhook operational guarantees](webhooks-and-resilience.md) and the historical
[F1–F6](https://github.com/sfelixalejandro/ash_billing/blob/fc5d38c5d131a20ab338ab362e083922dce04ff5/documentation/topics/security-remediation.md), [commit/fencing](https://github.com/sfelixalejandro/ash_billing/blob/fc5d38c5d131a20ab338ab362e083922dce04ff5/documentation/topics/webhook-commit-remediation.md) and
[final hardening](https://github.com/sfelixalejandro/ash_billing/blob/fc5d38c5d131a20ab338ab362e083922dce04ff5/documentation/topics/final-security-hardening.md) reports. Their past test counts and
branch status describe their own runs, not this release-preparation CI.
