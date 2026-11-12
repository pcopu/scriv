# Exact character-profile spelling

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

## Reproduced failure

The scenario establishes decomposed notes, changes only one field to composed
Unicode, and requires the exact new UTF-16 content in the saved package and
reopened editor. A simultaneous colour or name change must not force the save
and hide this defect. Its strict assertions are unchanged by this fix.

## Cause and minimal production change

`ScriptCharacter` previously used synthesized equality. Swift String equality
considers canonically equivalent composed and decomposed text equal.
`WorkspaceStore.updateCharacter` therefore returned success before changing
the project when the only edit changed that spelling. Fixing only that early
return would be insufficient: the project's no-op check, the form's dirty and
conflict checks, save snapshots and cloud changed-item detection also compare
the same character values.

`ScriptCharacter.==` now compares the authored name, ordered alias strings,
Biography and Appearance with exact UTF-16 element equality. ID, colour,
portrait image ID and portrait region keep their previous comparisons.
Synthesized hashing remains valid: equal characters still hash equally;
canonically equivalent but unequal values may share a hash, which is allowed.

The name/alias change guard in `WorkspaceStore.updateCharacter` also uses exact
UTF-16 comparisons before `CharacterMentions.bootstrap`. This preserves the
existing rule that legacy suggestions are frozen against the old catalog
before any authored name or alias spelling changes. Notes-only edits do not
trigger catalog bootstrap.

No form validation, name whitespace trimming, case-insensitive alias
deduplication, matching policy, serialization format or portrait behavior is
changed. The existing exact-string `JSONValue` equality from the earlier
script-text fix is preserved, not modified here. The UIKit form itself needs
no changes: its model comparisons now observe exact authored spelling.
