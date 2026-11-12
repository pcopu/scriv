# OAuth reauthentication and session isolation

Run `tracer app -- test services oauth` through the configured Scriv CLI. The
owned local Worker uses the original exact GitHub simulation with no external
forwarding. Original lines 1–283 and all 24 named runtime callbacks remain
unchanged; the appended chapter adds 16 HTTP requests for 40 total and six
simulated provider requests for 14 total. Neither unchanged request cap is raised.

The chapter adds two fresh sign-ins for the existing GitHub identity. It checks
opaque-state and exchange-code hashes, fresh PKCE bindings, request-bounded
default expiry fields, preservation of the original user ID/creation timestamp,
and exactly one new correctly hashed session per successful exchange. Two
callback requests share one state; two later exchanges share one code. Each pair
is dispatched before awaiting either result. Exactly one succeeds in each pair.
This does not force internal D1 overlap or prove arbitrary race or fault safety.

A separately seeded synthetic user/session distinguishes foreign-session access
from a nonexistent target. Public inventory excludes that session and the
original revoked session. A foreign-ID deletion reports ok without changing any
of the declared auth rows; sibling deletion revokes only its target and leaves
the current token usable. Final logout revokes only the current session. Original
and unrelated rows remain exact. Auth states/codes and tested-user sessions are
created only through public HTTP; no challenge/session reset bypass is used.

The additional observations cover complete rows in users, sessions, oauth_states,
auth_codes and email_identities. Other tables, rate counters and notification
transport are not included. No state, authorization code or bearer value is
printed or persisted in evidence. Service execution, independent semantic review, manual source links and native
acceptance require separate verification.

No live GitHub/account, native application, changed profile, alternate session
configuration, expiry wait, storage fault, statistical randomness or notification
delivery is exercised. No production source, original OAuth catalog/proposal,
GitHub Actions or native registry is changed.
