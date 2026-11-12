# Application Return delegate boundary

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Run against the matching automation-enabled UIKit Mac Catalyst application:

```sh
SCRIV_E2E_APP=/path/to/Scriv.app node tests/e2e/script-return-boundary.mjs
```

The current version uses an explicit public UIKit **delegate-contract input command**. Case 4 failed at an incorrect test expectation for an empty line's display placeholder; case 5 was not reached. The display expectation is now corrected from source, but the corrected five-case run is **pending**. No original test is retired here, and no physical Return-key equivalence is claimed. The E2E runner discovers the top-level scenario automatically.

## Actual application path

The scenario launches the real application with fresh synthetic storage, opens
Script, and adds each fixture through the visible Dialogue control. The
existing `text` command supplies initial text only. Each boundary operation
uses `selection`, observes both native UTF-16 endpoints and the exact source
text, then calls `return` on that same focused, hittable editor. The scenario
requires the matching application's advertised `return` capability. It never
falls back to newline insertion when that command is missing.

The explicit `return` adapter requires a focused editable `UITextView` with
no marked-text composition. It calls the installed public
`textView(_:shouldChangeTextIn:replacementText:)` delegate once, passing the
editor's actual `selectedRange` and `\n`. It reports the delegate's Boolean
result and calls `insertText` only when the delegate allows insertion. This
scenario asserts `{dispatched: true, delegateAcceptedInsertion: false}` before
waiting for the boundary result, so its successful path never inserts a newline.

The installed `ScriptEntryRow` delegate intercepts that request, calls its
installed `onSplit` using the range's **start**, and returns false. The
installed controller finishes
the draft, acquires the required edit access and invokes the production
boundary operation. It then focuses the new right-hand editor at offset zero.
The selected characters belong to that new line; their highlight is not
expected to survive. The scenario asserts character preservation, not retained
selection highlighting.

This is an explicit invocation of the real mounted delegate, not proof that
UIKit's keyboard event machinery dispatched it. No delegate is replaced, and
the adapter does not call `onSplit`, the controller or a model/store operation
directly. There are no written fixture packages or fallback execution paths.
The app-owned read-only `persisted-projects` command supplies saved evidence.
All subsequent boundary, focus, save and history work belongs to the actual app.

## Cases and assertions

The five fixtures run sequentially in the same isolated project:

1. `One two`, selection `[4, 7)`: the baseline selected `two` survives as the
   full right line, with exact left text `One `.
2. `One  two\tthree`, selection `[5, 8)`: two spaces and the tab remain exact;
   the split is `One  ` and `two\tthree`.
3. `😀 One  cafe\u0301 👩🏽‍🚀 two  `, selection from offset 8 through the joined
   emoji: the leading surrogate pair, decomposed accent, skin-tone/ZWJ emoji,
   doubled spaces and trailing spaces remain exact. The entire selected
   substring remains at the start of the right line.
4. `One`, collapsed selection at zero: an empty left line and full right line.
5. `One`, collapsed selection at three: a full left line and empty right line.

Offsets and comparisons use JavaScript UTF-16 `length`, `indexOf`, `slice` and
strict equality. Neither observed text nor expected text is normalized.
Every tested boundary is between complete characters and whole words.

For every case, the scenario checks:

- Adding Dialogue creates and focuses one new entry in the same project.
- Before Return, the exact fixture is saved, the original duration is 3,000 ms,
  and the requested selection is observed in the focused, hittable editor.
- The installed edit delegate returns false. The adapter reports that result
  and does not insert a newline on this path.
- Return creates exactly one further entry, preserves the original left ID,
  and focuses the new right ID at a collapsed zero caret. The left line and
  right editor reflect the expected split, with no inserted newline. An empty
  native editor remains exactly empty. A nonediting empty dialogue display
  shows exactly `Write dialogue…`, matching `ScriptAttributedText.make`.
- Both saved texts concatenate to the complete exact source. The selected
  substring is still present, without deletion or whitespace repair.
- Both lines keep the scene, dialogue kind and speaker. They are adjacent in
  scene order. Each owns positive time, including empty lines; their durations
  sum to the original duration. All complete source words retain their IDs.
  Saved word spellings match the source, and timing intervals are positive,
  ordered and bounded by the respective line duration.
- Every unrelated entry retains its full saved content, IDs and timing.
- Escape finishes the untouched right editor and both displayed lines match
  saved text, with only the exact display-only placeholder for an empty source.
  Persisted empty text is always asserted as `""`; the placeholder is never
  accepted in the saved text or a focused editor. One enabled workspace
  Command-Z restores pre-split entry text,
  IDs, order, speaker and all timing, and removes the right ID from the UI and
  saved package. One enabled
  workspace Shift-Command-Z restores the same split IDs and exact saved entry
  text, order, speaker and timing. History may intentionally bootstrap missing
  character annotations on the original sample rows, so `characterLinks` is
  excluded from these two history comparisons. Exact source strings and all
  word fields remain included. No timing-only approximation or normalized-text
  comparison is used.
- Five completed cases leave ten additional entries, with no extra Return
  lines. Each wait is bounded, and failure still closes the owned app session.

## Frozen baseline mapping

Baseline commit: `4d14b29f4fb49891e850fa9a8e5742dc878603c8`. IDs and lines below refer to `cli-migration-inventory.json`, not moving source line numbers.

### Primary UIKit baseline

Source: `apps/catalyst/Tests/ScriptUIKitTests.swift`.
SHA-256: `986a3151f30ac1ca31c0f0d42272958891b692387f0fc1b06162a107a960c177`.

`apps/catalyst/Tests/ScriptUIKitTests.swift::0008`,
`testReturnInvokesBoundaryOperationWithoutInsertingOrDeletingSelectedText`,
frozen line 101:

- The original uses `One two` and range `(location: 4, length: 3)`, then checks
  split offset 4 and preservation of the selected source text. Case 1 uses the
  exact source and selection in the native editor and dispatches the explicit
  public-delegate request. It verifies the resulting
  split at 4 and preservation of all source characters in the actual saved
  document, with additional UI, identity and history assertions.
- The original directly asserts the delegate returns false, the `onSplit`
  callback receives 4, `textEdits == 0`, and the standalone row editor still
  contains `One two`. This scenario observes the complete app after a real
  split, not the synchronous standalone row. It now checks the reported false
  delegate result, but does **not** observe callback counts, the callback's raw
  offset argument, journal ordering or the old editor's transient text.
  These remaining assertions prevent full baseline equivalence.

### Related core boundary baselines

Source: `apps/mac/Tests/ScrivCoreTests/ScriptBoundaryEditingTests.swift`.
SHA-256: `b82428d728f60400b7ca9f3b676c283776b006529f0c9811647e92491ff908ad`.

- `apps/mac/Tests/ScrivCoreTests/ScriptBoundaryEditingTests.swift::0001`,
  `testSplitPreservesExactTextWordIDsAndTotalTime`, frozen line 8: case 2 uses
  the same `One  two\tthree` fixture and offset 5. Exact split text, concatenated
  source, word identities and conserved owned time have direct saved-state
  assertions. The baseline's fixed cue at 1,700–3,000 ms is not constructed or
  checked, full scene-duration semantics are not independently observed, and
  there is no direct `TimingEngine.validate` invocation. Coverage is partial.
- `apps/mac/Tests/ScrivCoreTests/ScriptBoundaryEditingTests.swift::0004`,
  `testEmptyEndSplitUsesExistingTimeAndKeepsAllWords`, frozen line 38: cases 4
  and 5 reproduce `One`, offsets 0 and 3, two resulting lines, conserved
  3,000 ms of owned time, preserved word IDs and positive owned durations.
  They additionally check native focus and persisted undo/redo. Full scene
  validation remains the production operation's responsibility, not a claimed
  separately observed `TimingEngine.validate` assertion. No retirement is
  certified without native evidence and review of that assertion difference.

## Explicit gaps and non-claims

- There is no supported `deleteBackward` CLI action. Neither empty `type` nor
  replacement with an empty string is treated as Backspace. Merge-at-zero,
  native deletion, smart-delete configuration and composition behavior remain
  uncovered. In particular, the same frozen UIKit source's `::0009`
  (`testBackspaceAtZeroRequestsMergeButSelectionAndCompositionRemainNative`)
  and `::0010`
  (`testConfiguredScriptDeletionPreservesExactUnicodeAndAdjacentSpaces`)
  are not replaced.
- No marked-text/IME input, split inside a word or grapheme, invalid offset,
  stale-source rejection, insufficient duration or failed edit lease is
  induced. Rejected-operation atomicity is not claimed.
- Confirmed character-link partitioning, authored timing markers, image/audio
  reanchoring and bytes, direction coverage and all merge cases remain
  separate requirements. Retaining a speaker ID does not prove character-link
  identity preservation.
- No physical keyboard event, journal callback count, durable journal ordering,
  crash/reopen recovery or cloud synchronization is claimed.
- This revised scenario depends on the matching driver's explicit `return`
  command. No production editor change is required by this scenario, and no
  inventory, evidence ledger or legacy test is changed here. A previous pass
  of the separate Unicode editor scenario is not evidence that this Return
  scenario passes.

## Explicit delegate input adapter

Ordinary text insertion passing elsewhere does not prove delegate behavior.
`ScriptDraftSession.nativeTextDidChange` explicitly persists system/native
changes without a matching delegate operation. `ScriptTextView` has no
`insertText` override, and its registered key commands contain only Escape.
The application registers Command-Return to toggle editing, not unmodified
Return to split. Calling that shortcut is not an equivalent replacement.

The revised scenario uses the explicit delegate-contract adapter described
above rather than claiming `insertText` is equivalent to Return. It also reads
the original editor's exact text/selection, every
focused script editor, the saved original text, added saved IDs/text and entry
count when the Return-focus wait fails. These read-only observations have
bounded timeouts, do not repeat the mutation, and are limited to the isolated
synthetic fixture.

Source inspection confirms that `ScriptAttributedText.make` deliberately displays `Write dialogue…` for empty dialogue. `ScriptEntryRow.setEditing` instead supplies the exact source text to the editor. These are different UI states, not interchangeable source text.

The correction changes only `script-line-` display expectations for empty
dialogue, including after finishing and redoing both endpoint cases. Saved
text and focused-editor assertions remain strict empty-string checks. The
scenario does not scroll or remount rows to hide the mismatch, and no
production code changes are needed. Case 4's later persistence/history checks,
case 5, and the final five-case entry count remain unverified until rerun.

A supported real Return-key event through the Mac's computer-use keyboard
input, with the synthetic app and selected editor verified as focused, can
distinguish normal interface behavior from programmatic insertion. Availability
and permission for that native event route must be verified by the Mac worker.
Do not invoke private selectors, fabricate UIKit events, directly call the
split callback, add model mutations, or treat Command-Return as Return. The
explicit delegate adapter proves a different input boundary and must remain
labeled that way in run evidence. A pass cannot be reported as physical-key or
complete UIKit event-dispatch equivalence.
