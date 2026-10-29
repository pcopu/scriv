# Doppler billing and teams verification — 2026-10-29

## Scope and safety

Changes were implemented and tested in the assistant's Linux workspace. Stripe
provider traffic in the Workers tests is mocked with fabricated fixture IDs and
keys. No Stripe customer, checkout, subscription, charge, account setting or
Cloudflare infrastructure was created or modified. No deployment was performed.

This is a source and local-runtime verification report, **not** proof that live
billing, GitHub sign-in or native macOS interaction has passed acceptance.

## Correctness changes

- Checkout reconciles the complete canonical subscription list before permitting
  another charge. An expired local checkout cache cannot bypass a completed or
  pending payment. Existing incomplete, past-due, unpaid or paused subscriptions
  go to the billing portal instead of generating a second subscription.
- The recurring price must be USD 999 cents per month, licensed, fixed per-unit,
  without variable amounts, metering, tiering or quantity transforms. Checkout
  explicitly uses USD, one line item, quantity one and no promotion codes. Team
  membership does not affect the charge or impose a seat limit.
- Provider URL origins, response shapes and pagination are checked. Ambiguous
  checkout failures retain the same durable idempotency key. Checkout receipts
  and retirement of attempt keys commit together.
- Canonical Stripe state, not arrival order or the success redirect, determines
  entitlement. Replayed events re-propagate access invalidation without applying
  obsolete provider state. Failed canonical reads preserve the known local
  entitlement, do not acknowledge the event, and return a retryable HTTP 502.
- Subscription item periods are authoritative for the pinned Basil API version.
  A historical trial date cannot extend a current billing period. A delayed
  cancellation uses the provider's actual end time, so it cannot restart the
  30-day read/export grace period.
- Billing responses reauthenticate the current owner after provider waits before
  releasing a checkout or portal URL. A revoked session cannot receive the URL;
  a created checkout receipt still persists so retries cannot duplicate it.
- Team-project ownership follows the team's current owner, not a stale catalog
  owner. Lapsed-team administrators retain the documented read/export window but
  cannot rename/archive projects. Owners retain access.
- Invitation validity and paid-team status are rechecked inside membership
  insertion. Membership mutation rechecks actor authority in its SQL statement.
  Rejoining does not silently change an existing member's role. Owner removal,
  admin escalation and cross-team invitation revocation remain blocked.
- Team/catalog mutations also recheck the active device session, current role and
  applicable paid entitlement in their SQL statement. Delayed request bodies
  cannot outlive a completed administrator removal, device revocation or lapse.
- Hosted-media quota reservation atomically checks current membership, active
  session, paid entitlement and unarchived project state after receiving and
  hashing the bounded upload body. A revoked delayed upload writes neither a
  reservation nor an R2 object.
- Project lists hide access-denied entries rather than swallowing infrastructure
  errors. Rename responses return the committed timestamp; replay of an archived
  project ID no longer falsely reports successful creation.

## Native controls

`TeamSheet.swift` now includes team renaming, member/viewer invitations, 1/7/30-day
expiration selection, member self-service leave, and billing-portal recovery for
inactive subscriptions. The owner-only `billingCustomer` response flag allows
portal access even when a payment has not yet produced a paid plan; provider
customer IDs are not exposed.

The sheet owns its loading, pending-operation, invitation and error state. Team
switches and dismissal invalidate stale detail responses; accepted mutations
capture their original team/member target. Repeated clicks are disabled while a
mutation runs, errors are displayed inside the sheet, and an invitation created
for a dismissed/different team is not copied to the clipboard. Billing conflicts
refresh canonical account state before presenting the recovery message.

`TeamInvitation.token(from:serverURL:)` validates raw invitation tokens and exact
native/server invitation paths, including origin, credentials, query/fragment,
length and character checks. Local HTTP is restricted to the configured loopback
origin.

## Verification results

| Check | Result |
| --- | --- |
| `cloud/ npm run typecheck` | Passed |
| `cloud/ npm test -- --reporter=dot tests/billing-teams.test.ts` | **57 passed**, zero failed |
| New portable Swift invitation tests | **4 passed**, zero failed |
| Swift parser on TeamSheet and TeamInvitation | Passed |
| Full portable Swift run reported by native verification worker | **61 passed**, zero failed at this checkpoint |
| Native SwiftUI typecheck/build/render | **Blocked**: Linux workspace has no macOS SDK or runtime |
| Real Stripe test-mode or live checkout | **Not run** |

The 57 Workers tests execute in local workerd with real emulated D1, Durable
Objects and WebSockets. Coverage includes repeated checkout clicks; the fixed
price matrix; missed, duplicate and out-of-order billing events; incomplete
payments; idempotent network-failure retries; portal access and unsafe URLs;
provider pagination and malformed responses; team isolation; expired/revoked
invites; role escalation; lapsed-team read-only behavior; and authorization races
injected immediately before SQL writes. Five additional delayed-body cases
prove that team rename, invitation creation, project rename and team creation
cannot finish after the relevant membership/session/billing access is revoked. Five paused-upload cases additionally cover member removal, viewer downgrade,
billing lapse, device revocation and project archive. Three provider-response
ordering cases verify revoked sessions cannot receive billing URLs or initiate
provider writes after delayed price lookup. A processed-webhook retry is also proven
to close a stale removed-member socket without another Stripe fetch.

Fail-closed provider fixtures intentionally emit a sanitized
`billing_provider_error` warning. No uncaught RPC error stack remains in that
focused test run. An initial provider-ordering fixture exposed a local workerd
`Promise callback destroyed itself` crash when a deferred promise crossed test
and Durable Object request contexts. The deterministic fixture now injects the
revocation inside the awaited provider mock, preserving the response ordering
without that cross-context promise; the full focused run passes without a runtime
crash. Current aggregate results are tracked by the integration owner;
the counts above should not be mistaken for a later whole-repository run.

## Remaining acceptance gates

1. Compile/typecheck and exercise the final SwiftUI sheet on an authorized macOS
   runner: repeated clicks, switching teams during loading, closing during an
   invite request, leave/remove confirmation, role changes, expired billing and
   the return-from-browser flow.
2. Once separately authorized and configured, run Stripe **test-mode** checkout,
   payment failure/recovery, renewal and cancellation against the deployed API;
   test duplicate and out-of-order delivery. Never infer live readiness from the
   mocked provider fixtures.
3. Verify the configured Stripe portal permits the intended payment-method and
   cancellation recovery flows and cannot switch to an unsupported price or
   quantity. Reconciliation intentionally refuses unsupported subscriptions.

## Provider contracts consulted

- [Stripe Price object](https://docs.stripe.com/api/prices/object?api-version=2025-04-30.basil)
- [Stripe Checkout Session retrieval](https://docs.stripe.com/api/checkout/sessions/retrieve?api-version=2025-04-30.basil)
- [Stripe Basil subscription-item billing periods](https://docs.stripe.com/changelog/basil/2025-03-31/deprecate-subscription-current-period-start-and-end)
- [Stripe webhook delivery guidance](https://docs.stripe.com/webhooks)
- [Cloudflare SQLite Durable Object storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)
