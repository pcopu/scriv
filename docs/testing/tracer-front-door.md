# Scriv's Tracer front door

Tracer remains the common discovery, execution and mapping entrypoint. The
reviewed `tracer.json` still forwards exact arguments to `node cli/scriv.mjs`.
Scriv dispatches `test` to `scripts/run-cli-e2e.mjs`, which launches the existing
real Catalyst scenarios through `ScrivSession`. There is no simulated app or
alternate implementation. The native scenarios still share the real session
driver; this wiring does not change semantic actions into physical input.

## Native journeys

From the repository root with Tracer installed:

```sh
tracer actions
tracer app -- test --help
tracer app -- test --list
tracer app -- test --app /path/to/ScrivAutomation.app
tracer app -- test --scenario journeys/project-roundtrip \
  --scenario journeys/script-merge --app /path/to/ScrivAutomation.app
```

The JSON catalog currently contains 34 native entrypoints, not 34 complete UI
journey families. IDs omit `.mjs` and retain `journeys/` when applicable. Selection
is exact and runs in catalog order. No paths, globs, arbitrary scripts or shell
commands can be supplied as scenario IDs. A subset is labeled both in the
summary and evidence; it never receives `fullSuitePassed: true`.

The runner preserves isolated real-app launch, per-scenario time limits,
stop-after-failure, bounded owned-process-group cleanup, source/bundle identity
checks and separate exported-manifest support. See the
[full evidence contract](cli-run-evidence.md). Neither a source digest nor the
front door attests that source produced a particular app binary. No current
native build or scenario pass is claimed by this integration.

Existing direct controls remain available:

```sh
tracer app -- /path/to/ScrivAutomation.app
# Send JSON lines on stdin, for example: {"command":"snapshot"}
node cli/scriv.mjs /path/to/ScrivAutomation.app
node scripts/run-cli-e2e.mjs --app /path/to/ScrivAutomation.app
```

## Public CLI tooling journeys

```sh
tracer app -- test tooling
```

This separately labeled route exercises actual Tracer subprocesses against the
current Scriv checkout. It does not import production implementation APIs or
use a mock app. Tracer must be on PATH. For a trusted unpacked Tracer package,
set `SCRIV_TRACER_CLI` to its absolute executable or `bin/tracer.mjs` path;
this is a local executable selection, not a download or installation.

The thirteen journeys check discovery/help, exact native catalog, stable subset
selection, rejection of unsafe/ambiguous arguments, honest all-scenario and
subset not-run evidence, compatibility of legacy help/failed-launch behavior,
explicit refusal of recursive tooling execution, coverage argument gates,
coverage-builder CLI requirements, pinned-source no-native preflight the fixed service scenario catalog and wrapper failure propagation.
They deliberately remove `SCRIV_E2E_APP` from child environments and disable
Tracer auto-update for those subprocesses. They launch **zero native scenarios**.
The legacy stdin protocol's successful app round trip still requires native
verification; help and failed-launch parity cannot prove it.

Tooling output and no-app evidence remain in fresh OS-temporary directories
outside the source checkout. Every no-app evidence record stays `not-run`, with
`fullSuitePassed: false`, no app identity and no build attestation. A tooling
pass is not a native app pass, a complete migration or measured code coverage.

## Migration and mapping

The opt-in [scenario coverage collector](cli-scenario-coverage.md) extends the
same real native runner with separate per-session profile pairs and actual LLVM
and Tracer import. It requires a pre-build pinned source manifest and matching
coverage-build record. Linux tooling does not validate the successful native
capture/export/import path.

Maintain reviewed source/action/assertion links with changes. Run `tracer check`
and `tracer report --json` separately from the behavioral journeys. Preserve
historical measurements with their original hashes; stale source receives no
current measured credit.

The active repository now contains only Tracer-driven CLI scenarios. The user
explicitly requested removal of all legacy implementation suites. The
[removal record](cli-only-tests.md) preserves recovery and unverified gaps;
removal grants no additional accepted baseline entries or coverage.

Local service journeys share this front door:

```sh
tracer app -- test services --list
tracer app -- test services
tracer app -- test services cloud
tracer app -- test services updates
```

The tooling suite exercises public commands, not its own assertions recursively.
A nested `test tooling` request is refused before any child suite can start.
Native builds, fresh actual-app execution, input-route parity, live-account
journeys and measured coverage remain separate gates.

## Mapping scope is separate from execution

Use Tracer 0.3.0 or newer. Scriv explicitly ignores `tests/`,
`cloud/tests-e2e/` and `updates/tests-e2e/` only in manual mapping totals.
Their scenarios still run and all stored source/witness hashes remain checked.
The application CLI, native automation runtime, collectors and runners stay
included. See [current scope and limitations](cli-only-tests.md#application-mapping-scope).
