# Character alias actual-app candidate

**Blocked, not passing.** The current CLI lists this candidate with reason
`native-alert-route-library-validation-blocked`. Alias-only execution writes a
not-run report before app inspection or launch. Mixed runs keep this entry not-run
and run other eligible scenarios; they cannot become a full-suite pass. A mixed
coverage run is explicitly marked not-exported and does not import partial
measurements; select only eligible scenarios for measurement. Direct
entrypoint execution also exits 2 before launching anything.

```sh
tracer app -- test --list --scenario character-aliases
tracer app -- test --scenario character-aliases --output-dir /existing/evidence
```

The AppKit fallback has been removed from this scenario. Its deferred workflow
below may use only real UIKit controls/accessibility buttons and app-owned
saved-package exports after a separately authorized route has been established.
There is no command-line or environment bypass. Portable Tracer subprocess checks
verify blocked discovery, exact not-run evidence and direct-entry refusal. They
do not establish native alias behavior.

## Intended acceptance coverage

- Add `The Farmer` and `Franklin` through the Add alias dialog, then append
  `Papa, Jr.` with surrounding spaces. Assert the comma remains within one chip
  and existing values retain their order.
- Reject the case-insensitive duplicate ` frankLIN ` and a spaces-only alias.
- Add `🙂` without corrupting Unicode. Cancel an entered alias and verify it
  never becomes a chip or persisted alias.
- Observe that creation remains a draft until Save, then inspect the exact
  ordered alias array in the saved package and reopen the same character.
- Search for `pAPA, jR.` and the emoji through the native search field. Compare
  the full set of mounted ribbon identifiers, not just the character's name.
- Remove a middle chip and then the first chip, proving the rerendered chip
  actions still remove the correct values. Save the exact array
  `["Papa, Jr.", "🙂"]`, confirm the removed `The Farmer` alias produces the
  empty search state while `Franklin` matches only the untouched original
  Farmer Franklin profile, and reopen to inspect the retained chips.
- Remove the comma-containing alias, save, and confirm it stops matching.
  Re-add it, verify it is appended after the emoji, save, search, and reopen
  again. A final clean Cancel preserves the saved aliases.
- Compare all original character profiles and script entries, including
  existing link metadata, after alias saves. Only the synthetic new character's
  aliases may change during the subsequent edits.

The fixture must not already match the new profile's unique search names or
emoji. Its original `character-franklin` profile is checked separately before
creation and after alias removal, proving that removing an alias from one
character does not remove another character's matching alias. Unexpected
fixture collisions fail explicitly rather than silently weakening expectations.

## Exact frozen baseline mapping and gaps

Inventory baseline: `4d14b29f4fb49891e850fa9a8e5742dc878603c8`.
All mappings below are **unverified candidates**, not retirement approvals.

### Alias helper behavior

- ID: `apps/mac/Tests/ScrivAppTests/CharacterFormTests.swift::0003`
- Test: `testAliasChipsTrimNewAliasWithoutSplittingOrReorderingExistingNames`
  (original line 29).
- Frozen source SHA-256:
  `8d951589f92bf63da49aaee76e09ab2308c1e146706a7f80e2ec8cfc3d3b3d63`.

| Original assertion | Candidate observation | Remaining gap |
| --- | --- | --- |
| Line 31: append `"  Papa, Jr.\n"` to `["The Farmer", "Franklin"]` as one trimmed alias, preserving order | Actual form appends `"  Papa, Jr.  "`, checks all chip values and their order, then checks the exact persisted array | The single-line alert field is exercised with spaces, not the helper's literal newline input. This is not complete equivalence. |
| Line 32: `" frankLIN "` does not add a duplicate | The identical input is submitted through the dialog; the complete chip array and saved array contain only the original `Franklin` | Native run remains pending; the legacy SwiftUI helper implementation itself is not invoked. |
| Line 33: `" \n"` does not add an alias | A spaces-only dialog submission leaves the complete chip and persisted arrays unchanged | The exact newline-containing helper input remains untested. |

The old test covers the legacy AppKit/SwiftUI form helper. These are acceptance
observations of the current UIKit application, not proof of the retired target's
implementation behavior. The old code tests were removed at the user’s explicit
request; preserve the frozen inventory and unresolved assertion gaps.

### Unicode and comma preservation in validation

- ID: `apps/catalyst/Tests/ScrivUIKitTests/CharacterTeamTests.swift::0006`
- Test: `testCharacterBoundsRetainUnicodeAndDoNotSplitCommaAliases`
  (original line 51).
- Frozen source SHA-256:
  `43b372703babd778c1112dcea4e9f8ce98f543cda9ea3fc14bbcfd12e8a6b80d`.

| Original assertion | Candidate observation | Remaining gap |
| --- | --- | --- |
| Line 53: valid character metadata passes validation | Saving a Unicode-named profile with comma-containing and emoji aliases succeeds through the real form and reaches the package | The original exact `台詞` name, biography, and appearance fixture is not reproduced. |
| Line 54: aliases stay `["Papa, Jr.", "🙂"]` | The saved array and reopened chips equal that exact array after middle/first removals | Native run remains pending. |
| Line 55: biography retains leading spaces, combining accent, and newline in UTF-16 | Not covered | Exact biography preservation remains open. |
| Line 57: a 101-emoji name exceeds the UTF-16 name limit | Not covered | Unicode name limit remains open. |
| Line 59: a 20,001-character appearance fails validation | Not covered | Appearance length limit remains open. |
| Line 61: escaped control characters exceeding 64 KiB fail validation | Not covered | Encoded profile byte limit remains open. |

The additional add-dialog Cancel, alias removal, saved-package persistence,
reopening, and alias-search assertions are new acceptance coverage. They do not
claim retirement credit for unrelated link resolution, confirmed-mention
identity, lease/conflict, or durability tests. Relaunch recovery, dirty-editor
discard, 100-alias bounds, and the 500-UTF-16 alias limit are not exercised.

## Native action and validation gates

`Add alias` opens a `UIAlertController`. The scenario now
prefers the original `activate` route when exactly one such control exists.
Only when there are no matching actionable controls may it select exactly one
hittable accessibility element with button traits and no disabled trait. Both
routes require an exact accessible label or button title; matching a descendant
label's text is insufficient. Multiple matching controls remain a blocker.

The second route uses the provisional `accessibility-activate` command, which
calls the public native `accessibilityActivate()` method under the same
active-presentation and hittability checks. An absent qualifying Add or Cancel control cannot be treated as a passing interaction.

The AppKit fallback is not a supported execution route. Both native helper calls are removed, and the scenario is blocked at the runner and direct entrypoint boundaries.
The native adapter implementation remains unchanged and is not loaded by these
checks. No signing, entitlement, accessibility permission, private selector,
UIAlertAction closure, or direct model-write workaround is used.

If a permitted UIKit route is established later, the preserved candidate still
requires an exact enabled/hittable UIControl or qualifying UIView accessibility
button, rejects ambiguity, selects one route before dispatch, and never retries
an unsuccessful or uncertain mutation through a second route. No denial is
converted into passing acceptance coverage.

- Node syntax and portable Tracer refusal checks run on the Linux executor.
- Native alias Add/Cancel, alias validation and persistence remain unverified.
- The frozen inventory remains unchanged; no baseline retirement or parity claim.
- See [public alert route audit](public-alert-observation.md#current-route-audit)
  for the separate scene-menu and history-confirmation gaps.
