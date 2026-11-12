# Actual-app text growth and minimum timing

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

```sh
SCRIV_E2E_APP=/path/to/ScrivAutomation.app node tests/e2e/text-growth-timing.mjs
```

This is a candidate mapping with **native execution pending**, not a pass or
retirement certificate. The scenario requires the matching automation-enabled
Catalyst app and the existing bounded `import-fountain` command. It uses no
duration alert or native-accessibility plugin, and changes no shared driver.

## Frozen baseline

- Commit: `4d14b29f4fb49891e850fa9a8e5742dc878603c8`.
- Inventory ID:
  `apps/mac/Tests/ScrivCoreTests/EditingTests.swift::0006`.
- Method: `testTextGrowthResizesBeforeValidationAndPreservesIdentities`,
  frozen declaration line 65.
- Source SHA-256:
  `d3f69339fc5d303713696c3ae18ea21bba5882ad89f376ebf1dc18d7e8f1a1de`.

The original builds a one-scene project containing one dialogue `a`, with
owned duration 1 ms, one word ending at 1 ms and one picture cue from 0 to 1 ms.
It records the first word's identity, calls `TimingEngine.updateText` with
`a b c`, then asserts:

1. The entry owns exactly 3 ms.
2. Its first word retains the original word ID.
3. Its picture cue ends at exactly 3 ms.
4. Word end times are exactly `[1, 2, 3]`.
5. `TimingEngine.validate` succeeds.

Every value assertion has a corresponding direct assertion on the actual
app's persisted project. Successful editor application and package persistence
require the real production validator: `TimingEngine.updateText`,
`WorkspaceStore.change` and `ProjectRepository.saveLocked` validate the result.
The scenario does not implement a validator, retimer, cue mapper or project
model in JavaScript.

## Actual application path

The normal launcher creates a fresh synthetic run. The scenario saves its real
startup sample and records that package before importing this bounded text:

```fountain
Title: CLI text growth

INT. ROOM

@NARRATOR
a
[[scriv duration=1 coverage=0]]
```

The existing semantic import adapter creates its own private temporary file
and calls `WorkspaceStore.importScript(from:)`. The scenario supplies no
filename, URL, project package or caller-controlled path. This is the import
boundary documented in [fountain-import.md](fountain-import.md), not OS picker
automation. Before editing, assertions require exactly one distinct imported
project, one scene, one dialogue, one word at `[0,1]`, and one cue at `[0,1]`.
The owned duration must already be 1 ms. Testing a default-duration dialogue
or a three-word import cannot satisfy this setup.

Import selects its first entry through the production installation path. The
scenario verifies the installed title and line, discovers the enabled
Command-Return editing action from the actual responder chain, and dispatches
that existing action. It requires the imported entry's exact editor identifier
to become the sole focused script editor. A reachable native scroll ancestor
reveals the editor if necessary.

The existing `selection` command places the native caret at UTF-16 offset 1,
and `type` inserts ` b c` once. The scenario checks native editor text `a b c`
and collapsed caret 5, then dispatches the enabled Escape finish action. It
requires the finished display and the same saved entry to contain `a b c`
before checking every frozen assertion.

The edit follows the installed UIKit editor and draft lifecycle into the real
`TimingEngine.updateText` operation. It does not call the store directly or
change the duration through a separate control. `key` dispatches registered
responder actions and `type` uses native text insertion; neither is a claim of
physical key delivery, IME coverage or exact event-stream equivalence.

## Fixture differences and added evidence

The original directly constructs model IDs `s` and `a`. Import instead creates
its own IDs, title, scene heading and narrator profile. The scenario discovers
and records these identities rather than injecting them. The single-entry
timing, source text, word endpoints and single-cue extent that drive the
regression are asserted equal to the original fixture before the tested edit.
The imported speaker/profile is additional setup, not evidence for character
parity. No existing Fountain test is claimed by this scenario.

Additional assertions retain the entry, scene, original cue and first-word
identities; word texts become exactly `["a", "b", "c"]`, starts `[0,1,2]`,
and all three word IDs are distinct. Coverage, speaker, scenes, characters,
images and audio records remain unchanged. The saved revision advances and
every startup package remains unchanged in the app's JSON observer. Only
import creates a second project.

The cue may acquire normal source-owned anchor metadata when the production
resize materializes it. The scenario does not demand that old unanchored
metadata remain absent, nor erase that metadata from the application.
