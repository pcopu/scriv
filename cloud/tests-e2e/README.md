# Local service-process journey

Current tests enter through `tracer app -- test services` from the repository root. Legacy Vitest, Node unit and Python unit suites are removed; historical results below do not establish full replacement coverage. See [CLI-only testing](../../docs/testing/cli-only-tests.md).

The current cloud journey has **120 local HTTP requests**: the original 72-request
configuration/body/quota chapter, 16 scheduled-maintenance requests, and 32
interrupted-authorization requests. The initial empty-identity checks occur before
later synthetic fixture sessions are added. See [scheduled maintenance](../../docs/testing/scheduled-maintenance.md)
and [interrupted write authorization](../../docs/testing/interrupted-authorization.md)
for the added fixtures, exact checks and remaining limits. These are local service
results, not native application acceptance.

Run from the repository root with the already installed cloud toolchain:

```sh
npm --prefix cloud run test:service
```

This is one broad **service-process integration** journey. It bundles the unchanged
production `cloud/src/index.ts` and starts Miniflare/workerd in an owned child
process, then uses Node's real HTTP client against the verified `127.0.0.1` port.
It does not call production worker exports directly or use `dispatchFetch`.
Node 22.14+ and the cloud lockfile's installed esbuild, Miniflare, and Wrangler
migration reader are required. The migration reader only reads the three
SQL files; it is not used to start Vitest or load its configuration.

The original 18 HTTP checks cover health, wrong method, unknown route, unauthenticated
identity/project access, OPTIONS, missing GitHub/email configuration, wrong
content type/origin, malformed JSON/email/PKCE, and malformed verification input.
All three original migrations run before HTTP checks. Read-only count queries
assert users, sessions, email identities/challenges, OAuth states, and auth codes
remain empty at the end of the initial chapter. Only normal rejected-request
rate-limit writes are expected during that chapter.

The initial configuration/body/quota chapter makes **72 actual HTTP requests**. Two additional requests
use `node:http` with explicit HTTP/1.1 chunked transfer encoding, no Content-Length,
and two body writes. Valid JSON padded to exactly 4096 bytes reaches field
validation (400); 4097 bytes must fail the streaming byte limit (413).

Separate documentation-range synthetic client identities exercise the production
IP quota path through HTTP and D1: 20 missing-EMAIL requests return 503, the 21st
returns 429; 30 malformed verification requests return 400, the 31st returns 429.
Malformed verification exits before token creation. Read-only queries prove each
client starts with no quota records and ends with exactly one real-window record,
with counts 20→21 and 30→31. No near-threshold rows, clock overrides, quota resets,
or private-state oracle writes are used. Start/end timestamps and the unchanged
10-minute bucket are reported. The run fails explicitly without a quota claim if
it starts those checks in the final minute of a bucket or crosses a boundary;
rerun after the real boundary. These checks add abuse-containment evidence, not
legacy quota-test equivalence: the old quota baseline also required successful
email delivery, which this journey intentionally never performs.

The second configuration supplies an inert EMAIL RPC service whose `send` method
increments a bounded in-memory invocation counter before throwing. A separate
fixture RPC reads this counter before configuration replacement, immediately
after the oversized-body request, and at the initial chapter's completion; zero invocations are
required. Empty identity tables provide additional state evidence. No successful
sign-in is performed. Later chapters add only declared synthetic fixture sessions.

Isolation and cleanup:

- Fresh private HOME, TMP, and resource persistence directory, removed on exit.
- Sanitized child environment; no production Wrangler config, `.env`, credentials,
  remote bindings, provider requests, real email, or existing user data.
- Programmatic configuration only. Cloud metadata lookup, telemetry,
  observability, explorer, and inspector proxy are disabled.
- Every worker's outbound fetch is denied and counted; zero attempts required.
- Fixed loopback host and no redirects. The unchanged initial and maintenance
  helpers retain their 80/110 request guards; the later chapter caps the shared
  count at 160 (120 currently used). HTTP deadlines are at most 10 seconds, with
  request/response body caps and the same 90-second overall child deadline.
- Runtime disposed in `finally`; parent kills only its own child process group
  and removes only its freshly created directory, including on failure.
- Errors retain the original exception/stack. Output reports only counts,
  public timing/counter evidence, bundle hash, and cleanup, never request bodies,
  credentials, private headers, or authentication codes.

The initial chapter alone does **not** establish successful sign-in, OAuth, team operations,
provider delivery, project collaboration, native application launch, UIKit
behavior, or actual Catalyst E2E. No native coverage is granted. One frozen service method,
`cloud/tests/email-auth.test.ts::0018`, was retired after independent equivalence
review and execution: missing EMAIL with a sender and valid body, then oversized
input with EMAIL configured, both rejected before any send RPC. Default cloud
`npm test` now runs this journey through Tracer. Historical legacy
service results remain historical evidence, not coverage of the current tree.
The outbound fetch guard is a Worker-level deny policy, not a general OS network
sandbox; the Node host only performs local runtime control and loopback HTTP.


## Authenticated collaboration journey

Run `tracer app -- test services collaboration` from the repository root. The
unchanged production Worker and ProjectRoom Durable Object handle 81 real HTTP
requests: the original 36-request collaboration chapter and 45 appended
[device-discovery and relay checks](../../docs/testing/peer-discovery.md).
Fixtures provision four synthetic users with ephemeral bearer tokens
(only SHA-256 hashes stored), sessions, and an active team before the first HTTP
request. The session fixtures use production authentication checks, not an auth
bypass. No external provider login or billing flow is exercised.

The original chapter creates a team project as a member and checks create retry/conflict,
viewer read and outsider denial, two scene revisions, exact command retry and
changed-payload rejection, missing/conflicting leases, public lease token
redaction, version conflict, historical snapshot and event pagination. A real
HTTP role downgrade releases the member's lease, prevents new edits, and still
allows the already committed command receipt to be retried. Owner-only restore
advances the epoch and rejects old-epoch edits. Member removal hides the project;
logout invalidates the viewer's session. At that checkpoint, state retains exactly
three content events, one project, one revoked session and no R2 objects.
The appended chapter adds synthetic device/session, project and entitlement
fixtures, checks exact device inventories and public removal, and exercises
local STUN fallback and three strictly intercepted TURN provider outcomes.
No live relay credential provisioning or media transport occurs.

Within each chapter, application mutations use production HTTP routes;
synthetic setup and read-only storage observations are separate evidence. R2 is an empty isolated binding, asserted empty
before and after, not evidence of asset transfer coverage. There are no direct
calls to production exports or Durable Object internals. The same owned process
group, 90-second deadline, private temporary directories and cleanup used by the
cloud journey apply. Each request has a 5-second deadline, loopback-only origin,
no redirects, request/response limits and a 110-request total cap. Unexpected
Worker outbound fetch is denied and counted (zero required); the three controlled
TURN fixture calls are separate. This is not an OS network sandbox.
No credentials are printed or persisted in deliverables. Optional telemetry and
remote configuration discovery are disabled. The default service command runs
all 13 journeys in the order defined by [the service catalog](../../scripts/service-catalog.mjs).
Use `tracer app -- test services --list` to see the supported selections.
Instrumented journeys require the explicitly configured reviewed local Tracer runtime.

The collaboration journey does not cover WebSocket presence, discussion, atomic batch
uploads, asset delivery, authentication provider flows, native applications, or
all historical service assertions. No frozen legacy test is retired here.


## Authenticated discussions and assets journey

Run `tracer app -- test services discussions-assets`. The owned local Worker
process uses four synthetic identities and sessions, one synthetic active team,
and an isolated D1/R2 fixture. Real HTTP routes exercise canonical discussion
creation, message retry/conflict, reply/mention validation, cursor ordering,
resolution and history, plus hosted image byte/hash integrity, permission checks
and idempotent upload/deletion. The original 40-request chapter is followed by
23 [media-boundary checks](../../docs/testing/media-boundaries.md), for 63 HTTP
requests through that checkpoint. A further 20
[quota and interrupted-upload checks](../../docs/testing/media-reservation.md)
bring the total to 83, using two additional synthetic users and three sessions.
The media-boundary checks exercise JPEG/WebP byte and metadata
integrity, eight refused inputs and exact storage preservation, followed by deletion.
A simulated subscription lapse in the original chapter checks discussion
grace reads, exact retries and rejected new discussion writes. The original PNG is deleted
before lapse; its retention is checked after a denied deletion, not restart or lapse. Outbound requests are denied, telemetry disabled and
process state cleaned on exit. The image bytes are inert test data, not a decoded
image or a public upload. This is service-process evidence, not native UI, real
provider authentication, live billing, arbitrary concurrency or complete feature coverage.


## Authenticated atomic batch journey

Run `tracer app -- test services atomic-batch` after the [local runtime setup](../../docs/testing/atomic-batch-journey.md). It performs 29 real HTTP requests through the unchanged production Worker, including two multipart edits, exact retries and conflicts, missing uploads, viewer denial, validation and rejected-commit snapshot rollback. Its named action and assertion callbacks produce adapter-reported results. No provider login, live billing, native app or measured source coverage is claimed.


## Billing and generation journeys

`tracer app -- test services billing` uses signed synthetic events and a strict in-process provider fixture for 49 HTTP checks. The original 27 named entitlement steps use six provider calls; the appended [checkout-safety chapter](../../docs/testing/checkout-safety.md) adds 22 HTTP checks and 51 strictly intercepted calls, for 57 provider calls total. No Stripe network call, charge or account change occurs. `tracer app -- test services generation` checks job ownership, transitions, replay, device fencing and pagination in its original 34 HTTP requests, then adds 30 [metadata and device-recovery checks](../../docs/testing/generation-recovery.md), for 64 total, without provider execution. The original generation and billing steps record real action/assertion callbacks through the reviewed local runtime; checkout-safety and generation-recovery evidence are reported separately. See [billing](../../docs/testing/billing-journey.md) and [generation](../../docs/testing/generation-journey.md).


## Email authentication boundaries

`tracer app -- test services email-auth` runs 31 real HTTP requests with the
synthetic local mailbox. Its original 16 named callbacks cover sign-in, verified
identity reuse and session revocation. The appended 15
[attempt and consumption checks](../../docs/testing/email-consumption.md) verify
five-attempt exhaustion, one successful consumption from two competing requests,
separation from an unverified contact-email user, exact stored hashes and session
fields, replay refusal and logout. No real email is sent. Concurrent client
requests do not prove a particular internal transaction overlap; native and
failure-injected atomicity remain unverified.

### OAuth session ownership

The OAuth journey also repeats sign-in for the same synthetic GitHub identity,
checks one-use callback/exchange outcomes under concurrent client dispatch, and
verifies foreign-session preservation and sibling-only revocation. It runs 40
HTTP requests and 14 exact local provider simulations; no live GitHub login or
forced internal race is claimed. See `docs/testing/oauth-session-isolation.md`.

### Team entitlement grace

The team lifecycle journey now checks seven synthetic entitlement-date states,
including cancellation-date precedence, owner/member/viewer metadata visibility,
refused new projects after lapse, and owner archive after grace. It runs 80 HTTP
requests within the original cap. Capability fields are not document-write
execution. See `docs/testing/team-entitlement-grace.md` for fixture boundaries.

### Connected document deletion

The document-integrity journey now adds referenced-character refusal, corrected
parent-first graph deletion, metadata-only current tombstones, exact event
history and idempotent replay. It runs 80 HTTP checks within the original cap.
This is not permanent erasure or failure-injected atomicity. See
`docs/testing/document-graph-deletion.md` for the public-state limits.

### Staged batch recovery

The atomic-batch journey now checks shared-user upload capacity, auth-session
ownership, targeted cleanup after session/semantic failures, and cross-session
recovery of accepted receipts without duplicate edits. It runs 74 HTTP requests
within the original cap. See `docs/testing/batch-session-capacity.md` for the
public-state checks and untested TTL, crash, provider and native boundaries.

### Empty and unchanged history restoration

The revision-safety journey now checks unchanged-content and repeated empty restores,
discussion preservation, import refusal over tombstones, exact restore retries and
historical cursor pages. It runs 123 HTTP checks. See
[restore recovery](../../docs/testing/restore-empty-history.md) for the public-state
oracles and remaining native/fault/durability limits.

### Concurrent generation callbacks

The generation journey now adds duplicate claims, competing progress/completion
callbacks, corrected retry and terminal-state protection, for 80 HTTP requests.
See [callback concurrency](../../docs/testing/generation-callback-concurrency.md).
Client dispatch is concurrent; internal transaction overlap and native/provider
execution are not claimed.

### Signed billing webhook boundaries

The billing journey adds signature/envelope refusals, cross-team receipt reuse,
and exact failure/retry persistence, reaching 75 HTTP requests. See
[webhook boundaries](../../docs/testing/billing-webhook-boundary.md). Provider
responses and signing material are synthetic; native and live billing remain unrun.

### Email delivery failure recovery

The email journey adds accepted-delivery failure, real cooldown and successful
retry through public authentication, for 40 HTTP requests. See
[email recovery](../../docs/testing/email-delivery-recovery.md). The mailbox is
synthetic; real email delivery and native execution remain unrun.

### Cross-project hosted replica isolation

The discussions/assets journey now verifies independent copies and quota for
identical content in two projects, including guarded reads and delete/reupload,
for 107 HTTP requests. See [replica isolation](../../docs/testing/cross-project-replica.md).
No forced race, native execution or complete image decoding is claimed.
