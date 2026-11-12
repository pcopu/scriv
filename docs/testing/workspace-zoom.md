# Shared script zoom through the actual app

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Run against a newly built automation-enabled Catalyst application:

```sh
SCRIV_E2E_APP=/path/to/Scriv.app node tests/e2e/workspace-zoom.mjs
```

This candidate uses the real Script/Characters tabs, enabled native key commands,
native selection, and app-owned saved-package observations. It does not construct
a store, import fixture state, write preferences, call the zoom setter directly,
or use a fallback driver. It requires the new read-only snapshot
`font: {pointSize, name}` observation on native text views. An older bundle without
that observation fails explicitly.

## Implemented actual-app checks

- The shared zoom control reports a value between 70% and 200%. Actual mounted
  script text views expose finite font sizes; the scenario verifies their font
  sizes scale with every observed zoom change, rather than trusting the control
  title alone. The baseline font is measured from the app, not fixed at 22 points:
  the production pane-width optical scale can change the initial font size.
- Command-equals, Command-plus, both Command-Shift variants, and Command-minus
  are exposed by `ScrivUIKitApplication` as priority commands. Each synthetic
  stroke changes the visible percentage by exactly ten percentage points, except
  at a bound. All five work outside editing and while a script editor is focused.
- While editing, exact text, editor accessibility ID, first-responder status and
  a noncollapsed UTF-16 selection remain unchanged through all five shortcuts.
  The selection boundaries respect Unicode code points in the existing sample.
  Escape finishes editing without changing script text.
- Unsupported plain, Shift, Option, Control, Command-Option and Command-Control
  plus/equal/minus requests, and Command-Shift-minus, have no enabled command and
  are rejected without changing zoom. This checks adapter/responder rejection,
  not a delivery of those characters to normal typing.
- Two Characters-to-Script round trips retain the shared zoom; a size change
  made in Characters remains visible in Script. Mounted entry IDs/text and
  native font sizes are checked after each switch.
- Two upper/lower-bound cycles verify 200%/70% clamps, three additional attempts
  beyond each bound, and a return to 100%. At 200% at least one actual laid-out
  text-view frame must be taller than its 100% frame. Returning to 100% uses real
  minus strokes to reach 70% followed by three real increase strokes; this is
  **not** a menu reset command.
- The full exported saved project, including its revision, IDs, entries and
  timing, equals the baseline at checkpoints. At the end, the real Save command
  is sent and four successive observations, each at least 100 ms apart and after
  a native `Saved on this Mac` status, still equal the baseline. No authored text
  or other project content is intentionally edited by this scenario.

Each `key` is a synthetic single stroke through the enabled responder action and
the application's production policy/press gate. It is not a physical HID event.
The scenario keeps every legacy test and makes no migration or retirement claim.

## Exact frozen-baseline mapping

Inventory: `docs/testing/cli-migration-inventory.json`, baseline commit
`4d14b29f4fb49891e850fa9a8e5742dc878603c8`. Every mapping below is **partial,
pending native execution**. IDs refer to the frozen inventory, not current line
numbers.

### Workspace preference and content

`apps/catalyst/Tests/WorkspaceDurabilityTests.swift::0005`
(`testZoomIsAUserPreferenceNotProjectContent`, frozen line 69).

Source SHA-256:
`7a0c28c7101670500ce0be739a98bfbcbe87a868072e23c6489afb9e091b9232`.

The scenario reaches 130%, observes proportional actual UI font size, checks
unchanged saved project content and exercises both bounds through supported
keyboard actions. The original's `scriptFontSize == 18.2` is a store-derived
14-point metric, not the UIKit script presentation's actual font size; this
scenario deliberately does not equate them. It does not submit infinity, 100 or
0 directly to the setter, inspect the in-memory `store.project`, or prove that
preferences survive process relaunch. Repeated saved observations do not expose
a causal save-generation acknowledgement, the journal, or an awaited save task.
They are not exact parity for the original in-memory equality assertion.

### Keyboard acceptance and rejection

`apps/catalyst/Tests/ScrivUIKitTests/ScrivPlaybackKeyboardPolicyTests.swift::0003`
(`testZoomAcceptsPlusEqualsAndShiftedKeyboardVariantsWhileEditing`, frozen line
22) and `::0004` (`testZoomRejectsPlainKeysAndOtherModifierCombinations`, line 38).

Source SHA-256:
`4ba13698b9d594c43add88a5d2351da5cd64ccf42bc1b5e68f62dcc30ed56731`.

For `::0003`, all five exposed command variants run in focused and unfocused
contexts and must change actual UI size. The adapter requires an exact enabled
command match, so it cannot independently vary `characters` versus
`charactersIgnoringModifiers`, Caps Lock, or numeric-pad state. Those original
policy cases remain uncovered. For `::0004`, the listed supported modifier names
are checked for responder rejection; arbitrary `.other` bits and the original
pure policy decision itself are not tested.

IME composition, held-key reclassification, duplicate down events, simultaneous
physical keys, cancellation/deactivation, and action-without-down remain gaps.
In particular this scenario does not replace `::0010`
(`testCompositionStartCannotBeReclassifiedDuringHeldZoomPress`) or any press-gate
test by repeating independent complete synthetic strokes.

### Shared presentation and live editing

`apps/catalyst/Tests/ScrivUIKitTests/ScriptCharacterParityTests.swift::0002`
(`testOnePresentationWithOneSharedZoomFactor`, frozen line 43) and `::0003`
(`testChangingDensityPreservesLiveEditorAndExactCaret`, line 54).

Source SHA-256:
`6e96b2d3966d2af804062c82aeee1a7711d15f72eccae8b64369b42d11d978d6`.

For `::0002`, the scenario measures actual proportional font changes and shared
Script/Characters presentation at the current native window geometry. It does
not verify the exact 222/136-point inset/rail constants, the 930-point pane
calculation, or optical-scale behavior at 480/2,000-point widths.

For `::0003`, the scenario preserves the active editor's text, first responder
and exact native selection while changing zoom. It does not resize the pane,
observe `ObjectIdentifier`, measure a hidden display/editor pair together, or
replace the original density-change exercise with an equivalent geometry test.
An unchanged accessibility ID is not proof of native object identity.

Related source-structure test:
`tests/uikit-script-character-parity.test.mjs::0002`
(`Script and Characters tabs share one script presentation and the stored zoom`,
frozen line 18), SHA-256
`1fd5b3e6f4294639e9b9e24a9258d5a787679098b7b3ae65c9f7023900a6e63d`.
The scenario observes a subset of its intended shared-zoom behavior; it does not
replace its source-structure constraints or certify full parity.

## Explicit remaining UI gaps

- The native footer menu contains 70%, 85%, 100% · Default, 115%, 130%, 150% and
  200% actions. `ScrivCLI` does not currently observe/invoke `UIMenu` actions;
  sending `activate` to a menu-owning button does not establish a selected
  preset. No menu opening, checked-state, fractional preset, dismissal, or
  repeated Default action is claimed by this scenario.
- No window resize or long-text fixture is used. The taller text-view assertion
  does not replace `ScriptCharacterParityTests.swift::0005`
  (`testLongScriptStillWrapsAtNarrowWidthsAndLargeZoom`).
- Timeline zoom, detached tile/observer lifetime, and Storyboard word-chip fit
  are separate behaviors. This does not cover `TimelineTileMountTests.swift::0005`
  or `WorkspaceEndToEndTests.swift::0020` merely because their names include zoom.
- Native screenshots/pixel rendering, IME, physical keyboard layouts, process
  relaunch, preference storage and byte-level package comparison remain pending
  separate observation paths. Saved JSON equality is not package-byte equality.

## Semantic preset-menu route

The Script zoom scope of `menu-action` accepts only the original zoom UIButton,
its exact flat seven-action stored menu, matching Script controller/store and a
verified synthetic saved project. It uses public `UIControl.sendAction(UIAction)`
on that same owning button exactly once, after normal visibility, interactivity,
enabled and hittability guards. Menu options/action attributes must be empty;
unknown fields, wrong controls and unknown titles fail before dispatch. It never
resolves deferred menus, rebuilds context menus, touches UIAlertAction, uses a
relay, adds registrations, extracts private handlers or invokes the denied native
adapter. This is semantic menu-action dispatch, not native menu opening, pointer
selection, accessibility or menu lifecycle proof.

They run after editing is closed; they do not add active-selection menu coverage. The public SDK API and exact source ownership were independently audited. A separate directions-only duration menu scope is being developed; this zoom evidence does not verify that route.
