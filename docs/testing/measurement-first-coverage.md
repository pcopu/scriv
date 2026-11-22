# Measurement-first coverage

On November 20, all 12 cloud journeys passed in a fresh capture. The 15-module
Worker scope observed 1,154 of 1,164 statement anchors, including 11 from real
module initialization. Passing billing transport, media recovery and natural
room alarm cases brought the union to **1,163 / 1,164 (99.91%)** across 24
passing intervals. The remaining line is `cloud/src/project-room.ts:703`.
Runs exercising clean closure, dropped transport and a TCP reset observed the
close callback. A separate update Worker run reached **36 / 36** selected anchors
with four startup hits and all 48 HTTP checks passing.

Tracer can now rank gaps across a complete reference scope in one query:

```bash
TRACER_NO_UPDATE=1 node "$TRACER_CLI" --root "$SCRIV_SOURCE" measure gaps \
  --capture-set "$CAPTURE_SET" --reference-root "$REFERENCE_ANALYSIS_ROOT"
```

Choose a verified analysis root listed in the capture set. The report keeps its
instrumented denominator and admits cross-build evidence per file only when
the source hash and instrumented line set match exactly. Changed or unavailable
files stay visible, with failed observations and unknown outcomes tracked
separately from passing evidence. Keep capture sets, declaration files and
analysis roots together in persistent private storage outside the source tree.

The native `journeys/codex-loopback-generation` scenario connects through the
Settings UI to an isolated local protocol fixture. It verifies a generated PNG
and its persisted attachment, interruption and inspection of the same turn,
and refusal with the saved project unchanged. It uses `ws` from the existing
locked cloud dependencies. The Cancel control now sends the interrupt through
the same primary action that the CLI activates.

Seven comparison journeys passed on the earlier November 20 build. The fixture
passed in 8.185 seconds on the rebuilt instrumented Catalyst app, adding 916
lines beyond those comparisons where source and instrumentation match exactly.
It observed 53 lines in the changed Cancel view on the fresh binary. The
reference-build report combines these targeted runs to 8,215 / 21,674 lines
(37.90%). The earlier broad native checkpoint remains a separate measurement.

On November 13, 2026, the user cleared the exhaustive manual-mapping goal and
requested a faster workflow: connect tagged code and CLI actions provisionally,
then run scenarios to discover the actual execution coverage.

Manual source-to-assertion mapping is not a prerequisite for measurement.
The previous 20.76% figure describes that manual map, not execution coverage.
Keep the existing assertions and reviewed map; use instrumentation to guide
coverage discovery instead of maintaining more manual links before each run.

## Required first lookup

Before proposing more scenarios or estimating which code is covered, query the
retained measurements. Use a reusable external capture-set file instead of
reconstructing a long list of analysis roots. The concise output identifies
observed scenario matches, known-unobserved instrumented ranges and unknown
ranges. Detailed interval actions and evidence remain available with `--json`.

```bash
TRACER_NO_UPDATE=1 node "$TRACER_CLI" --root "$SCRIV_SOURCE" measure where \
  --capture-set "$NATIVE_CAPTURE_SET" \
  --source apps/catalyst/ScrivUIKit/Account/ScrivSignInController.swift

TRACER_NO_UPDATE=1 node "$TRACER_CLI" --root "$SCRIV_SOURCE" measure union \
  --capture-set "$NATIVE_CAPTURE_SET"
```

A capture set is ordinary version-1 JSON; input and outcome paths resolve from
its parent directory. Keep separate native, cloud and update scope files.

```json
{
  "version": 1,
  "inputRoots": ["analysis-a/source", "analysis-b/source"],
  "outcomes": "outcomes.json",
  "scope": "source-lines"
}
```

`where` validates stored payloads, the requested snapshot source and the exact
current requested file. Changed source stays historical and gives no current
credit. Missing datasets or absent instrumentation stay unknown. It preserves
independent provenance families and does not require the manual map or proposal
to be current. It does not run the app, force a production branch, or establish
assertion adequacy. Whole-scope `union` retains its stricter compatibility checks.

The full 38-root native union read 111,159,935 bytes in a measured 3.888 seconds.
The main delay was repeatedly assembling and interpreting that evidence. A
reusable capture set and one direct query remove those repeated preparation
steps; this change does not add a cache or scheduler.

Ten real-data acceptance checks matched independent source-line and scenario
oracles across native and cloud captures. Native lookups took 1.417–1.610
seconds; cloud lookups took 0.366–0.415 seconds on this host. The concise Sign-In
answer was 755 bytes and identified the Projects journey's 143 observed lines.
The capture-set union reproduced every prior independently validated native
file, interval, outcome and provenance group. Input dataset bytes stayed intact.
These are measured command times for this run, not universal performance bounds.

## First larger gap follow-up

The retained evidence showed zero observed lines in the native Sign-In and Teams
controllers. Extending the existing Projects journey with signed-out validation,
provider disclosure, cancellation, reopen and Teams open/dismiss checks added
**252 lines from a passing run in 41.688 seconds**, including **143 Sign-In** and
**80 Teams** lines. The remaining gain is 22 email-flow, five account-UI and two
workspace/character lines. Every cycle preserves the complete loaded model and
both saved project packages; no email, OAuth or billing action is submitted.

The initial attempt clicked during UIKit presentation and reached the existing
router guard. Its failed capture is retained. The test now waits for a unique
enabled public control with stable geometry before modal transitions; the CLI
has no transition-completion field. The wait is bounded, mutations dispatch
once, and production guards are unchanged.

At that checkpoint, native totals were **12,512 / 21,667 (57.75%) from passing runs** and
**12,514 / 21,667 (57.76%) across all observations**. The two extra lines are
router guard lines observed only in the failed attempt. There are 169 intervals
(151 passing, 18 historical failed), five retained provenance groups, and no
unknown outcomes. All 39 permitted current test graphs have passing evidence;
the restricted alias route remains blocked. The independently checked raw
counter union agrees with Tracer. Later measurements are recorded below.

Reusing the original native build with the full current test tree also exposed
a narrow host-file classification omission. The service-only test runner is now
an explicitly permitted host-file difference. Its exact before/after hashes are
checked, and native source, resource, package and build-script rejection tests
remain intact. No native inputs changed and no app rebuild was needed.

## Screen and service gap follow-up

The next lookup selected signed-out Discussion and Generation Jobs screens,
the existing real Codex connection journey, and six service boundary journeys.
Discussion navigation and three connect/disconnect cycles against an isolated
signed-out Codex runtime added **491 unique lines from passing scenarios** on
the retained native build, including 220 Discussion and 149 Codex-controller
lines. No account login or generation turn was submitted. The owned runtime
and supervisor stopped afterward, and their loopback port was confirmed closed.

That build's final checkpoint is **13,003 / 21,667 (60.01%) from passing runs**
and **13,057 / 21,667 (60.26%) across all observations**. Its 179 unique intervals
include 158 passing and 21 failed observations across six provenance groups,
with no unknown outcomes. The raw-counter oracle agrees for every file.
Passing endpoint sessions retain their own outcomes even when a later scenario
in the same invocation failed. Failed setup captures remain available.

The Jobs journey exposed a CLI defect: a sheet presented from the owned Settings
scene rendered in a native window absent from the CLI's window inventory.
The fix follows the presented-controller chain from Settings controllers whose
store is exactly the current workspace's store, retaining window deduplication
and the existing active-presentation and sensitive-input checks.

A fresh automation build using standalone Command Line Tools compiled and
bundled successfully in 209.478 seconds. Developer ID timestamping, strict
signature verification, approved-icon verification and Catalyst platform checks
passed. Its executable SHA-256 is
`433c9bc12251fb2931d077a64f892497f7f5618daef31b0cee460d0042e73a24`;
its build-source manifest SHA-256 is
`2f0b7f2920840ada8f1ba43d733687e239125422438e7814d8c50984dafb9527`.
The source change makes the preceding whole-build union historical. Fresh-build
acceptance and captures are tracked separately; old datasets are not rewritten
or forced into a compatible union. Per-file lookup can still reuse an old
observation when that requested file's current bytes match exactly.

The corrected Jobs journey passed on the fresh build in 22.57 seconds with
capture and strict pre/post signature checks. It verifies local/shared empty
history, signed-out refresh, two close/reopen cycles and complete loaded/saved
project preservation. Catalyst's native Done item is absent from the public
UIView snapshot, so the test discovers and verifies the Jobs controller's
priority Escape handler before dispatching Escape once. The failed capture
and the separate diagnostic remain retained; the diagnostic contributes no
measured interval.

The six scoped regressions—workspace, Settings navigation, Projects, capability
safety, local images/Discussion and default endpoint validation—also passed on
that build in 184.893 seconds, including capture and strict pre/post signatures.
Together with Jobs, these establish seven selected fresh-build journeys, not a
rerun of all 39 permitted routes. The default endpoint regression did not opt
into the separately completed live-runtime workflow.

## Working loop

1. Join proposal `existingPaths` to discovered native/service/tooling routes.
   These are provisional connections, not assertion or execution claims.
   Keep unmatched plans visible and respect restricted routes.
2. Deduplicate routes. A hundred plans referencing one journey require one
   execution, not a hundred executions.
3. Rank routes by proposed source ranges intersecting instrumented lines that
   have not yet been observed. Treat this score as a scheduling hint.
4. Run existing journeys through `tracer app -- test` with their measurement
   adapter. Native capture already exports and imports real LCOV intervals.
   It does not require new manual mappings or a rebuild of unchanged code.
5. Union observed file/line pairs only within compatible build, source and
   instrumentation scopes. Keep original intervals, outcomes and provenance.
   Record actual marginal gain, including hits outside the proposed targets.
6. Rerank from the remaining gaps. Extend tests or CLI access only when a gap
   warrants it. Review assertion quality separately; counters do not prove it.

Exact path matching currently connects 366 of 514 plans to 42 distinct
unrestricted routes: 33 native, seven service and two tooling routes. Another
148 plans lack a direct binding. These counts do not establish that a route
implements every assertion described by its associated plans.

## Verified pilot

Three automatically selected existing native journeys ran on the retained
instrumented Catalyst build. No new tests, manual links or app build were needed.

| Route | Command wall time | New observed lines |
| --- | ---: | ---: |
| `codex-endpoint-validation` | 13.013 s | 561 |
| `image-evidence-isolation` | 3.419 s | 40 |
| `settings-navigation` | 4.245 s | 31 |
| Total | 20.677 s | 632 |

All three passed. Timing includes the native run, profile capture, LLVM export
and import, but excludes candidate preparation and subsequent analysis.
The preceding workspace smoke pilot completed in 5.757 seconds and observed
1,748 lines, all already present in the cached union.

The 67 compatible cached intervals observed 9,732 unique lines. Adding the four
pilot intervals gives 10,364 of 21,667 instrumented lines across 150 app/Core
files, or 47.83%. Restricting the union to passing journeys gives 10,355 lines,
or 47.79%; nine lines occur only in an earlier failed journey. All measured
source hashes matched that retained capture-source checkpoint. Original datasets
were preserved.

The speculative connections were useful without being accurate predictions:
image-evidence-isolation hit none of its 950 proposed target lines but exposed
40 different new lines. Settings overlapped heavily with endpoint validation;
deduplication reduced its marginal gain to 31. Count the measurements, not the
guesses or the sum of individual journey totals.

## Completed remaining-scenario batch

The November 13 follow-up reused the verified instrumented Catalyst executable
and ran every remaining permitted native route. Twenty unchanged and nine
updated routes passed with capture. Together with compatible cached runs, all
39 permitted routes have passing captures for their current test-module graphs.
The fortieth route, character aliases, remains blocked by its recorded Library
Validation restriction and was not retried.

The union after those 29 runs was **12,258 / 21,667 lines (56.57%)** across 150
app/Core files. All of these observed lines occur in passing runs as well.
The runs added 1,894 unique observed lines to the 71-interval pilot checkpoint;
command wall time totaled 789.249 seconds, excluding preparation and analysis.
Raw evidence, historical failures and separate provenance groups were retained.

The first focused gap extension added Escape cancellation and Command-Return
opening to the existing project-browser journey. Public key discovery and
dispatch must reach `ProjectBrowserController`; both shortcuts verify browser
dismissal, the complete loaded model, absence of alerts and preservation of both
complete saved packages. Its passing capture added exactly the intended two
previously unobserved lines, `ProjectBrowserController.swift:181-182`, in 19.882
seconds. The native union at that checkpoint is **12,260 / 21,667 (56.58%)**, leaving **9,407
unobserved instrumented lines**. Its 167 unique intervals include 150 known-passing
and 17 historical failed intervals, with no unknown outcomes and four retained
provenance groups. This demonstrates the measured-gap loop without
adding production code or rebuilding unchanged native inputs.

The native executable SHA-256 is
`c784f0aac49c509e9f603f09e3aa1754c0dd8860f3e4065175c0dbf8f3a2e165`.
Its original full source manifest SHA-256 is
`81e8bf51df498ff80b434cebe56c2bdb69d3847ed136ad95c5bed848a6a9a443`.
The separately pinned journey snapshots and strict pre/post signature checks
preserve the retained build record; no new build attestation was created.

## Native capture with separately pinned journeys

Use explicit trusted Tracer entrypoints and paths from verified source/build
records. `SCRIV_JOURNEY_SOURCE` is an immutable snapshot of the current tests and
host adapter. The three `--coverage-build-source-*` arguments identify the
unchanged original build tree, rather than rewriting its manifest when a test
changes. They are optional only when both trees are identical.

```bash
TRACER_NO_UPDATE=1 node "$TRACER_CLI" --root "$SCRIV_JOURNEY_SOURCE" app -- test \
  --scenario "$SCENARIO" --app "$SCRIV_AUTOMATION_APP" \
  --source-manifest "$SCRIV_JOURNEY_MANIFEST" \
  --source-manifest-sha256 "$SCRIV_JOURNEY_MANIFEST_SHA256" \
  --coverage --coverage-build-record "$SCRIV_COVERAGE_BUILD_RECORD" \
  --coverage-build-source-root "$SCRIV_BUILD_SOURCE" \
  --coverage-build-source-manifest "$SCRIV_BUILD_MANIFEST" \
  --coverage-build-source-manifest-sha256 "$SCRIV_BUILD_MANIFEST_SHA256" \
  --coverage-max-sessions 64 \
  --output-dir "$SCRIV_COVERAGE_OUTPUT" --tracer "$TRACER_CLI"
```

Both complete manifests are checked at preflight, at each actual session
boundary, and through export/import. Only explicitly enumerated host files,
test directories and documentation may differ. Native sources, resources,
packages and build scripts must match. Each capture retains both full manifests
and their exact difference list. The imported analysis copy contains the original
build bytes for the source files named by the actual LCOV exports. Model
Document uses one session on apps advertising JSON import error
acknowledgement across owned presentations. `SCRIV_JSON_VALIDATION_ISOLATION=fresh` retains the 23-session
control for comparing coverage and timing on the same app.

Read the produced `evidence.json`; `coverage.analysis.root` identifies the
external source copy containing the imported dataset. Run `measure check` and
`measure report` on that root. All output stays outside pinned source.
The analysis copy records its own file list and digest in `analysis-sources.json`
and `analysis.json`. The complete producer manifest still supplies the import
identity. Analysis copies request independent filesystem clones where supported,
with an ordinary-copy fallback. Keep the original pinned build source, raw
profiles, LCOV pairs and imported datasets for replay and comparison.

## November 13 service checkpoint

All 13 existing service selectors passed in isolated local fixtures. Initially
only generation and updates had counter adapters. The shared opt-in adapter now
covers the other eleven cloud routes too, selecting 1,600 statement sites on
1,164 original anchor lines across 15 modules. No production TypeScript or
deployment configuration changed.

The twelve cloud routes together observed **1,143 / 1,164 selected anchors
(98.20%)** with the same result in the known-passing union. At that checkpoint,
**21 anchors remained unobserved.**
The focused collaboration, atomic-batch, discussions-assets, billing, OAuth and
team-lifecycle extensions all pass and add 30 anchors to the prior checkpoint.
The separate updates route then observed **32 / 36 (88.89%)**. Neither
percentage is an overall project percentage or a percentage of all backend lines.

Use the existing public service selector with a fresh external output directory:

```bash
TRACER_NO_UPDATE=1 \
SCRIV_SERVICE_COVERAGE_DIR="$NEW_SERVICE_CAPTURE" \
SCRIV_TRACER_CLI="$PINNED_CAPTURE_TRACER" \
SCRIV_TRACER_RUNTIME="$PINNED_SCENARIO_RUNTIME" \
  node "$TRACER_CLI" --root "$SCRIV_SERVICE_SOURCE" app -- test services
```

Set the separately documented update-counter environment for updates. Preserve
the capture runtime pin; a newer analysis CLI is not a substitute for the
journeys' explicitly verified runtime. Each Worker reload starts a distinct
before/after interval with a unique phase occurrence ID. Ordered credential-free
request descriptors, raw snapshots, reversible insertion ledgers, exact
source/build/tool identities and decreasing-counter rejection checks are retained.
See [generation-counter-coverage.md](generation-counter-coverage.md) and
[update-counter-coverage.md](update-counter-coverage.md) for adapter limits.

Three failed cloud attempts remain visible: the initial discussions build
configuration, the initial billing counter closure, and a billing import stopped
by disk exhaustion. Their repaired runs passed. The two interrupted raw billing
phases were verified and imported into new analysis roots with separate recovery
receipts; original partial artifacts stayed unchanged. The final service union
initially contained 23 phases: 19 from passing attempts and four from failed
attempts, with 14 retained provenance groups and no unknown outcomes. Recovery added no new
observed anchors and did not change either failed attempt to passing.

The gap follow-up retains 39 phases: 31 passing and eight failed, across 22
provenance groups with no unknown outcomes. A new billing attempt first failed
because Miniflare translated the fixture exception into an HTTP provider error;
the test now verifies that actual response and continues through pagination.
The separate true fetch-rejection branch remains unobserved. Every original
raw snapshot, failed interval, dataset, source and tool identity was preserved;
independent raw-counter and imported-dataset comparisons agree.

## Reusable Tracer commands

The Tracer source now supports provisional binding without requiring reviewed
manual mappings. An external discovery catalog preserves exact paths, ordered
argv and restrictions. Stale proposal source pins remain visible and cannot be
used for prediction scoring, but do not block legitimate route execution.

```bash
node "$TRACER_CLI" --root "$SCRIV_SOURCE" proposal bind \
  --file docs/testing/proposed-scenario-map.json \
  --routes "$EXTERNAL_ROUTE_CATALOG" --json

node "$TRACER_CLI" --root "$SCRIV_SOURCE" measure union \
  --input-root "$ANALYSIS_A" --input-root "$ANALYSIS_B" \
  --scope source-lines --outcomes "$OUTCOME_DECLARATIONS" --json
```

Default union scope is strict full capture identity. Explicit `source-lines`
scope requires exact source bytes and identical instrumented line universes,
retains distinct build/probe/tool provenance groups, and unions observed
presence without adding cumulative counters. Legacy and modern IDs for the same
capture occurrence deduplicate; conflicting outcome declarations are rejected.

Outcome declarations bind exact interval IDs to evidence paths and SHA-256
hashes. Generic Tracer checks their integrity; producer-specific validators must
check what the evidence means. This batch independently compared imported rows
with actual raw profile or per-site counter deltas and checked recorded process
outcomes. Report both all-observed and known-passing unions. Missing outcomes
remain unknown. Journey marginal gains depend on the stated encounter order.

The source and installed Tracer skill now describe this workflow, including the
actual adapter-selection step and the limits of provisional predictions. These
commands provide binding and union; scheduling/ranking remains an explicit
external decision. No automatic scheduler or released/global CLI upgrade is
claimed.

## Remaining measured gaps

The retained native build's passing-only checkpoint identifies these gaps.
Its whole-build totals are historical after the CLI source change; query each
current file before choosing more work. These are priorities from the actual
instrumented universe, not estimated whole-file coverage or proof of dead code.

| Native source | Observed / instrumented | Unobserved |
| --- | ---: | ---: |
| `WorkspaceStore.swift` | 1,039 / 2,352 | 1,313 |
| `CloudClient.swift` | 27 / 895 | 868 |
| `CodexController.swift` | 155 / 873 | 718 |
| `ScrivCLIRunCapability.swift` | 70 / 409 | 339 |
| `ScrivDiscussionController.swift` | 220 / 312 | 92 |
| `TeamsController.swift` | 80 / 282 | 202 |

The next useful native variants are account-backed cloud/team/discussion flows
and Codex job lifecycle/error handling, with their actual supported CLI routes,
isolated fixtures and required runtime services checked first. A passing local
backend journey does not establish native UI or native-client execution.
The 21 cloud gaps on November 13 comprised eleven startup initializers, six media storage/race
guards, two natural 24-hour alarm lines, one WebSocket error callback and one
billing fetch-rejection line. Startup counters were already nonzero at the
baseline; ordinary requests do not add interval observations for those sites.
Source ranges are available in the retained union reports.

These observations are line-counter increases during whole intervals, including
polling and background work. Startup before the baseline, uninstrumented code,
helpers and other isolates remain outside the observed scope. Counters establish
neither per-action causality, branch coverage nor assertion adequacy. No overall
project denominator or release/notarization claim is inferred from these results.

## Verification and retained limits

Scriv's repository/type checks, all 18 public CLI tooling checks and the public
source-provenance journey passed. The latter includes 18 measurement-output
checks using synthetic importer fixtures; these are tooling evidence, not extra
native coverage. The earlier measurement-first checkpoint passed 151 Tracer
journeys. After adding the direct lookup and capture-set support, the integrated
full check passed 155 journeys with four Linux-only TTY skips, and all 447 manual
links validated. Both skill copies validated. Ten real-data lookup checks and
eight independently rerun public lookup regressions also passed.

Existing affected Scriv references were maintained without adding manual links
to support the measured runs. All 2,520 live links and 1,211 explicit comment
declarations validate. Proposal integrity passed at the published `c867f33`
checkpoint; the later host-file edit leaves its planning pin stale until a
planning review. That does not gate measured lookup. An unrelated preexisting
`tooling-service-steps.json` witness pin remains unresolved, and historical v89
catalog context was preserved. These catalog limits neither create execution
credit nor invalidate the separately checked raw captures.

The earlier lookup checkpoint published Tracer source and installed-skill
changes. The follow-up adds the separately verified Scriv automation build
described above. Neither establishes a Tracer package release, global CLI
upgrade, release notarization, trusted-helper behavior or app distribution.
