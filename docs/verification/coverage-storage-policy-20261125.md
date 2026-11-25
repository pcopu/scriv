# Coverage storage implementation verification — November 25, 2026

## Scope and checkpoints

This change adds managed archive storage on top of Scriv
`48221411af6b228104372823622161f14d576153`, which includes the existing
index-pruning change `d789c627d94024e3a1a292349f21c98db102498f` and subsequent
native journey work. The original `compact --prune`, default unmanaged index
cleanup, deferred function-map regeneration and `--keep-indexed-profiles`
behavior are preserved.

The public CLI used Tracer `f031a47cab64307df1f045bcd433be62d433aea9`.
The provenance continuation separately used its unchanged pinned runtime from
`8e12583bb8da60f9325a7cee5d1050b3b33aa679`. Its five module hashes were checked
by the existing journey; no runtime pin was relaxed.

## Executed checks

| Check | Result | What it establishes |
| --- | --- | --- |
| `npm run check` | Passed | Cloud TypeScript check, 25 design concepts, 3 sample frames and repository asset/release-file integrity. |
| `npm test` through the pinned public Tracer entrypoint | **47/47 public CLI journeys passed** | Existing CLI behavior plus the storage paths listed below. Native scenarios executed: **0**. |
| `tracer app -- test provenance` with the pinned runtime | Passed | Existing source provenance/recovery journey and **18** measurement-output checks using synthetic importer fixtures. |
| `tracer check --json` | **2,782/2,782 links and 1,205/1,205 comment declarations valid** | Reviewed manual-association integrity only. No measured native coverage or exclusions were added to obtain this result. |
| `git diff --check` | Passed | No whitespace errors in the patch. |

The storage checks cover complete source sharing and reuse; independent file
bytes and unchanged modes; actual Tracer use of the returned Git root; budget
refusal before a native invocation allocates a run; actual Scriv CLI execution
from a verified shared source inside its archive; and truthful `not-run`
evidence with a separate partial storage receipt when a catalog restriction
prevents launch. An ordinary nested checkout and altered shared manifest are
rejected. The tests also cover inode accounting, filesystem headroom, archive
leases and explicit dead-process lease recovery.

The preservation fixture imports a three-line synthetic LCOV interval through
the real Tracer CLI. Two lines have increasing counters. Before and after
cleanup, its retained proof has **3 instrumented lines, 2 observed lines,
2 passing-only observed lines and 1 passed outcome**. The original interval ID,
payload hash, source/build hashes, evidence bytes and dataset bytes remain
identical. Only the two matching synthetic indexed-profile files disappear.
An idempotent second cleanup preserves the retention receipt too.

A separate failed-outcome fixture keeps **2 observed lines and 0 passing-only
observed lines**. Historical content-only interval IDs and already absent indexes
remain accepted without rewriting history. `keepIndexedProfiles:true` preserves
both index bytes and inodes while still requiring the full proof. Incomplete,
active, uncertain, tampered or mismatched evidence retains all its artifacts.

The report fixture generates three reproducible gap reports with a cache limit
of two, retires the first report's recipe, and checks the original capture set,
outcomes, receipt and dataset remain unchanged. Archive cleanup with explicit
capture-set/reference arguments verifies identical union/gap results. A reference
fixture source absent from the current query tree is honestly reported as
unavailable and receives no current-source coverage credit.

Projection tests use explicitly synthetic saved APFS records to check arithmetic
and refusal conditions. They cover verified cleanup before and after, unchanged
policy/input-plan identities, retained invocation IDs, complete archive proof,
incomplete/duplicate additions, changed containers, noise and additional-build
double counting. These fixtures are not APFS measurements.

## Actual APFS acceptance remains outstanding

The execution host was Linux. It had no connection to the user's 18–22 GB Mac
archive. The genuine audit reported physical APFS usage as unavailable. No Apple
signature verification, APFS file clone, actual archive migration, representative
native batch, physical reclaimed-byte result or measured next-100-run figure is
claimed by these checks.

Use the [storage policy and acceptance procedure](../testing/coverage-storage-policy.md)
on that Mac. Save the initial audit, historical cleanup, representative-batch
audit and final cleanup outside the measured archive. Compare actual target
container usage and original evidence proofs, then run `test storage forecast`
on the equally cleaned before/after records. A partial cleanup, changed input
plan or unresolved physical delta must remain a blocker to the quantitative
claim. Unknown legacy compiler directories or unregistered reports remain
retained until their ownership and regeneration contract can be established.
