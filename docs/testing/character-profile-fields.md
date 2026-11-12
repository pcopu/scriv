# Character profile fields actual-app candidate

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

```sh
SCRIV_E2E_APP=/path/to/ScrivAutomation.app node tests/e2e/character-profile-fields.mjs
```

This scenario launches the actual automation-enabled Catalyst application in a
UUID-isolated synthetic workspace. It saves the initial project with the real
Command-S action, edits mounted UIKit controls, and observes both the view tree
and the app-owned `persisted-projects` export. It never seeds a project package,
calls a validation/model helper, invokes private handlers, or substitutes a mock
application. Offscreen text fields, text views and palette buttons are revealed
through their actual ancestor scroll view before input is dispatched.

## Scenario coverage

- Open Add character and observe that Name, Biography and Appearance begin
  empty. Enter Name as `"  台詞  "` and require the saved name `台詞`, matching
  the form's intentional outer-name trimming. Enter Biography exactly
  `"  cafe\u0301\n"` and Appearance exactly `"Warm light"`. Unlike the name,
  authored notes must retain leading spaces, the decomposed accent, and the
  final newline through native insertion, saving and later reopening.
- Select Purple and then Pink using the freshly rendered palette controls.
  Record the enabled palette labels on each editor opening, require all eight
  standard names, and preserve that exact multiset after rerendering. A retained
  custom colour may share its label with a standard swatch. Every activated
  colour still requires one unique enabled control, and the saved colour must
  be exactly `F272AC`. Selected swatch artwork is not inspected.
- Before each Save, observe that draft text and colour changes have not reached
  the saved package. After saving, compare the complete character array, not
  only the changed values. Every pre-existing profile and script entry's text,
  identity, order and timing must remain unchanged. On the first accepted
  creation only, missing/null `characterLinks` may become an array of
  unconfirmed suggestions. Previously explicit links, including empty arrays,
  remain exact. All later edits require complete entry equality against the
  post-creation package, including the materialized links and their IDs.
- Reopen the same character by its unique search result and immutable ribbon
  identifier. Submit a 101-emoji name, requiring the name-validation issue and
  the complete untruncated draft. Restore the valid name, submit 20,001 `x`
  characters in Appearance, and require the exact notes-limit issue. Restore
  Appearance, then enter U+0001 repeated 12,000 times in Biography through the
  actual text view. Require all original code units before Save and the distinct
  encoded-profile-size error afterward, with the draft still exact. All three
  invalid Saves must leave the saved character unchanged. Restore the original
  text before clean Cancel, so no dirty-discard alert needs activation.
- Edit Biography and Appearance to distinct multiline notes containing blank
  lines, trailing spaces, composed and decomposed accents, CJK text and a joined
  emoji. Change the colour to Orange (`FF7E21`), save, reopen, then save the
  unchanged profile again. Check all text exactly at each stage.
- Clear both notes, choose Green (`69C581`), save and reopen to prove empty text
  is persisted rather than replaced by stale notes. Restore the original exact
  notes and Pink, save, and perform two further clean Cancel/reopen cycles.
- Finally establish a decomposed accent in each notes field. Change only
  Biography to its canonically equivalent composed spelling, save, inspect the
  exact persisted spelling, and reopen. Then independently do the same for
  Appearance. No simultaneous name or colour change may force the save and
  conceal a canonical-equality no-op. Any failure stops the scenario; later
  assertions are not considered exercised.

The script checks JavaScript strings with strict equality. JavaScript strings
and UIKit text input offsets use UTF-16; neither normalization nor a
code-point-only comparison is used. The synthetic fixture must not already
match the `台詞` search query. Any collision fails explicitly.

### Encoded profile-size rejection

The encoded-size input is the frozen baseline's exact Biography fixture:
U+0001 repeated 12,000 times. Its 12,000 UTF-16 units are below the 20,000-unit
notes limit. Its JSON string alone is over 65,536 bytes because every control
character must be escaped. The local JSON byte-count assertion only describes
this synthetic fixture; it does not substitute for the application's encoder
or validator.

The test uses the normal CLI `text` command against the native Biography
`UITextView`, waits for strict equality with all 12,000 code units, and checks
the saved profile is still unchanged. It then presses the real Save button and
requires the exact native error:

> This character's complete profile exceeds 64 KiB. Shorten its notes before saving; the draft remains here.

The same mounted input must still contain the entire exact fixture after this
rejection, and the complete saved character array and script entries must stay
unchanged. The test restores the original Biography before inspecting and
cleanly dismissing the editor. If UIKit sanitizes, truncates or refuses the
control characters, the scenario fails before claiming encoded-size coverage.
No model setter, helper invocation, package write or substituted input is used.

### Missing legacy character annotations

`WorkspaceStore.createCharacter` calls `CharacterMentions.bootstrap` before
appending the new profile. That operation fills only nil `characterLinks` from
the pre-existing catalog, preserving authored script wording and previously
explicit annotations. The first accepted catalog edit can therefore legitimately
change a legacy sample entry from no `characterLinks` field to an array.

The scenario allows only this missing/null-to-array transition during creation.
It still deep-compares every other entry field, including text, entry and word
IDs, order, speaker and all timing. If links were already explicit, it
deep-compares the entire entry without exclusions. Newly materialized links
must have nonempty unique IDs within their entry, remain unconfirmed, refer to
the pre-existing character catalog, occupy ordered non-overlapping valid
UTF-16 ranges, and contain the exact original source substrings. Completeness
of the suggestion matcher is a separate baseline, not claimed here. Every
later profile check compares all entries with the post-creation snapshot,
including the exact link IDs and metadata. No external package rewrite or
model mutation is used to establish this baseline.

## Frozen baseline mapping and remaining gaps

Inventory baseline: `4d14b29f4fb49891e850fa9a8e5742dc878603c8`.
The observations below are source-mapped candidate assertions, not execution attestation or baseline retirement approval.

- ID: `apps/catalyst/Tests/ScrivUIKitTests/CharacterTeamTests.swift::0006`
- Test: `testCharacterBoundsRetainUnicodeAndDoNotSplitCommaAliases`
  (original line 51).
- Frozen source SHA-256:
  `43b372703babd778c1112dcea4e9f8ce98f543cda9ea3fc14bbcfd12e8a6b80d`.

| Original assertion | Candidate observation | Remaining gap |
| --- | --- | --- |
| Line 53: the valid fixture passes validation | The saved name `台詞`, Biography `"  cafe\u0301\n"` and Appearance `"Warm light"` match the original fixture after native Save | Name input has surrounding spaces that the form intentionally trims, and the original `["Papa, Jr.", "🙂"]` aliases are absent here. |
| Line 54: aliases remain `["Papa, Jr.", "🙂"]` | Not covered by this scenario; see the separate alias candidate | The alias dialog's native action remains a separate gate. |
| Line 55: Biography retains exact UTF-16 leading spaces, accent and newline | Exact original Biography is inspected in the input, saved package and repeated reopened inputs, including after clearing/restoring it | Full baseline method equivalence remains incomplete because the alias fixture and assertion are absent. |
| Lines 56–57: 101 emoji exceed the 200-UTF-16-unit name limit | Submit the exact `🙂` repeated 101 times; require the native name error, untruncated draft and unchanged saved profile | This runs while editing with an empty alias array rather than the helper's full original fixture. |
| Lines 58–59: 20,001-character Appearance fails validation | Submit the exact `x` repeated 20,001 times; require the native notes error, untruncated draft and unchanged saved profile | This runs while editing with an empty alias array rather than the helper's full original fixture. |
| Lines 60–61: 12,000 escaped control characters exceed 64 KiB | Enter exact U+0001 repeated 12,000 times through Biography; require all native code units, the distinct 64 KiB error, an untruncated draft and an unchanged saved profile, then restore original notes | This runs while editing with an empty alias array rather than the helper's full original fixture. |

The empty new-form and draft-isolation checks supplement
`character-validation.mjs`, but do not replace the helper's complete immutable
project assertions in `CharacterTeamTests.swift::0005` or the legacy SwiftUI
presentation-state assertions in `CharacterFormTests.swift::0002`. The old
tests must remain until their full assertion sets have verified equivalents.

Colour changes, multiline edits, clear/restore, idempotent Save, canonical-only
notes replacement, and repeated clean reopening are additional acceptance
coverage. This scenario does not
exercise alias mutation, dirty-draft discard, project/account navigation during
an edit, competing edit leases, remote conflicts, portraits, launch recovery,
or the exact 20,000-character accepted boundary. It does not inspect palette
pixels or claim that the selected swatch artwork reflects persistence.

### Canonical-only save regression

Initial source inspection identified the early equality return in `WorkspaceStore.updateCharacter`: Swift `String` equality treats canonically equivalent spellings as equal.

Expectations were not weakened to canonical equality. This scenario/document slice makes no production change. A failure still stops the scenario, so later assertions must never be credited to an earlier failing run.
