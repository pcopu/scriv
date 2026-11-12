# Make and revise a short film

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

The goal of this outcome-first Tracer journey is to reach a reopened, internally
consistent two-scene film through one continuous real-app workflow, then work
backward from that outcome to the required interactions and assertions.

## Run through the actual CLI

```sh
tracer app -- test --list --scenario journeys/short-film
mkdir -p /absolute/evidence/directory
tracer app -- test --scenario journeys/short-film --timeout-ms 600000 --output-dir /absolute/evidence/directory
```

Native execution requires the matching automation-enabled Catalyst bundle and
the runner's normal source/build provenance inputs. Without macOS or a valid
bundle the runner records **not-run**, not success. The longer explicit timeout
is appropriate for this multi-chapter workflow. All-scenario runs retain the
runner's existing default timeout unless the caller overrides it.

Static, app-free plan inspection:

```sh
node tests/e2e/journeys/short-film.mjs --list-cases
```

There is no per-chapter selector. A failure stops the story, reports the chapter
and closes its owned app session. The runner never retries an uncertain mutation.

## Continuous outcome and assertions

One `ScrivSession` launches with opt-in workspace persistence. The startup
synthetic project is saved as a complete sentinel. The real New project control
creates a second project; the first ten chapters continue in that process.
The eleventh terminates it and starts a second real process in the same owned
workspace. No JSON/Fountain fixture import, storage reset, or helper-owned
replacement project occurs. Default sessions still always create fresh roots.

1. Create a project and rewrite its opening direction. Preserve the complete
   sentinel, not merely its script text.
2. Create Ada and Béa through the character form, including biographies,
   appearances and colors. Search the cast and write the opening dialogue.
3. Add dialogue, replace a decomposed accent using an exact native UTF-16 range,
   and confirm Ada's source link. Source and identity remain separate.
4. Import two generated 2×2 PNG versions through the production post-picker
   importer, select the first historical version and tag both characters.
   Verify real file hashes, decoder dimensions and visible preview evidence.
5. Exercise [character portrait choices](character-portrait-menu.md) through the
   original stored menu actions. Reject wrong/untagged image identity, wrong
   character, missing portrait removal, extra arguments and stale removal.
   Tag Ada in version 2, return the cue to version 1, choose version 2 for Ada,
   reselect it without any revision, remove and restore it, and choose version 1
   for Béa. Preserve source, tags, cues, image bytes and immutable Date bits.
6. Import generated PCM attached to dialogue, cancel then commit trim changes,
   adjust clip volume/mute, add scene audio and adjust master volume. Append
   source text and prove its confirmed link, old word identities, audio anchors
   and other content survive.
7. Create a second scene, author its direction, cancel then apply owned duration,
   and add dialogue. Verify that insertion extends direction coverage and creates
   the second scene's first picture cue, without altering the first scene's media.
8. Rename Ada to Ada Vale through the existing character editor after all media,
   source annotations and audio attachments exist. First edit and restore every
   draft field, then clean-cancel without entering a discard alert. Reopen and
   commit the name, biography, appearance and color once. Preserve every source
   byte, word/speaker/link ID, old confirmed wording, image tag and audio anchor.
   Reopen the profile and observe the updated name on the already-tagged image.
9. Play/pause the real scene clock, switch tabs, find/advance/return, revise the
   ending, undo/redo the complete film, then review a known prior local revision.
   Each Undo and Redo must create exactly one revision, retain immutable native
   project/image Date bits, immediately preserve the complete sentinel, and leave
   no alert. The loaded and persisted film must match every expected content field.
   The subsequent history preview is read-only and must not change any saved field
   or exact Date witness.
10. Save, open the sentinel and reopen the film through the normal project browser.
   Compare every model field and native Date bit, all five source entries, both
   character profiles and portrait pointers, confirmed identity, image lineage/tags/selection, both
   audio placements, mix, owned duration and authored coverage.
11. Close the first app and cold relaunch through its retained ownership
   descriptor. Require the same workspace UUID/root and a new process-session UUID.
   Before saving anything, verify exactly the original two persisted packages,
   then open the film through Projects. Compare every model field and native Date
   bit again, check decoded picture bytes and each available local audio clip's
   own card. The dialogue clip must show the renamed cast member, a 37 percent volume display
   and its saved trim/offset fields; the scene track must retain its separate
   100 percent volume, scene attachment and timings. Open each real Trim & timing
   editor and cancel without changing any project field, revision or native Date
   bit. Retained portrait pointers and the same renamed character ribbon must
   survive. Reopen that character through Edit and compare the actual name,
   biography and appearance fields, including accents, trailing spaces and line
   breaks. Clean Cancel must retain the full film and sentinel. This does not
   claim selected-colour pixels or dirty-discard confirmation. The new process's
   unsaved startup sample must not become a third package. See [owned workspace safety](cli-persistent-workspaces.md).

Generated UUIDs and timestamps are observed and validated, then retained as
immutable relationship witnesses. Expected mutations are explicit; observation
of arbitrary output is not treated as a complete behavior oracle. Read-only
observer polling is bounded and does not repeat imports, edits or menu actions.

## Scope and remaining gaps

This adds a cross-feature journey alongside the existing Tracer CLI scenarios.
It does not delete their distinct error/boundary coverage or promote any frozen
legacy assertion to accepted. App implementation and app CLI remain included in
Tracer coverage; scenario/support files remain under the explicit `tests/`
ignore. Existing source-to-scenario links and historical measurements are not
refreshed or relabeled by adding this candidate.

The project keeps the UI's default title because project/scene rename alerts do
not yet have a verified public confirmation route. Character profile rename uses
the existing ordinary editor, not an alert; clean Cancel is not dirty-discard
confirmation coverage. The [public alert audit](public-alert-observation.md#current-route-audit)
records the distinct presentation, scope and Library Validation blockers. Portrait
choice/removal uses original stored public UIActions, not physical menu input.
Portrait crop/analysis, missing/remote images and arbitrary image-card menus remain
uncovered. Removing a stored portrait can still display the first tagged image
through the app's normal fallback. Separate scenarios still own
split/merge, word timing, dialogue duration, picture coverage editing, audio
reattachment and validation boundaries. This story does not cover aliases,
delete/restore confirmation, arbitrary table/context-menu selection, physical
gestures, IME, file pickers, microphone, actual audible output, crash/power-loss
recovery, package roundtrip, provider generation, cloud/account or collaborative
service behavior. The cold-reload chapter does not enable
automatic startup recovery or persistent account preferences.
Spoken-word assertions check exact tokens, valid ordered endpoints and retained
word identities. They do not supply an independent literal oracle for every
automatic retiming endpoint; those numerical cases remain separate coverage.

Portable syntax, registry, CLI routing and tooling checks establish preparation and dispatch only. Source/branch coverage still requires a matching instrumented execution and is not claimed here.
