# Interaction-first scenario suite

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

> Testing update, 2026-11-09: legacy test suites and runners referenced below were removed. Prior results remain historical, not current commands or proof of replacement coverage. See [current CLI-only testing](cli-only-tests.md).

## Goal and counting units

The target is a small set of complete application journeys, not one replacement
scenario per old test method. Audit the whole codebase and connect authored source ranges to the exact E2E
steps that address their user-visible behavior. Keep meaningful regression
oracles, without making one new scenario per old method or implementation branch.
The user’s current working range is roughly 20–100 comprehensive journeys, not a
hard cap or a required count. Choose the smallest sensible set after the audit.

- **Interaction:** one supported action with preconditions and an observable
  outcome, such as add dialogue, connect Codex, or restore a project revision.
- **Route:** button, menu, keyboard, drag, touch, accessibility or semantic CLI
  entry point for that action. Route-specific behavior needs its own evidence.
- **Journey:** a coherent sequence of interactions, such as create a project,
  author text, undo/redo, save, close and reopen.
- **Case:** a data/state variant of a journey, such as Unicode, an empty input,
  a rejected range, reconnect, offline recovery or an interrupted operation.
- **Assertion:** an observable invariant from the old suite, mapped to a journey
  step and a case. Many old methods may map to one journey, and one method may
  require several journeys.

## Code-to-step links first

The primary artifact is a simple source-line → CLI action (or ordered action
sequence) → E2E-step map, independent of language or CLI. Each link identifies
a source range, named actions and the precise test range addressing it. Unmapped
lines remain visible. Source and test snippet hashes flag stale links after edits.
A manually reviewed link is an association, not proof that those lines executed.
Native run evidence and any future instrumented execution evidence stay distinct.
See code-e2e-map.md for the minimal link/report commands and code-scope-audit.json
for the captured whole-source subsystem audit. Optional language-specific runtime
adapters may report lines observed during an action sequence, with background
execution ambiguity; they are not a prerequisite for the generic map.

Account for authored production code, platform adapters, test infrastructure and
configuration separately. Generated, dependency, non-executable and unreachable
paths need explicit scope or classification, never an invented passing test.
Historical test mappings remain regression-risk references; they are not a
requirement to reproduce every implementation-specific assertion as a separate
E2E case. Do not remove still-needed behavioral coverage on the strength of a
static link alone.

## Historical inventory and backward mapping

Three inventories cover authored UI, project/integration UI, and service/failure
boundaries. Stable interaction IDs must include source evidence, preconditions,
result, routes, current CLI capability, uncertainty and any required permission.
Cross-surface actions are referenced rather than counted repeatedly.

Use the frozen entries and assertions as supporting regression evidence, mapping
relevant behavior backward to:

1. A supported interaction or explicit non-UI system boundary.
2. A journey step, state/data case and required input route.
3. The actual-app observation proving it, including persistence after reopening
   where relevant, rejection without mutation, and ordinary undo/recovery.
4. Native evidence identifying the source, app, scenario, case and cleanup.

Unmapped assertions remain visible. A mapped action is not automatically a
verified action, and a semantic app command does not certify physical menu,
keyboard, gesture, picker or accessibility behavior.

## Consolidation approach

- Build the complete supported-action catalog before adding more isolated files.
- Group related operations into journeys, separating case data from step helpers.
- Fold existing slices into those journeys, retaining exact regression oracles.
- Keep import/export format and validation variants in tables, not per-method
  files. Combine positive setup and rejected changes with unchanged-state checks.
- Share app launch, UI targeting and saved-state observation helpers, never copied
  model algorithms or alternate validators.
- Run native proof before removing any remaining old assertion coverage.
- The final state is scenario-based coverage, not a permanently retained old suite.

## Constraints that cannot be hidden by counting

Real account/provider flows need isolated authorization and any required usage
approval. Menus, alerts, drag/drop, clipboard and document pickers require their
actual supported routes; the blocked native adapter cannot be bypassed. Some
security, protocol-abuse, signing, crash, storage-fault and performance invariants
have no honest UI-only equivalent. They need controlled end-to-end system cases
with real boundaries and explicit failure setup, not a falsely passing UI step.

Input/state combinations are unbounded. “Every interaction” means every supported
action and route, with systematic equivalence classes and boundary cases for its
inputs and states, rather than every possible string or event ordering.

## Progress measures

Report cataloged interactions and verified routes, implemented/passing base
journeys, mapped legacy assertions and unresolved gaps separately. File count is
an organizational choice, not coverage. The number of retired legacy methods is
an audit trail, not a proposed number of replacement journeys. A single native
journey may prove many old methods while some implementation-shape assertions
need a separate observable contract or an explicit disposition rather than a
literal source-string replacement.

## Backward mapping implementation

The per-entry ledgers are `assertion-journey-map-native.json` and
`assertion-journey-map-services.json`. They preserve exact frozen test IDs and
assertion source-line keys, including assertions in helper scopes. Run
`node scripts/check-assertion-journey-map.mjs` for combined key integrity.

There are three distinct gates:

1. **Key accounting:** every baseline entry/assertion has one ledger row. A
   provisional journey family is a routing hypothesis, not mapped behavior.
2. **Semantic mapping:** source setup, each branch/parameter and its exact
   expected result have a concrete journey step, app oracle and route. Unreachable
   or non-equivalent UI contexts remain gaps even when their source was read.
3. **Replacement acceptance:** the authored journey/case passes against the real
   app with source/build evidence and every original assertion reconciled. Only
   this gate permits the corresponding old implementation to be retired.

Source-body review alone does not satisfy the second or third gate. The mapping
files cannot grant retirement and do not duplicate or override native evidence.

## Complete entry disposition pass

Every frozen test entry now has a concrete disposition: 1,077 proposed behavioral
contracts and 52 separate implementation/model/fixture/harness/system
requirements. No test remains only in a generic family bucket. All 5,422 source
assertion keys are retained. Native helper lines include setup prerequisites and
regex-matched declarations, not only runtime assertions. Service ownership is
unique for 1,877 lines; 68 shared/parameterized/helper lines retain explicit
relationships rather than invented unique owners. Native helper caller and
argument expansion also remains incomplete.

This completes entry classification, not full assertion-to-observable-oracle
acceptance. Every proposed route and case still needs independent evidence. The v23 source
checkpoint adds five candidate entrypoints (31 total), including pending character
consolidation, Layers, generation review, picture coverage and loaded-model
roundtrips. They are not five newly completed families; native acceptance remains
separate from source availability.
Implementation-only requirements need an explicit system witness or documented
supersession decision; source naming/style cannot be silently counted as an
application interaction. The remaining old suite is transitional, never the
intended scenario-only final state.
