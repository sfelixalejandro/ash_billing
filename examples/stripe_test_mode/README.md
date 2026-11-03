# Isolated Stripe Test Mode consumer

This small Plug/Bandit application consumes AshBilling through a path dependency,
with its own Ash domain, PostgreSQL resources, migrations and native billing policies.
It is a validation harness, not a production starter application. It is outside the
Hex package allowlist. The library's normal tests require no Stripe credentials.

## Requirements and safety

Use Elixir/OTP compatible with the repository, PostgreSQL 16+, Python 3 and Stripe CLI.
Configure your default Stripe CLI profile with a test secret key, or provide
`STRIPE_SECRET_KEY` through your existing secure environment. Never commit or print
that value. The launcher rejects live/unknown keys and verifies `livemode=false`
against Stripe before starting. It captures the test listener's signing secret in
memory and redacts secret keys/signing secrets from its logs.

The database is deliberately named `ash_billing_stripe_integration`, separate from
the library test database. The local PostgreSQL user must be allowed to create it.
The HTTP server binds only to `127.0.0.1:4089`. Its control routes intentionally
operate without a public authentication layer: do not deploy or expose them on a
public tunnel. A public webhook-only ingress requires a separately reviewed setup.
Only `/webhooks/stripe` should ever receive Stripe traffic.

From this directory:

```sh
mix deps.get
mix compile --warnings-as-errors
python3 run.py --preflight
python3 run.py
```

The launcher creates/migrates the isolated database, starts Stripe CLI forwarding,
and starts the consumer. It prints readiness, not credentials. Validation state,
redacted logs and identifiers stay under the ignored root `audit/stripe_validation/`.
Stop with Ctrl-C. Restarting resumes non-secret identifiers from its state file;
do not run setup again for an existing run. Keep those files local. To start a new
run, choose a fresh `ASH_BILLING_EVIDENCE_DIR` through your secure local environment.
No database or Stripe objects are automatically deleted.

The example shares the repository's dependency source directory, but compiles into
its own build directory and has a separate lockfile. `simple_sat` is declared here
because this consumer uses Ash Policies. No integration dependency was added to the
library's runtime dependencies.

## Real Stripe scenarios

Use the local control routes in a second terminal. They accept no caller-provided
customer, price, tenant, credential or module parameters:

```sh
curl -X POST http://127.0.0.1:4089/control/setup
```

Setup creates a labeled test product, two recurring prices, a local user, a persisted
Stripe test Customer, and a recurring Checkout Session for 20 seats. It repeats
customer creation to verify identity reuse. Open its returned Checkout URL locally.
Use only Stripe's documented test card `4242 4242 4242 4242`, a future expiration and
a fictitious CVC/name. Leave optional saved-checkout enrollment unchecked. This does
not move real funds. Do not publish the Checkout URL or response data.

After completing the test Checkout:

```sh
curl -X POST http://127.0.0.1:4089/control/verify_subscription
curl http://127.0.0.1:4089/state
curl -X POST http://127.0.0.1:4089/control/swap_twenty
curl -X POST http://127.0.0.1:4089/control/quantity_ten
curl -X POST http://127.0.0.1:4089/control/swap_ten
curl -X POST http://127.0.0.1:4089/control/schedule_cancel
curl -X POST http://127.0.0.1:4089/control/resume
curl -X POST http://127.0.0.1:4089/control/cancel_now
```

Run these sequentially. Each mutation reads the subscription back from Stripe and
waits up to 15 seconds for a processed webhook snapshot, matching PostgreSQL state
and the expected policies on a freshly loaded actor before returning `PASS`.
The wait checks event quantity as well as price, status and the cancellation flag;
it does not repeat the provider mutation. Missing webhooks, stale SQL or incorrect
authorization fail the command. Inspect `/state` to diagnose a timeout;
`swap_twenty` requires remote quantity=20 and `swap_ten` requires quantity=10.
`verify_subscription` checks the session's paid status, remote active status and
persisted subscription, not just a success redirect. `/state` reloads the actor and
its relationships and runs native `Subscribed` and `HasPrice` policy checks. The
HasPrice policy is compiled with the actual price created for this run. After swapping
to the other price its original-price policy should deny; after swapping back it
should allow. After immediate cancellation both subscription policies should deny.

For a one-time test payment:

```sh
curl -X POST http://127.0.0.1:4089/control/payment_checkout
# Complete the returned Checkout using only the documented test card.
curl -X POST http://127.0.0.1:4089/control/verify_payment
```

Verification requires both `payment_status=paid` from Stripe and a paid completion
receipt in PostgreSQL. This exercises an immediate card payment, not delayed payment
methods. The receipt table illustrates transactional/idempotent SQL handling; it is
not a payment ledger or an external fulfillment service.

```sh
curl -X POST http://127.0.0.1:4089/control/persistence_recovery
```

This makes a real Stripe test Customer request with a deliberately denied local
persistence action, retains the remote ID, then retries with the authorized actor
and verifies that the same Customer is associated. It is a real API test combined
with controlled local failure injection.

## Explicitly local simulations

```sh
curl -X POST http://127.0.0.1:4089/control/replay
curl -X POST http://127.0.0.1:4089/control/out_of_order
curl -X POST http://127.0.0.1:4089/control/failures
```

`replay` locally re-signs an already received real Stripe event and verifies durable
deduplication and one SQL receipt. It is **not** an official Stripe resend.
`out_of_order` feeds a stored real creation snapshot to sync after immediate
cancellation; it is locally arranged ordering, not a Stripe/Test Clock delivery claim.

`failures` sends locally signed synthetic events. It checks returned handler errors,
exceptions, a one-shot deferred PostgreSQL commit failure, exact-event retry, parallel
duplicates, and rollback of an initial customer association before an ownership
conflict. The last case creates a real test Customer but uses a deliberately
contradictory local snapshot. Fault triggers are removed after the commit test.
The expected conflict remains failed/retryable, not processed.

These simulations do not demonstrate exactly-once external effects. SQL receipt
idempotency is tested; real emails/remote fulfillment require separate effect keys
or a transactional outbox. For an official Stripe resend, use a registered HTTPS
**test** webhook endpoint targeting only the webhook route, not this control server.
Never describe local HMAC replay as an official resend.

See [Stripe testing](https://docs.stripe.com/testing) and the
[public upgrade guide](../../documentation/topics/upgrading-to-0.5.md).

## Offline launcher checks

```sh
python3 -m unittest discover -s . -p 'test_*.py'
mix test --no-start
```

These checks reject live/unknown keys, require an explicit false livemode during
preflight, and verify redaction. They mock network access and do not claim real
Stripe validation.

The Elixir tests exercise convergence and negative controls without starting the
consumer, contacting Stripe or requiring PostgreSQL. They cover missing webhooks,
stale quantities/prices/status, incorrect authorization and bounded waiting.
