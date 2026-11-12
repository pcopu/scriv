# Interrupted write authorization journey

Run `tracer app -- test services cloud`. The original configuration/body/quota
checks and scheduled-maintenance chapter remain unchanged. The appended chapter
adds eight interrupted writes, eight real public logouts, eight revoked-token
reads and eight successful retained-owner retries: 32 additional HTTP requests.
The full cloud journey now has 120 requests. No native or provider run is implied.

Each attempt starts with a unique synthetic session and no matching
request:<sessionId>: counter. An owned raw HTTP connection sends valid JSON's
first byte and its exact Content-Length, leaving the body incomplete. Read-only
D1 polling waits for precisely one new per-session counter with count 1.
index.ts creates that marker only after authenticate returns. This proves initial
authentication completed, not that the handler already reached body(). No other
/v1 request uses this session before that observation.

While the body remains incomplete and no response has started, the test calls the
real /auth/logout endpoint, requires 200/{ok:true}, observes revocation of that
still-unexpired session and confirms the original owner session remains live.
Only then does it release the remaining body. Expected refusals are:

- Team create: 401/session_expired.
- Team rename and join-link create: 409/access_changed.
- Membership role change: 409/membership_changed.
- Personal and team project create: 409/access_changed.
- Personal and team project rename: 409/access_changed.

Each refusal preserves every ordered row in teams, team_members, join_links,
projects and billing_events, plus all assets, R2 keys/content bytes/specified
metadata and team storage counters. Expected session revocation and security
rate-limit writes are deliberately excluded from business-state equality.
A subsequent old-token identity read is 401/session_expired and cannot increment
the observed request counter.

The exact same payload then succeeds through the retained owner session. Oracles
check actual persisted names/roles, exact generated owner membership and unchanged
other team memberships, join-link token hash/creator/expiry, and project IDs,
ownership, team scope and titles. Previously stored media and team quotas remain
unchanged after all successful retries. Source, fixtures and hashes contain no
real user data or credentials.

The marker poll has a five-second deadline and only reads D1. Raw requests have
ten-second deadlines, response bounds and explicit destruction; the existing
90-second process-group cleanup remains in force. No fixed delay stands in for
the ordering barrier, production hook, direct handler invocation or clock override
is used. The five-millisecond polling interval only schedules read observations.

This establishes eight controlled body-interruption interleavings. It does not
establish arbitrary races, every mutation route, role/entitlement changes during
writes, token expiration boundaries, invite consumption races, socket propagation,
transaction failure/rollback, all persistent state, or native behavior. Existing
maintenance receipts must be re-reviewed because the full test file changed,
even though their original assertion lines are unchanged.
