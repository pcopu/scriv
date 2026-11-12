# Script line menu boundary coverage

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Run against the matching automation-enabled UIKit Mac Catalyst application:

```sh
SCRIV_E2E_APP=/path/to/Scriv.app node tests/e2e/script-menu-boundaries.mjs
```

This is **candidate coverage, native execution pending**. No original test is
retired here. The scenario observes the mounted row's installed context-menu
builder through an explicit adapter. It does not open a physical context menu
or execute any menu action. The E2E runner discovers the top-level scenario.

## Frozen baseline and assertion mapping

- Commit: `4d14b29f4fb49891e850fa9a8e5742dc878603c8`.
- Source: `apps/catalyst/Tests/ScrivUIKitTests/WorkspaceEndToEndTests.swift`.
- Source SHA-256:
  `8bf3334e3ef7dfcfadb8118ab33a6d79756914ea1956ee5311fbf656db7aaae5`.
- Inventory ID:
  `apps/catalyst/Tests/ScrivUIKitTests/WorkspaceEndToEndTests.swift::0010`.
- Test: `testLineMenuDisablesMovesPastTheSceneEnds`, frozen line 564.

The original creates a `WorkspaceStore` in isolated screenshot storage and
calls `ScriptScreenController.entryMenu` for the first and last scene entries.
It recursively finds actions by their exact titles and checks four attributes.
The scenario checks each corresponding Boolean from the mounted row's real
`UIAction`:

1. First entry: `Move up` has `disabled === true`.
2. First entry: `Move down` has `disabled === false`.
3. Last entry: `Move up` has `disabled === false`.
4. Last entry: `Move down` has `disabled === true`.

All four behavioral assertions have explicit candidate replacements. The
baseline uses the startup sample's scene ends; this scenario deliberately
uses the actual blank template's two-entry, one-scene project to make ordering
and membership independently observable. It does not reproduce the entire
startup sample fixture. Neither test executes a move or proves physical menu
presentation. The frozen source hash and declaration were checked against
the baseline commit and inventory, not moving working-tree line numbers.

## Actual application path

The scenario launches the real application with fresh synthetic storage and
waits for its enabled, hittable `workspace-tabs` control. It verifies that the
installed workspace Save and New key commands are enabled and dispatches
those UIKit responder actions. These are registered-action invocations, not
physical keyboard events.

It saves the initial project and records every persisted project identity
before New, preventing a delayed initial save from being mistaken for the new
project. The app-owned `persisted-projects` export identifies the newly created
project. No fixture package is written and no store/model method is called
from the scenario.

The new project must contain exactly one scene and two distinct entries, both
in that scene. Their saved numeric `order` values must differ. Those values,
not view-tree position, identify the first and last entries. Exact saved text
must match the real blank template: `Describe the opening moment.` and
`Your first line.`.

After selecting the actual Script segment, the scenario finds both displayed
`script-line-<saved ID>` identifiers with their exact saved text. It walks
their observed snapshot paths to their actual `ScriptEntryRow` ancestors.
There is no invented row identifier or cached path assumption.

For each row, `menu` must return a `context` array containing one actual menu.
The scenario recursively checks native menu/action records and requires
exactly one `Move up` and one `Move down` action. Both must be offered rather
than hidden. Their `disabled` values must be actual Booleans; missing, empty
or unresolved observations cannot pass as disabled actions.

The four assertions run once initially and again after each of two real
Storyboard-to-Script round trips. Every observation resolves the current row
path from a fresh snapshot. After each pass, the scenario invokes the real
Save action and compares persisted entries, scenes, cues and characters with
the new project's pre-observation values. It also checks that exactly one
new project exists and every original saved project remains unchanged. Every
wait is bounded, and failure still closes the owned session.

## Explicit context-menu observation contract

`ScriptEntryRow` is a `UIView`, not a menu button. It installs its own
`UIContextMenuInteraction(delegate: self)`. Its configuration returns a lazy
action provider that calls the row's `menuProvider`. `makeRow` installs that
closure to call the controller's production `entryMenu(id)`.

This line menu is **not** stored in `UIButton.menu` or
`ScrivSecondaryMenu.menu(of:)`. The initial storage-only `menu` adapter could
not observe it; the unrelated speaker button's menu is not a replacement.
That source-level mismatch was identified before creating the scenario.

The revised adapter intentionally supports one known app-owned builder:
when the target is an actual mounted `ScriptEntryRow`, it invokes that row's
currently installed `menuProvider` and serializes its result into `context`.
The production builder reads entry, scene order, navigation and lock state
and constructs `UIAction` objects. Their handlers are not executed. The
adapter does not reconstruct disabled rules in a test model, select an entry,
call `moveEntry`, or open a menu.

The driver's separate `primary` and `secondary` arrays still observe stored
button and `ScrivSecondaryMenu` menus. This scenario uses only `context` and
fails if the matching contract is missing. It never falls back to a controller
method, a fake menu, another menu type or direct model state.

Invoking this known menu builder is an explicit observation boundary; it is
not a claim that all menu inspection is callback-free. Generic deferred menu
providers remain unresolved. No arbitrary provider/action execution is added
by this scenario. The actual UIKit delegate configuration/action-provider
dispatch and physical secondary-click presentation remain untested.
