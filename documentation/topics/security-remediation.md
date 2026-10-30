# Security remediation F1–F6

> Historical report. See [final security hardening](final-security-hardening.md) for
> the subsequent U1–U4 changes, dependency audit, and current release assessment.


## Scope and preserved work

The remediation started at local HEAD `3dc78a1f0d1a86662a1a162d2799fb15153260f8`.
Pre-existing changes in `CHANGELOG.md`, `lib/ash_billing.ex`, and
`test/ash_billing_test.exs` were retained. The initial diff was saved separately as
`/tmp/ash-remediation-preexisting.patch`. No reset, clean, destructive checkout,
commit, push, PR, release, or Hex publication was performed.

The original `/tmp/ash_security_audit_test.exs` and audit report existed and were
reviewed. All ten original diagnostic tests ran and passed before implementation:
seven asserted defective behavior, with two grouped under F2, and three were
negative controls. Thus all six findings remained present. Inverted expectations
and additional adversarial cases are now permanent in
`test/ash_billing/security_regression_test.exs`.

## Findings and implementation

| Finding | Root cause | Resolution | Production files | Regression evidence |
|---|---|---|---|---|
| F1 | Erasing customer IDs breaks later cancellation lookup | Retain ID and persist private `billing_deleted_at`; revoke configured subscriptions in tenant scope; reject late nonterminal events; tombstoned customer helpers deny access | Customer transformer, `webhook_sync.ex`, `ash_billing.ex`, `resource_lock.ex` | Deletion/cancellation without metadata; late creation; deletion racing reconciliation; two tenants sharing the provider customer ID; loaded stale subscription under tombstoned actor |
| F2 | Equal-second snapshots and status-only CAS permit lost updates | Hold customer then subscription row locks through provider reads and updates; reconcile price/trial/period/cancellation differences; compare the full read entitlement snapshot on direct conditional writes | `webhook_sync.ex`, `resource_lock.ex` | Reversed same-second price changes; stale trial extension; same-status direct stale write; terminal transitions; two independent BEAM nodes |
| F3 | Public creation writes an ID unconditionally from a stale record | Public creation uses the same conditional empty-ID association as webhook sync; tombstones are excluded; nontransactional local writes serialize safely | `ash_billing.ex`, `webhook_sync.ex`, `resource_lock.ex` | PostgreSQL stale-record conflict and ten competing public API calls with one ETS identity winner |
| F4 | Export checking does not load configured handler modules | Load before checking; distinguish nil from invalid configuration; invalid required handlers always return 500 | `plug.ex` | Real available/unloaded BEAM handler executes; its failure remains retryable; missing handler cannot be acknowledged through the sync-error opt-out |
| F5 | A killed process cannot execute ETS lock cleanup | Remove the unmonitored reclaim lock; persistent CAS remains authoritative; nontransactional serialization uses monitored, reentrant OTP locks | `deduplication.ex`, `resource_lock.ex` | Kill a blocked reclaim worker and acquire again; retain exactly-one-reclaimer contention tests; verify inner locks do not release outer fences |
| F6 | Lease expiry does not fence handler execution | Plug executes synchronization, handler and completion inside a verified-token execution fence: PostgreSQL transaction/row lock or single-node OTP lock | `deduplication.ex`, `plug.ex`, `resource_lock.ex` | Expired leases while original handler lives; memory and PostgreSQL; stale tokens; process kill; rollback/retry; independent BEAM nodes |

All six original defects are addressed for the supported PostgreSQL path and the
single-node ETS/memory fallback tested here. This is not a claim of exactly-once
external effects or universal correctness for arbitrary custom data layers.

## Security invariants

- Historical customer ownership is retained after deletion. Ordinary webhook
  delivery cannot silently replace an existing provider identity.
- Tombstoned customers cannot receive fresh nonterminal entitlements through
  synchronization, and their loaded billing helpers fail closed.
- Tenant filters and the supplied actor/authorization options remain attached to
  Ash operations. No user-facing action policy or public acceptance list was
  broadened as part of this work.
- PostgreSQL serialization is owned by database rows and transactions, not by a
  shared ETS table or distributed Erlang connectivity.
- The library takes customer locks before subscription locks. Event processing
  takes the event fence before synchronization. Event IDs and second-resolution
  timestamps are not treated as a total order of provider state.
- A configured required handler cannot be silently skipped. Failed completion or
  loss of lease ownership cannot authorize executing through `with_lease/4`.
- An untrappable process exit cannot leave the removed `reclaim_lock` behind.
  Local nested operations cannot release the enclosing execution fence early.
- External effects remain at-least-once. Stable event/effect idempotency keys or a
  transactional outbox are still required for external side effects.

## Incremental and final verification

Actual intermediate runs:

| Command scope | Result |
|---|---|
| Original temporary audit reproductions | 10 diagnostic tests passed before changes |
| F1 regressions plus webhook sync tests | 31 passed |
| F2 regressions plus PostgreSQL subscription and webhook sync tests | 58 passed |
| F3 regressions plus public API/payment tests | 61 passed |
| F4 regressions plus Plug tests | 21 passed |
| F5 first contention run | Exposed an ETS serialization regression after removing the orphanable lock; fixed with monitored OTP serialization, without weakening the contention test |
| Combined lease/deduplication regressions | 47 passed |
| New permanent adversarial suite after expansion | 20 passed |
| `mix format --check-formatted` | Passed |
| `mix compile --warnings-as-errors` | Passed |
| `mix test` | 297 passed |
| `mix test --cover` | 297 passed; total coverage 90.81%, above the configured 90% threshold |
| `mix help --search credo` / `dialyzer` | No available tasks; no Credo or Dialyzer run claimed |
| `mix hex.audit` | Failed with a pre-existing HIGH Bandit advisory; no suppression or dependency update performed |

The separate-node test starts a second BEAM with `:peer`, loads the same test
resource modules, starts an independent Repo and deduplication server, and shares
only PostgreSQL. Each remote worker pins its database connection; the parent
observes that backend waiting on a PostgreSQL lock via `pg_stat_activity` before
releasing the original worker. It tests both subscription ordering and event lease
reclamation. Other race tests use messages, barriers and bounded absence assertions;
there are no arbitrary sleeps in the new regressions. Lease timestamps are aged
only in test fixtures to simulate expiry, never in production code.

Early failed test executions also exposed fixture issues (the remote Repo was
linked to a short-lived RPC worker; a new scoped fixture had not accepted its
foreign key). Those fixtures were corrected. The final passing results do not hide
these intermediate failures or attribute them to pre-existing source problems.

Runtime verified: Elixir 1.20.4 / OTP 29 with PostgreSQL. The repository's other
Elixir/OTP CI combinations were not independently run locally. No live Stripe
account operations, network-partition simulation, database failover or exhaustive
load/DoS testing was performed.

## Compatibility and deployment

1. **Migration is required before upgraded code is deployed.** The customer
   extension adds nullable private `billing_deleted_at`. In the consuming app run
   `mix ash.codegen preserve_deleted_billing_customers`, review the generated
   migration, and apply it using the app's normal deployment process. Only the
   test database schema was updated here.
2. Deleted provider IDs are retained rather than cleared. On a loaded tombstoned
   customer, `customer_id/1` returns nil and `create_customer/2` returns
   `{:error, :customer_deleted}`. Applications that want a replacement identity need
   an explicit trusted recovery workflow. Existing lost mappings are not rebuilt
   automatically.
3. Invalid configured handlers return 500 even with
   `return_500_on_sync_error: false`. Nil continues to mean no custom handler.
4. With PostgreSQL deduplication, handler database operations on that same Repo
   now participate in the event-resource transaction. Keep handler work bounded
   and synchronous; avoid synchronous re-entry creating lock cycles. Arbitrary
   processes spawned by a handler are outside this fence.
5. Row locks require primary-database reads and writes on the same Repo. Provider
   requests and handlers can hold a connection, so pool capacity and bounded
   HTTP/transaction timeouts must be reviewed. Different Repos do not form a
   distributed commit. A disconnected database can release its fence while an
   already-issued external request remains in flight; idempotency is essential.
6. Memory/ETS fences remain single-node. PostgreSQL persistent deduplication and
   `with_lease/4` are required for the demonstrated cross-node guarantee. Calling
   `acquire/2` alone is not execution fencing. `deduplicate?: false` still opts out.

## Independent adversarial review and residual risks

The second review checked deletion versus reconciliation, conditional ownership
writes, full-snapshot CAS, handler loading and failure responses, monitor-based
crash recovery, lock reentrancy, stale tokens, transaction rollback, tenant
separation, and actual cross-BEAM database waits. It found and corrected the local
reentrancy gap rather than declaring success from the original reproductions alone.

U1–U4 remain separate reviews, not automatic changes: sensitive attributes accepted
by application actions, tenant-required event storage, Connect/account/environment
scoping, and configured custom-provider routing. The new tenant tests cover
customer/subscription synchronization; they do not establish support for tenant-
required deduplication resources.

Unknown customer deletion events with no local mapping cannot identify a local
owner. The customer marker is not a global Stripe deletion ledger. Already-erased
historical identities and long-lived stale actor caches require application
reconciliation/freshness policy. Do not treat this upgrade as an automatic repair
of all historical billing data.

### Pre-existing dependency advisory

`mix hex.audit` reports Bandit **1.14.0**, HIGH,
`EEF-CVE-2026-116078` / `GHSA-pxjf-g536-7r93`: memory amplification from HTTP/2
request bodies made of one-byte DATA frames. The OSV API record was retrieved and
identifies **1.14.1** as fixed. Bandit is a dev/test dependency in this library;
consumer production HTTP-server dependencies must be assessed separately.

The original GitHub-only advisory check did not detect this record. The broader
Hex check supersedes that limited result; there is no claim of a clean dependency
audit. The existing lockfile was not altered. Upgrade Bandit in a separate reviewed
change and rerun Hex audit; do not suppress the advisory to obtain a green result.

Primary record: https://api.osv.dev/v1/vulns/EEF-CVE-2026-116078

## Production-readiness recommendation

The six reproduced defects have targeted corrections and adversarial regression
coverage, including real PostgreSQL locks across two BEAM instances. This is a
substantial improvement, but not unconditional production approval. Before
production, apply the customer migration, review handler transactional/idempotency
contracts and database pool/timeouts, reconcile affected historical records, run
the supported CI runtime matrix, address applicable U1–U4 integration risks, and
resolve the pre-existing dependency advisory in relevant environments.

## File inventory and diff summary

Production code changed:

- `lib/ash_billing.ex`
- `lib/ash_billing/deduplication.ex`
- `lib/ash_billing/plug.ex`
- `lib/ash_billing/resource/transformers/add_customer_id_attribute.ex`
- `lib/ash_billing/webhook_sync.ex`
- `lib/ash_billing/resource_lock.ex` (new)

Tests and fixtures changed:

- `test/ash_billing/postgres_subscription_test.exs`
- `test/ash_billing/webhook_sync_test.exs`
- `test/support/postgres_support.ex`
- `test/test_helper.exs`
- `test/ash_billing/security_regression_test.exs` (new; 20 permanent tests)
- `test/support/security_provider.ex` (new; independent-node fixture)

Documentation changed:

- `CHANGELOG.md` (existing Unreleased notes preserved)
- `documentation/topics/webhooks-and-resilience.md`
- `documentation/topics/security-remediation.md` (new)

`test/ash_billing_test.exs` remains modified solely by the pre-existing 94-line
addition; this remediation did not edit it. `mix.exs` and `mix.lock` are unchanged.

The production diff adds a 60-line locking helper, a private customer tombstone,
conditional identity persistence, expanded snapshot guards, required handler loading,
and fenced event execution. Much of the Plug diff is extraction of the existing
processing body into the fenced callback, not unrelated behavior changes. The
remaining new lines are adversarial tests/fixtures and migration/contract guidance.
The new regression file has 817 lines covering six findings, negative controls,
PostgreSQL tenant isolation and actual separate-node locking.
