# Measured coverage of real Tracer scenarios

This opt-in collector extends `tracer app -- test` rather than introducing a
mock application or an implementation-level test suite. It brackets each real
`ScrivSession` used by selected scenarios. A scenario may launch many apps;
**each app run has its own cumulative before/after pair and UUID**. Profiles
from different sessions are never combined.

One workspace session on public checkpoint `e9819de` successfully captured,
exported and imported a real interval: 150 app/Core files, 21,667 instrumented
line records and 1,736 counter-increasing lines, with no stale measured files.
That is a scoped historical observation, not a full-suite or current-build pass.
Every changed collector/build still needs a matching macOS run. Linux's public
tooling journeys cannot establish native success; their hand-authored LCOV
fixtures exercise output handling only and must never be reported as app hits.

## 1. Pin source before building

Use the source manifest supplied with the exact checkpoint, or export one from
the final source checkout with `scripts/export-cli-source-manifest.mjs`. Include
all intended untracked source using that tool's explicit `--include` options.
Once published/tracked, a complete checkout needs no untracked includes. Keep
the manifest outside source, build, template and work directories, and retain
its exact SHA-256. Never regenerate hashes after a build to disguise a mismatch.

```sh
node scripts/export-cli-source-manifest.mjs \
  --output /private/tmp/scriv-coverage-evidence/source.json
```

The parent directory must already exist. Review source selections as described
in [the export contract](cli-run-evidence.md). Do not include credentials,
private diagnostics or user projects. Paths in the following examples are
caller-chosen placeholders; use actual verified inputs, not invented build data.

## 2. Make a matching coverage build

Use the existing CLI-only Catalyst builder and its approved template, SDK and
signing inputs. Do not install Xcode or weaken security settings to bypass a gate.
In addition to its normal required arguments, supply:

```sh
python3 scripts/rebuild-catalyst-cli.py \
  --automation --coverage \
  --coverage-source-manifest /private/tmp/scriv-coverage-evidence/source.json \
  --coverage-source-manifest-sha256 PINNED_SOURCE_SHA256 \
  --coverage-build-record /private/tmp/scriv-coverage-evidence/build.json \
  --template /verified/template.app --output /separate/ScrivCoverage.app \
  --sparkle-framework /verified/development/Sparkle.framework \
  --work /separate/build-work --identity EXISTING_SIGNING_IDENTITY \
  --version NUMERIC_VERSION --build NUMERIC_BUILD
```

The builder verifies the exact source manifest before compilation and after
final signing, icon and platform checks. It then hashes the signed executable
into a create-only record with source-manifest hash, executable hash and the
`/scriv-source/` coverage prefix. Its existing parent must be owned by the user
and not writable by others; use canonical paths, such as `/private/tmp` on macOS,
not symlinked `/tmp`. Noncoverage builds do not require these options.

This is producer-declared build evidence, not cryptographic attestation. Template
assets and third-party Sparkle are retained from the approved template. The
native adapter and runtime helper are rebuilt from source but not instrumented
or attested by this host-only record. A missing record cannot be replaced by hashing today's checkout.

## 3. Run selected real scenarios

Start with a small verified route and a deliberate storage budget:

```sh
tracer app -- test --coverage --scenario workspace \
  --app /separate/ScrivCoverage.app \
  --source-manifest /private/tmp/scriv-coverage-evidence/source.json \
  --source-manifest-sha256 PINNED_SOURCE_SHA256 \
  --coverage-build-record /private/tmp/scriv-coverage-evidence/build.json \
  --coverage-max-sessions 1 \
  --output-dir /private/tmp/scriv-coverage-evidence
```

Repeat `--scenario` for more exact listed IDs. The selection runs in catalog
order. Coverage requires explicit IDs; it never silently profiles all native
entrypoints. The session cap defaults to 64 and accepts 1–64. Some composed
journeys create many sessions, so choose an adequate cap. Every attempt reserves
a slot, including failures; slots are not recycled.

The raw bound is two 16 MiB snapshots per session. LLVM indexed profiles and
LCOV exports are separately bounded at 64 MiB each. At the maximum cap, retained
artifacts can consume many GiB. Confirm sufficient disk before running; a low
cap reduces the bound but can stop a multi-session scenario. Nothing is deleted
automatically to make room.

Preparation also creates an exact source copy for analysis under this run's
private evidence directory. Its bound is 10,000 files, 64 MiB per file and
512 MiB total. It copies only the verified manifest, rejects symlinks and
existing output, and verifies the original and copy before capture. These are
separate regular files, never hard links or a symlink back to build source.
Tracer requires a Git root, so the copy has new empty local Git metadata, with
no copied history, template hooks, remote, staged files or commits.

LLVM tools default to `xcrun --find llvm-profdata` and `llvm-cov`. Optional
`--llvm-profdata /absolute/tool` and `--llvm-cov /absolute/tool` must identify
compatible trusted tools. The importer must be Tracer 0.1.2 or newer. It defaults
to `SCRIV_TRACER_CLI` or PATH; `--tracer /absolute/package/bin/tracer.mjs` selects
a trusted installed package. An opaque managed launcher is rejected; resolve its
actual package first. Tool binaries/entrypoints are hashed before capture and
checked again after export and before import. Tracer's `bin`, `src` and package
manifest are separately pinned, so changing an implementation module is detected.

## What is recorded

- After real launch/isolation handshake, collect and release a before profile
  through bounded stdio chunks. No app container is read and no counters reset.
- Observe the actual ordered scenario command names and completion states.
  Parameters, returned UI/model data, credentials and native logs are not stored.
- On session close, collect/release the after profile, verify executable/probe
  identity, and terminate the owned app even if collection fails. Transfer
  completion timestamps are not claims of atomic snapshot instants.
- After scenario processes finish and cleanup is confirmed, index before and
  after **separately** with real `llvm-profdata`; export each against the exact
  executable with real `llvm-cov -format=lcov`.
- Verify source, bundle, probe and tools again before invoking actual
  `tracer measure import` for each complete interval. No `--allow-stale` fallback
  is used. Import uses the external analysis root, and the original build source
  is checked again after import. The strict eligible source file set is unchanged.

Private output includes `coverage/capture.json`, pinned build/source/probe/Tracer
records and `coverage/sessions/RUN_UUID/` containing raw profiles, indexed
profiles, LCOV, session/interval/export records and successful import receipts.
The collector exports line counters only. The raw profiles can regenerate
function and branch data separately. The analysis copy holds only source files
named by the exports, with their original build hashes.
On macOS the collector uses transparent filesystem compression when it reduces
allocated disk blocks and preserves the exact LCOV bytes and permissions.
The `.lcov` paths are readable by Tracer and LLVM tooling as ordinary files.
Both capture.json and the runner's evidence.json track phases/outcomes. The
measurement dataset stores only Tracer's validated counters and provenance, not
the raw profile/export files. Do not publish raw captures or private evidence
without separate review and authorization.

`coverage/capture.json` records `analysis.root` and `analysis.dataset`.
Tracer 0.3 always writes `docs/testing/code-e2e-measurements.json` below its
selected root. Therefore this collector uses
`coverage/analysis/source/` as that root, **never the pinned build checkout**.
The sibling `coverage/analysis/analysis.json` records the verified source-copy
identity. To inspect results, use the recorded canonical root:

```sh
tracer --root EXTERNAL_ANALYSIS_ROOT measure report --json
tracer --root EXTERNAL_ANALYSIS_ROOT measure check --json
```

Each invocation has its own create-only analysis root and dataset. Multiple
sessions within that invocation import separate intervals into that dataset.
Different invocations do not automatically merge counters or deduplicate lines
across reports. Report exact scope rather than adding interval totals together.
The public `scripts/prepare-coverage-analysis.mjs` command also prepares such a
copy with `--source-manifest`, `--source-manifest-sha256` and an external
`--output` whose owned, non-group/world-writable parent already exists. It does
not capture, invent, import or migrate any measurements.

The earlier collector imported into the source checkout, leaving an untracked
dataset that caused the next strict manifest check to fail. Preserve that
checkout, dataset and its raw evidence. Use a separate clean, verified checkout
and a newly matching build for later runs; do not delete the old dataset, silently
copy it into a new run, ignore it in source verification, or regenerate the old
build's manifest. The new analysis preparer refuses manifests containing the
measurement dataset. A partial failed preparation remains available for inspection
and is never reused or erased automatically.

An import can succeed before receipt persistence fails. Such an interval remains
marked imported, with receipt pending. A failed/timed-out import can be uncertain;
the runner records that and stops without retrying. Inspect the retained run ID
and Tracer measurement report before any retry. Earlier confirmed imports remain
reported if a later interval fails. Do not delete a lock or rewrite history.

## Boundaries and interpretation

The interval includes polling, transport, capture and background execution.
Snapshots are not globally atomic, command names omit arguments, and observed
line increases do not attribute execution to an individual command, certify an
assertion, establish branch coverage or authorize legacy-test retirement.
Expected command rejections can coexist with a passing scenario assertion.

Launch/handshake work before the first profile and termination after the second
are outside the interval. Crashes, timeouts, unsupported instrumentation,
unfinished commands, uncertain cleanup or missing/inconsistent profiles prevent
a completed measurement. Failed scenario assertions remain failed even when
their complete session intervals can be exported/imported; the interval records
the scenario's final status in its limitations.

Only instrumented app/Core inputs are represented. Helpers, runtime/browser code,
backend and other languages need their own compatible measurement adapters.
Keep manual links, native assertion outcomes and measured counters separate.
