# Actual-app CLI run evidence

> Testing update, 2026-11-09: legacy test suites and runners referenced below were removed. Prior results remain historical, not current commands or proof of replacement coverage. See [current CLI-only testing](cli-only-tests.md).

Run through Tracer on macOS with a separately built automation-enabled Catalyst app:

```sh
tracer actions
tracer app -- test --list
tracer app -- test --app /path/to/ScrivAutomation.app
```

The optional `--app /path/to/ScrivAutomation.app` overrides `SCRIV_E2E_APP`.
Optional `--output-dir /existing/synthetic-artifacts` selects a parent directory
outside the source checkout. Each invocation creates its own private temporary
subdirectory and `evidence.json`. `--timeout-ms 120000` sets the per-scenario
limit (100 through 3600000 milliseconds). Exit codes: 0 passed, 1 failed,
2 not-run or runner/preflight error. Missing macOS or app never becomes a pass.

The runner discovers regular entrypoint files in `tests/e2e/*.mjs` and
`tests/e2e/journeys/*.mjs` whose names contain letters, digits, underscores and
hyphens, sorts them, and runs them sequentially. Support modules and opt-in
live-account scenarios are not discovered. It stops on
failure; later scenarios remain explicitly not-run. Each scenario uses the
actual application through `SCRIV_E2E_APP`, with no smoke/mock fallback.

`--list` prints the native catalog as JSON without launching an app, producing
evidence or checking the build. `--scenario ID` accepts only an exact listed ID
without `.mjs`; repeat it to select multiple scenarios. Selected scenarios keep
catalog order. Unknown IDs, traversal, duplicate IDs, duplicate scalar options,
missing values and unsupported flags fail before any evidence directory is made.
`--list` may be combined only with `--scenario`. `--help` must be used alone.

Evidence includes `selection.mode` (`all` or `subset`), available and selected
counts, and `fullSuitePassed`. Exit 0 and `status: passed` refer only to the
selected scenarios. `fullSuitePassed` is true only when an unfiltered native run
passes every discovered entrypoint. An explicit selection stays a subset even
when it names every current ID. Neither result establishes complete UI coverage.

The existing `node scripts/run-cli-e2e.mjs [OPTIONS]`, `SCRIV_E2E_APP` variable
and JSON-line control `node cli/scriv.mjs /path/to/ScrivAutomation.app` remain
available. The Tracer entrypoint calls this same runner, not a parallel suite.
See [front-door usage](tracer-front-door.md) for the separate public-CLI tooling
journeys and their verification limits.

`--coverage` adds optional [per-session measured collection](cli-scenario-coverage.md)
for explicitly selected native scenarios. It requires the pinned source manifest
and a matching `--coverage-build-record`; it does not accept the whole suite by
default. Native scenario statuses, collection/export/import status and partial or
uncertain imports remain separate. Source and bundle checks happen again after
LLVM export and before the deliberate measurement-dataset writes. The source
identity scope is labeled accordingly in evidence. The optional build record is
producer-declared evidence, not cryptographic build attestation.

The bounded JSON contains scenario statuses, timestamps, exit codes/signals,
cleanup status, exact Git HEAD, Git index digest, and a digest of all tracked
and nonignored untracked source file contents, paths and permission modes.
Deleted tracked files and symlink targets participate in that digest. Nested
Git submodules are unsupported and fail preflight. Only digests and counts,
not source contents or local paths, enter the JSON. App identity includes both
the Scriv executable SHA-256 and the full bundle digest, including resources,
Info.plist, signatures and symlinks. Source/app identities are checked again
after execution; a change prevents an overall pass. The digest identifies
bytes, not proof that a particular source revision produced that app. Keep
independent build provenance. An in-progress evidence file is not a final pass.

Scenario stdout/stderr is discarded deliberately: assertion messages and native
logs can contain private local diagnostics. No screenshots, project contents,
environment dump, raw Git diff, credentials, or user data are copied to evidence.
The terminal prints only the summary and evidence file location.
The `coverage-session-limit` diagnostic means the run used all slots reserved
by `--coverage-max-sessions`. Count planned app launches, including relaunches.

Each scenario runs in a fresh POSIX process group. The current session launcher
directly spawns the app into that same group. On timeout, interruption, or a
remaining owned process, the runner sends SIGTERM and then bounded SIGKILL only
to that group. It never kills by application name or bundle ID. If termination
cannot be confirmed, evidence says cleanup is uncertain and no later scenario
starts. Process-group cleanup does not verify detached descendants. A future
launcher change to detached spawn or LaunchServices must update this ownership
contract before using this runner. SIGKILL of the runner itself or host failure
cannot guarantee cleanup or final evidence; do not treat partial output as a pass.

A scenario pass is not a migrated XCTest baseline, native keyboard-responder
proof beyond its assertions, release qualification, or proof that an installed
production app works. `baselineMigrated` always stays false. Retain old UI
coverage until the separately documented parity and actual-app gates pass.

## Git-free exported source

An isolated source archive can run the same full runner without inventing a Git
repository. On the producer's real checkout, after all source edits are complete:

```sh
node scripts/export-cli-source-manifest.mjs \
  --output /external/scriv-source-manifest.json \
  --include apps/catalyst/ScrivUIKit/Automation \
  --include cli --include docs/testing --include tests/e2e --include tests/live-e2e \
  --include tests/tracer --include tracer.json \
  --include scripts/run-cli-e2e.mjs \
  --include scripts/export-cli-source-manifest.mjs \
  --include scripts/inventory-cli-migration.py
```

The command prints the manifest SHA-256 and file count. It selects existing
tracked files plus nonignored untracked files explicitly selected by repeated
`--include` file/directory arguments. Review those selections before transfer.
Export **only the files named in the manifest**, preserving their relative paths,
and transfer the manifest separately outside the extracted source directory.
The manifest stores relative paths and SHA-256 hashes, never source contents.
It also records the producer's actual HEAD as `baseCommit`; working changes are
represented by the file hashes, not falsely attributed to that commit. Export
fails for missing tracked files, selected symlinks, unsafe paths and submodules.
Output is create-only, outside the source tree. Regenerate after any source edit.

Caches, node_modules, build outputs, app bundles, user projects, environment
files, common credential files and logs are excluded by path policy. Do not put
private diagnostics, receipts, GPS records, backups, credentials or user data in
source selections under other names. Path filtering is not a content-secret
scanner. Do not include these files in the source archive or publication either.
The excluded files do not participate in exported source identity. Dependencies,
build inputs and toolchain provenance remain separate responsibilities.

On the consumer, use the digest from the producer's confirmed export result:

```sh
tracer app -- test \
  --app /path/to/ScrivAutomation.app \
  --source-manifest /external/scriv-source-manifest.json \
  --source-manifest-sha256 PRODUCER_MANIFEST_SHA256
```

Both manifest options are required for exported mode. There is no implicit
fallback from Git to manifest mode. The verifier checks the pinned manifest
bytes, sorted unique safe paths, every file's contents, and the exact eligible
consumer file set before running any scenario and again afterward. Missing,
mutated or unexpected source files and symlinks (including parent-directory
symlinks) fail closed. Keep the manifest and evidence outside the source tree.
A failed check records a bounded `source-manifest-*` blocker, not a pass.

Evidence distinguishes `git-working-tree` from
`verified-exported-source-manifest`. Exported identity has no Git index digest
or claimed consumer HEAD: its base commit is explicitly producer-declared and
not verified through consumer Git. The separately supplied digest pins the
manifest but does not authenticate a producer by itself. Neither mode proves
that source produced the application. `buildAttestation` remains null,
`sourceToAppMatch` remains `not-established`, and executable/bundle hashes and
runner-owned process-group cleanup are unchanged.

Synthetic generator/verifier checks can test Git-free transfer and rejection of
missing/mutated/extra files, symlinks, unsafe paths, and missing/wrong manifest
digests without launching an app. These checks are tooling tests, not actual-app
scenario evidence or source-to-binary attestation.
