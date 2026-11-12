# Recover after an email delivery failure

Run `tracer app -- test services email-auth`. Nine new HTTP requests extend the
original sixteen runtime callbacks and fifteen consumption checks to forty total,
within the unchanged request cap. Original lines 1–273 and footer remain exact.

Two browser-entry refusals check a disallowed media type and a foreign Origin
before counters, challenge rows or the mailbox change. The synthetic mailbox then
accepts the first valid code and throws a response failure. The app returns an
exact sanitized error, clears the stored digest, marks the reservation send_failed,
and creates no identity/session. An immediate identical request retains the
reservation and fails cooldown without sending again.

The test waits the real minute, with a small margin, without changing the clock,
expiry or stored challenge. The same email/proof request replaces the failed row
with a fresh sent challenge. Independent digest and request-bounded time checks
validate it. Verification creates exactly one expected user, verified identity and
session; public identity, logout and expired-session refusal complete the recovery.
All earlier identity/session/challenge rows remain exact. Two synthetic sends,
empty final mailbox and zero outbound attempts are required.

Only local fixtures are used. Switching Miniflare's mailbox configuration is not
a full process restart. No new direct D1 fixture writes or production helper calls
are added. The failed request returns no challenge ID, so its invalidation is
asserted through exact stored fields rather than verifying an unavailable ID.
This does not test exact cooldown edges, ten-minute expiry, concurrent resends,
transaction faults, real email delivery, native UI or browser rendering. The
unchanged owned-process deadline is 90 seconds. Runtime, consumption and recovery
evidence remain separate; mapping is not measured execution coverage.
