# Actual-app CLI test migration

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

> Testing update, 2026-11-09: legacy test suites and runners referenced below were removed. Prior results remain historical, not current commands or proof of replacement coverage. See [current CLI-only testing](cli-only-tests.md).

## Reproduce the baseline

```sh
npm run test:inventory
python3 scripts/inventory-cli-migration.py --check
# Only creates the file when missing; refuses to overwrite differences:
python3 scripts/inventory-cli-migration.py --write
```

The generator reads source directly from the frozen baseline commit, so later
commits, uncommitted modifications and new CLI tests cannot inflate the original
baseline. Default invocation and `--check` are read-only validation. `--write`
creates a missing inventory only and refuses to overwrite any differing existing
content, including edited migration statuses or evidence. It captures named Swift and Python tests,
JavaScript test registrations, each literal `it.each` row, standalone harness
entrypoints, assertion source lines, and shell verification source lines.
Registration conditions such as the opt-in cloud load test are retained.
Fixtures with no test declarations are explicitly marked entrypoints requiring
manual review; they are not represented as independently runnable tests.

Limitations are deliberate and explicit:

- Loops inside tests, Python `subTest` branches, template-generated registrations,
  mocks, and conditional platform code require manual expansion and comparison
  with each original runner's discovery output. The ledger retains source and
  assertion sites; it does not invent a runtime case count.
- Swift discovery is based on `func test…` declarations; adding other test
  frameworks or registration styles requires extending the generator.
- UIKit candidates include repeated selectors, helper definitions and
  accessibility metadata. They are a review checklist, not proof that every
  interface affordance has been discovered.
- The ledger is a frozen baseline, not an editable evidence database.
  Keep replacement scenario mappings and run evidence in separate files keyed
  by entry ID and source hash. The generator refuses to overwrite differences; keep verified evidence
  outside this file and retain the baseline hashes when recording mappings.
- Per-file numerical IDs are baseline-relative and stable because the baseline
  commit is frozen. Any future deliberate rebaseline requires explicit mapping
  reconciliation using source path, name, parameters and source hash.

## Architecture and what exists now

The initial `ScrivCLI.swift` implementation is an **opt-in test-build adapter**
compiled with `SCRIV_CLI_AUTOMATION`. It accepts JSON-line commands over the
launched app's stdin and emits prefixed JSON replies on stdout. It requires the
explicit launch switches and a verification root. It invokes real UIKit controls
on the main actor instead of calling a replacement model. Its capabilities
response explicitly reports that complete interface parity is false.

The matching launcher is `cli/scriv.mjs`; `scripts/rebuild-catalyst-cli.py
--automation` opts the build into the adapter. The first scenario is tab
navigation plus negative-target handling, and is **not** equivalent coverage
for any retired suite:

```sh
SCRIV_E2E_APP=/path/to/automation/Scriv.app node tests/e2e/workspace.mjs
```

A successful result requires launching the actual automation-enabled Catalyst
app. Portable protocol tests do not satisfy this gate. Menu selection, gestures,
OS panels, native helpers, network scenarios and multiple windows remain
explicit parity gaps in this first slice.

This is the beginning of a driver, not a complete migration. A snapshot, an
activation command, text insertion, segment selection and scrolling cannot
stand in for every interface action. In particular, `sendActions` exercises a
control's configured handler, but does not demonstrate pointer hit testing,
physical keyboard delivery, menu-bar routing or gesture recognition. Both the
semantic control path and physical input path need coverage where the original
regression depends on those differences.

A feasible completed architecture has four layers:

1. **Isolated actual-app session.** Launch the actual Catalyst executable with a
   fresh synthetic verification root. Validate the app bundle identity, build
   hash, protocol version and test-build capability before dispatch. Do not
   attach a regression runner to a user's ordinary workspace or accounts. Keep
   the automation transport disabled in release builds; do not add a public
   listener, persistent credential, broad filesystem entitlement or signing
   exception to make tests easier.
2. **UI command adapter plus native input driver.** Give every relevant control
   a stable identifier; route semantic commands through existing UI actions and
   responder paths. For physical Escape, command shortcuts, context menus,
   drags, precision scrubbing, focus, resizing and native dialogs, exercise
   actual native events. Accessibility or event-injection permissions, if
   needed, are a separate explicit setup gate, never bypassed. Enumerate all
   scenes/windows, sheets, popovers and native plugin windows, not only the
   first workspace view tree. Reject ambiguous, stale, disabled, occluded or
   unsupported targets rather than substituting a direct store mutation.
3. **CLI scenarios and observability.** Use request IDs, bounded waits and clear
   unsupported-action failures. Await observable conditions rather than fixed
   sleeps. Assert rendered state, focus, ordering, layout bounds, captured
   screenshots and synthetic package persistence after close/reopen. Include
   interrupted and repeated flows. Record transport failure, timeout, skipped
   and not-run as distinct from pass. Pair logical snapshots with screenshots
   and physical-input evidence where layout or input behavior is the invariant.
4. **Controlled external fixtures.** Use synthetic accounts, isolated local
   cloud state and deterministic provider/failure fixtures through the actual
   app's existing boundaries. Exercise real client/service behavior. A fake
   successful server or a mocked model alone cannot replace authorization,
   durability, concurrency, signed-update or helper identity tests. Fault
   injection belongs only in narrowly gated test code, not normal operation.

## Interface parity review checklist

Review every `ui_candidates` entry and every UIKit screen, including generated
menus and delegate-driven behavior. Associate each unique user action with a
command, supported input modes and enabled/disabled/locked/loading states.
The following groups organize the review; none is certified complete yet:

- Workspace navigation, window creation/closing/resizing, panels, preferences,
  command menus, first-responder focus and keyboard shortcuts.
- Projects: create, select, search, refresh, open local/external packages,
  import script, bookmarks, reopen and startup/recovery failures.
- Script: caret/range editing, copy/paste/undo/redo, Fountain paragraph identity,
  character mentions, direction rails, timing holds and duration scrubbing,
  draft recovery, lock conflicts and asynchronous saves.
- Storyboard, images and layers: tile selection, context menus, drag/drop,
  anchors, split preview, image/version picking, placement, timing edits,
  inspector controls, downloading and coverage navigation.
- Characters: search, creation/edit/delete, portraits, link/unlink occurrences,
  image review, ignore/save, auto-tag toggles and scan/pause/resume.
- Audio: import/select/delete, playback/pause/seek/volume, clip edits,
  word timing drafts, save/cancel and shortcuts during text editing.
- Generation: prompt editing/recovery, review, references, person navigation,
  submission, job progress/cancel/retry, stale requests and Codex setup.
- Discussion and teams: participant/context pickers, posting/editing,
  invitations, expiry, roles, member removal and concurrent access revocation.
- Account/settings: sign-in cancellation, sign-out, session refresh, setup
  consent, advanced settings, runtime bootstrap failures and late callbacks.
- History, local save indicators, offline/reconnect/replay and durable restart.
- Updates: explicit check, offer, cancel, keyboard dismissal, nested native
  modal handoff, save fence, rejection, relaunch and durable recovery.
- OS boundaries: document pickers, drag/drop from outside the app, share/open
  events, native menu bar, accessibility, scale/appearance, multiple screens.

## Migrating non-interface invariants without losing them

Some current checks have no one-to-one visible button. A UI-only port cannot
honestly preserve their assertions by checking a happy-path screen:

- **Cloud authorization/concurrency:** run app-originated operations against
  isolated local service state; retain adversarial protocol and race fixtures
  for paths the normal UI intentionally cannot produce. Map each old assertion
  to an observed request rejection or persisted invariant. Multi-client/load
  requirements need real independent app sessions where applicable, and
  service-level evidence for cases outside the interface.
- **Packaging, signatures, entitlements and assets:** inspect the exact bundle
  under test before launch, and exercise launch/helper/update behavior. Source
  structure assertions need equivalent artifact/security evidence, not a
  fabricated UI command for an invariant a user cannot change.
- **Core boundaries and failure recovery:** seed synthetic boundary fixtures,
  act through the app and assert rendered/persisted outcomes after restart.
  Cancellation ordering, malformed envelopes and denied operations may need
  explicit isolated fault adapters in addition to the UI interaction.
- **Update publishing tooling:** Python release tests cover publisher behavior,
  not only the installed app. A CLI suite can orchestrate offline publisher
  checks and app update acceptance in one run, but should label them accurately.
  Do not publish, change trust pins or use real signing secrets just to migrate
  a regression test.
- **Source/design integrity:** preserve artifact hashes, expected metadata and
  design assertions as CLI preflight gates where meaningful. Replacing them
  with an app screenshot alone is not equivalent coverage.

Until each case has an equivalent evidence plan, its status remains unmigrated.
If “every test uses the actual app” is interpreted to exclude all supporting
artifact/service/tool checks, these invariants cannot all be preserved by that
constraint alone. Record the incompatibility rather than claiming 100%.

## Acceptance and retirement gates

For each original entry, retain its source identity and all assertion/parameter
variants, then record:

- Replacement CLI scenario IDs and the exact invariant each replaces.
- Native app build identity, macOS/SDK/architecture, isolated fixture identity,
  command transcript, result, and relevant screenshot/persistence artifacts.
- Verification that the scenario fails for the original regression, then passes
  the fixed app, where reproducing it is safe and feasible.
- All original conditional/parameter cases, interruption/repetition paths,
  concurrency timing and security-negative assertions.
- Independent review that no direct model shortcut or silently skipped action
  has been counted as interface parity.

Only after every entry is mapped and verified, all UI action groups are audited,
and the full replacement suite passes on the actual Catalyst build should old
suite removal be considered. A compiled driver, passing portable tests, or a
single successful app smoke scenario does not meet that gate.

## Environment constraints

This checkout's initial inventory was produced on Linux. UIKit compilation,
Catalyst launch, physical input and visual acceptance cannot be demonstrated by
that inventory run. Respect `AGENTS.md`: preserve the UIKit target, standalone
Command Line Tools and retained SDK workflow; do not install Xcode or simulators
to bypass a build gap. Verify compilation, resource bundling, nested signatures,
native launch/helper behavior and release processing separately. The legacy Mac
app or a Foundation-only harness is not a substitute for actual Catalyst E2E.

## Second slice: transport and live layout candidates

`tests/e2e/transport.mjs` exercises actual tab controls, native header geometry,
the single transport on each tab, seek slider callbacks, play clock advancement
and pause. The adapter reports live view frames, appearance and slider state;
its `slider` command validates bounds before sending the actual value-change
event. Run both initial scenarios using `SCRIV_E2E_APP=... npm run test:e2e`.

`cli-migration-candidates.json` records partial overlap with five baseline
entries and the exact remaining gaps. These are unverified candidate mappings,
not migrated entries. No original test is retired by this slice. Native
compilation and actual-app execution remain required; portable syntax checks
do not count as native acceptance.

## Third slice: editing, characters and project browsing

`editing.mjs` adds dialogue through the real add button, types Unicode via the
native editor, finishes via its registered Escape key command, invokes the
workspace undo/redo key commands and checks the isolated saved package. It
creates a character through the actual form and colour buttons, then checks
ribbon rendering and persistence. `projects.mjs` checks project search, clear,
close/reopen and rejection of covered controls while a sheet is active.

The key adapter only dispatches key commands registered by the current responder
chain and enabled by `canPerformAction`; it does not accept arbitrary selectors
or call domain methods. This tests command routing, not physical keyboard event
delivery. Native execution remains unverified until the actual application can
be launched in the verification environment. Eight candidate mappings remain
partial; no original suite has been retired.

## Harness isolation and reachability

CLI sessions use a unique preference suite as well as a scratch project root.
Workspace, cloud/Codex configuration, character analysis preferences and project
bookmarks use that suite only for the explicit CLI verification launch. Normal
launches retain their normal defaults and existing test injection remains intact.
The driver reports `hittable` from live clipped geometry and UIKit hit testing;
actions reject covered or offscreen controls. This is still not proof of
physical pointer/keyboard delivery. Session errors do not suppress child cleanup,
and shutdown has a bounded grace period before terminating its own child.

## Sandbox-compatible run roots

The launcher passes a fresh UUID, not a filesystem path. Before constructing
any workspace, the automation-enabled app atomically creates its own private
run directory inside its sandbox temporary directory and configures verification
storage there. The capabilities handshake confirms that run ID and root. The
launcher validates the dedicated directory before using it for synthetic-package
assertions. No sandbox entitlement or user-folder permission is relaxed.
