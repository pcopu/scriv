# Native UI parity refinement — Doppler working tree

## Evidence actually inspected

The four **current** PNGs in `design/images/` were opened and visually inspected,
not inferred from the archived iterations. The three existing native captures in
`docs/screenshots/` were also opened. Those older captures remain untouched:
they are evidence for their recorded earlier commit, not for these changes.

The implementation remains native **SwiftUI + AppKit**. UIKit is an iOS framework;
replacing the Mac view tree with it would not create faithful native Mac parity.
No browser facsimile or synthesized application screenshot was used as proof.

## Acceptance matrix for transcript reconciliation

“Parsed” below means Swift frontend syntax checking, **not** Apple-framework type
checking. “Geometry” and “mentions” refer to the seven and three passing focused
tests described below. None of these rows has a fresh native screenshot pass yet.

| Screenshot feature | Implemented control / behavior | Actual verification | Remaining gate |
| --- | --- | --- | --- |
| Script typography, shared text edge, blue-gray native panels | Larger script/speaker/time text, aligned rows, current-passage scroll, continuation label, find-next/previous with result counts | Approved pixels inspected; source parsed | Native layout at reference/minimum window sizes; dark appearance |
| Fixed direction anchors, overlapping colored ranges, lower handles | Shared phase-interleaved rail, source/end selection, overlap picker, keyboard adjustment; zero-owned notes take no time | Geometry: gaps, plateaus, round trips and collisions passed; source parsed | Real pointer/keyboard dragging, coincident endpoints, remote leases |
| Separate owned duration and coverage | Validated duration popovers in script/layers; lower handle edits coverage only | Wiring reviewed; geometry clamps passed | Native Cancel/Apply, minimum values, undo and live-conflict feedback |
| Individual word pills, rectangular selection, phrase-to-neighbor drag | Click/Command/Shift selection, marquee, drag/drop and context actions; no wording/order changes | Geometry: source-preserving row grouping passed; source parsed | Actual marquee/drop gesture priority and cut updates |
| Image sequence and shared cuts | Responsive two-/three-column rows, physical cut handles, duration pills, add/split/merge/remove actions, searchable existing-asset reuse | Geometry: positive-duration cut limits passed; store API wiring reviewed | Native drag, repeated actions, removal/undo, stale-selection handling |
| Wide preview, layers, playhead and overview | Full-width 16:9 preview, expanded preview/layers, selected-cue recentering, visible-range indicator, paused current-word highlighting, Characters Play/Pause | Source parsed; no replacement image renders | Fresh native captures and end-to-end scroll/seek/playback |
| Character names/aliases, profile and tagged-image gallery | Tested name resolver, search/empty state, profile editor, tags, portrait selection, image detail | Three mention tests passed, including ambiguous aliases and Unicode; source parsed | Native link/tag/edit navigation and profile/image identity persistence |
| Immutable regenerated image versions | Version popover changes only selected placement; older assets/discussions retained | Version-helper/store wiring reviewed; source parsed | Real regeneration, late result, version restoration and discussion checks |
| Editing/collaborator state | Navigation-context-fenced acquisition/save/release; stale requests cannot reopen editors or affect another project | Source review/parse; cloud/core tests tracked separately | Two signed-in clients, interrupted leases, A → B → A navigation |
| Discussion, real member mentions and archived threads | Authorized-member @picker with stable IDs and removable chips; in-app unread badge/activity, focused-message navigation, old/resolved/deleted-item conversation browser | Native API wiring/source parsed; durable server/client behavior covered by backend/core owners | Signed-in multi-client acceptance; no email or push delivery is claimed |
| Local Codex controls and generation | Actual Start/Stop/Connect/account controls; inline generation status/cancel; durable job/recovery UI owned by Codex integration worker | Native API wiring/source parsed; no fabricated account/runtime | Actual authorized runtime acceptance |
| Audio, volume and waveforms | Real imported local recordings; measured PCM peaks; master/clip volume and mute; entry anchors, source trims, draggable audio lanes and removal | Audio helper/store APIs reviewed; source parsed; engine/core evidence recorded by native worker | Native playback/device acceptance; no TTS, cloud audio upload or automatic speech alignment is claimed |

The core owner separately expanded the preserved sample to the full 56.3-second
scene with 16 authored timed slots plus two zero-owned notes. Reference wording,
timing and stable IDs are not replaced by text extracted from a screenshot at
runtime. Original design/sample media digests are unchanged.

## Checks performed here

- Seven `PresentationGeometryTests` passed with Swift 6.4.1 on Linux: row/gap
  interpolation, zero-time plateaus, round trips and clamping, partial coverage,
  coincident handles, source-preserving storyboard grouping, and legal cut limits.
- Three `CharacterMentionTests` also passed after integrating the core resolver
  into the real linked-text view (10 focused tests total at this checkpoint).
- The changed SwiftUI/AppKit source was parsed with the Swift compiler frontend.
  Parsing is **not** Apple-framework type checking or a native build.
- `node scripts/check-repo.mjs` verified all 25 original design images and all three
  original sample images against their manifests.
- `git diff --check` passed at this checkpoint. Other workers own aggregate test
  reports; this note does not replace those reports.

## Reproducible native capture contract (implemented, not run on Linux)

`Scriv --screenshots <fresh-empty-output-directory>` now requests a 1448 × 1086
window, uses the 29.4-second sample moment, and emits:

1. `01-script.png`
2. `02-characters.png`
3. `03-storyboard.png`
4. `04-collaboration-local.png`
5. `04-codex-popover.png`

The fifth PNG is necessary because a real `NSPopover` is a **separate native
window**. It is captured separately, not composited into the fourth PNG.
`capture-metadata.json` records schema version, exact PNG pixel dimensions,
AppKit window frames/content bounds, selected tab/items, playhead, discussion
visibility, actual Codex state and actual collaborator/message counts. A success
marker is written only after all five captures and metadata succeed. Nonempty
output is rejected so stale files cannot masquerade as a current pass.

The collaboration capture intentionally uses the real local/signed-out state;
it does not fabricate online peers, messages, accounts or a connected Codex runtime.

## Remaining acceptance gates

**Visual parity is not yet verified for this working tree.** This Linux host cannot
compile/type-check SwiftUI/AppKit, launch the Mac application, or capture its real
windows. An authorized Mac executor must build and review fresh native captures,
then exercise window resizing, scrolling, repeated clicks, cancel/back navigation,
word marquee/drop, overlapping rails, duration edits, version changes and live
lease interruptions. Both light and dark appearance need that native review.

Real signed-in collaboration and an actual local Codex runtime require their own
account-bound integration acceptance. There is no basis for treating the local
fourth-state capture as evidence that those external services are configured.

The three existing sample assets are not the generated photograph set inside the
four design concepts. Exact picture/portrait equality therefore is not claimed.
Source image bytes have not been cropped out of concept art or relabeled as new
native evidence. Audio controls now operate on real imported local recordings and
measured samples. They do not imply synthesized dialogue, automatic transcription,
word-level audio alignment or cloud audio transfer. Those are not silently added.

## Final UI code scope

All controls in the matrix are connected to implemented model/store operations,
not mock actions. Native runtime/visual acceptance remains separate from finishing
this code. Read-only intent reconciliation may identify product questions; this
pass does not change word-drag timestamp semantics or other disputed behavior.
