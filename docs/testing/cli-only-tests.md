# CLI-only testing after legacy suite removal

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

On 2026-11-09, the user explicitly requested removal of the old tests from the
active repository, keeping only Tracer-driven CLI scenarios. This supersedes the
older instruction to keep legacy suites until all replacement behavior passed.
It does **not** establish replacement parity or 100% coverage.

## Known blocked scenario

`character-aliases` is explicitly blocked by the unresolved native alert route
and the recorded AppKit Library Validation denial. `test --list` exposes the
restriction. Alias-only runs record not-run before app inspection/launch; mixed
runs never spawn it, preserve its reason, and cannot claim a full-suite pass.
Its direct entrypoint is guarded and its native-helper fallback removed. Mixed
coverage selections containing it are marked not-exported; use an eligible-only
selection to collect measurements. No security bypass or native acceptance is
implied. See [alias gates](character-aliases.md).

## Current commands

Use a trusted installed Tracer 0.3.0 or newer. Tracer is distributed from the
[official repository](https://github.com/pcopu/tracerCLI), not an npm release.
`SCRIV_TRACER_CLI` may select its absolute executable or `bin/tracer.mjs` path.
The npm wrapper uses the same Tracer commands without downloading tools or
installing agents; it disables optional update checks.

```sh
tracer actions
tracer app -- test tooling
tracer app -- test services --list
tracer app -- test services
tracer app -- test --list
tracer app -- test --scenario journeys/project-roundtrip --app /path/ScrivAutomation.app
# Equivalent local convenience commands:
npm test
npm run test:services
npm run test:e2e -- --list
npm run check
```

- `test tooling` runs 17 public CLI journeys through actual Tracer subprocesses.
  It checks discovery, arguments, catalogs, selection, failure propagation,
  provenance gates, and honest native-not-run results. The suite cannot invoke
  itself successfully: nested tooling execution is explicitly refused.
- `test services` invokes 13 black-box HTTP journeys against real local Worker
  processes, synthetic D1/R2 state and denied unexpected outbound access. The
  supported IDs and stable order are defined in [the service catalog](../../scripts/service-catalog.mjs);
  use `tracer app -- test services --list` for the current selections. Instrumented
  journeys require the reviewed local Tracer runtime specified by
  `SCRIV_TRACER_RUNTIME`; see `atomic-batch-journey.md`. These are local service
  integration results, not native acceptance or live provider/account actions.
  Provider-dependent scenarios use controlled synthetic fixtures.
- `test` lists 40 retained native candidates: 39 eligible and one explicitly
  blocked. Eligible candidates use the actual Catalyst CLI session. A matching automation-enabled app and macOS are required.
  Linux reports `not-run`, never a fake pass. Opt-in live CLI scenarios remain
  separately gated in `tests/live-e2e`; they are not launched by default.
- `check`, `verify-native.sh`, and `verify-catalyst.sh` are source/build integrity
  checks, not replacement behavioral suites. The latter wrappers no longer run
  Swift/XCTest or source-shape assertions.

## Removed and retained

`legacy-test-removal.json` lists all 169 removed files with their original hashes:
Swift/XCTest suites, Node implementation suites, cloud Vitest tests/config,
update Python/unit suites, fake Codex/selfcheck fixtures, obsolete test runners,
the obsolete local mapping implementation, and two legacy in-app test harnesses.
Old SwiftPM/Xcode test targets, Vitest/Playwright dependencies and test hooks were
removed. Application code, CLI fixtures/scenarios, release safety checks and
production resources are retained. Historical test bytecode is outside source.

Deleted source remains recoverable from Git history. Old baseline/oracle documents remain as historical
evidence and a list of gaps; they are not instructions to run deleted suites.

The frozen baseline has 1,129 entries. The public mapping ledger includes no
execution attestation and grants no retirement authorization. Some retained build/release integrity
commands appear in that historical inventory and remain necessary safety gates.

## CI and coverage boundaries

The isolated migration checkpoint included a proposed GitHub workflow update,
but that edit is excluded from publication. The existing remote workflow is
preserved unchanged and still references removed suites and the retired AppKit
build path. Publication uses an explicit [skip ci] marker and does not dispatch
Actions. CI modernization requires separate authorization; no remote CI pass
is claimed.

Instrumented service journeys require the reviewed runtime not supplied by a fresh Scriv checkout alone. Native acceptance, input-route parity, live-account paths and measured coverage require separate checks. Manual links describe source associations, not executed lines. Neither a green tooling run nor deletion of untested code proves 100% coverage.

## Application mapping scope

Tracer 0.3.0 now explicitly excludes these scenario/test-only directories from
Scriv's manual mapping denominator:

- `tests/`: native and opt-in live scenarios, tooling journeys, assertions and
  synthetic fixture/support helpers.
- `cloud/tests-e2e/`: isolated local cloud-service HTTP scenarios and fixtures.
- `updates/tests-e2e/`: isolated local update-service HTTP scenarios and fixtures.

Rules and reasons are saved as `ignoredSources` in `code-e2e-links.json`. They
change only manual mapping totals/minimums. They do not skip execution, delete
links or bypass source/witness integrity. Ignored sources remain navigable in
`tracer report --json` under `ignoredFiles`, with separate `ignoredTotals`.

Application source, `cli/`, native automation/fixtures, coverage collectors,
CLI dispatchers/runners, build tools and release-safety code stay included.
Do not ignore an application route simply because it is hard to test. The
isolated proposed workflow pins Tracer 0.3.0 to read this scope, but that workflow
change is excluded from publication. The preserved remote workflow does not
provide this gate.
Older clients do not honor ignores; use 0.3.0 or newer for these reports.

```sh
tracer report --json
tracer report --source tests/tracer/cli-front-door.mjs
tracer check
tracer check --require-minimum
# Restore a directory only by removing the exact saved trailing-slash path:
# tracer unignore tests/
```

Scope exclusion does not establish 100% mapping, measured coverage or CLI feature
parity. Native acceptance and existing observed-coverage gaps remain unchanged.

Billing is simulated-provider service integration: 57 expected provider calls across entitlement and checkout checks are answered by strict in-process fixtures, and every unexpected request is denied. It performs no live provider login, payment or subscription change. Generation coordinates local jobs without invoking a provider. Instrumented service selectors require the explicitly selected reviewed local runtime; no package is vendored here.
