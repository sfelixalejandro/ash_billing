# Stripe Test Mode validation

Real provider validation is separate from the library's credential-free automated
suite. The repository includes an isolated AshPostgres/Plug consumer with a dedicated
PostgreSQL database, native Ash billing policies and a loopback webhook endpoint.
The consumer is not included in the Hex package.

See the [consumer instructions and source](https://github.com/sfelixalejandro/ash_billing/tree/fix/v0.4.2-production-hardening/examples/stripe_test_mode)
for setup and individual scenarios. This URL targets the candidate working branch;
release documentation should point at the approved release ref.

The launcher accepts only `sk_test_` credentials, verifies `livemode=false` against
Stripe, obtains a test CLI listener secret without printing it, and keeps evidence
outside Git. Use only Stripe's documented test payment details. The control server
is loopback-only and must not be published; a public ingress must route only the
signature-verifying webhook path and needs a separate review.

Verify more than Checkout redirection: retrieve the session's payment status and
subscription directly from Stripe, wait for the signed webhook to synchronize SQL,
then refresh the actor before evaluating policies. Check 20-seat price changes by
reading quantity back from Stripe; inspecting the local request alone is insufficient.

Classify evidence accurately:

| Execution | What it demonstrates |
|---|---|
| Real Stripe Test Mode API/Checkout | Remote test objects, payment state, quantities and lifecycle responses |
| Stripe CLI forwarding | Genuine test events delivered to the local signature-verifying endpoint |
| Local replay of a stored real event | Local deduplication; not an official Stripe resend |
| Locally arranged snapshot ordering | Ordering/terminal guards; not a claim that Stripe delivered that order |
| PostgreSQL fault injection | Rollback, lease state, HTTP behavior and retry after controlled failures |

A registered HTTPS test endpoint is required for an official Stripe resend. Keep
that validation pending if no approved ingress exists. An immediate test-card payment
does not validate asynchronous payment methods, live transactions, Connect scopes
or external exactly-once fulfillment. Run application-specific checks separately.

The configuration diagnostic is not proof of readiness. Require CI on the exact
candidate commit, inspect package contents, and retain private evidence without
credentials, raw payloads, cookies or Checkout access URLs in public documentation.

Primary references: [Stripe testing](https://docs.stripe.com/testing),
[Stripe CLI](https://docs.stripe.com/cli), and
[idempotent requests](https://docs.stripe.com/api/idempotent_requests).
