# Historical bundle notes

These notes preserve an earlier design bundle. Image paths have been updated for this repository; the current documents are linked from the repository README.

# Scriv UIKit design bundle

Visual concepts for Scriv: a script-first writing workspace with timed images, spoken-word editing, forward-only direction coverage and shared character profiles.

## Approval status

| File | Status |
| --- | --- |
| `12_main_layered_editor_earlier_approved.png` | **Earlier user-approved reference; unchanged.** Original single script flow with preview and layered editor. |
| `../images/02-characters.png` | **User-approved; unchanged.** Linked character profiles and tagged image gallery. |
| `../images/03-storyboard.png` | **Proposed; not yet user-approved.** Images, overlaid duration pills, individual spoken-word pills, marquee selection and direction bands. |
| `../images/01-script-editor.png` | **Included — updated proposed main view; not yet user-approved.** Focused eight-entry script viewport with a common text edge and overlapping directions on one shared colored gutter track. |

All four screens are included. The main concept shows a focused eight-entry excerpt with all script text aligned to one left edge. Direction-only, forward-only coverage ranges share one vertical gutter track and use distinct colors; each fixed top curves right into an arrow pointing to its own direction line, and only the selected bottom handle is draggable. Owned sequence time remains separate from coverage. Other concept images remain unchanged. Visuals illustrate the interface; precise provisional timings and word mappings are specified by `../storyboard-timing-example.json`. Screens 03 and 04 remain proposed and await user approval. No application implementation is claimed.

The main-screen concept uses a focused script excerpt. Rendered hooks and end-cap colors are illustrative; the interaction rules below and the JSON define fixed top anchors and draggable lower ends. The viewport does not change source wording or cue timing. Use the JSON for exact example times when the visual is approximate.

## Direction coverage and owned time

Every direction has two separate values:

- **Owned time:** zero or positive sequence time, shown in its ordinary duration pill. Positive owned time creates a dedicated action slot; a 0s direction adds no sequence time.
- **Coverage:** the following moments to which the direction applies. Coverage always starts at the direction’s authored position and can overlap subsequent speech, action and images. Coverage itself adds no time.

The main view keeps one script flow. **Speech labels, dialogue, Direction labels and direction text all share one left text edge.** Overlap is shown through the shared colored gutter track, never text indentation. Place “(To the farmer)” immediately before Randy’s affected speech, and “(Re: Miyazaki)” immediately before Franklin’s question, preserving the exact wording. The standalone reaction retains its own action slot.

**Only directions have vertical controls:** a fixed top anchor and **one lower/end handle**. There is no upper handle and no speech range bar; speech retains ordinary duration pills. Coverage cannot extend backward or end before the direction’s owned action finishes. To affect earlier words, move the direction earlier in the script, then extend its lower handle.

Moving the lower handle changes coverage only. It does not change owned duration, shift speech or alter runtime. Editing the owned-duration pill creates or resizes the action slot and shifts following sequence content. Use one narrow shared vertical track entirely within the left gutter. Example colors are **purple** for “(To the farmer)”, **coral** for Franklin’s reaction and **teal** for “(Re: Miyazaki)”. Coincident coverage uses interleaved colored dashes on the same centerline. At each range’s fixed top, a matching colored curve turns right into a small arrow pointing to its own direction line. Arrows end just before the shared text edge; connectors stay in the gutter. Matching end caps keep each range discoverable. The top arrow is fixed, not a resize handle.

Selecting a note brings its range forward as a solid stroke and exposes only its lower/end handle. Other ranges retain their colored anchor arrows and end caps. Give the shared rail a generous invisible hit area; clicking an overlapping range or coincident endpoint opens a compact picker identified by both color and source text. Selecting through the source note or keyboard also identifies the active direction. The duration pill shows owned time; coverage color does not change that value. Within the active range, distinguish any owned action segment from its lighter forward-only continuation. A 0s note has an anchor and coverage, with no owned action segment.

## Exact example

| Direction | Authored start | Owned time / slot | Forward coverage |
| --- | --- | --- | --- |
| (To the farmer) | 25.3s | **0s** | 25.3–30.7s (**5.4s**) |
| Franklin looks between the boys and the invoice. | 30.3s | **2.4s**, 30.3–32.7s | 30.3–35.5s (**5.2s**) |
| (Re: Miyazaki) | 32.7s | **0s** | 32.7–35.9s (**3.2s**) |

Randy’s unchanged speech occupies **25.3–30.3s (5.0s)**. Franklin’s unchanged question occupies **32.7–35.5s (2.8s)**. The authored order is: 0s farmer note; Randy’s speech; 2.4s reaction; 0s Miyazaki note; Franklin’s question.

The excerpt owns **5.0 + 2.4 + 2.8 = 10.2s**. Its direction coverage can be displayed through **35.9s**, but that endpoint does not extend the excerpt’s sequence time. The farmer note and reaction coverage overlap for **0.4s**; the reaction and Miyazaki coverage overlap for **2.8s**. These coverage intersections add no time.

A standalone direction is unspoken. Its text is retained as direction text, without fabricated spoken-word timestamps. Character identity is shared across the views; “Farmer Franklin” and “Franklin” refer to the same profile.

## Storyboard selection and image cuts

Display large images with overlaid duration pills, each spoken word in its own pill below, and direction coverage bands beneath the words. Bands may span several images and overlap on separate subrows. One image cue may also span neighboring script entries.

Click one word or use a Photoshop-style rectangular marquee to highlight several pills. Drag a contiguous selection into the previous or next image to move the image cut. Any intervening words travel with the boundary, preserving exact source wording and order. The shared cut transfers time between adjacent images without changing their combined duration or total sequence time. Speech word timestamps and direction rules remain separate from this image-cut edit.

The existing “gung ho” preview transfers **0.6s** from 08A to 08B: **2.0s / 1.8s** becomes **1.4s / 2.4s**. The cut moves from **27.3s to 26.7s**; the words remain at their original timestamps.

| Image cue | Range | Duration | Covered spoken words |
| --- | --- | --- | --- |
| 08A | 25.3–26.7s | 1.4s | He gets a little |
| 08B | 26.7–29.1s | 2.4s | gung ho with our flavor of |
| 08C | 29.1–30.3s | 1.2s | capitalism. |
| 09A | 30.3–32.7s | 2.4s | None — the reaction is unspoken direction. |
| 10A | 32.7–34.2s | 1.5s | Can I trust |
| 10B | 34.2–35.5s | 1.3s | this guy? |

`../storyboard-timing-example.json` is illustrative schema version 3. It separates authored sequence ownership, direction coverage, speech, individual word timestamps and image cues. Stable word IDs and image-to-word assignments are unchanged. Source dialogue reconstructs exactly; image references remain placeholders. Its overlap intersections distinguish coverage from owned action time.
