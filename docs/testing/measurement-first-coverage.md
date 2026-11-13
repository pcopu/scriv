# Measurement-first coverage

On November 13, 2026, the user cleared the exhaustive manual-mapping goal and
requested a faster workflow: connect tagged code and CLI actions provisionally,
then run scenarios to discover the actual execution coverage.

Manual source-to-assertion mapping is not a prerequisite for measurement.
The previous 20.76% figure describes that manual map, not execution coverage.
Keep the existing assertions and reviewed map; use instrumentation to guide
coverage discovery instead of maintaining more manual links before each run.

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
source hashes match current application source. Original datasets were preserved.

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
seconds. The final native union is **12,260 / 21,667 (56.58%)**, leaving **9,407
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
and their exact difference list. The imported analysis copy uses original build
source. The model-document journey needs 23 sessions; earlier incomplete capture
was retained, and its complete passing run now supplies all those observations.

Read the produced `evidence.json`; `coverage.analysis.root` identifies the
external source copy containing the imported dataset. Run `measure check` and
`measure report` on that root. All output stays outside pinned source.
Analysis copies request independent filesystem clones where supported, with an
ordinary-copy fallback. Full byte/hash checks, private permissions, create-only
writes and copy independence remain verified. This addresses disk duplication
without hard-linking mutable source or removing capture evidence.

## Service measurements

All 13 existing service selectors passed in isolated local fixtures. Initially
only generation and updates had counter adapters. The shared opt-in adapter now
covers the other eleven cloud routes too, selecting 1,600 statement sites on
1,164 original anchor lines across 15 modules. No production TypeScript or
deployment configuration changed.

The twelve cloud routes together observe **1,113 / 1,164 selected anchors
(95.62%)**; the known-passing union is identical. **51 anchors remain unobserved.**
The updates route remains a separate **32 / 36 (88.89%)** scope. Neither
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
contains 23 phases: 19 from passing attempts and four from failed attempts, with
14 retained provenance groups and no unknown outcomes. Recovery added no new
observed anchors and did not change either failed attempt to passing.

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

The largest native gaps are concentrated in workflows the current journeys do
not reach. These are priorities from the actual instrumented universe, not
estimated whole-file coverage or proof that the code is dead.

| Native source | Observed / instrumented | Unobserved |
| --- | ---: | ---: |
| `WorkspaceStore.swift` | 1,028 / 2,352 | 1,324 |
| `CloudClient.swift` | 27 / 895 | 868 |
| `CodexController.swift` | 6 / 873 | 867 |
| `ScrivCLIRunCapability.swift` | 70 / 409 | 339 |
| `ScrivDiscussionController.swift` | 0 / 312 | 312 |
| `TeamsController.swift` | 0 / 282 | 282 |

The next useful native variants are account-backed cloud/team/discussion flows
and Codex job lifecycle/error handling, with their actual supported CLI routes,
isolated fixtures and required runtime services checked first. A passing local
backend journey does not establish native UI or native-client execution.
The 51 cloud gaps are led by `project-room.ts` (26), `media.ts` (6),
`billing.ts` (4) and `email-auth.ts` (4); the remaining 11 are distributed across
six modules. Source ranges are available in the retained union reports.

These observations are line-counter increases during whole intervals, including
polling and background work. Startup before the baseline, uninstrumented code,
helpers and other isolates remain outside the observed scope. Counters establish
neither per-action causality, branch coverage nor assertion adequacy. No overall
project denominator or release/notarization claim is inferred from these results.

## Verification and retained limits

Scriv's repository/type checks, all 18 public CLI tooling checks and the public
source-provenance journey passed. The latter includes 18 measurement-output
checks using synthetic importer fixtures; these are tooling evidence, not extra
native coverage. Tracer's full check passed 151 journeys with four Linux-only
TTY skips. Its 444 manual links validated. After the final documentation-only
skill path clarification, the affected project/installation journeys passed
13 checks with the same four platform skips, and both skill copies validated.

Existing affected Scriv references were maintained without adding manual links
to support the measured runs. All 2,520 live links and 1,211 explicit comment
declarations validate; proposal integrity also passes. An unrelated preexisting
`tooling-service-steps.json` witness pin remains unresolved, and historical v89
catalog context was preserved. These catalog limits neither create execution
credit nor invalidate the separately checked raw captures.

This checkpoint publishes source and installed-skill changes. No Tracer package
release, global CLI upgrade, Scriv application rebuild or distribution is implied.
