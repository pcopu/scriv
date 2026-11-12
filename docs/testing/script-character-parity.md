# Script and Characters presentation parity

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Run against the actual automation-enabled Catalyst application:

```sh
SCRIV_E2E_APP=/path/to/Scriv.app node tests/e2e/script-character-parity.mjs
```

## Full frozen baseline mapping

- Frozen ID: `apps/catalyst/Tests/ScrivUIKitTests/WorkspaceEndToEndTests.swift::0011`
- Method: `testScriptLooksTheSameInScriptAndCharactersTabs`
- Scenario: `tests/e2e/script-character-parity.mjs`

The original method selects Script, sets its native scroll offset to 300,
records the script controller view width, first display font size and scroll
offset, then selects Characters and asserts:

1. The script controller view width is unchanged, with 1-point tolerance.
2. The native display font size is unchanged, with 0.01-point tolerance.
3. The script scroll offset is unchanged, with 1-point tolerance.

All three assertions are implemented. The scenario also checks every mounted
script display's font, stable entry identifiers and exact text. It performs two
Script → Characters → Script cycles, observing settled layout twice after each
switch. The Characters search field must be mounted on Characters, preventing a
no-op tab transition from passing.

## Real UI and unambiguous observation

The scenario uses existing `select`, `scroll`, and `snapshot` commands only.
It selects the unique `workspace-tabs` control and identifies script displays by
their existing `script-line-` identifiers. It requires exactly one UIScrollView
ancestor containing every script display. This excludes unrelated Characters
profile/ribbon scroll views. The scroll view's direct root stack and parent
controller view establish the script pane. Runtime checks require that stack
and scroll to span the pane width and that the pane contain its actual shared
script zoom control. Width comparisons use the controller view, not a text row.

No source assertion, model mutation, arbitrary selector, mock backend or unit
fixture substitutes for app behavior. No driver additions are required.

## Fixture differences and scope

The original test creates a new 1280 × 800 UIWindow and directly changes the
store tab and UIScrollView offset. The scenario runs the production workspace
window at the automation bundle's native launch size in its fresh UUID-isolated
synthetic project. It uses the tab's real control action and the existing native
scroll command. It does not force a test-only window size or resize a private
controller. It requires enough real scroll extent to reach 300 points and fails
rather than silently accepting a zero/clamped scroll offset.

Thus the same three behavioral assertions are covered at the app's real launch
size, with repeated round trips. Exact 1280 × 800 fixture geometry and behavior
at other widths are not claimed. This is not coverage for the separate ribbon
resize or optical-density metric tests. No project data is edited.
