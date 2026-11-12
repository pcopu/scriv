# Character portrait stored-menu route

Status: v70 **native-unverified candidate**. This adds a narrow CLI route for the
existing Choose/Remove portrait operation (CHR-21), not complete app parity,
physical menu coverage or proof that the native build runs.

## Public action contract

`menu` observes the already-installed `character-portrait-options` button menu.
`menu-action` accepts exactly the normal protocol id plus:

```json
{"command":"menu-action","target":"character-portrait-options","scope":"character-portrait-options","action":"Use Image · v2","characterID":"CURRENT_CHARACTER_ID","imageID":"TAGGED_IMAGE_ID"}
```

For Use, `imageID` identifies the chosen tagged asset and `action` must be its
exact current installed title. Re-observe after mutations: an unplaced image's
name can change from Image to Ada portrait after assignment. Selection of the
already-current portrait reaches the production no-op guard.

For Remove, use action `Remove portrait` and `imageID` equal to the current
stored portrait pointer. A wrong/stale image ID, absent pointer or untagged asset
fails before dispatch. No optional flags, arbitrary action names, target path
aliases, file paths or handler names are accepted.

The helper calls `UIButton.sendAction` on the original owning button and stored
UIAction once. It does not rebuild a menu, register/relay an action, extract its
closure, call a selector or invoke a Store setter. This is semantic public menu
action dispatch, not opening/choosing a native menu or generating a pointer event.
It does not load the denied accessibility bridge or operate any alert.

## Guarded scope

- Current owned offline synthetic project/package, with existing read-only
  loaded-model and allowlisted local-image byte/decoder evidence.
- The actual mounted Script/Characters panels share the workspace store. No
  modal, discussion/account UI, source draft, playback, sync, conflict,
  generation, analysis scan or character creation is in progress.
- The selected character matches the complete empty-search ribbon and actual
  rendered profile. Every tagged asset is local. The menu has exactly the
  production inline sections, titles, attributes and checkmarks, with no
  duplicates, providers, commands or unrelated actions.
- The shared dispatcher still requires a unique active, enabled, hittable target.
  The helper revalidates model, navigation, controller/control/menu/action identity
  and existing file evidence before the one dispatch. No mutation is retried.

A compile-gated read-only Script readiness predicate refuses active/acquiring/
applying/pending or unresolved drafts and pending boundary/caret work. It never
finishes or discards a draft. It uses the actual boundary-pending flag, since a
completed boundary Task handle can remain cached. Production lifecycle behavior
and the existing insertion readiness predicate are unchanged.

## Continuous film acceptance plan

FILM-J01 keeps its original project and sentinel. Its fifth chapter:

1. Rejects an untagged version borrowing another image's title, a wrong rendered
   character, removal with no stored pointer, and an extra request key.
2. Selects version 2 through the real picker, tags Ada, then returns the picture
   cue to historical version 1. The two imported 2×2 PNGs remain unchanged.
3. Chooses version 2 as Ada's portrait, reselects it with no revision or Date-bit
   change, rejects stale removal identity, removes the pointer and restores it.
4. Chooses version 1 as Béa's portrait. Exact whole-model comparisons permit only
   the expected pointer/revision/modifiedAt change. Source, words, confirmed
   links, cue/image IDs, tags and immutable project/image Date bits stay exact.
5. Later profile edits retain both portraits. History/model checks, project
   reopen and cold reload retain their relationship to the same two image assets,
   while the film's cue still displays version 1.

Removal clears only the stored portrait choice. The production portrait view
may still display its first-tagged-image fallback, so no blank-avatar assertion
is made. Crop/analysis semantics, remote/missing images, ambiguous menu titles,
leases/races, other menu variants and pixel rendering remain separate gaps.

## Verification limits

Run through `tracer app -- test --scenario journeys/short-film` with a matching
native automation build and sufficient timeout, as documented in
[the film journey](short-film-journey.md). App-free listing, syntax, registry,
repository/type checks and portable Tracer tooling do not execute this UIKit
route. This executor has no Darwin/Catalyst compiler; compilation, real UIAction
execution, guard failures and measured native coverage remain unverified.
The fixed alias scenario block and prior Library Validation denial are unchanged.
