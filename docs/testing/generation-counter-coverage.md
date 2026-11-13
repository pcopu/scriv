# Generation-journey module counter capture

The existing generation CLI journey supports opt-in cumulative counters for
selected statement entries in `cloud/src/access.ts`, `generation.ts`, `http.ts`
and `index.ts`. All 80 ordinary HTTP checks and their assertions remain unchanged. Six separate collector requests
check the measurement channel. The normal route uses the ordinary Worker build.

Set `SCRIV_TRACER_CLI` and `SCRIV_TRACER_RUNTIME` to the verified installed Tracer
0.3 entrypoint and scenario runtime. Set `SCRIV_GENERATION_COVERAGE_DIR` to a new
absolute directory under an existing canonical, user-owned private parent outside
the source repository. Then run:

```sh
SCRIV_GENERATION_COVERAGE_DIR=/absolute/private/parent/capture-1 \
  node scripts/tracer-cli.mjs app -- test services generation
```

Use a fresh directory for every capture. No software is installed, no live account
is contacted, and no Mac access is needed. Existing auth/team journey exclusions
are unchanged. This mode supports the existing esbuild platform package layout on
Linux/macOS; it refuses an `ESBUILD_BINARY_PATH` override rather than trusting an
unrecorded binary. Preserve all earlier captures and partial failure evidence.

## Source and build boundary

The test-only instrumenter selects variable, expression, return, throw and if
statements in existing statement lists. It inserts fixed-slot counter increments
at exact original TypeScript offsets. Removing the recorded insertions, header
and footer must reproduce the original source exactly. It does not reprint the
source, wrap standalone control bodies or infer hits across a function/range.

A narrowly scoped esbuild loader validates every loaded production TypeScript
file against the strict source manifest and substitutes only those four
instrumented modules. Ordinary application imports and the corresponding snapshot
imports resolve to the same recorded module graph. The loader graph, build options, emitted bundle, source
hashes, insertion ledger and tool input hashes are retained privately. Other
source modules stay uninstrumented. The wrapper delegates to the real index
handler and re-exports the original Durable Object classes. Neither production
source nor deployment configuration is edited. Tool/build identities are
producer-declared evidence, not cryptographic compiler attestation.

The nonce-guarded snapshot route exists only in this measurement build. It
returns bounded counter data and identity fields, never fixtures, environment,
request data or credentials. The nonce is temporary and kept out of stored
source, URLs and evidence. Transport is restricted to the owned loopback origin
with five-second request deadlines, size limits and explicit outbound denial.
The existing owned child watchdog and cleanup remain in effect. Cancellation
during preparation prevents later Worker launch and import; failed or uncertain
imports are not automatically retried.

## What the numbers mean

The denominator is selected original statement-anchor lines in four collected
module instances, sampled through the Worker wrapper during the generation
journey. The counter on each line sums its selected
statement-site counters. A hit means statement entry, not completion, every
expression/branch, all TypeScript lines, SQL engine coverage or assertion quality.
Concise arrows, standalone control bodies, unselected statements, multiline
continuations and other uninstrumented code remain unknown. This is not a
universal TypeScript instrumenter. Module directives, labels, decorators,
namespaces and class static blocks are refused rather than silently broadening
the reviewed transform. The current HTTP error constructor retains its original
super call and TypeScript parameter-property initialization; probes before super
use only private module state and never access this or call application helpers.

Real repeated before/after reads must preserve cumulative counts, one generation
per collected module, advancing per-module snapshot sequences and the exact ordered
module/source identities. Snapshots are collected synchronously in one wrapper
request; this is not evidence of a globally atomic snapshot across other isolates.
Missing/wrong nonce requests must leave those
counters unchanged. Module initialization occurs before the real baseline, so
its already-nonzero counters are not interval increases. Never manufacture zero
baselines or claim those initialization lines ran again during the HTTP interval.

The official interval contains the entire 80-check journey, including its existing
synthetic project creation, logout/recovery and concurrent-callback continuations.
Logout calls ProjectRoom.refreshAccess; access and HTTP helpers are also imported
by Durable Object classes. These counters identify collected module instances,
not a request or Durable Object instance. They may include incidental or background
work sharing those instances, and do not prove main-fetch-only attribution or
coverage of other isolates. No per-action causality, forced internal SQL overlap,
Durable Object-instance, native app or overall-backend coverage is established.
Do not combine this denominator with manual mapping, native intervals or other
captures to claim overall coverage.

After successful owned cleanup, the collector verifies source/tools/build inputs,
requires genuine Tracer to reject the real endpoints reversed, and imports the
real pair into a separate verified analysis copy. The original source remains
unchanged before and after import. Use `measure report` and `measure check` on
that external analysis root. Keep raw profiles, datasets and local paths out of
Git. Report the exact source checkpoint, observed and instrumented anchor counts,
stale/invalid status and these limits alongside the result.

## Shared service capture

`SCRIV_SERVICE_COVERAGE_DIR` enables the shared adapter through the existing
`tracer app -- test services` selector. Supply a new absolute output directory
under a canonical, user-owned private parent outside source. The service runner
creates that directory and gives every selected cloud journey its own child
output. The updates journey retains its separate update-counter adapter.

```sh
SCRIV_SERVICE_COVERAGE_DIR=/absolute/private/parent/service-capture-1 \
  node scripts/tracer-cli.mjs app -- test services revision-safety
```

The shared mode uses an explicit runtime allowlist of 15 cloud modules. It
selects 1,600 statement sites on 1,164 distinct original anchor lines at the
November 13 adapter checkpoint. These are the transform's candidate universe.
Only actual before/after counter increases establish observed anchors. The
existing generation-only environment variable retains its four-module capture.
The generation journey rejects simultaneous generation-only and shared modes.

The allowlist includes access, atomic-batch, auth, billing,
character-image-validation, email-auth, email, generation, http, index, media,
notifications, project-room, teams and validation. `types.ts` supplies erased
TypeScript declarations. The same restricted AST transform, reversible insertion
ledger and pinned build-loader graph apply to every selected module. Preparation
refuses any unsupported construct or counter universe whose maximum safe counter
values cannot fit the existing 64 KiB collector response bound.

Each journey calls `begin(base)` after fixture provisioning and before its public
requests. It calls `end(base, ordinaryRequests, actions)` before disposal. The
ordered actions record actual request method and normalized path. Query values,
headers and bodies are omitted, UUID/hash components are normalized and join-link
tokens are redacted. The shared host-fetch observer forwards original arguments
unchanged. Node HTTP requests require explicit recording. WebSocket descriptors
may appear in the ordered sequence separately. The number of HTTP-prefixed action
descriptors must equal the supplied ordinary HTTP request count. Existing journey
assertions and their independently maintained request-count checks remain active.
Collector requests are outside that ordinary-request sequence.

Cloud, billing, collaboration and email-auth reconfigure Miniflare. Their adapters
end the current phase before every reconfiguration and begin a new phase after
its fixture setup. Each `phase-NNN` directory contains independent real baseline
and final snapshots, collector controls, LCOV endpoints, interval metadata and an
external analysis/import result. Each shared phase declares its own interval run ID, formed from the capture ID
and phase number, in both LCOV TN fields and endpoint metadata. Raw collector
snapshots retain the original capture ID. The phase export records both IDs and
actual module generations, preserving separate occurrences when counts repeat.
No delta crosses a reconfiguration. Within each
phase, per-module generation remains fixed and counter/sequence monotonicity is
strict. A new phase may observe a fresh generation or the continuing generation
of an instance retained by Miniflare.

The module/build/probe/source identities are stored once at the journey output
root and verified for every phase import. The shared probe pins all cloud journey
entrypoints and the shared runner. Raw phase evidence remains available when a
journey or import fails. A partial phase lacking a valid after-export cannot be
imported. Parent finalization never retries an uncertain import. Each successful
phase retains the real reversed-endpoint rejection control and its own verified
analysis copy. Source identities, anchor universes and outcome evidence must be
checked when combining intervals. Repeated phase denominators must not be added
as unique backend coverage.

These counters retain the module-instance and selected-anchor limitations above.
In particular, a snapshot import of ProjectRoom or BillingCoordinator does not
establish that their methods executed in the collected instance. Uncollected
isolates, initialization before baselines, SQL engine work and all unselected
source lines remain unknown. Shared mode does not alter production source,
provider fixtures, authentication, permitted origins or outbound restrictions.

## November 13 measured batch

All twelve cloud routes eventually passed with the shared adapter. The union
observed 1,113 of 1,164 selected anchor lines (95.62%), with 51 unobserved. The
known-passing union is identical. Three failed attempts remain retained with
their original outcomes; repaired discussions and billing runs passed. This
supersedes neither the historical four-module generation scope nor the separate
update-worker denominator. See [measurement-first-coverage.md](measurement-first-coverage.md)
for the cross-scenario results, remaining gaps and exact interpretation.
