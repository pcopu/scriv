# Coverage archive storage policy

The managed archive keeps the evidence needed to repeat Tracer's measurement
import and coverage queries. It shares immutable source and signed build inputs,
removes verified derived artifacts, and refuses new work when its configured
allocation budget or filesystem headroom is exhausted. It does not evict captures
to meet a limit. Use this policy before expanding coverage across hundreds of runs.

## What writes the bytes

The source audit at `d789c627d94024e3a1a292349f21c98db102498f` found
91,216,056 tracked bytes. This includes 45,841,169 bytes under `design/` and
37,961,544 under `docs/`. A hundred ordinary full copies would therefore contain
9,121,605,600 logical bytes before builds, profiles or reports. These are Git blob
sizes, **not measured physical APFS usage**. Cloned files can share extents.

| Writer | Retained output | Policy |
| --- | --- | --- |
| External source export or checkout | Full source, design assets, documentation, sometimes Git history | Create one shared snapshot per exact source-manifest hash. Do not copy a full checkout for each invocation. |
| `rebuild-catalyst-cli.py` | Signed app, build record, compiler objects/module cache | Reuse a compatible instrumented build; request CoW template copies. Optional guarded cleanup removes newly owned compiler work after build verification. |
| `coverage-session.mjs` | Before/after raw profiles, ordered commands, context, session and slot receipts | Retain. Sessions stay distinct. A valid failed scenario also retains its measured evidence. |
| `collect-cli-coverage.mjs` | LCOV, interval/export/import receipts and temporary indexed profiles | Retain LCOV and receipts. Remove matching `.profdata` only after final evidence and replay verification. Already absent indexes are accepted. |
| `prepare-coverage-analysis.mjs` | Source subset, dataset and analysis provenance | Normal capture copies only the paths measured by LCOV. Keep its independent source files and dataset at their original paths. |
| Tracer `measure batch` | Capture sets, outcome declarations, batch receipts and reports | Capture sets, outcome declarations and evidence bindings remain durable. A report is disposable only through the explicit regenerable-report cache. |
| `test storage report` | Current gap report plus a small regeneration recipe | Keep the newest configured number; regenerate and compare older reports before removing them. Keep their recipes. |

The existing archive compressor reports a reduction in per-file allocated blocks.
That is useful accounting but is not a physical-space benchmark. Compressing a
file can also break existing extent sharing. Do not infer reclaimed APFS bytes
from `allocatedBytesSaved`, logical sizes or clone counts.

## Retention contract

Every finished imported run keeps its original `evidence.json`, capture and
analysis records, full build/journey source manifests, source comparison, probe
and Tracer manifests, contexts, slots, session receipts, raw profiles, LCOV pairs,
interval/export/import records, measured source subset and dataset. Keep all
external capture-set and outcome files that refer to it. Neither cleanup nor
input deduplication relocates old evidence or rewrites its identity.
The existing `--keep-indexed-profiles` request is honored by managed cleanup and
historical migration; it does not waive verification of the retained raw evidence.

Before removing an index, cleanup checks the completed actual-app receipt,
unchanged app/source flags, process-group cleanup, imported intervals, and exact
retained file hashes. It invokes the selected immutable Tracer package to:

1. Run `measure check` on the retained dataset.
2. Reimport the original LCOV and manifest into a private independent dataset
   copy. Each interval ID must match and every import must report `changed:false`.
3. Run `measure batch` with the original native receipt to validate source/build
   binding, outcome declarations, unique observations and passing-only totals.

The proof is checked again after cleanup and after legacy input cloning. A
separate `retention.json` binds that proof to the original receipt. Repeating
cleanup without new work preserves that receipt. A tampered, unfinished, active,
uncertain or incompatible run remains untouched and is reported as unverified.
An inability to replay is a blocker, never permission to regenerate provenance.

Raw profiles remain available for later LLVM work. Re-export also requires the
matching signed app and recorded LLVM tools; the presence of raw bytes alone
does not prove that those external tools remain available. Deferred
`--export-functions` can regenerate a missing index in temporary storage, checks
the recorded tool and indexed-profile digest, and removes the temporary index.
Coverage import/query replay uses the retained LCOV and source and does not
require rebuilding the app or retaining `.profdata`.

## Initialize and share inputs

Use an existing private canonical archive directory outside all source trees.
The limit is explicit bytes. The following variables must name real existing
inputs. `TRACER` must be the selected release's `bin/tracer.mjs`, rather than an
opaque launcher; `SCRIV_TRACER_CLI` uses that same immutable entrypoint for captures.

```sh
export SCRIV_TRACER_CLI="$TRACER"
node "$TRACER" --root "$SCRIV_SOURCE" app -- test storage init \
  --archive "$ARCHIVE" --budget-bytes "$BUDGET_BYTES" \
  --run-reserve-bytes "$RUN_RESERVE_BYTES" --min-free-bytes "$MIN_FREE_BYTES" \
  --keep-reports 2

node "$TRACER" --root "$SCRIV_SOURCE" app -- test storage source \
  --archive "$ARCHIVE" --source "$SCRIV_SOURCE" \
  --manifest "$SOURCE_MANIFEST" --manifest-sha256 "$SOURCE_MANIFEST_SHA256"

node "$TRACER" --root "$SCRIV_SOURCE" app -- test storage build \
  --archive "$ARCHIVE" --app "$INSTRUMENTED_APP" --build-record "$BUILD_RECORD"
```

Use `source`'s returned `root` and `manifest`, and `build`'s returned `app` and
`buildRecord`, in subsequent runs. Source snapshots retain the complete manifest,
including design images and documentation, once per identity. They use a fresh
empty Git directory for Tracer discovery. They do not carry Git history, caches,
or mutable measurement datasets. The build store binds the complete signed
bundle, all file modes/link targets, executable, build record and source manifest.
It does not treat matching main executables as proof that other bundle files match.

Creation reserves conservatively rounded file bytes plus metadata headroom before
copying. A verified existing input can be reused even when the remaining budget
would not admit another copy. APFS copies are independent CoW files; no hardlinks
or symlink substitutions connect mutable source and analysis trees. Shared inputs
are immutable by contract and are revalidated before reuse.

For a new build, use the existing CLI builder with its normal signing and source
arguments plus `--discard-work-after-build`. This option requires a coverage build,
a new canonical work directory under a private owned parent, and a build record
outside the work tree. Only after signature, Catalyst platform, unchanged source
and record checks succeed does it remove that invocation's compiler work. A failed
build or pre-existing work directory is retained. Template cloning requires a
filesystem that supports `/bin/cp -cRp`; keep the template and output on the same
APFS volume. Do not reinstall Xcode or change the signing route for this policy.

## Run under the policy

Put native `--output-dir` inside the initialized archive. The native runner finds
the policy in its ancestors, obtains an exclusive archive lease, checks budget
and free headroom, captures normally, saves its final evidence, then applies the
retention verifier. It writes a separate `storage.json`; a storage error is
reported separately without converting a native failure into a pass or rewriting
the original outcome. Inspect storage status before the next batch.

```sh
node "$TRACER" --root "$JOURNEY_SOURCE" app -- test \
  --case 'journeys/local-images#first-line' \
  --app "$SHARED_APP" --output-dir "$ARCHIVE/runs" --coverage \
  --source-manifest "$JOURNEY_MANIFEST" \
  --source-manifest-sha256 "$JOURNEY_MANIFEST_SHA256" \
  --coverage-build-record "$SHARED_BUILD_RECORD" \
  --coverage-build-source-root "$BUILD_SOURCE" \
  --coverage-build-source-manifest "$BUILD_SOURCE_MANIFEST" \
  --coverage-build-source-manifest-sha256 "$BUILD_SOURCE_MANIFEST_SHA256" \
  --tracer "$TRACER"
```

Create `runs/` first. Discover valid cases with `tracer app -- test --list` and
choose the case/state from the coverage worklist. The example is an existing
case, not an assertion that it ran on the machine reading this document. Build
reuse still requires the existing strict build/journey manifest comparison;
only its explicit host-only differences are permitted.

`runReserveBytes` defaults to 256 MiB and `minFreeBytes` to 512 MiB. They are
configuration defaults, not measured peak bounds for every scenario. Calibrate
the reserve from the largest representative invocation, its raw-session limit,
LLVM work, and verification scratch. Start with small batches. The admission
budget is conservative file allocation plus this reserve; it may count shared
APFS extents more than once. It is not an OS-enforced quota and cannot bound
unmanaged processes or an invocation that exceeds its reservation. A strict
system-wide limit requires an independently configured volume quota. The policy
stops subsequent admissions rather than deleting valid evidence to conceal an overrun.

## Apply the policy to historical runs

Run archive-wide preview, inspect its retained-unverified reasons, then apply.
The command discovers existing native runs without assuming that the old source
roots are still present. Missing mutable source roots block their deduplication,
not independently verified coverage replay or index cleanup.

```sh
node "$TRACER" --root "$SCRIV_SOURCE" app -- test storage clean \
  --archive "$ARCHIVE" --tracer "$TRACER" \
  --capture-set "$CAPTURES" --reference-root "$REFERENCE" > "$CHECKPOINTS/preview.json"

node "$TRACER" --root "$SCRIV_SOURCE" app -- test storage clean \
  --archive "$ARCHIVE" --tracer "$TRACER" \
  --capture-set "$CAPTURES" --reference-root "$REFERENCE" --apply \
  > "$CHECKPOINTS/initial-cleanup.json"
```

Source roots named by verified runs are checked against their full manifests.
Duplicate files of at least 16 KiB become independent CoW clones **at the same
paths**, with identical bytes/mode/owner/mtime. Files with incompatible ownership,
links, attributes, ACLs or flags are skipped. A verified inode/hash cache avoids
recloning unchanged files on the next cleanup; it never authorizes deletion.

Old runner receipts contain app hashes but no reliable app path. To deduplicate
archived builds or explicitly identify additional source roots, pass `--inputs`
with a separately retained JSON plan:

```json
{
  "version": 1,
  "kind": "scriv-coverage-storage-inputs",
  "sourceRoots": [
    {
      "root": "/absolute/archive/old/source",
      "manifest": "/absolute/archive/old/sources.json",
      "manifestSHA256": "EXACT_RECORDED_SHA256",
      "gitObjects": true
    }
  ],
  "apps": [
    {
      "app": "/absolute/archive/old/ScrivAutomation.app",
      "buildRecord": "/absolute/archive/old/build-record.json"
    }
  ]
}
```

These are identities to verify, not permission to rewrite them. Legacy app
deduplication requires real strict signature verification before/after and an
exact full-bundle/build-record match. Framework symlinks and canonical paths stay
in place. No clone operation is reported as reclaimed physical bytes. Arbitrary
old compiler directories or reports without an ownership/regeneration contract
remain visible in the inventory; they are not guessed to be disposable.

The optional `gitObjects:true` explicitly includes that source root's real Git
object directory. It fingerprints the Git tree before/after and clones only
identical ordinary object/pack/index/reverse-index files. Git configuration,
HEAD, refs, the working index, logs and alternates stay untouched. Symlinked or
worktree `.git` files, active locks and oversized trees are skipped. Inspection
is bounded to 20,000 Git entries, 4 GiB per tree and 2 GiB per file. New shared
snapshots need no historical object copies.

Generate future disposable reports with `test storage report --archive ...
--tracer ... --capture-set ... --reference-root ...`. Recipes bind the input
capture-set hash, original query root, reference root and complete Tracer package.
Use immutable capture-set/outcome files and a pinned shared query source for each
checkpoint; create a new capture-set file when the batch grows.
Eviction requires regeneration with matching output bytes. If inputs have changed,
the report stays and the cache reports the blocker. With `keepReports:0`, the
result returns no retained report path and points to its retired recipe.

The archive lease serializes managed captures, sharing, cleanup and audits.
After an interrupted process, `test storage unlock --archive ...` recovers a
lease only when its process is confirmed dead on this same host. It cannot steal
a live or foreign-host lease. Stop other archive writers before applying policy.

## APFS acceptance measurement and next 100 runs

Keep measurement output in a separate `CHECKPOINTS` directory so redirected JSON
does not grow inside the archive while it is being measured. Use one quiet APFS
container and record unrelated activity. Do not delete snapshots as part of this
benchmark. The implementation records their listing when available.

1. Before migration, run `test storage audit --archive "$ARCHIVE"` and save its
   JSON. This inventories logical and allocated file bytes by category and records
   real `statfs`, `df`, `diskutil info` and target-container `diskutil apfs list`
   results. Audit acquires the lease; the small lease overhead is accounted for.
2. Apply the historical cleanup with the real capture set and reference. Its
   `before` and `after` measurements provide the cleanup delta. Confirm every
   relevant run is verified, capture-set/union/gap results are unchanged, and
   inspect skipped input files. Keep this cleanup report as the batch baseline.
3. Run a representative batch using the same shared build/source inputs. Include
   the ordinary small and large session shapes you actually plan to run, including
   relaunches if those are part of that workload. Count completed imported **runner
   invocations**, not raw profiles or repeated observed lines. Preserve native
   failures honestly. Do not mix a new native build into this sample.
4. Save an audit immediately after the batch, then run archive-wide `clean --apply`
   with the final real capture set/reference and save that cleanup report. Review
   the automatic per-run storage receipts too. The final cleanup must verify the
   original and added captures and their outcomes. An unresolved run prevents the
   benchmark from qualifying as fully verified.
5. Produce the projection from equally cleaned states:

```sh
node "$TRACER" --root "$SCRIV_SOURCE" app -- test storage forecast \
  --before "$CHECKPOINTS/initial-cleanup.json" \
  --after "$CHECKPOINTS/batch-cleanup.json" --runs 100 \
  > "$CHECKPOINTS/next-100.json"
```

The conditional estimate is `ceil(100 * retained_container_growth / completed_runs)`.
Both snapshots must describe the same archive/APFS container and preserve all
previous completed invocation IDs, the same policy hash, and the same explicit
input-registration plan. A nonempty baseline must already have verified
cleanup so deletion of old artifacts cannot offset new-run growth. Nonpositive
or noise-obscured growth is unresolved, not zero-cost evidence. Linux, stale or
incomplete inventories and unverified cleanup cannot produce an APFS estimate.
The command consumes supplied measurement records; it does not authenticate a
fabricated JSON file or perform a live benchmark itself.

If the next 100 runs need new builds, separately measure their physical cost and
pass `--new-builds N --build-bytes PHYSICAL_BYTES_PER_BUILD`. The run sample must
then have no shared-input growth, preventing double counting. Never subtract
logical source bytes or summed file blocks from physical container growth.

Report a table containing initial archive usage, after historical cleanup, after
the representative batch, and after its final cleanup. For every row include
timestamp, container/volume UUID, physical used/free bytes, logical/allocated file
bytes, completed invocation count and evidence verification status. Report the
batch's shared-input growth, observed peak/reservation, per-run retained delta,
next-100 projection, and remaining headroom against the configured budget.

Apple documents [clone extent sharing and shared free space across APFS volumes](https://developer.apple.com/documentation/foundation/about-apple-file-system).
Its [`du` manual](https://raw.githubusercontent.com/apple-oss-distributions/file_cmds/main/du/du.1)
distinguishes apparent size from allocated blocks. Those distinctions are why
the acceptance result requires actual target-container measurements. Source
audit figures or a portable tooling pass cannot substitute for that result.

## Verification status of this implementation

The implementation was developed in a Linux workspace on top of Scriv
`d789c627d94024e3a1a292349f21c98db102498f` and Tracer
`f031a47cab64307df1f045bcd433be62d433aea9`. Public CLI tooling fixtures exercise
source sharing, budget admission, replay-preserving cleanup, invalid evidence,
leases, cache eviction and projection validation. Their raw profile bytes and
APFS arithmetic examples are explicitly synthetic. They do not count as native
journeys, real APFS clones, signing verification or an archive migration.

The change builds on `d789c627d94024e3a1a292349f21c98db102498f`, which already
prunes verified LLVM indexes and regenerates them for function maps. Its existing
CLI routes remain supported. The real 18–22 GB Mac archive was not connected. Its before/after measurements,
historical cleanup and measured next-100 figure therefore remain acceptance work
for that host; no disk-saving number is claimed by this document.
