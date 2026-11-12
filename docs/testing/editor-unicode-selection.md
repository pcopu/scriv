# Native Unicode selection and replacement

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Run with the real automation-enabled UIKit Mac Catalyst application:

```sh
SCRIV_E2E_APP=/path/to/Scriv.app node tests/e2e/editor-unicode-selection.mjs
```

The scenario launches its own app with fresh synthetic storage. It adds dialogue
through the visible Script controls, selects native UTF-16 ranges and inserts
text through `UITextView.insertText`. It observes saved results through the
read-only `persisted-projects` command. It does not write fixture packages,
mutate the store, inject a replacement editing model, or use a fallback driver.

## Exact-text and selection assertions

- Adding Dialogue creates one new entry in the same saved project and focuses
  that entry's native editor.
- Initial text includes a leading surrogate-pair emoji, precomposed `caf\u00e9`,
  decomposed `cafe\u0301`, a skin-tone/ZWJ astronaut emoji and repeated names.
- Replacing `One` at UTF-16 range `[3, 6)` preserves its surrounding spaces and
  the complete leading emoji. Replacing only the second `Alex` preserves the
  first occurrence. Replacing the entire astronaut sequence with `🎬` uses its
  full UTF-16 length. A subsequent insertion at a collapsed caret preserves two
  leading spaces and a decomposed accent in the inserted suffix.
- Each range is observed in the focused native editor before insertion. Each
  replacement checks the full exact result and a collapsed caret at
  `start + replacement.length`, then checks both again after saving.
- With the decomposed word selected, the enabled script zoom shortcut changes
  the visible zoom label. The same entry still has one focused editor, the exact
  original text and both selection endpoints. Selection is not reissued before
  typing, so a refresh cannot be repaired by the test itself.
- The final replacement changes only `cafe\u0301` to `caf\u00e9`. The result is
  canonically equivalent but has different UTF-16 code units and a shorter
  native range. It must persist exactly, not be dropped as an unchanged edit.
- Escape finishes editing and displays the exact text in the corresponding
  script line. One enabled workspace Command-Z restores the exact previously
  saved decomposed representation. Shift-Command-Z restores the composed one.
  Both outcomes must appear in the UI and the actual saved package.
- Throughout saved-state checks, the new entry retains its ID, scene and
  dialogue kind, entry count remains `before + 1`, and every pre-existing
  entry's text is unchanged. Each persisted word's exact spelling must match
  its source token. The canonical-only edit preserves all word IDs, timing
  endpoints and timing ownership metadata.

JavaScript strict string equality compares UTF-16 code units. Range arithmetic
uses `length`, `indexOf` and `slice`, never code-point or grapheme counts.
Normalization is used only to establish that the two fixture spellings are
canonically equivalent; observed text and expected results are never normalized.
The `text` command selects all only during initial setup. Every selection under
test uses `selection` followed by `type`, without selecting all.

## Frozen baseline mapping and remaining gaps

Baseline commit: `4d14b29f4fb49891e850fa9a8e5742dc878603c8`.
The IDs below refer to `cli-migration-inventory.json`, not current source line
numbers. All mappings are **partial candidate coverage, native runtime pending**.
No legacy test may be retired on this scenario's evidence alone.

### Script editor selection and refresh

Frozen source: `apps/catalyst/Tests/ScriptUIKitTests.swift`.
SHA-256: `986a3151f30ac1ca31c0f0d42272958891b692387f0fc1b06162a107a960c177`.

1. `apps/catalyst/Tests/ScriptUIKitTests.swift::0001`,
   `testNativeEditorUsesConstrainedWidthAndKeepsExactSelection`, frozen line 10.
   The original line 19 checks exact selection and line 20 exact UTF-16 text
   after changing editor width from 260 to 700. This scenario checks those
   observable properties after a real script zoom refresh, including nonempty
   selection. This is a different stimulus: it does **not** reproduce the
   constrained-width change or the repeated long-text fixture. The narrow
   height exceeding wide height (line 18), `isScrollEnabled == false` (line 21)
   and unlimited text-container lines (line 22) remain unverified.
2. `apps/catalyst/Tests/ScriptUIKitTests.swift::0004`,
   `testRowRefreshPreservesNativeEditorIdentityAndCaret`, frozen line 63.
   The original invokes `setEditing` twice and asserts object identity at line
   69 and the exact selection at line 70. The scenario observes selection,
   text, focus and a single editor for the same entry after a real zoom/store
   refresh. An accessibility identifier and unique view count do **not** prove
   `ObjectIdentifier` equality, and this does not isolate the repeated
   `setEditing` call. Both differences block full assertion parity.

### Adding, finishing and workspace undo/redo

Frozen source:
`apps/catalyst/Tests/ScrivUIKitTests/WorkspaceEndToEndTests.swift`.
SHA-256: `8bf3334e3ef7dfcfadb8118ab33a6d79756914ea1956ee5311fbf656db7aaae5`.

`apps/catalyst/Tests/ScrivUIKitTests/WorkspaceEndToEndTests.swift::0002`,
`testAddUndoRedoCharactersAndStoryboardThroughRealControls`, frozen line 102.

The add-control count, newly focused editor, typed result, end of text focus,
enabled workspace Undo, changed text after Undo and restored text after Redo
have corresponding actual-app assertions here. The last two are strengthened
to exact previously saved and final Unicode strings rather than only
`text != final` and `text == final`. Saving each earlier edit before the next
one makes the expected undo boundary explicit.

This scenario does **not** select an existing character in the ribbon, select a
Storyboard picture placement, inspect the picture's installed tap recognizer,
assert `store.errorMessage == nil`, or recreate the original 1448-by-900 light
window. Persisted exact text is not a substitute for those missing assertions.
The complete original test therefore remains required.

### Related tests explicitly not replaced

The following IDs use the same frozen `ScriptUIKitTests.swift` hash above:

- `apps/catalyst/Tests/ScriptUIKitTests.swift::0002`,
  `testDelegateJournalsExactUTF16OperationBeforeAllowingUIKitMutation`:
  successful final text does not prove that the exact operation reached the
  journal before mutation, or that the surviving confirmed character-link ID
  and range are correct. Repeated-substring replacement is not that assertion.
- `apps/catalyst/Tests/ScriptUIKitTests.swift::0003`,
  `testRejectedNativeEditCannotMutateTextOrJournal`: no journal write failure or
  rejected delegate operation is induced.
- `apps/catalyst/Tests/ScriptUIKitTests.swift::0008`,
  `testReturnInvokesBoundaryOperationWithoutInsertingOrDeletingSelectedText`:
  no Return/split boundary operation is exercised.
- `apps/catalyst/Tests/ScriptUIKitTests.swift::0009`,
  `testBackspaceAtZeroRequestsMergeButSelectionAndCompositionRemainNative`, and
  `apps/catalyst/Tests/ScriptUIKitTests.swift::0010`,
  `testConfiguredScriptDeletionPreservesExactUnicodeAndAdjacentSpaces`:
  replacement is not Backspace. The present command set has no supported
  `deleteBackward` action; an empty `type` call is not assumed equivalent.
  Merge counts, smart-delete configuration, actual deletion and composition
  behavior remain uncovered.
- `apps/catalyst/Tests/ScriptUIKitTests.swift::0011`,
  `testSharedFontAppliesToDisplayAndNativeEditorWithoutReplacingEither`:
  zoom-label change does not prove exact display/editor font sizes or native
  object identity. This scenario does not claim those assertions.

No recovery-comparison, duration-scrub, character-link identity or IME-composition
coverage is claimed. The scenario invokes native UI controls and responder
actions, not physical pointer dragging or hardware keystrokes. It does not
relaunch the process to prove reopen/recovery behavior.

## Reproduced persistence defect and repair

The production repair is deliberately below the test adapter:

- `Models.swift` gives `ScriptEntry` and `TimedWord` exact UTF-16 source-text
  equality while retaining the existing comparison of all other fields.
  Previously, synthesized equality considered canonically equivalent strings
  equal. Both `applyEditorDraft`'s `next == project` and `change`'s
  `next != before` could therefore discard the edit. The shared model fix also
  reaches undo/redo, immutable history and saved-revision checks, cloud dirty
  item detection, incoming project comparisons and row render caches. Truly
  identical content still compares equal and remains a no-op.
- `CloudModels.swift` makes JSON string payload equality exact and recursively
  retains array/object value comparison. Cloud commit/conflict/reconciliation
  and readable history comparisons must not erase the change after the local
  model accepts it. Numeric, Boolean, null and object-key matching semantics
  remain unchanged. Synthesized hashing remains valid: unequal canonical
  spellings may share a hash, but equal values always have equal hashes.
- `TimingEngine.swift` updates the exact spelling of canonically equivalent
  word tokens without replacing IDs or retiming words. Previously, its
  canonical token-array comparison could leave stale word text behind.
- `WordTimingEditing.swift` preserves authored timing fields without copying
  the old matched token's spelling over newly authored text. Timing-only edits
  must also preserve exact text rather than accept canonical substitutions.
- `WorkspaceStore.swift` requires exact source text in the missing-journal
  no-change exception. A canonical-only edit cannot masquerade as an untouched
  draft when its recovery record is absent.

The repaired build still requires a native rerun. The exact-text assertions
are retained and strengthened, never relaxed to normalized equality. No cloud
network write, recovered-draft UI or authored-timing interaction is exercised
by this local CLI scenario; their downstream fixes need their own native or
integration evidence before those baseline tests can be retired.
