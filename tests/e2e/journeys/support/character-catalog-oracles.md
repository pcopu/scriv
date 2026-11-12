# AUT-J05 character catalog oracle reconciliation

Status: authored consolidated runner; native execution pending. Existing native slice evidence does not transfer automatically. This is the catalog portion of AUT-J05, not certification of the complete interaction inventory.

Runner: `tests/e2e/journeys/character-catalog.mjs`.
Shared actual-UIKit steps: `character-catalog-steps.mjs`.
Synthetic cases and declared oracles: `character-catalog-cases.mjs`.

Each group is an independent workflow and launches/closes a fresh isolated app. `--list-cases` (optionally with `--group`) inventories workflows without launching. A PASS is emitted only after every assertion in that workflow succeeds. No legacy scenario is imported or executed.

## create-find-reopen

Reconciles `character-validation.mjs`:
- Save the synthetic baseline with the actual workspace command; select Characters and read the app-owned saved package.
- Opening an empty create form exposes an empty Name and disabled Save. Clean Cancel does not create a placeholder or change any existing character.
- Whitespace-only Name disables Save. Exactly 201 ASCII UTF-16 units enable the action but fail native validation with the original exact error text; the mounted draft and saved character array remain unchanged.
- Restore the exact empty draft, cancel without dirty-discard UI, and verify unchanged saved characters.
- Save `CLI Validation Zéphyr`; verify baseline project identity, exactly one new character and exact name.
- Search for the original unmatched query; assert the no-results text and zero ribbons. Clear search restores the empty field and complete created catalog count.
- Lowercase matching yields exactly the new character's ribbon and exact label. Select by saved ID, edit, verify exact Name and enabled Save, cancel, repeat reopen/cancel, and compare the complete character array.

## edit-profile

Reconciles `character-profile-fields.mjs`:
- Preserve fixture noncollision and decomposed-accent preconditions. All three new fields are empty; name with outer spaces remains exact in the draft and is trimmed on save. Biography whitespace, decomposed accent, and trailing newline remain exact.
- Purple then Pink remains actionable after rerender. All eight palette labels are present, and the exact opening label multiset (including possible custom-color duplicate labels) remains unchanged.
- Unsaved fields/color leave both complete characters and entries unchanged. Creation adds exactly one character with exact profile values and empty aliases; all old characters remain identical.
- Preserve every entry and explicit characterLinks array. Only absent legacy links may materialize. Every inferred link has a nonempty unique ID, is unconfirmed, references an old character, and has an ordered nonoverlapping in-bounds UTF-16 range whose text matches the original source slice.
- Subsequent saves change only the target character's intended fields; all other character fields and every entry/link field remain identical to the created package.
- Exact 202-unit emoji Name and 20,001-unit Appearance retain the full draft and show the original exact form errors, with Save still enabled and the package unchanged.
- Exactly 12,000 U+0001 units remain below the field limit, exceed 65,536 bytes when JSON-escaped, and remain exact in native UITextView before Save. Assert the distinct original 64-KiB error, retained full draft, enabled Save, and unchanged saved profile. Restore every field and clean-cancel without resolving a dirty-discard alert.
- Save multiline notes containing decomposed/composed accents, CJK and emoji, with Orange. Reopen/resave unchanged; clear both notes with Green; save/reopen/clean-cancel; restore original exact notes with Pink; repeat clean reopening twice. Every draft and saved transition has its original exact field and package oracles.
- Establish decomposed Appearance, then normalize Biography alone and Appearance alone, separately. Each replacement differs in exact UTF-16 while remaining canonically equivalent; drafts do not publish, Save persists the exact replacement, and reopen/cancel preserves it. Canonical equality alone cannot satisfy these assertions.

## search-focus

Reconciles `character-search-escape.mjs`:
- Fresh catalog contains Randy and Miyazaki and an empty search. Save every baseline ribbon identity.
- Twice: enter Miya using the actual native text callback; assert search first-responder status, Miyazaki present, Randy absent and a smaller catalog.
- Assert exactly one CharactersController Escape command, no modifiers, clearSearchCommand action, priority over system behavior and enabled eligibility.
- Dispatch the public Escape key. Assert empty text, resigned first responder, Randy restored and the entire sorted baseline ribbon identity set restored. Assert command eligibility is now disabled.

## Limits and checks

Aliases remain in their separate blocked slice. No alias/dirty-discard alert resolution, deletion, conflict/lease outcomes, process relaunch persistence, Return variant, physical gestures, AppKit helper, private action, clipboard, provider/account, security or production change is introduced.

Native command: `SCRIV_E2E_APP=/path/to/automation/Scriv.app node tests/e2e/journeys/character-catalog.mjs`. Run individual workflows using `--group create-find-reopen`, `--group edit-profile`, or `--group search-focus`.
