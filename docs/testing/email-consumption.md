# Email attempt exhaustion and one-time consumption

Run `tracer app -- test services email-auth`. The original 16 named runtime
callbacks remain unchanged. An appended chapter adds 15 HTTP requests, for 31
total. All delivery uses the existing synthetic local mailbox, never real email.

Five guaranteed wrong codes increment one challenge's attempts from one through
five. Each returns the same exact 401/invalid_code response and preserves users,
verified identities and sessions. The correct code/proof then also fails while
the challenge remains unexpired, with attempts fixed at five and no consumption.

A different PKCE proof requests a fresh challenge for that same synthetic email.
Two correct verification fetches are dispatched before either response is
awaited. Exactly one succeeds and one fails. The successful challenge has one
attempt and one consumption marker, and there is exactly one new verified user,
identity and session. A later identical replay fails without another write.
This does not force a particular server/transaction overlap or inject a fault.

Before issuance, a synthetic GitHub-style user is seeded with that same email
only as a contact field. Successful email verification does not reuse this user.
It creates a distinct email-namespace user and verified identity; the contact
user remains byte-for-byte unchanged and receives no session. Existing verified
identity reuse is covered separately by the original chapter.

Read-only row checks independently recompute challenge-ID, challenge-bound code
and issued-token hashes. They check persisted send timing, ten-minute challenge
expiry, one-minute resend timestamp, the default 30-day session and an ASCII
device name truncated to 100 characters. No plaintext code/token is logged or
included in evidence. This is limited to the declared rows, not every data store,
entropy quality, provider behavior or full privacy certification.

The winning token reads the correct identity and exactly one public session.
Real logout changes only its revocation timestamp, and a later identity read is
401. Original users, identities, sessions and challenges remain exact. The
locked-out challenge remains locked and the successful one remains consumed.
Rate-limit counters are intentional exclusions from state equality.

The 40-request cap, five-second request bounds, 90-second owned-process watchdog,
local runtime pins, outbound deny guard, disabled telemetry and cleanup are
unchanged. No real email/provider account, native app, arbitrary race, storage
failure, elapsed-expiry boundary or measured source coverage is claimed. New
HTTP evidence remains separate from the original runtime callback report.
