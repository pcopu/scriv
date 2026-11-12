# Project device discovery and relay contract

Run the entire existing collaboration journey:

    tracer app -- test services collaboration

The appended chapter preserves the original collaboration assertions. Only the
isolated test request budget changes, from 80 to 110. No production guard or
application source is changed.

Four synthetic users and eight synthetic sessions provide distinct timestamped
device descriptors. Exact full public inventories prove paid-team visibility,
own-device-only visibility during read grace, restored paid visibility, and
exclusion of expired, revoked and unrelated sessions. They also prove that
using a different personal project alone does not exclude an otherwise eligible
teammate session. Public logout removes that session; public team removal removes
the teammate while preserving their own personal-project access. Inventory
responses must contain only the expected descriptor fields and report onlineStatus
as unknown, not claim devices are currently reachable.

The test uses explicit synthetic D1 identity and entitlement fixture setup, not
provider login, billing or real accounts. It never inserts or resets rate counters.
Twenty ordinary ICE configuration requests succeed in one real hourly bucket;
the twenty-first receives the exact rate-limit error. Another session belonging
to the same owner remains eligible. Unauthorized/invalid-session requests never
reach the TURN quota. A bounded real wait avoids starting immediately before a
bucket boundary; this does not test time travel, bucket reset or cleanup expiry.

With TURN unconfigured, responses contain the exact STUN fallback, relayAvailable
false and a time-bounded one-hour expiry. The test does not contact that STUN
server. A subsequent isolated Miniflare configuration intercepts three fake
provider calls: valid configuration, HTTP failure, and invalid response shape.
It checks the exact encoded provider URL, POST, synthetic authorization, and TTL
body, then asserts exact public success/error responses. All credentials and
relay values are nonfunctional fixture strings; no external provider receives
traffic. Fresh fixture observers are acquired after Miniflare reconfiguration.

The original restored document must remain exactly unchanged and R2 empty.
Controlled provider calls are distinct from unexpected outbound attempts.
Owned process and temporary-state cleanup remain in the existing harness.

The catalog and incremental proposal contain bounded source relationships for
independent review. They do not establish native UI behavior, real TURN credential
provisioning or media transport, 1,000-device pagination, all role/grace boundaries,
provider timeout or malformed JSON handling, full concurrent revocation safety,
or measured source-line execution.
