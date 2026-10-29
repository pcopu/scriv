# Original Pro conversation: implementation scope reconciliation

## Coverage and evidence

Read-only audit performed 2026-10-29 before implementation of the follow-on jobs,
audio, mentions and history features. Source: original conversation
`6ae29899-d288-83e9-8057-68a7c10d4ab6`, read through Global Search conversation
context, including every previous page to the beginning. There were **64 unique
visible messages in 65 contiguous chunks**, from **00:51:57 to 20:49:26 UTC**.
Every chunk had `content_omitted: false`; the split assistant message's offsets
were contiguous, and both pagination ends were reached. This covers visible user
and assistant text, **not hidden tool actions or original attachment payloads**.
The actual requested root `transcript.MD` was subsequently published at commit
`ae41d6f9b6a53fb0a019791a385a651db14ed3b3` and read completely: **72,487 characters**,
41 verbatim user messages plus explicitly reconstructed work history. It is not a
full raw platform export. Reconciliation found no new or superseding product
requirement; the additional explicit reminders concern the earlier repository
audit and `structure.md`, not another app feature. The transcript's historical
build/completion assertions do not certify the later working tree.
Assistant statements that an app was finished are not completion evidence.

All four current approved PNGs were opened and visually inspected:
`design/images/01-script-editor.png`, `02-characters.png`, `03-storyboard.png`,
and `04-collaboration-local-codex.png`. These are design evidence, not current app
screenshots or proof of native runtime behavior.

## Latest user choices, in order

- Script-first, public fork renamed Scriv; native Mac writing workspace.
- Time every authored dialogue/action entry; display its duration on the left;
  play images against the timed script and current word. Main view is left script,
  right preview and layered timeline.
- Character names and aliases in script link to Characters; images carry depicted
  character tags and appear in their character gallery.
- UIKit-inspired native visual language, with the layered editor retained.
- Three views: main editor, script beside Characters, and full-width Storyboard.
- Storyboard simplifies to images, overlaid duration pills, words and overlapping
  directions; one entry may span multiple images. Resize a cut by transferring
  time to/from its neighbor. Individual word pills support click/marquee selection
  and dragging single/multiple words to an adjacent image to adjust cuts.
- The temporary separate dialogue/direction columns were **rejected**. Keep one
  common left text edge. **Only directions** have vertically extended coverage;
  owned duration may be zero or positive. Coverage begins at its authored position
  and can only extend forward. A curved top anchor identifies its source line.
- Separate overlap lanes were subsequently replaced by **one shared vertical rail
  with distinct interleaved colors**. Do not restore the superseded two-column or
  separate-rail concepts.
- Live multiplayer: visible other-user caret/selection, exclusive script-line
  editing, streaming accepted changes, full history; bottom-right project/item
  discussion for characters, lines, directions and images.
- Free single-person use and hosted script metadata. P2P **images** on both plans;
  multiplayer and hosted **image** storage are premium.
- Separate Scriv sign-in and local Codex/ChatGPT controls. Start owned process,
  Stop owned process, Connect existing local server; credentials remain local.
- Preserve created designs/plan while removing inherited unrelated app code.
- Final commercial/runtime choice supersedes earlier proposals: **$9.99/month per
  team, no per-seat charge, reusable team invitations**, on the existing Cloudflare
  Workers paid plan; D1/SQLite Durable Objects/R2 replace the earlier literal
  Postgres/Redis design. Deployment itself was excluded from the ready-to-handoff
  coding request. Commit often, then preserve the entire conversation as transcript.

Key user sources:
[timed-script concept](https://chatgpt.com/c/6ae29899-d288-83e9-8057-68a7c10d4ab6?messageId=92b45f21-b292-4710-9339-20c6e93a10ef),
[playback layout](https://chatgpt.com/c/6ae29899-d288-83e9-8057-68a7c10d4ab6?messageId=7c839060-26a0-45c1-a203-3cf11eb80cd9),
[collaboration/storage](https://chatgpt.com/c/6ae29899-d288-83e9-8057-68a7c10d4ab6?messageId=7ee77063-c6bc-4424-a602-06a13aad9b0c),
[local Codex](https://chatgpt.com/c/6ae29899-d288-83e9-8057-68a7c10d4ab6?messageId=2cd06a9c-e2e5-4acc-a016-0a74ff4559b2),
[entire app/final billing and platform](https://chatgpt.com/c/6ae29899-d288-83e9-8057-68a7c10d4ab6?messageId=151274de-6b9b-4eb8-a169-8e753583f3d5).

## Accepted-design details versus explicit user wording

The [02:29 layered-view explanation](https://chatgpt.com/c/6ae29899-d288-83e9-8057-68a7c10d4ab6?messageId=c4664310-c13e-5bde-a2fc-3e0f42febd0f)
describes dialogue speech clips and waveforms; approved concepts show volume.
The user then approved the two liked views and later requested exact visual parity.
**No visible user message explicitly requests TTS, generated voices, a particular
audio provider, shared audio transfer/storage, video export, configurable aspect
ratios or batch generation.** Real user-imported local audio is a bounded way to
make the accepted waveform/volume controls functional, not a claim that TTS was
requested. Cloud/P2P transport remains image-specific unless later instructions
change that scope.

The [03:53 preserved local-engine plan](https://chatgpt.com/c/6ae29899-d288-83e9-8057-68a7c10d4ab6?messageId=cbcf3fab-3431-55bd-80e7-1c745f7d70f7)
also describes durable generation ownership/progress/source/output records,
"Waiting for this Mac", safe recovery before retry, and conversations that survive
image replacement. These were assistant-proposed details in the plan the user then
asked to preserve/build, not separately explicit quoted user feature statements.
The saved plan further describes history actor/affected-item inspection and a
read-only preview before restoration. Its superseded pricing and database names
must not be confused with rejection of these product behaviors.

## Concrete gaps found by source audit, before follow-on work

1. Playback was visual timing only; no real audio model, import, engine, volume or
   waveform data. Do not fabricate waveforms or inert volume controls.
2. Local generation kept one in-memory job UUID and no journal/recovery/shared
   status surface. Restart/navigation could leave a valid file undiscoverable in
   the app. No automatic generation retry is permissible merely because a response
   was lost.
3. Image discussions keyed the exact immutable image-version ID. Regeneration
   therefore opened a fresh conversation instead of preserving the image lineage's
   conversation. Older versions survived, but their threads fragmented.
4. History listed label/revision/date/Restore but lacked actor, affected-item
   before/after inspection and preview. Deleted-item threads also lacked a
   discoverable archive browser even though the backend retained their records.

These findings are implementation scope, not unavailable-test excuses. Subsequent
commits must be inspected for actual closure; this dated audit does not claim they
remain open or were already completed. Most explicit editing, timing, character,
multiplayer, P2P image, billing and account controls already had concrete native or
backend paths at audit time. Separate verification documents distinguish source
checks from real macOS, authenticated Codex, paid usage and WebRTC execution.
