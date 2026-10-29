# Scriv product and interaction design

**Status:** Design specification. The new application implementation has not started. The interface images are concepts; the [timing fixture](../design/storyboard-timing-example.json) defines the precise provisional example values.

Scriv is a script-first Mac workspace. Its Script, Characters and Storyboard views share the same project. Collaboration and local Codex controls extend that workspace.

## 1. Script editor

[Selected script editor concept](../design/images/01-script-editor.png)

Keep one continuous script flow on the left, with the current image and layered Images / Dialogue / Direction / Words editor on the right. A shared playhead connects the current text, word, image and timeline position.

Speech labels, dialogue, Direction labels and direction text all share **one left text edge**. Stable identities survive line renumbering, text edits and reordering. The source wording remains authoritative.

### Owned time and direction coverage

Speech and standalone actions occupy sequence time. Every direction has two distinct values:

- **Owned duration:** zero or positive time assigned to that direction's action slot. The duration pill displays this value.
- **Coverage:** the following moments to which the direction applies. It begins at the direction's authored position and may overlap later speech, actions and images.

Coverage adds no time. A zero-second note can apply across several seconds of existing content. A direction with positive owned duration can also continue to apply after its action slot ends.

Place a note immediately before the speech or action it should affect. To affect earlier words, move the note earlier in the script. Preserve its exact wording.

### One shared colored direction rail

Only directions have vertical coverage controls. Each range has a **fixed top anchor** and **one draggable lower endpoint**. The top curves right into a small arrow pointing to its own direction line. Arrows end before the common text edge; connectors stay within the gutter.

Overlapping directions share one vertical track. Use distinct colors and interleaved strokes on the same centerline, with matching source arrows and end caps. Example colors are purple for “(To the farmer)”, coral for Franklin's reaction and teal for “(Re: Miyazaki)”.

Selecting a direction emphasizes its range and exposes its lower handle. Overlapping ranges or coincident endpoints can be selected through a compact picker identified by both color and source text. The source note also selects its range. Text alignment stays fixed as ranges overlap.

Dragging the lower endpoint changes coverage only. Editing the owned-duration pill creates or resizes an action slot and shifts subsequent sequence content. Coverage cannot end before the direction's owned action finishes. Speech retains ordinary duration pills.

### Example

| Direction | Authored start | Owned time | Coverage |
| --- | --- | --- | --- |
| (To the farmer) | 25.3s | 0s | 25.3–30.7s |
| Franklin looks between the boys and the invoice. | 30.3s | 2.4s, ending at 32.7s | 30.3–35.5s |
| (Re: Miyazaki) | 32.7s | 0s | 32.7–35.9s |

Randy's speech occupies 25.3–30.3s; Franklin's question occupies 32.7–35.5s. Together with the reaction, this excerpt owns **5.0 + 2.4 + 2.8 = 10.2 seconds**. Direction coverage extending to 35.9s does not add sequence time.

Concept images may show a focused script excerpt. Rendered hooks and colors illustrate the idea; these interaction rules define fixed starts and draggable lower ends.

## 2. Storyboard

[Selected storyboard concept](../design/images/03-storyboard.png)

Use a full-width image sequence with minimal metadata: large images, duration pills overlaid on each image, spoken-word pills below, and direction coverage bands underneath.

Every spoken word is an individual pill. Click a word or use a rectangular, Photoshop-style marquee to select several. Drag a contiguous selection into the previous or next image to move the cut. Any intervening words travel with that boundary, preserving the exact source wording and order. Word timestamps remain fixed; image assignments change.

Dragging a shared image boundary transfers time between adjacent cues. Their combined duration and total sequence duration stay fixed. Prevent zero-length images.

The demonstrated “gung ho” move changes the first two image durations from 2.0s / 1.8s to 1.4s / 2.4s:

| Image cue | Range | Duration | Spoken words |
| --- | --- | --- | --- |
| 08A | 25.3–26.7s | 1.4s | He gets a little |
| 08B | 26.7–29.1s | 2.4s | gung ho with our flavor of |
| 08C | 29.1–30.3s | 1.2s | capitalism. |

A script entry can have several images. An image cue can also span neighboring entries; the asset and its timed placement have separate identities. Direction text stays unspoken, with coverage displayed in its own band. Overlapping direction bands remain distinguishable beneath the spoken words.

## 3. Characters and image identity

[Selected Characters concept](../design/images/02-characters.png)

Each character has one stable profile and can have aliases. “Farmer Franklin” and “Franklin” refer to the same identity.

Link explicit character names in speaker labels, dialogue and directions. When one speaker mentions someone else, the name opens the mentioned character's profile. Preserve the exact script wording; links are annotations over it.

Selecting a name opens the corresponding Characters profile and identifies related images. An image can carry several character tags. Tags identify who is actually depicted; mentioning someone in the dialogue does not automatically put that character in the image.

Image regeneration creates a new version. Existing references and discussions retain the identity and version they originally described.

## 4. Collaboration and local Codex

[Collaboration and local Codex concept](../design/images/04-collaboration-local-codex.png)

Live collaborator cursors and selections show who is working where. Entering edit mode acquires exclusive editing of that script item. Others can continue reading, playing and discussing it. Server-accepted changes appear in a durable history timeline; cursor movement and temporary presence do not.

A compact bottom-right Discussion panel provides **Project / This item** contexts. Characters, lines, directions and images each retain their conversation as names and positions change. An item's editing lease does not block discussion. Image annotations identify the specific image version; text annotations use stable source anchors.

Scriv account controls and **Codex on this Mac** are separate. The local controls provide Start, Stop, Connect and connection/account status. Scriv can stop the process it started; disconnecting an externally managed runtime leaves that process running.

Generation executes on the user's Mac. The cloud stores scripts, membership, collaboration, history and premium media; local AI credentials stay on the Mac. A generated result attaches to stable project items with source-version checks, preserving newer edits when generation finishes late.

The [multiplayer architecture](multiplayer-design.md) specifies proposed persistence, lease fencing, replay, discussions, storage, billing and local-runtime responsibilities. These remain implementation plans, not claims of deployed or tested behavior.
