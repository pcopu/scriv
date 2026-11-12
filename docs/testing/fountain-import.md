# Actual-app semantic Fountain import

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

```sh
SCRIV_E2E_APP=/path/to/ScrivAutomation.app node tests/e2e/fountain-import.mjs
```

Requires an automation-enabled Catalyst app containing `ScrivCLIImport.swift`
and the matching `import-fountain` driver command. Native compilation and
execution are pending. This document is a coverage map, not a pass certificate.

## Boundary and isolation

`import-fountain` accepts only `{ "text": "synthetic Fountain source" }` in
addition to the ordinary protocol `id` and `command` keys. It accepts at most
65,536 UTF-8 bytes, including empty text. There is no caller filename, path,
URL, project, external-file grant or sandbox-denial fallback. The 64 KiB bound
allows an over-limit test inside the existing 1 MiB JSON envelope. Both ASCII
and multibyte over-limit inputs are tested.

`ScrivCLIImport` is compiled only under `SCRIV_CLI_AUTOMATION` and requires
`--scriv-cli`, `--screenshots`, a valid 36-character run UUID, and exact matching
of the app-computed run root to `SCRIV_VERIFICATION_ROOT`. The normal launcher
creates a fresh UUID, and the app's startup creates its private run directory
exclusively. Import does not create or adopt an existing external run root.
The helper checks that the current project has a UUID and its current package
is exactly `Projects/<current-project-id>.scriv` in this run. The private root,
Projects directory and current package must be real app-owned directories;
descendants are opened with no-follow descriptor-relative traversal.

Only the trusted system temporary prefix is resolved for macOS's possible
`/var` to `/private/var` alias. Run-owned components must not resolve through
symlinks. Root/child descriptor identities are checked again before import.
The helper requires a mounted workspace with no presented modal or current
store error and calls `UIKitPresentation.finishEditing(in:)`, the same normal
finish-editing operation called before the real import picker. It does not
manufacture an editor commit, erase an error, or replace the current model.

The app creates a fresh UUID-named `.fountain` file directly in its own run
directory using `openat` with `O_CREAT | O_EXCL | O_NOFOLLOW`, mode `0600`.
It writes only the supplied bounded synthetic UTF-8 bytes, checks file identity
and size, then calls **`WorkspaceStore.importScript(from:)`**, the same entry
point called after the production document picker. That production method
performs the real UTF-8 read, Fountain parse, `TimingEngine.validate`, project
installation and normal persistence. No test parser, copied validator, direct
model assignment or special test-only save exists in the adapter.

The temporary file is removed after the synchronous importer returns, only if
the name still denotes the exact regular-file device/inode created by this
request. No run directory, package, replacement file or unrelated file is
removed. Descriptor checks reduce path replacement risk; a URL-based production
import cannot lock an entire namespace against a separate same-user process
with access to the private app container. No such process is introduced here.
The helper reads no production project or user file. Import failures are generic
at the adapter boundary; the response contains only `dispatched` and the
observed `projectChanged` boolean, never paths, raw source or underlying errors.

This is an **explicit semantic application import boundary**. It is not OS
document-picker automation, physical keyboard input, security-scoped external
file selection, permission grant or complete UI-event equivalence. A successful
dispatch alone is insufficient: the scenario requires changed project identity,
actual app-owned saved packages and the installed title in the workspace header.

## Frozen baseline identity

- Commit: `4d14b29f4fb49891e850fa9a8e5742dc878603c8`.
- Source: `apps/mac/Tests/ScrivCoreTests/FountainTests.swift`.
- Source SHA-256:
  `ef94a9c83bd09dcd8055f876a1126f06d16286f2bffc816795a6e3b05bd71e8b`.
- IDs below have the exact prefix
  `apps/mac/Tests/ScrivCoreTests/FountainTests.swift::`.
- The frozen inventory, source tests and retirement flags are unchanged by this
  slice. Line numbers below refer to the frozen source, not the working copy.

## Unchanged-input, exact assertion mapping

Each item retains every listed original value assertion on the app's persisted
project. Every original `TimingEngine.validate` success assertion is exercised
by the production importer before installation; the JavaScript scenario does
not substitute an approximate timing validator. These are candidate mappings
pending native execution, not verified migrations.

1. `0002`, line 14,
   `testParentheticalIsUnspokenForwardDirection`: three entries; entry 0 is
   direction, owns 0 ms and has no words; entry 1 is dialogue with exact text
   `You stupid guy!`.
2. `0003`, line 25, `testCRLFAndSceneOrder`: exactly two scenes, two entries and
   two cues. Extra checks preserve scene/title and entry/text order; those are
   additions, not replacements for the original count assertions.
3. `0005`, line 47, `testMetadataImmediatelyAfterTextAppliesToThatEntry`: exactly
   one entry, 2000 ms owned, 0 ms coverage, last word ends at 2000 ms.
4. `0006`, line 55, `testMidDialogueParentheticalKeepsSpeakerAndIsNeverSpoken`:
   exact four-entry text sequence, one character, entry 0/2 and entry 2/3
   character IDs equal, parenthetical entry 1 has no words and owns 0 ms.
5. `0008`, line 73, `testTitlePageAuthorDoesNotCreateATimedEntryOrExtraScene`:
   exact title `Audit fixture`, scene titles `["INT. ROOM - DAY"]`, entry text
   `["Hello there."]`, character names `["Jason"]` and one cue.
6. `0011`, line 125, `testTitlePageToleratesUTF8BOMCRLFAndTabIndentedValues`:
   exact title `BOM title`, one scene, exact entry text `["Wait."]`.
7. `0012`, line 133, `testTitlePageStopsAtNonMetadataEvenWithoutBlankSeparator`:
   exact title `No separator`, scene titles `["INT. ROOM - DAY"]`, entry text
   `["Wait."]`.
8. `0013`, line 141, `testTitleLikeBodyAfterBlankAndForcedActionsAreNotMetadata`:
   all three original inputs. First: exact title `Actual title` and the two
   literal body/action texts. Second: the literal opening forced action.
   Third: the literal opening transition `CUT TO:`. Each import independently
   reaches production validation and saves its own project.
9. `0015`, line 163, `testEmptyAndMetadataOnlyInputsRemainValid`: all four
   original inputs (empty, two newlines, title/author, indented author). Each
   produces exactly one scene, no entries and no cues, then passes production
   validation. No nonempty text is silently substituted for the empty inputs.
10. `0016`, line 173, `testTitleMayContainAColonOrTransitionText`: exact title
    `CUT TO:` and entry text sequence `["CUT TO:", "Wait."]`.

## Original CI failure and intentional fixture correction

`0007`, line 65,
`testEmptyScenesAndMalformedTimingAnnotationsRemainSafe` is **not an
unchanged-input, unchanged-assertion mapping**. The frozen fixture puts the
malformed annotation immediately after `!Wait.` without a blank separator.
The existing production parser deliberately treats every nonblank continuation
of forced action as literal text. Its four whitespace-separated tokens produce
1500 ms (`4 * 375`), not the frozen expectation of 1000 ms. The correction is
to the fixture's intended metadata boundary, not to that production behavior.

Three distinct cases remain separate:

- **Corrected metadata fixture, related to `0007`:** a blank line terminates
  forced action before `[[scriv duration=-1 coverage=99999999999999999999]]`.
  The scenario retains the original scene-title, entry-count and 1000 ms owned
  assertions. It additionally checks literal entry text `Wait.` and 1000 ms
  coverage. Negative/overflow metadata must not change the valid timing.
- **Exact original `0007` input, corrected literal expectation:** there is no
  added blank line. The scenario checks two exact scene titles, one direction,
  exact text `Wait.\n[[scriv duration=-1 coverage=99999999999999999999]]`, and
  1500 ms owned/coverage. It explicitly does not preserve the obsolete 1000 ms
  assertion, so this is not retirement evidence for the frozen test.
- **Post-baseline regression, no frozen ID:**
  `testForcedActionContinuationKeepsTimingAnnotationLiteral` uses the valid
  annotation `[[scriv duration=2000 coverage=3000]]` immediately after forced
  action. All five working-test assertions are retained: one entry, direction
  kind, exact literal two-line text, 1500 ms owned and 1500 ms coverage. Native
  verification of this new regression remains pending.

For reproducibility, SHA-256 of each Swift method's UTF-8 source, beginning
with its four-space-indented `func` and ending at its four-space-indented
closing brace, excluding a trailing newline:

- Frozen malformed method:
  `4411e4ab97dd69b97e5ce3af92d2f901ffecba1acee40df22bb70cf2dc87cc2c`.
- Corrected working malformed method:
  `22529fa3b5a1cd46bd9703f75db817cbbd596fce1654f81cedc7f172277d19b7`.
- Post-baseline literal-continuation method:
  `89bd97a3f06ccd3af1837c3902d01654e246311d9eac4b54c7b9d7637e62a362`.

## Additional checks and remaining gaps

The scenario performs 18 imports after saving the real sample project, ending
with exactly 19 packages. Each accepted import creates exactly one distinct
project, installs its actual title in the workspace header and preserves every
previous saved project unchanged. Invalid parameter/type/size requests must
reject without altering saved projects. Tests use only the app's existing
bounded `persisted-projects` observer; the parent never writes import files or
project packages into the app's container.

Deferred original IDs:

- `0001`, `0004`, `0017`: production export/reimport round trips.
- `0009`: all-keys/indented-value import plus its export/reimport assertions.
  Its parse-only portion is not counted as a completed test here.
- `0010`, `0014`: exact caller-supplied fallback titles (`Filename fallback`
  and `Plain text`). The production file importer derives its fallback from
  the app-generated filename; this bounded command intentionally does not
  accept a caller filename or expose parser-only title parameters.

No export serializer shortcut is added. No picker/save-dialog, external access,
recovery failure, active-editor interruption, cold reopen, unsupported JSON
import, screenshot or pixel-layout parity is claimed. Root/symlink tampering
is defended in the helper but is not exercised by this scenario. No production
parser or persistence behavior, legacy test, GitHub Action or retirement flag
is changed by these three slice files.
