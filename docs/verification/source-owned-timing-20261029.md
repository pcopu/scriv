# Source-owned pictures and authored word timing — 2026-10-29

## Ownership rule

An image cue now stores a `startAnchor` (`entryId`, entry-relative `offsetMs`) and an `authoredDurationMs`. `startMs` and `endMs` remain the resolved scene projection. Its **source** owns all forward coverage, including the portion over later entries; covered children do not own fragments of that picture.

Reordering changes neither authored extent nor cue/image/version identity. A moved parent's outgoing image and direction coverage travels with it and covers its new successors. An incoming parent's coverage remains with that original parent and covers the replacement successor. Direction `coverageDurationMs` and every owned slot/word/audio record stay unchanged by reorder.

If pictures overlap, playback chooses the cue with the latest start; equal starts use the stable cue-ID order. When a short foreground cue ends, the underlying cue can reappear. There is no image blending, fragment cloning, automatic merging, deletion or version retargeting. Layers/Storyboard expose overlapping placements, and preview selection can inspect an underlying image. Shared-cut dragging is available only for a genuinely shared, unobscured boundary. Independent image-coverage editing remains available.

The resolved end is `min(sceneDuration, startMs + authoredDurationMs)`. Moving a cue near the scene end clips its projection, not its authored extent; moving it back or adding later content restores the extent. A zero-owned direction can explicitly own an image at offset zero. At the exact scene end, that cue is dormant (`startMs == endMs == sceneDuration`) while its authored extent remains positive; it is excluded from playback/cut gestures and reappears when following scene time is added. An edit that would erase authored coverage is rejected transactionally rather than silently deleting the cue.

## Migration and later edits

Old JSON remains readable: both new cue fields are optional as a pair. Before a timeline edit, legacy scene cues are anchored at their existing start to the positive owned slot containing that instant. At a shared boundary, that is the following owned slot; an ambiguous coincident zero-second note is **not guessed** as the owner. The source picker can explicitly choose that direction. Migration occurs in the same undoable edit, preserves IDs/assets/versions/prompts, and does not rewrite legacy files merely by reading them.

Inserting content does not silently assign another line's picture to the new line. Existing sources and authored extents are retained, so a new uncovered interval may need an image. Deleting a source deliberately removes its owned cue placements but retains image assets and historical snapshots. Deleting a covered child does not delete its parent's image. Explicit owned-duration changes remap affected timing while retaining source identity; a collapsing placement is rejected rather than discarded.

Server validation verifies source/scene/offset and the resolved projection; overlap is accepted only between valid anchored cues. Anchor and authored-extent changes participate in live/offline timing fences even when a scene-end clamp leaves the visible endpoints unchanged. Older writers cannot strip established anchors or authored word markers. A deliberate local undo/restoration upgrades the historical geometry and preserves authored markers on surviving word IDs, rather than bypassing the guard with a label.

## Real word timing, separately from image cuts

`setWordTiming` changes an individual word's actual entry-relative start and end. `shiftWords` shifts one word or a contiguous same-line phrase while preserving its duration. Both preserve exact text/order, cue geometry, source duration, image lineage and audio metadata. They neither generate nor align, stretch or rewrite audio.

Word times must remain positive-duration, nonoverlapping, source-ordered and inside the line. Any interior word can be shortened with the precise editor, even when the initial estimates are contiguous. A body drag needs available silence; collision errors explain how to trim a word or its neighbors to make room. The separate existing word-to-image drag continues to move a shared image cut, not speech.

Edited words carry `timingSource: "authored"`. Subsequent text edits retain matching IDs and authored endpoints, estimating only intervening unpinned spans. Whitespace-only edits preserve all timings. Duration/text changes that cannot fit around authored words fail without mutation and explain the needed timing adjustment. Existing files without this optional marker remain editorial estimates, not claimed speech-recognition alignment.

## Verification boundary

Portable Swift tests exercise source-owned incoming/outgoing overlap, tail restoration, zero-owned sources and dormant-tail restoration, legacy coding, invalid anchors, cut rejection, source identity through owned-duration changes, local history restoration, offline timing conflicts, individual/interior timing, phrase timing, authored pins, unchanged audio/word/image metadata, and rejected-edit atomicity. Existing timing/editing tests also run.

Linux compilation and portable tests do not establish AppKit/SwiftUI interaction or visual parity. No live account, paid generation, deployment, user-Mac access or audio alignment was used. Final assembled test counts and native gates are recorded by the integration owner; focused development logs are `/tmp/scriv-anchor-tests.log` and `/tmp/scriv-anchor-full-tests.log`.
