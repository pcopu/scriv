# Backend verification

Verified locally on 2026-10-29. This report covers `cloud/` and the native-facing
API contract in `docs/cloud-api.md`. No Cloudflare infrastructure was provisioned
or deployed, and no live subscription or provider account was modified.

## Runtime and reproducible commands

The backend tests execute inside Cloudflare's actual local `workerd` runtime
through its Vitest integration. D1 migrations, SQLite Durable Objects, WebSocket
upgrades and private R2 bindings are real local emulations. This is broader than
mocking the Worker handler in ordinary Node. Stripe responses are deliberately
mocked; GitHub's browser consent and Cloudflare's TURN service are not exercised
with real credentials.

Environment used for the final local checks:

| Component | Version |
| --- | --- |
| Host | Linux workspace |
| Node | 24.22.1; package minimum is 22.14 |
| npm | 11.9.0 |
| Wrangler | 4.155.0 |
| workerd | 1.20261023.1 |
| Vitest | 4.1.12 |
| Cloudflare Vitest plugin | 1.4.10 |
| TypeScript | 5.9.3 |
| Workers compatibility date | 2026-10-28 |

Run from `cloud/`:

```sh
npm ci
npm run typecheck
npm test -- --reporter=verbose
npm run test:load -- --reporter=verbose
npm run build
npm run check:config
```

Dependencies were installed from the lockfile using `npm ci --ignore-scripts`
in this workspace. The final checks used the installed lockfile versions above.
The release workflow also runs the documented clean install.

## Results

| Check | Result |
| --- | --- |
| TypeScript `tsc --noEmit` | Passed |
| Functional integration suite | **24 passed**, zero failed |
| Default-suite load case | One intentionally skipped; executed separately below |
| Explicit 500-connection load case | **1 passed**, zero failed |
| Wrangler deploy dry run | Passed; **97.85 KiB** raw, **24.86 KiB** gzip |
| Production configuration preflight | Correctly refused the placeholder API origin and all-zero D1 ID |
| Production deployment | Not run |

The functional suite completed in 3.91 seconds in its final run. The workerd test
harness emitted an `Application called deleteAllDurableObjects()` diagnostic
while resetting isolated test bindings. Assertions and the process exit code
were successful; this diagnostic was not observed from a deployed service.

### Behavior covered by the functional suite

1. Public health, authenticated writes and private-project non-disclosure.
2. Single-use PKCE exchange and rejection of the wrong verifier.
3. Free solo editing, paid live sockets and paid hosted media.
4. Exclusive item leases across two devices of the same account, including
   attempts to reuse another device's editor-window ID.
5. Optimistic item-version rejection; durable receipt replay after lease expiry;
   no duplicate history; fencing-token advancement and stale-release rejection.
6. Atomic rollback when any operation has an invalid cross-reference.
7. Empty-project atomic import, cyclic character/portrait references, fractional
   Swift image dates, idempotent retry and rejection of a second import.
8. History restore, epoch advancement, lease invalidation and preserved item
   discussion.
9. Item and history persistence across Durable Object eviction.
10. Reusable team joins without per-seat limits, viewer permissions and join-link
    revocation without silently removing existing members.
11. Item discussion while another user holds the edit lease; idempotent sends.
12. Authenticated peer inboxes, free same-account device signaling and denial of
    cross-project recipients.
13. WebSocket hello, authenticated device identity, ordered replay and watermarks.
14. Live event batches delivered in sequence before the following watermark.
15. Stale project timing rejection for geometry edits.
16. Immediate member-removal socket closure and subsequent HTTP denial.
17. Lossless discussion pagination when 501 messages share one timestamp.
18. R2 content hash verification, immutable replica deduplication, private reads,
    atomic quota accounting and quota release after deletion.
19. Rejection when team storage capacity is insufficient.
20. Stripe signature, timestamp and payload verification.
21. Canonical Stripe subscription selection that preserves a newer active
    subscription when an older cancellation arrives, including duplicate events.
22. Checkout rejection when the configured price differs from USD $9.99/month.
23. Unchanged-geometry text edits still reject missing character references and
    invalid word data; failed edits leave the canonical item and history unchanged.
24. Shortening a scene below an existing cue or overlapping cue boundaries
    rejects the entire transaction and preserves the prior head and timing version.

The checks are implemented in `cloud/tests/backend.test.ts`. They exercise
specific safety and collaboration behaviors, not every possible account or
network condition.

## 500-member load exercise

`cloud/tests/load.test.ts` creates 500 different authenticated users and sessions
in one paid team, connects 500 project WebSockets, sends one presence update
from every connection, acquires 100 separate line leases, then starts 100
concurrent text edits on those independent lines. Each line keeps its existing
owned duration, so these are independent text edits, not competing timeline
geometry changes. The import creates history sequence 1; the final head is 101.

The test verifies all 100 updated line values in the canonical snapshot and all
**50,000 logical event observations**: 100 accepted mutations delivered to each
of 500 clients. It also verifies the observer's full sequence set before the
subsequent watermark. This count refers to events inside received frames; the
physical WebSocket frame count is not separately instrumented because events
may share a batched frame.

The latest local run, with event batching and geometry-scoped scene validation,
reported:

| Metric | Measured result |
| --- | --- |
| Concurrent authenticated connections | 500 |
| Concurrent independent writers | 100 |
| Accepted durable writes | 100 / 100 |
| Delivered logical mutation observations | 50,000 / 50,000 |
| Connection acknowledgement p95 | 452 ms |
| Write acknowledgement p95 | 1,145 ms |
| Observer mutation delivery p95 | 1,170 ms |
| Timed scenario duration | 11,129 ms |
| Test duration including setup | 11,374 ms |

Earlier runs completed the same correctness assertions:

| Implementation checkpoint | Write acknowledgement p95 | Observer delivery p95 | Scenario duration |
| --- | --- | --- | --- |
| Before event batching | 1,033 ms | 1,503 ms | 13,040 ms |
| Event batching, before scoped geometry validation | 2,167 ms | 2,215 ms | 10,382 ms |
| Event batching and scoped geometry validation | 1,145 ms | 1,170 ms | 11,129 ms |

These runs are not a controlled benchmark. Background load and local emulation
affect the numbers, so they do not establish a performance improvement or a
production percentile. The final run confirms that removing redundant scene
scans preserves capacity and correct delivery.

**The earlier 500 ms p95 aspiration is not established by this measurement.**
This verifies local room capacity and ordered, lossless delivery for the tested
burst. It does not verify internet latency, sustained hours of 100 writers,
large-project history replay, 500 continuously moving cursors, or a production
region's throughput and cost. A multi-machine staging load test remains the
release gate for any public latency or sustained-throughput promise.

### Validation and fanout controls

Every put retains its item-shape, word-timing and reference checks. Whole-scene
duration and image-cue validation runs only for entry, scene or cue creation,
deletion, resurrection or changed geometry fields. Text, word, label and
appearance changes within unchanged geometry do not rescan every scene entry and
cue. A scene move validates both the old and new scene. The two focused
regression cases above cover the retained reference checks and rejected geometry.

Durable item changes commit immediately. Socket notifications combine up to
50 milliseconds of changes, at most 64 events or 256 KiB per batch. A larger
single notification becomes a snapshot-required hint while its full journal
record remains durable. Watermarks flush pending notifications first; a dropped
connection recovers from ordered history replay.

Presence input is limited to 5 Hz per connection. Full presence snapshots are
coalesced to at most 5 Hz for up to 100 connections, and 1 Hz above 100. That
reduces large-room all-to-all traffic, with visibly less frequent cursor updates
in a large room. Presence is transient and expires after 30 seconds. It is not
part of the durable item history. The load test sends one 500-member presence
burst, not sustained cursor motion.

Existing item-lease changes still publish a full current lease list. The load
case acquires 100 leases before starting the writes. The test drains those
frames, but its 50,000-delivery assertion counts item mutations, not lease or
presence frames. Project room capacity is capped at 1,000 simultaneous sockets;
this is separate from the uncapped number of people who may join a team.

## Configuration and account-bound release gates

The repository intentionally has a placeholder `PUBLIC_URL` and D1 database ID.
`npm run deploy` runs a preflight that stops until the deployment agent replaces
both. `npm run build` only bundles a dry run and does not imply deployment.
See `cloud/README.md` for exact provisioning commands and secret names.

Before enabling production access, the deployment agent must complete:

- Cloudflare Workers, D1 migration and private R2 provisioning on the chosen
  account and origin.
- Real GitHub OAuth consent and callback through the signed native Mac app,
  including logout and revoked-device behavior.
- Stripe test-mode checkout at exactly USD $9.99/month per team, portal changes,
  renewal, cancellation, duplicate/out-of-order webhooks and entitlement
  propagation; then deliberately switch to live keys.
- Two real Macs on separate networks for reconnect, edit-lease contention,
  stale draft reconciliation, restore during editing and chat delivery.
- Direct WebRTC media transfer and forced TURN relay, including an unavailable
  source peer and paid hosted fallback. Without TURN secrets some restrictive
  NAT pairs cannot connect directly.
- A staging load exercise before promising a specific latency, concurrency
  duration or monthly operating budget.
- External periodic content exports and a restore drill, in addition to the
  application journal and D1 recovery tools. Immutable application history is
  not an independent disaster-recovery copy.

The [Workers pricing documentation](https://developers.cloudflare.com/workers/platform/pricing/)
lists a $5 base plan with included usage, rather than a total monthly cost cap. Durable Object duration/storage, R2 media and optional TURN traffic must be
monitored against actual usage. The backend implements one $9.99 recurring Team
subscription, quantity 1, with no per-seat billing.

## Handoff status

Backend source, migration, native API contract, reproducible local tests and
deployment instructions are ready for the deployment agent. Production secrets,
real account smoke tests, external recovery operations and public performance
claims remain deployment/release work and are not represented here as verified.
