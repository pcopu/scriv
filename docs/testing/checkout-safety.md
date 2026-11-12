# Checkout safety journey

Run the existing billing journey through `tracer app -- test services billing`.
The original 27 named entitlement steps and assertion witnesses remain unchanged.
The appended chapter adds 22 real loopback HTTP requests and 51 strictly
intercepted synthetic Stripe requests. Together those original two chapters have 49 HTTP requests
and 57 intercepted provider calls. The later webhook-boundary chapter brings the
complete journey to 75 HTTP requests and 59 intercepted synthetic provider calls. No live provider, customer, charge or account
is involved. The original runtime report covers the original named steps; the
appended chapter reports its separate checkout-safety evidence.

The callback checks the exact ordered URL/query, method, synthetic authorization,
Stripe version, form entries and idempotency header. Each case must consume its
whole planned queue with no additional request. Existing team, project and event
rows remain unchanged after every action. The new team's synchronization fields
may legitimately change during checkout, so refusal does not imply no local write.

Cases cover:

- Wrong fixed amount, provider HTTP failure, malformed JSON and array responses.
  These fail before customer/session creation and preserve the new team row.
- A role changed by the price-response fixture is rechecked before customer or
  session creation. This is deterministic fixture interleaving, not a race test.
- First checkout creates one synthetic customer and verifies the complete fixed
  USD 9.99 monthly price/quantity form despite adversarial client body fields.
- Real saved checkout expiry elapses before an authoritative provider-open
  response is reused. Its different returned URL proves provider readback.
- Complete/unconfirmed checkout blocks replacement. Confirmed terminal and
  expired checkouts permit replacement. Three successful creates use distinct
  keys; retries after failed creates and storage-failure atomicity are untested.
- A cached customer mismatch and HTTP, wrong-host, userinfo, nondefault-port and
  malformed URLs are rejected without another checkout POST. A following valid
  lookup proves the cached receipt remains available. This does not test every
  cached identity field or all URL normalizations, such as explicit HTTPS :443.
- Active entitlement blocks a new checkout. Any nonterminal subscription also
  blocks it, including the supplied unrelated-price past-due record.
- Portal requests use exact customer/return fields. Wrong-host portal URLs fail.
  A session revoked by the provider-response fixture produces the exact sanitized
  401/session_expired error object, explicitly excluding the portal URL.
  The provider call has already happened; no remote rollback is claimed.

Only the wrong amount varies the fixed-price predicate. Other price fields use
one known-valid fixture, not independent negative tests for every condition.
No concurrency, live payment, provider idempotency enforcement, malformed new
receipt, restart persistence, transaction rollback, native or measured-coverage
acceptance is claimed. Current execution logs and independent receipts remain
separate from declared source links.
