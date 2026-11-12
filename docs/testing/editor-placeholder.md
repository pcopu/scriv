# Added dialogue placeholder selection

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Run against a separately built automation-enabled Catalyst app:

```sh
SCRIV_E2E_APP=/path/to/Scriv.app node tests/e2e/editor-placeholder.mjs
```

The launcher gives the real application fresh synthetic storage. This scenario
uses the visible Script tab and Dialogue add control, native text insertion and
the enabled Escape responder action. It never writes fixtures or changes the
store directly. Saved results come from the app's bounded read-only
`persisted-projects` observation.

## Exact baseline mapping

Frozen inventory ID:
`apps/catalyst/Tests/ScrivUIKitTests/WorkspaceEndToEndTests.swift::0012`

Method: `testAddedLineOpensWithPlaceholderSelected`.

Frozen baseline source SHA-256:
`8bf3334e3ef7dfcfadb8118ab33a6d79756914ea1956ee5311fbf656db7aaae5`.
The frozen inventory line number is 612; use the method and ID if lines move.

1. The original adds dialogue and identifies the new entry. The replacement
   captures persisted entry IDs before activating the actual Dialogue control,
   then verifies the first-responder editor's ID is newly added to the same
   persisted project.
2. The original checks editor text equals the new entry text and selection is
   `NSRange(location: 0, length: added.text.utf16.count)`. The replacement waits
   for that same first-responder text and full native selection (`selection.start == 0`, `selection.end == length`), using JavaScript
   string length, which also counts UTF-16 code units. It verifies the saved
   placeholder is `New line` and rechecks selection after scrolling into view.
3. The original directly checks `store.requestedEntryEditingSelectsText == false`.
   That private store flag is **not observed** by this scenario. Two successive
   native `type` commands check its intended behavior: replacing the selection,
   then appending at a collapsed caret after change processing. This catches
   selection replay that affects typing but does not prove the internal flag's
   value. Exact assertion parity remains partial without a read-only observation
   of that flag. Do not retire the legacy test based on this scenario alone.

## Additional actual-app assertions

- `type` calls native insertion without selecting all. The existing `text`
  command must not be used: it would manufacture the selection being tested.
- Unicode replacement contains an accented character and a surrogate-pair emoji;
  the collapsed caret after each insertion must equal the UTF-16 text length.
- Escape finishes editing, removes editor focus and displays exactly the final
  text in the corresponding script line.
- The same entry persists as dialogue with the final text, and entry count
  increases by exactly one.

This invokes UIKit controls and responder actions, not physical keyboard events.
It does not assert the legacy test's 1280-by-800 window geometry or a process
relaunch. Storage persistence is verified through the actual saved package.
