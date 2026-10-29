# Stable inline character links

Character links annotate the exact authored script text; they never rename or normalize prose. Speaker IDs, image tags, and character discussion threads remain separate stable identities.

## Review and correction

- Confirmed names open the same character profile even after its name or aliases change, or another profile reuses its old name.
- Old projects and newly typed name matches receive lightly highlighted **suggestions**, not silently assigned identities. Select the line's **Review character suggestions** button, or **Review character links…** in its context menu.
- Confirm all suggestions in that line at once, confirm one, choose a different character, or **Keep unlinked**. Save commits only annotation metadata.
- **Link other wording** finds exact occurrences of a phrase without changing it. Choose the intended character for a specific occurrence; different occurrences of the same name can refer to different people.
- **Find more name suggestions** explicitly scans untouched prose against the current catalog. Normal display does not repeat that scan after a line has been initialized.

Before a profile is added, renamed, has aliases changed, or is deleted, legacy suggestions are frozen against the *previous* character catalog. New profiles therefore cannot automatically acquire old wording. Deleting a character retains an explicit unlink at its old annotated ranges. Historical documents without annotations cannot prove the identity intended before an earlier rename, so their guesses remain reviewable.

## Persistence and edits

`ScriptEntry.characterLinks` is optional for backward reading. Missing/null means legacy, not yet initialized; `[]` means initialized with no links. A link stores a unique annotation ID, optional `characterId`, `location` and `length` in UTF-16 units, exact `text`, and `isConfirmed`. A nil character identity is a confirmed explicit unlink. Ranges must be sorted, nonoverlapping, within scalar boundaries, and match the source text exactly.

Native text-edit events preserve unaffected annotation IDs and adjust their offsets. Editing inside a linked name revokes that occurrence's old assignment and may offer a new unconfirmed suggestion. Without exact edit events, repeated-name ambiguity is conservatively returned to review rather than guessing which occurrence survived. Merely editing elsewhere never rebinds old text to newly created profiles.

Local packages, history, and generic cloud entry records carry the same fields. Established annotation arrays cannot be silently omitted by legacy cloud writers; the server rejects such a write clearly instead of discarding identities. An explicit empty array remains a deliberate reset, and explicit historical restore remains supported.

Generation context reads confirmed annotation identities, not name guesses. Speaker identities and explicitly tagged image characters remain independent sources of context.

## Focused verification

`CharacterMentionTests` covers legacy decoding, reviewable bootstrap, rename/alias removal/name reuse, exact-word corrections and unlinks, repeated identical names, Unicode offsets, multi-edit reconciliation, token-boundary changes, malformed ranges, local/cloud round trips, and timing-editor integration. Linux core tests and Swift parsing do not certify native macOS rendering.
