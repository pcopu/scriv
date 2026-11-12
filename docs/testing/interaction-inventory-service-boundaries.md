# Service and verification boundaries for interaction-led E2E planning

## Scope, evidence, and counting

This is a read-only design assessment, not migration acceptance. Work should
proceed **interaction inventory → grouped end-to-end journeys → backward
assertion mapping**, rather than create one scenario for every old test. No
application source, scenario, frozen ledger, or legacy test was changed for this
assessment. No app, external service, update, account, signing operation, or
network experiment was run.

The primary denominator here is the non-Catalyst/non-Swift-package portion of
`docs/testing/cli-migration-inventory.json`, frozen at commit
`4d14b29f4fb49891e850fa9a8e5742dc878603c8`. All **75 source-file hashes** in this
scope were checked against `git show` at that commit and matched the ledger.
All recorded test names were reviewed; representative test implementations,
fixtures, service contracts, and runner configurations were inspected to
separate real boundaries from mocks and source checks. This is not a completed
line-by-line assertion disposition.

| Frozen suite | Files | Inventory entries | Assertion-source lines |
| --- | ---: | ---: | ---: |
| Cloud Vitest | 11 | 194 | 497 |
| Node tests | 40 | 198 | 1,188 |
| Update Python unittest | 4 | 36 | 98 |
| Native Objective-C update policy | 1 | 11 | 32 |
| Runtime-bridge XCTest | 1 | 1 | 2 |
| Standalone Swift selfchecks | 4 | 4 | 44 |
| Verification scripts and fixtures | 14 | 14 | 84 |
| **Primary scope** | **75** | **458** | **1,945** |

The remaining frozen suites are 286 Catalyst and 385 Swift-package entries.
Their UI and authoring mappings belong to the companion inventories; related
core protocol/journal families are referenced below but not added to this
458-entry denominator. The complete baseline is 1,129 entries in 171 files.

An entry may be a declaration, expanded parameter row, or whole script. It is
not necessarily one execution, one assertion, or one user interaction. Examples:

- Ten bad Stripe price rows are variants of checkout validation, not ten checkout
  controls or journeys (`billing-teams.test.ts::0003–0012`).
- `codex-cancellation.selfcheck.swift` has one entry, while its runner exercises
  six cancellation modes; account-refresh has one entry and four default modes.
- Two of the 14 verification entries are synthetic-runtime fixture executables.
  They are infrastructure, not independent user journeys.
- Nine Node entries exercise actual Chromium WebRTC media channels. Seven more
  exercise a real local Workers/R2 update feed. The other **182 Node entries**
  are a mixture of source checks, reference/state models, and tool/harness
  tests, not 182 unperformed UI journeys.
- `cloud/vitest.config.ts` uses actual local workerd/D1/Durable Object/R2
  implementations. Email delivery and Stripe responses are controlled fixtures;
  some records are seeded directly. This does not prove native sign-in, real
  email delivery, real payment, deployed service behavior, or WAN transport.
- Browser peer tests relay signaling through the harness and use empty ICE
  server lists. Real Chromium channels are not proof of native WKWebView,
  authenticated service signaling, cross-network NAT traversal, or forced TURN.

### Planning estimate, not coverage percentage

The normalized catalog below contains **43 proposed boundary interaction
classes** across ten groups. That is an explicit planning granularity, not an
automatically discovered or exhaustive product count. A reasonable refinement
range is **35–50 classes**, depending on whether role changes, reconnect paths,
and operator subcommands need distinct contracts after implementation review.
Do not add these 43 to UI-control counts: most describe the backend half of the
same interaction already counted by an authoring/integration journey.

These can be exercised by **eight service-backed journey families**, mostly
overlays of the integration inventory's IJ-01–IJ-10 and authoring AUT journeys.
Estimate **20–32 independently isolated execution variants**, not eight giant
fragile scripts: multiple accounts/processes, cancellation, reconnect, role
change, and update phases need separate starts. This estimate does not include
the security/fault/performance matrices below. No percentage of the 458 entries
is asserted equivalent or retired.

## Distinct boundary interaction inventory

Each numbered row names a user-, client-, or operator-observable boundary.
Repeated selectors, helper calls, and malformed-input variants are not new
interactions. The proposal does not assert every service route has a native UI.

| Group | Proposed classes | Evidence and UI relationship |
| --- | --- | --- |
| A. Identity/session, **5** | A1 request/resend email code; A2 verify code and establish device session; A3 optional OAuth callback/PKCE exchange; A4 logout/revoke device; A5 read/resume authenticated account state | `docs/cloud-api.md` native sign-in; `email-auth.test.ts`; `backend.test.ts::0001–0002`; IJ-04. Expiry, resend, and reordering are variants of these contracts. |
| B. Shared project state, **6** | B1 create/initially import shared content; B2 acquire/renew/release edit ownership; B3 commit an atomic edit and reconcile an uncertain receipt; B4 join/resume live state and presence; B5 preview/restore historical state; B6 list/rename/archive shared projects | `backend`, `atomic-batch`, `collaboration`, `presence-stream`; IJ-01/IJ-03 plus authoring actions. Geometry and character changes reuse B3. |
| C. Teams/entitlement, **6** | C1 create/rename team; C2 create/revoke/accept invitation; C3 change membership role/remove/leave; C4 observe paid/free/read-export grace access; C5 request fixed-plan checkout; C6 open billing recovery portal and reconcile provider state | `billing-teams.test.ts`, backend billing/access cases; IJ-08. Provider lifecycle is a separate boundary from opening a URL. |
| D. Discussion, **4** | D1 find/create canonical item/project conversation; D2 send/reply with mentions/attachments and recover a receipt; D3 resolve/reopen; D4 browse/page messages, conversations, and eligible mention recipients | `collaboration.test.ts`, `docs/cloud-api.md` discussions; IJ-09. Image versions retain lineage-specific context rather than new unrelated conversations. |
| E. Shared generation, **4** | E1 register a job; E2 claim/heartbeat/complete execution ownership; E3 pause/cancel/explicitly recover; E4 list/refresh/inspect retained status | `generation.test.ts`, `shared-jobs-refresh-fence.test.mjs`, Codex selfchecks; IJ-07. A job-status acknowledgment is not evidence that an image was generated. |
| F. Media transport, **4** | F1 upload/delete a private hosted replica with quota accounting; F2 fetch and verify immutable content; F3 discover/authorize peers and signal a connection; F4 request/receive/retry peer media with integrity checking | Backend media/signaling cases, peer tests, digest caller checks; IJ-03 and picture-authoring journeys. Hosted fallback and TURN are variants requiring their own actual transport witnesses. |
| G. Local runtime, **5** | G1 discover/select runtime; G2 explicit consent and pairing/connect; G3 handshake/read capabilities/account; G4 refresh account or replace/forget pairing through its authorized lifecycle; G5 cancel/disconnect/reconnect without accepting late responses | Runtime-bridge consent, bootstrap/session-grant selfchecks, Codex smoke/account/cancellation; IJ-05/IJ-06. Persistent pairing changes retain their separate permission requirements. |
| H. In-app updater, **4** | H1 discover a channel-bound update; H2 download/verify/prepare; H3 cancel/defer/retry an eligible phase; H4 durably save, install, terminate, and relaunch | Objective-C policy, updater Node guards, Python acceptance; IJ-10. Download preparation and final relaunch preparation are distinct phases. |
| I. Release operator, **3** | I1 stage signed immutable release artifacts; I2 publish channel pointer with concurrency/read-back fences; I3 independently verify transition and protected data | `release_test.py`, `staged_test.py`, `acceptance_test.py`, feed tests. Operator CLI boundaries, not extra application UI journeys. |
| J. Verification tooling, **2** | J1 build/package and verify an identified executable/resource/helper graph; J2 collect bounded capture/performance evidence and reject stale/failed output | Native verification/runtime/icon tests and scripts. Tool behavior is not automatically a user-visible application feature. |

## Grouped end-to-end journeys

These are design targets, **not new runnable scenarios or an execution claim**.
Use the companion inventories' interaction IDs as the primary UI owners; the
SV-J IDs below describe required service extensions, not duplicate journeys.
For every journey, test the real app path and validate its durable/remote
outcome independently. Source-string matches or command-dispatched flags are
not adequate acceptance oracles.

### SV-J01: Sign in, resume, and lose access

**UI owner:** IJ-04, with IJ-08 enrollment where needed. **Boundaries:** A1–A5,
C2–C4. **Planning:** 3–4 isolated variants.

Start signed out in a disposable origin-scoped profile; request and verify a
code through an authorized test delivery channel; close/reopen the app; observe
the same account and authorized catalog. Repeat with an expired/resend challenge
and with a second device revoking the first session. The old device must lose
its live connection and fail new reads/writes without changing saved local
work. OAuth is a separate variant if that optional configuration is supported.

Required witnesses: actual native state transition, authenticated account/session
response, rejected stale-session request, and unchanged local package. Do not
credit cryptographic randomness, hashed secret storage, enumeration resistance,
all quota limits, or all revocation races from this UI journey.

### SV-J02: Collaboratively edit, reconnect, and restore

**UI owner:** IJ-01/IJ-03 plus AUT script/timing/character/image edits.
**Boundaries:** B1–B6. **Planning:** 3–5 variants.

Two actual app instances use independent device/editor identities on an isolated
real service. Import a project once, contend for an entry, perform text and a
structural timeline edit, interrupt a connection, and resume. Then preview and
restore history while the other editor has stale state. Include a large atomic
structural edit as a bounded variant, not a different journey per affected cue.

Required witnesses: both rendered views converge; canonical project contents,
item versions, sequence/epoch, and history agree; retries create one durable
edit; stale ownership cannot overwrite; explicit draft/recovery UI retains
uncommitted wording; restore invalidates old leases. Do not infer exact
transaction rollback points, eviction/migration correctness, or every
source-anchor/Unicode boundary from the happy-path sync result.

### SV-J03: Continue a conversation across content changes

**UI owner:** IJ-09, with picture versioning and IJ-03 history.
**Boundaries:** D1–D4. **Planning:** 2–3 variants.

Create an item conversation, mention an eligible member, reply with a versioned
attachment, resolve/reopen, and navigate away/back. Regenerate the associated
image or delete the item while retaining its historical conversation; reconnect
a second reader and continue pagination without duplicating a retried send.

Required witnesses: canonical conversation/message IDs, exact original version
anchor, durable send receipt, ordered pages, live delivery before its replay
watermark, and persisted read-only historical content. Synthetic repeated or
backward timestamps, concurrent creation interleavings, and unauthorized
recipient payloads remain protocol-level matrices.

### SV-J04: Run, cancel, recover, and attach generation

**UI owner:** IJ-07, IJ-05/IJ-06, and authoring picture review/versioning.
**Boundaries:** E1–E4, G3/G5, F2. **Planning:** 3–4 variants.

Review the actual request, start an authorized generation, inspect shared job
state from another app, interrupt the owner or cancel at a supported phase,
explicitly recover where required, and accept a completed result. Navigate or
change account while a refresh/result is pending to test stale publication.

Required witnesses: one execution owner/grant, correct uncertain versus confirmed
cancellation state, exact submitted prompt provenance, unchanged original image
bytes, verified new asset identity, saved placement, and no late result applied
to another project. A real model turn requires its own authorization and cost
limits; a synthetic runtime run must be labelled as synthetic. Neither a job
record nor a fake model's success covers the real generation boundary.

### SV-J05: Deliver verified media between devices

**UI owner:** IJ-03 plus picture picker/inspector/version workflows.
**Boundaries:** F1–F4. **Planning:** 2–4 variants.

Display a missing image, fetch it from an authorized peer through the actual
native bridge, disconnect/retry, and show the correct version. Exercise hosted
fallback separately when entitled. A cross-network direct/TURN variant is a
separate environment gate, not satisfied by local browser tests.

Required witnesses: bytes cross the selected real transport; SHA-256 and byte
count match the requested immutable asset; native rendering uses that identity;
original package assets remain unchanged; unavailable/corrupt content is not
published as success. Retain corrupt chunk, stale checksum, unsolicited frame,
capacity, and reordered signaling tests even if one visual retry succeeds.

### SV-J06: Connect a runtime without crossing trust boundaries

**UI owner:** IJ-05/IJ-06. **Boundaries:** G1–G5. **Planning:** 3–4 variants.

Exercise discovery, decline consent before connection, approve an authorized
first connection, check protocol/account readiness without generating, and
close/reopen Settings or disconnect while work is pending. In an appropriate
isolated signed environment, verify session-only versus persistent pairing and
explicit forget/replacement behavior.

Required witnesses: actual coordinator/helper connection lifetime, native
readiness/error state, owned child cleanup, absence of activity after decline,
and no late completion reviving a closed request. UI text alone cannot prove
Keychain ACLs, helper identity, audit tokens, sandbox boundaries, or that a
locked/raced grant never became an in-memory fallback.

### SV-J07: Manage a team through billing and membership changes

**UI owner:** IJ-08 and IJ-04. **Boundaries:** C1–C6. **Planning:** 2–4 variants.

In explicitly authorized provider test mode, create a team, invite a member,
open checkout once despite repeated interaction, reconcile provider completion,
and verify team access from another account. Then downgrade/remove membership
and exercise canceled-subscription read/export grace or billing portal recovery.

Required witnesses: the promised fixed plan/quantity, one provider operation,
canonical server entitlement rather than redirect success, role-correct UI and
HTTP access, and preserved local projects. Mocked Stripe responses in the frozen
suite do not prove a real checkout. The many provider-envelope, price, webhook,
pagination, and delayed-revocation variants remain service checks.

### SV-J08: Complete a verified application update safely

**UI owner:** IJ-10; local persistence and recovery from IJ-01/IJ-03.
**Boundaries:** H1–H4, with I1–I3 as release prerequisites.
**Planning:** 2–4 variants.

Use explicitly authorized disposable old/new signed builds on the existing
acceptance channel. Check/download, cancel or defer in a legal phase, then
complete the save/whole-modal-chain preparation and relaunch. Include a failed
save/termination attempt where the original app and protected project survive.

Required witnesses: independent build/channel/team/key pins, exact source/build
identity, changed executable and running process, unchanged protected package
bytes, and no false install/relaunch success after failure. The policy harness
links real plugin implementation but intentionally never starts SPUUpdater or
installs an app; the Python inert-fixture tests also cannot establish this
journey. Publication, signing, installation, and agreements remain separately
authorized actions, not consequences of writing this inventory.

The per-family variant ranges sum to **20–32**. They indicate isolation needs,
not a commitment to a test-file count or an exhaustive cross-product.

## Backward assertion mapping after journey design

Use this table to locate evidence families, then map each original assertion
within those families to an actual checkpoint or retained gate. A row does
**not** mark every entry in that source as covered. IDs are frozen ledger IDs;
source filenames below retain their repository-relative prefixes.

| Original family | Fold into grouped journey | Assertions that still require another boundary |
| --- | --- | --- |
| `cloud/tests/email-auth.test.ts` (21), `backend.test.ts::0001–0002` | SV-J01 request/verify/resume/logout, visible expiry and denied access | Hash-only storage, PKCE/entropy, exact atomic attempt and quota boundaries, cross-origin requests, rollback, maintenance deletion |
| `cloud/tests/billing-teams.test.ts` (57), backend plan/quota/webhook cases | SV-J07 membership and provider/entitlement lifecycle; SV-J01 access revocation | All fixed-price variants, canonical subscription pagination, HMAC/timestamp checks, out-of-order webhooks, authority rechecks during awaited bodies/provider responses |
| `cloud/tests/atomic-batch.test.ts` (13), backend edit/restore cases | SV-J02 large structural edit, idempotent retry, restore; same authored UI actions | 1,001-item multipart resumption, missing/mutated parts, transaction rollback, temporary versus UI-owned leases, eviction, abandoned-part expiry |
| `cloud/tests/authored-validation.test.ts` (3) | SV-J02 accepted authored links/unlinks/timing from real authoring | Malformed protocol payloads, half-surrogate and exact-source drift, provenance stripping, cross-reference rollback. Local JSON import alone does not cover server validation. |
| `cloud/tests/collaboration.test.ts` (45) | SV-J02 replay/history/ownership; SV-J03 conversations/mentions; SV-J05 lineage | Repeated/backward clocks, concurrent canonical creation, room migration, durable receipt authorization, tombstones, byte budgets, slow-body races |
| `cloud/tests/presence-stream.test.ts` (5) | SV-J02 real final selection, idle presence, removal/reconnect | Exact coalescing deadlines, large-room roster deltas, legacy full-snapshot compatibility and lost-baseline repair |
| `cloud/tests/generation.test.ts` (14) | SV-J04 lifecycle and explicit recovery | Concurrent claims, operation-ID payload reuse, server-owned device identity, terminal receipt replay, pagination and all revoked/removed/archived races |
| `cloud/tests/image-prompts.test.ts` (6), `character-image-analysis.test.ts` (5) | SV-J04 exact submitted provenance and version-bound review; authoring character/picture journeys | UTF-16/byte budgets, malformed/duplicate regions, unknown versus canonical IDs, forbidden prompts/paths/credentials on job routes |
| `cloud/tests/backend.test.ts` (24) | Distributed across SV-J01/02/03/05/07, rather than a separate backend journey | Authentication denial, cross-project non-disclosure, immutable media/hash/quota transactions, lease/epoch/version fences and subscription reconciliation still need independent oracles |
| `cloud/tests/load.test.ts` (1) | No replacement by an ordinary two-app journey | Explicit opt-in 500 members, 100 writers, 50,000 delivered observations and percentile collection; local burst is not a WAN/SLA result |
| `tests/peer-transfer.browser.mjs` (9), `tests/peer-transfer.test.mjs` (5) | SV-J05 native media delivery/retry | Preserve actual transport faults and the state-machine edge matrix until matched at the same boundary; browser signaling is harness-controlled |
| Node digest/picker/character/timeline/layout/source-policy files | Corresponding AUT picture/character/audio/script journeys and SV-J04/05 | Actual controls/rendered bytes can replace source-shape intent only when independently observed; cache ownership, no filesystem work in getters, constant constraint allocation, and async fences are not proved by one screenshot |
| `tests/project-package-opening.test.mjs` (6), `startup-diagnostics.test.mjs` (10), `prompt-recovery-render.test.mjs` (10) | IJ-01/IJ-02/IJ-03 actual reopen, failed open, recovery review; SV-J02 persistence | Bookmark/security scope, lock contention, bounded metadata-denial seam, journals, no render-time I/O, owner lifetime and privacy limits |
| `tests/shared-jobs-refresh-fence.test.mjs` (4), Codex protocol/setup/modal guards | SV-J04/06 actual pending/cancel/navigation interactions | Existing source-derived ordering models and synthetic policy refusals require actual late-response witnesses before retirement |
| Runtime consent (1), Swift selfchecks (4), `runtime-bootstrap-integration.test.mjs` (8) | SV-J06 lifecycle, plus SV-J04 cancellation and account freshness | Exact grant ownership/lifetime, locked/conflicting/raced Keychain states, signed helper validation, callback cardinality and protocol races |
| `scripts/test-update-plugin-policy.m` (11), updater Node guards | SV-J08 real legal-phase cancellation/save/relaunch and IJ-10 controls | One-shot/stale callback policy, explicit termination retry and trust policy; source presence is not runtime evidence |
| `updates/tests/feed.test.mjs` (7), Python update tests (36) | SV-J08 real discovery/download, with operator prerequisites I1–I3 | Signature/pin/channel/tamper/truncation checks, unsafe archive entries, no redirect, create-only receipts, immutable publication and compare-and-swap pointer commit |
| Native runtime/verification/icon checks and 14 verification entries | Build prerequisites and trustworthy evidence for every journey | Harness rejection of stale/missing/failed output, compiled resources, bounded diagnostics, privacy, performance, and packaging/signing architecture remain independent gates |

## Non-UI gates that grouped journeys must not erase

These are nine **gate families**, not nine tests. They can share fixtures and
orchestration with journeys while retaining assertions at the boundary that
actually exposes the invariant.
“Retain” here means retain the behavioral invariant, not permanently retain the
old unit/source-test implementation. The requested end state is a scenario suite.
These families need explicit end-to-end system/failure cases; any invariant that
cannot be observed that way remains an openly unresolved migration gap, not an
exception silently preserving the legacy suite.

1. **Identity, authentication, and confidentiality.** Keep crypto/PKCE,
   single-use attempts, secret-at-rest/logging checks, request quotas,
   cross-origin rejection, account separation, and cross-project non-disclosure.
   A successful login never proves absence of leaked plaintext or entropy bias.
2. **Authorization under concurrency.** Retain removal/downgrade/revocation while
   bodies, D1 writes, billing lookups, media uploads, and job claims are pending.
   A disabled button is not the server's final transactional authority check.
3. **Atomicity, crash, and recovery.** Keep all-or-nothing writes, durable
   receipts, eviction/restart, journal/lock contention, immutable history,
   migrations, and publication races. A reopened final state does not identify
   whether intermediate partial data escaped to a peer.
4. **Wire-format and resource bounds.** Invalid JSON/UTF-8, unknown fields,
   duplicate IDs, exact UTF-16 boundaries, numeric overflow, input/output byte
   limits, pagination, path/symlink rejection, and oversized snapshots require
   controlled protocol/filesystem inputs. Do not create unsafe production UI
   affordances simply to make them clickable.
5. **Execution ownership and asynchronous lifetime.** Preserve duplicate/late
   completion, unrelated-thread events, uncertain cancellation, navigation and
   account fences, and one-shot callbacks. Use the actual controller/service
   with controlled dependencies where a real provider cannot produce a reliable
   interleaving. Label that scope honestly, not as complete live E2E.
6. **Transport and immutable-content integrity.** Retain byte/hash checks,
   corrupt chunks, stale checksums, unsolicited messages, connection capacity,
   missed signals, unavailable peers, private R2 access, and quota accounting.
   Visible pixels alone cannot establish which bytes or transport produced them.
7. **Release cryptography and monotonic publication.** Independently verify
   signed feed/archive bytes, channel/build/key pins, anti-downgrade/replay,
   bounded fetch, immutable paths, pointer-last commit/read-back, and concurrent
   publish rejection. A signed transport fixture is not a signed native app.
8. **Native trust, packaging, and operating-system boundaries.** Keep Catalyst
   versus native helper/module separation, compiled icon/resources, real
   sandbox/Keychain/XPC identity requirements, inside-out signing, notarization
   and Gatekeeper acceptance. The current native-accessibility adapter is
   Library Validation-blocked: no observation or action may load it, and no
   entitlement/signing/OS-security weakening is proposed to unblock a test.
9. **Performance, privacy, and evidence validity.** Keep opt-in load and native
   fixed-work measurements, log schema/caps/redaction, owned-process cleanup,
   stale evidence rejection, build provenance, and untouched inputs. The JS
   playback profile explicitly measures logical/reference work, not UIKit
   speed. Native timings and sustained WAN/load claims need their own runs.

Related Swift core families such as `CloudCommitBarrierTests`,
`CloudSnapshotFenceTests`, `PendingProjectSaveJournalTests`,
`EditorDraftJournalTests`, `CuePromptDraftJournalTests`, `GenerationJournalTests`,
`RuntimeBridgeEnvelopeTests`, and `RuntimeBridgeSessionGrantTests` fit these
retained gates. They remain within the companion core denominator; naming them
here is not a second mapping or additional coverage credit.

## Constraints and next acceptance step

- Keep the UIKit/Mac Catalyst target. Do not substitute the legacy AppKit app,
  Xcode, a simulator, or a mock backend for an unavailable boundary. Follow the
  repository's existing standalone-CLI/retained-SDK constraints.
- The present synthetic CLI root intentionally isolates saved data and limits
  commands. Its successful local import/edit scenarios do not establish a
  multi-account service, actual OS input, authenticated model turn, or update.
- Provisioning two real app clients, a controllable disposable service, mail
  delivery, provider test mode, native signed helpers, or TURN may be necessary.
  Those are unimplemented environment dependencies here, not granted actions.
- Keep reads, synthetic fixture setup, actual service writes, billing,
  credentials/pairing, signing, publication, install, and destructive operations
  distinct. Respect the task's permissions and required confirmations; do not
  weaken security or retry a denied boundary via another route.
- Prefer a few ordinary journeys with meaningful negative/lifecycle variants.
  Do not build a cartesian product of every parameter row through the UI, and
  do not conceal an untested service gate behind a broad journey name.
- For each original assertion, record its frozen ID/source line, the interaction
  and journey checkpoint, the observable invariant, required isolation/roles,
  the actual boundary exercised, evidence/build identity, and disposition:
  **covered**, **partially covered**, **requires end-to-end system/failure case**, **blocked**, or
  **obsolete with explicit justification**. One journey may cover many original
  assertions; one old test may split across several dispositions.
- Only retire an old assertion after its corresponding actual outcome has run
  and been verified, or after an explicit obsolescence decision. Retaining a
  narrower fault/contract test is compatible with an interaction-led E2E plan.

The next deliverable should be an integrated journey graph plus this backward
checkpoint ledger, not another one-to-one replacement script list. Completion
means every relevant assertion has an honest disposition and every required
interaction has evidence at its real boundary, not that a new test count
matches the old one.
