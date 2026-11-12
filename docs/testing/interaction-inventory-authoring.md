# Authoring interaction inventory and journey plan

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Status: source-derived planning inventory, 2026-11-08. No new scenario, native run, old-test retirement or application change is authorized or claimed by this document.

**Scoped planning result: 175 supported interaction groups, organized into 16 proposed base journey families.** This is not 175 tests, not a promise of 16 total whole-app tests, and not 16 necessarily new files: existing scenarios should be consolidated/reused. Parameter rows and route variants run through these bases. Six image-recovery actions and project/integration operations are excluded to avoid double-counting companion inventories.

The question is how many **base journeys** the new CLI suite needs, not how many old test methods it can rename. Define the reachable actions first, group them into short journeys, and attach old assertions and edge-case data to those journeys. This inventory covers App navigation, Script, Characters, Images and Audio. Projects, history, recovery, account, teams, discussion, settings, runtime, updates and service/fault boundaries belong to the companion inventories.

## Current scoped implementation note

The v70 candidate adds a guarded stored-UIAction route for CHR-21 through the
existing Portrait options button and a continuous-film chapter. See
[portrait route and remaining limits](character-portrait-menu.md). It is
native-unverified; this does not retroactively change the planning inventory,
counts, historical evidence or acceptance status below. Other menu and alert
variants remain separate gaps.

## Counting contract

- An interaction ID denotes a distinct app-owned user intent/state transition. Choosing one of N scene/character/image choices or entering N different strings does not make N interaction IDs.
- Repeated controls for the same operation are variants: e.g. add dialogue from an empty state or footer; seek from a slider, word or waveform; zoom via key or preset. Variants still require evidence because their routing can fail independently.
- Open, draft/preview, accept and cancel are separate when they have different state/lifecycle behavior. A toggle is one parameterized operation with both target states, not two unrelated tests.
- A base journey is a short reusable sequence in a fresh synthetic workspace. Data rows, route variants, interruption points and assertions do not increase the base-journey count. They do increase executed cases and runtime.
- This is a finite catalog of supported app-owned action types. It is not a claim to enumerate every possible string, timing, OS menu, assistive technology or interleaving. Inherited UIKit text selection/editing/clipboard/IME behavior is a variant matrix, not thousands of extra app commands.
- Stable IDs below should survive label changes. Split an ID only if the actual command/lifecycle contract differs; append new IDs instead of renumbering old ones.

## Coverage language

Every catalog row contains a current CLI status. These are **source observations**, not new pass claims:

- `E(name)` means an existing `tests/e2e/name.mjs` scenario exercises some part of the operation. It does not mean every variant is covered. - `R` means ordinary adapter primitives appear suitable but no scoped scenario was found. Reachability still needs native verification. - `M` means menu invocation is missing: `menu` observes installed menus/builders; it does not activate `UIAction` menu items. - `A` means Catalyst alert acceptance/cancellation is blocked by the current public activation route. The native accessibility bundle hit Library Validation; no bypass or retry is proposed here. - `G` means physical pointer/gesture/drag/drop, modifier state, horizontal scrolling or native text-event delivery is missing or only partially represented. - `F` means a file-picker/clipboard/media-input handoff is missing. A semantic synthetic import is not proof of the picker. - `I` means connected/provider-dependent work needs a separate authorized integration fixture; synthetic local evidence alone cannot certify it.

`ScrivCLI.swift` supports UIKit controls, text/selection, vertical scroll, sliders, key-command routing, explicit Return-delegate dispatch, menu observation, synthetic script imports/exports and read-only saved/image evidence. These are different coverage boundaries. Calling a production Store method would establish semantic app-command coverage, **not** physical menu, alert, gesture or key-event coverage. No private action-handler invocation, direct project assignment or copied domain algorithm is proposed.

## Source aliases

All aliases start at `apps/catalyst/ScrivUIKit/` unless noted. Paths and line anchors refer to the inspected working tree; the frozen baseline checklist is separate.

- `WS` = `App/ScrivWorkspaceController.swift`; `WH` = `App/ScrivWorkspaceHeader.swift`.
- `SC` = `Script/ScriptScreenController.swift`; `ST` = `Script/ScriptTextViews.swift`; `SR` = `Script/ScriptDirectionRails.swift`; `SD` = `Script/ScriptDurationScrubDriver.swift`.
- `CC` = `Characters/CharactersController.swift`; `CE` = `Characters/CharacterEditorController.swift`; `CL` = `Characters/CharacterLinksController.swift`; `CR` = `Characters/CharacterImageReviewController.swift`.
- `KEY` = `Shared/ScrivPlaybackKeyboardRouter.swift`; `SCREEN` = `Shared/ScrivScreenController.swift`.
- `STORE` = `apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift`, compiled into the Catalyst target as shared production services by `scripts/generate-catalyst-project.py:29–34`.

## App navigation: three counted interactions

Destination-specific project/integration routes are listed under cross-references, not counted again here.

| Interaction ID | Action / variants | Preconditions | Observable result | Source callsite | CLI coverage / gap |
| --- | --- | --- | --- | --- | --- |
| NAV-01 | Switch workspace tab: Script, Characters, Storyboard | Workspace recovered; no blocking presentation | Correct cached panels; edits finish through normal path; one transport; selection/scroll retained as designed | WS:94–109,163–194 | E(workspace), E(script-character-parity), E(transport) |
| NAV-02 | Scroll authoring surface: vertical content, horizontal ribbon/timeline | Mounted content exceeds viewport | Different content becomes reachable; no authored mutation | SC:203–213; CC:38–50,64–74; image/audio scroll owners below | E(editing), E(script-character-parity); horizontal G |
| NAV-03 | Open/inspect/dismiss a workspace, context or secondary menu | Enabled visible menu owner; current context | Correct menu/options/checkmarks/disabled state; merely opening does not edit | WS:118–149; SC:403–449; ST:271–273; `Shared/ScrivSecondaryMenu.swift` | E(script-menu-boundaries) observes builder only; M/G for actual presentation/dismissal |

Ordinary sheet dismissal and Escape (`SCREEN:34–49`) are shared route variants of the domain-specific close/cancel IDs, not a fourth navigation operation.

Window resize, split/stack changes, wide/narrow header variants, light appearance and focus loss are **environment parameters**, not extra domain commands. Snapshot geometry covers some layouts; current CLI has no window-resize/focus-event command. Test them as route/viewport variants when supported.

## Script: 37 counted interactions

| Interaction ID | Action / variants | Preconditions | Observable result | Source callsite | CLI coverage / gap |
| --- | --- | --- | --- | --- | --- |
| SCR-01 | Select a source entry | Current scene entry exists; rail/source control visible | Selected entry/cue and playhead follow source; presence updates | SC:348; SR:47–49; STORE:1114–1120 | R; row click variant enters editing instead |
| SCR-02 | Begin editing selected/source line: tap caret, Edit text, Cmd-Return | No pending boundary; current entry; lease available | Real editor gains focus at remembered/requested UTF-16 caret | SC:63–82,349,412; ST:161–164; KEY:153–154,254–257 | E(editor-unicode-selection), E(workspace-zoom); menu/tap G/M |
| SCR-03 | Edit source text: insert, replace, delete, select-all replacement; dialogue/direction | Editable native text view, valid range and accepted draft journal | Exact bytes/UTF-16 retained; words/annotations reconcile; rejected edit does not mutate | ST:250–262; SC:359–360; `Script/ScriptDraftSession.swift` | E(editing), E(editor-unicode-selection), E(text-growth-timing); clipboard/IME/native deletion variants G/F |
| SCR-04 | Move caret/change native text selection | Current source editor; valid UTF-16 range | Exact selection and presence; refresh/zoom retain editor identity | ST:264–265; SC:361–363 | E(editor-unicode-selection), E(script-return-boundary), E(workspace-zoom); physical selection G |
| SCR-05 | Finish editing: Finish, Escape, Cmd-Return or normal navigation | Active draft; finish accepted | Draft commits or remains recoverable on failure; display replaces editor without lost wording | SC:70–73,218–221,365,387–390; ST:44–47 | E(editing), E(editor-placeholder), E(editor-unicode-selection); recovery delegated |
| SCR-06 | Split source line at Return | Focused editor, no composition; acquired lease and exact original | New line boundary; preserved source characters, IDs/timing/anchors according to production split | ST:250–255; SC:127–160 | E(script-return-boundary), explicit delegate only; physical Return/IME G |
| SCR-07 | Merge into previous line using Backspace at zero | Editable source; collapsed caret at 0; no composition; both leases | Previous/current lines merge atomically; no invented whitespace/scene crossing | ST:48–50; SC:128–160 | G; no delete-backward driver command |
| SCR-08 | Add entry, kind=dialogue/direction; footer/empty-state variants | Current scene; mutation accepted | One new source after current selection, default timing, placeholder selected once | SC:485,495; STORE:1161–1164 | E(editing), E(editor-placeholder), E(script-search); empty/zero-scene variants R |
| SCR-09 | Set speaker or No speaker | Selected dialogue; current menu context, unlocked | Speaker identity changes without changing source wording | SC:434–439; ST:202 | M |
| SCR-10 | Move source up/down | Entry belongs to scene; target position exists; unlocked | Order and source-owned outgoing coverage move; other scene unchanged | SC:422–423; STORE:1190 | E(script-menu-boundaries) eligibility only; M for execution |
| SCR-11 | Request entry deletion | Current unlocked line | Destructive confirmation opens, no edit yet | SC:424,465–467 | M then A |
| SCR-12 | Confirm entry deletion | Current confirmation/navigation | Source/time and owned placements removed as revision; history retained | SC:465–483; STORE:1189 | A |
| SCR-13 | Cancel entry deletion | Deletion confirmation open | No project/revision/selection change from cancellation | SC:480–483 | A |
| SCR-14 | Select scene | Existing scene, current menu context | Finish/retain prior draft; stop playback; select new source and seek 0 | SC:441–445; STORE:1191–1196 | M |
| SCR-15 | Add scene | Current project and menu context | New scene selected through ordinary Store action | SC:447; STORE:1208–1211 | M |
| SCR-16 | Open rename-scene dialog | Selected scene exists | Current title shown in local field | SC:448,469–475 | M/A |
| SCR-17 | Edit scene-title draft | Rename dialog open | Local text changes, canonical title unchanged | SC:471–475 | R after unreachable dialog; A lifecycle |
| SCR-18 | Accept scene rename | Original navigation still current | Title saved through Store; source content preserved | SC:474–475 | A |
| SCR-19 | Cancel scene rename | Rename dialog open | Original scene title/revision preserved | SC:473 | A |
| SCR-20 | Request scene deletion | Current selected scene/menu context | Destructive dialog describes script/placement removal and asset retention | SC:449,477–483 | M/A |
| SCR-21 | Confirm scene deletion | Current confirmation/navigation | Scene/source/placements removed; assets/characters retained | SC:477–483; STORE:1207 | A |
| SCR-22 | Cancel scene deletion | Delete-scene dialog open | Scene and all content retained | SC:480–483 | A |
| SCR-23 | Open/refocus Find | Script header, workspace Find or Cmd-F; focus policy permits | Search row appears/refocuses, potentially switching from Storyboard | WS:105–109; SC:179,514,528–529; KEY:147–149,259–261 | E(script-search), E(global-shortcuts); overflow M |
| SCR-24 | Edit/clear Find query | Find field mounted | Case-insensitive source/name/alias matches, current highlight/count; no document edit | SC:187,510–517 | E(script-search) |
| SCR-25 | Advance Find previous/next | Query with results | Wraps to correct row/highlight; zero results safe | SC:191–195,516,518,520,530–531 | E(script-search); native search-field Return variant not covered by UITextView-only return command |
| SCR-26 | Close Find: Close, header toggle, focused Escape | Search row visible; Escape only while field focused | Query/count/highlights clear; responder exits search | SC:196,514,524–528 | E(script-search) |
| SCR-27 | Open precise owned-duration editor | Current unlocked entry | Original duration shown, source-specific explanation | SC:452–463; ST:145–146; image timeline sheet is same intent | R opening; A commit route, alternative sheet entry M |
| SCR-28 | Edit owned-duration draft | Numeric editor open | Local seconds change only | SC:456; `Images/ImageCoverageViewController.swift:21–23` | R after route; numeric input validation pending |
| SCR-29 | Accept owned duration | Finite 0…3600s; exact current entry/context; required lease | Production retiming/coverage rules apply, or rejection preserves state | SC:458–461; `Images/ImageCoverageViewController.swift:30–40`; STORE:1112 | A/M; no semantic coverage claimed |
| SCR-30 | Cancel owned-duration draft | Numeric editor open | No duration mutation; lease released | SC:457; `Images/ImageCoverageViewController.swift:26–29` | A for alert, R for reachable sheet |
| SCR-31 | Preview owned duration with hold/vertical drag | Pill; draft finish accepted; original/context/lease captured | Preview label changes, no canonical edit before release | SD:20–45,50–55 | G |
| SCR-32 | Commit owned-duration scrub on release | Valid original/context; lease ready; visible pill | Exactly one duration mutation; delayed lease must not double-commit | SD:42–45,56–70 | G; numeric commit shares underlying intent with SCR-29 but distinct deferred lifecycle |
| SCR-33 | Cancel owned-duration scrub | Gesture cancellation/failure/navigation | Preview resets; no mutation; lease/task cleanup | SD:46,66–70; SC:239–241 | G |
| SCR-34 | Preview direction coverage by dragging endpoint | Direction entry; unlocked; current rail geometry | Endpoint preview changes, owned time unchanged | SR:122–130 | G |
| SCR-35 | Commit/adjust direction coverage | Valid captured source/context; release, or accessibility ±100ms | Coverage applies through Store independently of owned duration | SR:51–55,131–136 | G; public accessibility increment/decrement not currently exposed |
| SCR-36 | Cancel direction-coverage drag | Active pan cancelled/failed | Preview disappears, no authored edit | SR:138 | G |
| SCR-37 | Adjust shared script zoom: preset or relative keyboard | Store exists; keyboard not composing | Text sizes across Script/Characters/Storyboard agree; text/selection unchanged | SC:312–315; KEY:140–145,246–252 | E(workspace-zoom), E(editor-unicode-selection); presets M, physical key repeat G |

Play/pause, seek, play-from-source and Follow playback are counted once in AUD. Picture split belongs to IMG. Review character links, opening a character from speaker/inline link, and character chips belong to CHR. Project save/undo/redo/history/import/export and recovered-draft actions belong to companion integration inventory.

## Characters: 48 counted interactions

| Interaction ID | Action / variants | Preconditions | Observable result | Source callsite | CLI coverage / gap |
| --- | --- | --- | --- | --- | --- |
| CHR-01 | Search character names/aliases | Characters pane mounted | Ribbon/profile filter, no canonical edits | CC:36–37,111,125–126 | E(character-search-escape), E(character-validation) |
| CHR-02 | Clear/finish character search: Escape, Clear search, search Return | Search field/no-results state | Full ribbon restored when cleared; focus ends on Return | CC:112–124,180–184 | E(character-search-escape), E(character-validation); Return variant R |
| CHR-03 | Select/open character: ribbon, speaker, confirmed inline link, tag chip | Existing character identity | Correct canonical profile shown; filtered-out selection clears filter | CC:94–96,149–152,264; SC:358; ST:200,267–269 | E(character-validation); link interaction G, image-chip R |
| CHR-04 | Expand/collapse character notes | Biography or appearance nonempty | Notes display changes only | CC:210–215 | R |
| CHR-05 | Open create/edit profile | Add/Edit; current item and lease for existing | Local draft appears; no placeholder character created | CC:33,180–189,307–310; CE:29–75 | E(editing), E(character-profile-fields), E(character-validation) |
| CHR-06 | Edit profile text, field=name/biography/appearance | Editable profile form | Local exact text; Save eligibility/validation; no mutation until save | CE:40–43,97–105 | E(character-profile-fields), E(character-validation) |
| CHR-07 | Choose character color | Editable profile | Draft swatch changes without moving opening custom-color choice | CE:129–145 | E(editing), E(character-profile-fields) |
| CHR-08 | Open Add alias | Editable profile, current context | Alias alert opens without modifying aliases | CE:114–118 | E(character-aliases) reaches blocked alert |
| CHR-09 | Edit alias draft | Alias alert open | Text only; canonical/profile alias list unchanged | CE:118 | E(character-aliases) partial; A lifecycle |
| CHR-10 | Accept new alias | Nonempty trimmed bounded value; count <100; not duplicate ignoring case | One draft alias appended, existing order/spelling preserved | CE:120–127 | A |
| CHR-11 | Cancel alias addition | Alias alert open | Draft aliases unchanged | CE:119 | A |
| CHR-12 | Remove alias chip | Editable draft alias exists | That draft alias removed; no source rewrite | CE:106–113 | R; saved alias fixture/import needed |
| CHR-13 | Save character: button/name Return | Valid draft/current scope; existing lease; no conflicting authored change | Create/update persists once; portrait preserved; errors retain full draft | CE:42,151–168 | E(character-profile-fields), E(character-validation); Return variant R |
| CHR-14 | Close unchanged character form | Clean draft; Cancel/header close/Escape/swipe | No edit; held lease released | CE:37,53,78–85,174–183 | E(character-profile-fields), E(character-validation); swipe G |
| CHR-15 | Request closing dirty character form | Unsaved changed draft, no nested modal | Discard confirmation; draft still intact | CE:174–181 | R opening, A resolution |
| CHR-16 | Keep editing after dirty-close request | Discard alert open | Same draft/editor retained | CE:179 | A |
| CHR-17 | Discard dirty character draft | Discard alert open | Form closes, canonical profile unchanged, lease released | CE:180–183 | A |
| CHR-18 | Request character deletion | Existing unlocked character | Confirmation explains preservation/removal effects | CC:194,312–319 | M/A |
| CHR-19 | Confirm character deletion | Original navigation current | Character/speaker/inline/image links removed; source wording/images/history preserved | CC:316–318 | A |
| CHR-20 | Cancel character deletion | Delete confirmation open | Character and links unchanged | CC:315 | A |
| CHR-21 | Choose/remove portrait | Current character unlocked; tagged image for choose | Portrait identity changes/removes without retargeting image placements | CC:228–242,259 | M |
| CHR-22 | Open script-character-link review | Current source; draft finishes; menu or suggestion button | Immutable source snapshot shown; lease acquisition; source unchanged | SC:395,413,428–432; CL:32–60 | R for suggestion button, M context route |
| CHR-23 | Retry opening link review | Acquisition failed but exact source still reviewable | Reacquires lease or explains stale source without mutation | CL:53,79–96 | R; controlled lease/fault fixture needed |
| CHR-24 | Show more suggested/reviewed links | >40 in a group | Next 40 rendered; existing choices retained | CL:103–106 | R |
| CHR-25 | Find more name suggestions | Review lease/current scope | New non-overlapping suggestions in local draft, none auto-confirmed | CL:109–114 | R |
| CHR-26 | Choose correction target for a link | Character catalog nonempty; acquired review lease | Pending local choice; Save disabled until confirmed | CL:123–130 | M |
| CHR-27 | Confirm/correct selected link | Existing target character, current lease/scope | Exact occurrence annotated in local draft; no source spelling changes | CL:134–136,171–179 | R for existing suggestion; M for changed target |
| CHR-28 | Unlink/keep occurrence unlinked | Review current; link or pending choice | Explicit unlinked annotation retained, no re-inference | CL:143–145,162,171–179 | R |
| CHR-29 | Expand/collapse Link other wording | Review open | Manual occurrence controls disclosure only | CL:49–52 | R |
| CHR-30 | Enter exact wording to locate | Review open | Exact UTF-16 occurrences/excerpts, or no-match message | CL:50–51,149–165 | R |
| CHR-31 | Link a chosen exact occurrence to character | Valid occurrence/current lease/catalog | Only chosen range assigned; intersecting local annotations reconciled | CL:159–160,171–179 | M |
| CHR-32 | Show more exact occurrences | >20 literal occurrences | Next 20 rendered without losing review draft | CL:167–168 | R |
| CHR-33 | Save reviewed links | Current exact source/links; acquired lease; no pending choices | One production annotation save, source bytes unchanged; stale save rejected | CL:181–188 | R; json-character-links exercises import validation, not this UI |
| CHR-34 | Cancel/close link review | Sheet open, including dirty local review | Local review discarded; no source/annotation write; lease released | CL:40,57,68–72,191–192 | R |
| CHR-35 | Toggle auto-tag new images | Analysis availability permits operation | Preference changes or refused switch resynchronizes | CC:52–54,281–285 | R/I; must not start provider work implicitly in synthetic run |
| CHR-36 | Start/restart or pause character scan | Analysis ready/scanning | Real scan state changes; no duplicate concurrent work | CC:59,289–293 | R/I |
| CHR-37 | Open unresolved image-character review | Pending candidate/banner or unnamed card | Candidate crop review presented | CC:163,295–305 | R/I fixture |
| CHR-38 | Select unresolved region | Current image, needs-review annotation | Region selection changes; no canonical edit | CR:137–145 | R |
| CHR-39 | Filter candidate characters | Region review open | Choice list filtered by name/alias | CR:104–105,116,165–178 | R |
| CHR-40 | Choose existing character for region | Current catalog character | Local choice set, new-name draft cleared; Save enabled | CR:167–184 | R |
| CHR-41 | Open Name this character | Current unresolved region | Name alert; no creation yet | CR:180,186–193 | R opening/A |
| CHR-42 | Edit proposed character name | Name alert open | Local field changes only | CR:188 | R/A |
| CHR-43 | Accept proposed name | Nonempty trimmed name <=200 characters | Local name chosen; existing identity may resolve on submit; no premature creation | CR:190–192 | A |
| CHR-44 | Cancel proposed name | Name alert open | Prior review state retained | CR:189 | A |
| CHR-45 | Save tag and advance | Valid existing/new choice; exact image/project context; not saving | Production review resolution updates tags/portrait crop and advances; original image bytes preserved | CR:106–108,195–205 | R/I fixture; repeated/stale acceptance gates |
| CHR-46 | Mark candidate Not a character | Current unresolved region; not saving | Ignored decision persists and advances; source image unchanged | CR:158,196–205 | R/I fixture |
| CHR-47 | Skip candidate for now | Current candidate; not saving | Session-local skip; candidate remains available next review | CR:159 | R |
| CHR-48 | Finish image-character review | Not saving | Sheet closes; unsubmitted choice/skip produces no canonical edit | CR:120–126 | R |

Tagged-image Inspect, Show in script, Download and Edit character tags from `CC:252–275` are variants of the IMG IDs below. Discuss character/image/source actions belong to the companion integration inventory. Character analysis provider execution/security is a service boundary; the local UI intent remains listed here, and global deduplication must not count it twice.

## Audio and shared transport: 31 counted interactions

Additional aliases: `AL` = `Audio/AudioLibraryController.swift`; `AE` = `Audio/AudioClipEditorController.swift`; `AT` = `Audio/AudioTransportView.swift`; `AC` = `Audio/AudioUIKitControls.swift`; `AW` = `Audio/WordTimingEditorController.swift`; `AD` = `Audio/AudioTimingDraft.swift`; `LT` = `Images/LayerTimelineViewController.swift`; `SB` = `Images/StoryboardViewController.swift`.

| Interaction ID | Action / variants | Preconditions | Observable result | Source callsite | CLI coverage / gap |
| --- | --- | --- | --- | --- | --- |
| AUD-001 | Open local audio library | Current workspace/scene | Same scene-scoped sheet via workspace menu or Layers Audio | WS:125; LT:22; AT:92 | R via Layers; M workspace |
| AUD-002 | Close library | Library open | Dismisses; valid already-started import continues | AL:42,161,169 | R |
| AUD-003 | Import local audio: at playhead or into dialogue | Saved positive-duration scene; valid position/target | Decode/measure asset and add local placement; captured source/scene preserved | AL:103,146,153; SC:418; STORE:1334,1348 | F/M; no synthetic audio import command |
| AUD-004 | Cancel audio file selection | Import picker open | Pending attachment cleared; no import | AL:168; STORE:1337 | F/A |
| AUD-005 | Select audio card | Visible card | Local selected styling; no clip mutation | AL:111,231,275 | G; UIView tap is not UIControl activate |
| AUD-006 | Play from chosen source: clip or script line | Current source; available in-scene audio for clip | Seek and start scene playback; active clip Play pauses; overlap is mixed, not solo | AL:128,243; SC:415 | R clip button, M source menu |
| AUD-007 | Change clip volume | Current clip | Only clip volume 0…1 changes | AL:119,124,212,274 | R slider |
| AUD-008 | Mute/unmute clip | Current clip | Clip mute changes; volume/placement retained | AL:120,219,269; LT:160 | R button; M menu |
| AUD-009 | Remove clip placement | Current clip | Library confirms; Layers removes immediately; source asset and script survive | AL:136,270; LT:160; STORE:1387 | M/A; confirmation difference is required route variant |
| AUD-010 | Cancel clip removal | Library confirmation open | Clip retained | AL:139 | A |
| AUD-011 | Open clip trim/timing | Current scene/clip | Local draft from actual clip | AL:113,221,268; LT:160; AE:19 | R library button; M other routes |
| AUD-012 | Edit source trim draft: text, ±100ms, waveform endpoints, accessibility | Timing editor open | Preview only; source-in can shrink duration; opposite endpoint preserved | AE:31,38,40; AC:70,75,95,176,193; AD:42,70 | R text/stepper; G drag/custom accessibility |
| AUD-013 | Edit draft placement offset | Timing editor open | Local scene-start/attached-line offset; source trim unchanged | AE:39,101; AD:54 | R |
| AUD-014 | Change draft attachment: scene/dialogue/direction | Valid offset and same-scene target | Absolute time retained where possible; clamp notice otherwise | AE:117,133; AD:59 | M |
| AUD-015 | Apply clip timing: Apply/Cmd-Return | Exact original/context; valid trim/offset/attachment | One update or no-op close; stale/invalid draft retained with error | AE:142,152; AD:74 | R |
| AUD-016 | Discard clip timing: Cancel/Escape | Timing editor open | No draft applied | AE:63,152 | R |
| AUD-017 | Move audio placement by Layers drag | Visible current clip | Preview then release changes offset, optionally word-snapped; trim/attachment unchanged | LT:161,199,206,225 | G |
| AUD-018 | Open word-timing review | Dialogue with words | Requested/first word draft; edit-lease acquisition | SC:419; LT:138; SB:189,372; AT:97; AW:100 | M opening routes |
| AUD-019 | Select another draft word | Word present in draft | Preserve pending other-word drafts; refresh fields/timeline/scroll | AW:41,49,115; AC:260 | R chips; G timeline/horizontal scroll |
| AUD-020 | Edit word start/end draft: text, ±100ms, endpoint drag | Selected draft word | Draft only; invalid typed input retained and omitted from preview | AW:50,53,142; AC:95,265; AD:112,119 | R text/stepper; G drag |
| AUD-021 | Save complete word draft: button/Cmd-Return | Lease; original words/duration/context; valid non-overlapping ranges | Atomic reviewed sequence; authored markers; invalid/stale draft retained | AW:152,164; AD:124 | R |
| AUD-022 | Discard word timing | Review open or acquisition pending | Cancel/Escape closes, cancels/releases lease, no canonical edit | AW:94,104,111,163 | R |
| AUD-023 | Toggle scene play/pause: button/Space | Positive duration; keyboard focus policy permits | Real clock starts/pauses; end restarts at 0; script caret preparation/restoration | AT:20,65; KEY:151,242; SC:99,116; STORE:1145 | E(transport), E(global-shortcuts); physical held-key/focus G |
| AUD-024 | Seek scene time: slider/ruler/word/audio block | Current scene/control | Playhead changes without independently starting playback; word may select | AT:79; LT:31,137,158,210; SB:189,372 | E(transport) slider; M/G other variants; “Play word” is seek-only |
| AUD-025 | Seek previous/next image boundary | Positive scene duration | Adjacent cue start beyond 100ms threshold, fallback start/end | AT:18,81 | R |
| AUD-026 | Change project audio volume | Project has clips | Persisted 0…1 project-wide volume; last nonzero retained | AT:28,71,80; STORE:1377 | R |
| AUD-027 | Mute/unmute project audio | Project has clips | Zero/restored nonzero volume across imported audio | AT:23,71; STORE:1384 | R |
| AUD-028 | Toggle Follow playback: Script/settings | Shared preference available | Active line follows playhead when enabled; preference shared across surfaces | SC:503,508; `Account/ScrivSettingsController.swift:39`; STORE:1143 | E(settings-navigation) preference only; actual following R |
| AUD-029 | Shift whole spoken word by Layers drag | Current word, legal room inside line/neighbors | Both endpoints shift once; IDs/text/images/audio preserved | LT:139; `apps/mac/Sources/ScrivCore/WordTimingEditing.swift:67` | G; UI supplies one word, not arbitrary phrase |
| AUD-030 | Retime word endpoint by Layers drag | Current word, valid range | One endpoint changes; crossing neighbors rejected atomically | LT:143; `apps/mac/Sources/ScrivCore/WordTimingEditing.swift:47` | G |
| AUD-031 | Cancel active Layers audio/word drag | Active gesture | Escape/disappearance/cancel clears preview without commit; playback stays paused | LT:165,199,224 | G; Escape alone cannot create missing gesture state |

The six shared transport/follow IDs AUD-023…028 are counted here once. Settings and image surfaces reference them. Clip/source playback AUD-006 differs from seek-only AUD-024. Numeric draft save and direct gesture release have distinct lifecycle contracts.

## Images: 56 counted interactions, six recovery cross-references

Additional aliases: `PV` = `Images/PreviewViewController.swift`; `IP` = `Images/ImagePickerViewController.swift`; `II` = `Images/ImageInspectorControllers.swift`; `CA` = `Images/CueAnchorViewController.swift`; `CV` = `Images/ImageCoverageViewController.swift`; `SP` = `Images/ImageSplitPreviewController.swift`; `DS` = `Images/ImageDurationScrubDriver.swift`; `DR` = `Images/ImageTimelineManipulationDriver.swift`; `DG` = `Images/ImageTimelineDragState.swift`; `BR` = `Images/GenerationBriefReviewController.swift`; `IU` = `Images/ImageUIKitSupport.swift`.

The image source traversal identified 62 operations. Six recovery-only operations, IMG-050…055, are cross-referenced rather than counted here because recovery belongs to the companion inventory. IDs are not renumbered to hide that boundary. Except simple word selection/clearing, no current image-authoring scenario was found; count/tab/empty-observer tests are not authoring coverage.

| Interaction ID | Action / variants | Preconditions | Observable result | Source callsite | CLI coverage / gap |
| --- | --- | --- | --- | --- | --- |
| IMG-001 | Select picture placement: card, rail, Layers tile, overlap choice | Existing cue/current context | Correct selected cue; card clears words/pauses, rail does not seek, Layers seeks start | SB:144,350; LT:105; PV:69–72 | R control, G tap, M overlap menu; side effects differ by route |
| IMG-002 | Follow current playhead picture | Current/selected cue exists | Select current cue; Storyboard also scrolls to it and clears words if cue changes | PV:68; SB:208–211 | R |
| IMG-003 | Select Storyboard words: click/Cmd/Shift/marquee | Visible source words | Replace/toggle/range-union selection and corresponding cue; no source edit | SB:194–200,224–235 | E(picture-coverage/follow) plain click only; G modifier/marquee |
| IMG-004 | Clear Storyboard words: Deselect/background/Escape | Word selection active | Words clear; cue/playhead retained; Escape also cancels duration scrubs | SB:62,203–204,219–221 | E(picture-coverage/follow) Deselect; G background; R key |
| IMG-005 | Change Layers presentation: expand/collapse, larger sheet/close | Preview/Layers available | Same timeline data in chosen presentation; no project edits | PV:33,91–103; LT:24–26; IU:130–131 | R; modal toolbar close needs proof |
| IMG-006 | Change timeline zoom | Layers visible | Geometric scale changes/caps for long scenes, timing unchanged | LT:19–20,44 | R slider |
| IMG-007 | Toggle timeline snapping | Layers visible | Later drag snap setting changes; image offset/coverage Shift bypass distinct | LT:21,170,206–208; DR:68 | R toggle; G Shift-drag |
| IMG-008 | Add picture placement | Positive scene duration; valid interior playhead | Adds/selects cue, splits existing cue or fills gap; invalid boundary atomic | SB:63; STORE:1238–1240 | R |
| IMG-009 | Begin image import | Valid captured destination | Opens image picker; pauses without seeking/changing inspected cue | SB:63,98,361; PV:59,111; STORE:1392–1407 | R/M opening; F picker |
| IMG-010 | Accept image file import | Saved package; PNG/JPEG/WebP; valid captured target | Real import attaches intended existing/new cue; later navigation not overridden | STORE:1405–1407,1420–1435 | F; no image import command |
| IMG-011 | Cancel image import | Picker open | No asset/project mutation; initial pause remains | STORE:1392–1407 | F/A |
| IMG-012 | Open image/version chooser | Existing target cue | Project-wide or lineage-filtered chooser; missing-image route included | PV:56,84,105,110; SB:359; IP:18–19,50 | R/M |
| IMG-013 | Filter image choices | Chooser open | Case-insensitive direction/title/character-name/alias matches | IP:51–59 | R; search delegate delivery needs native proof |
| IMG-014 | Preview image choice | Matching cell visible | Local selected image/checkmark only | IP:65–66 | R collection-cell activation |
| IMG-015 | Use chosen image/version | Target/image current; editable cue | Only target image identity changes, other uses/discussions preserved | IP:33,47,72–75 | R |
| IMG-016 | Cancel image chooser | Chooser has optional local choice/query | Closes without cue-image mutation | IP:32; SCREEN:35–49 | R button/key |
| IMG-017 | Fetch missing image | Known asset lacks verified local bytes | Guarded storage/peer recovery, deduplicated active request; not local retry | PV:56; II:55–60; SB:360; CC:258; STORE:1716–1736 | R/M/I |
| IMG-018 | Retry failed local image read | Configured view in failed local load state | Retries read/digest/decode, no network fetch | `Images/UIKitAssetImageView.swift:58–59,81–120` | R; failure fixture required |
| IMG-019 | Inspect exact image version | Existing image ID, local bytes optional | Original version metadata/bytes, not rendition from current source | PV:26,57; SB:357; LT:181; II:21–31; CC:252 | R/M |
| IMG-020 | Close inspector | Inspector open, including missing asset | Dismiss only | II:25,27; SCREEN:35–49 | R |
| IMG-021 | Show image in script | Exact version currently placed | Select scene/cue/seek; inspector also selects anchor entry and dismisses | II:42–43,63–67; CC:255–256 | R/M; route side-effect difference retained |
| IMG-022 | Show/hide captured prompt | Inspector open | Historical submitted text or explicit not-captured state, never inferred history | II:37–39,49 | M |
| IMG-023 | Copy image prompt: manual or captured | Nonempty eligible prompt | Exact selected prompt copied; unavailable variants disabled/absent | II:49–50 | M/F; no clipboard observer |
| IMG-024 | Share original image | Verified local original URL | System share sheet with original file; external recipient/commit separate | II:51 | M/F; sharing needs authorized recipient/action |
| IMG-025 | Open pictured-character tags | Asset exists | Exact-version tags editor via Preview/inspector/Characters | PV:82–83; II:33; CC:270–275 | R |
| IMG-026 | Toggle pictured character tag | Image/character exist; no foreign lease | Immediate canonical add/remove on exact version | II:102–117 | R; lease/context variants need fixture |
| IMG-027 | Close tags editor | Tags editor open | Dismiss; previously saved toggles stay, unlike chooser Cancel | II:121–122; SCREEN:35–49 | R |
| IMG-028 | Open picture source editor | Existing cue | Captures original and acquires lease; Save initially disabled | CA:18–20,43–50; LT:113,183 | M; custom accessibility activation missing |
| IMG-029 | Choose source entry | Source editor; target in same scene | Local dialogue/direction owner; offset resets to zero, bounds/quote refresh | CA:58–70 | M |
| IMG-030 | Preview source offset: seconds/stepper/drag | Editable source/current original | Local offset/ghost only; stays in owner slot, zero-owned stays zero | CA:32–38,67–77; DR:38–88; DG:51–64 | R text; G stepper primitive/drag |
| IMG-031 | Commit source/offset | Current cue/source/context; legal offset; lease | One setCueAnchor or no-op; unrelated pictures/audio preserved | CA:79–87; DR:90–106 | R save if reached; G release |
| IMG-032 | Cancel source/offset | Source editor or active offset drag | Dismiss/reset geometry, release lease; no timing mutation | CA:44,53; DR:102–106; LT:165–168 | R button/key; G drag state |
| IMG-033 | Open precise picture-coverage editor | Cue exists | Captured authored duration and lease; ordinary click/menu/accessibility variants | SB:315; PV:114; LT:112,184; CV:18–27 | R click; M menu; G accessibility |
| IMG-034 | Preview picture coverage: numeric/vertical scrub/right grip | Editable captured cue | Preview only; authored tail beyond scene retained | CV:21; DS:30–64; DR:68–88; DG:65–69 | R numeric; G gestures |
| IMG-035 | Commit authored picture coverage | Current cue/context/lease; 1ms…24h | One setCueDuration; no-op/stale/detached/denied cases do not author | CV:31–36; DS:66–75; DR:90–100 | R numeric; G gestures |
| IMG-036 | Cancel picture coverage | Numeric draft or active gesture | Restore saved duration/release lease, no authored mutation | CV:26,29; DS:77–88; SB:203–204; DR:102–106 | R/key; G gesture state |
| IMG-037 | Open picture split preview | Cue; no conflicting modal | Pause; cut starts at interior playhead or midpoint | SP:17–20,68–77; SC:354–356 | R script button; M menu routes |
| IMG-038 | Move split-preview cut | Split sheet open | Slider/marker/before-after durations only; no seek or project edit | SP:33–35,54–61 | R slider |
| IMG-039 | Commit picture split | Interior cut, captured revision/cue current | Two cues retain exact version; script/words/audio unchanged; immediate Layers variant at playhead | SP:64–66; LT:187; STORE:1216–1220 | R button; M immediate menu |
| IMG-040 | Cancel split preview | Split sheet/popover | Local cut discarded; no seeking/edit; pause remains | SP:36,70; SCREEN:35–49 | R button/key |
| IMG-041 | Preview shared-cut drag | Unobscured adjacent movable cues | Local edge/grip translation without canonical edits | SB:333–342,432–436; LT:117–124,225–230 | G |
| IMG-042 | Commit shared-cut drag | Exact captured cues/context; legal positive durations | One boundary edit; Storyboard 20ms/point vs Layers scale/snap | SB:339–341,436; LT:121–123,200–201 | G |
| IMG-043 | Cancel shared-cut drag | Active gesture | No mutation; Layers Escape cancels; Storyboard Escape currently does not call shared-cut driver | SB:204,436; LT:166–167,224–230 | G; do not assume Escape parity |
| IMG-044 | Move edge words to adjacent image | Contiguous edge phrase; legal adjacent unobscured cut | Cut moves around words; source word text/order/timing preserved; select destination | SB:373–394; STORE:1223 | M/G; local drag payload identity/fences required |
| IMG-045 | Merge with next picture placement | Valid adjacent movable cut | Left image/version retained, right cue removed, scene/script time unchanged | SB:365–367; `apps/mac/Sources/ScrivCore/ProjectEditing.swift:113–120` | M |
| IMG-046 | Request placement removal | Current cue | Confirmation only, promises asset/script/word preservation | SB:369 | M |
| IMG-047 | Confirm placement removal | Confirmation/current navigation | Delete cue only; asset/source remain | SB:369; IU:136–138 | A |
| IMG-048 | Cancel placement removal | Confirmation open | Cue/project unchanged | IU:136–138 | A |
| IMG-049 | Edit/clear optional image direction | Cue-scoped recovery ready | Pause on edit; accepted text durably journaled, empty clears override only | PV:249–250,275–289; `Images/GenerationComposerViews.swift:21–23` | R; native delegate/journal ordering not proven by type |
| IMG-056 | Open generation-brief review | Current presentation scope/context, no modal | End editing; immutable source/identity/portrait request captured | PV:220–228; BR:18–28 | R |
| IMG-057 | Switch brief section: Source/People/Exact request | Valid review | Read corresponding captured content only | BR:123,151–162,300 | R segment/button |
| IMG-058 | Follow source-person link | Resolved person in request | Switch People, expand identity, reveal header | BR:164–196,234–238 | R |
| IMG-059 | Expand/collapse person details | Valid People section/person | Disclosure with bounded scroll; no canonical edit | BR:199–205,255–285 | R |
| IMG-060 | Copy full exact request | Review still current | Exact captured text copied; invalidation blocks stale copy | BR:45–47,65–75,320–321 | R action/F clipboard evidence |
| IMG-061 | Close brief review: Done/X/Escape | Valid or invalidated review | Only dismissal; never generate/save/rebase/discard | BR:5–6,45,55–64,103–108 | R/key |
| IMG-062 | Generate image for captured placement | Saved project; content; settled recovery; available references | Flush/capture real request, launch job; attach only in valid scope or retain for recovery | PV:212–216,249–252; SB:362; LT:186; STORE:1496–1566 | R/M/I; image-evidence-isolation is not generation coverage |

Recovery-only references, excluded from the count: `IMG-050` retry rejected attempted text (`PV:259–262`); `IMG-051` use recovered draft (`PV:264–270`); `IMG-052` retry save/recovery preparation (`PV:270`); `IMG-053` request local direction discard (`PV:271`); `IMG-054` confirm exact scoped discard (`PV:271`, `IU:138`); `IMG-055` cancel discard (`IU:138`). The companion recovery journey must preserve saved direction, exact newer draft, scope and lease fences. These reserved references should be reconciled with its canonical IDs rather than silently duplicated.

Generation cancel-in-progress (`Account/ScrivGenerationProgressView.swift:29–34`), generation history retry/recovery, authentication and provider setup belong to integrations. Image/source discussions also reference integration IDs. Add character from empty tags (`II:120`) uses CHR-05; direction/source buttons in Storyboard/Layers use SCR-01; owned-entry duration uses SCR-27…33, not IMG coverage. Timeline audio/word editing and seek use AUD IDs.

## Proposed base journeys: 16 in this scope

These are test architecture, not new implementations. A normal case should usually be 6–12 meaningful steps plus saved/UI assertions. Run cancel/failure/stale variants as independent parameter cases with fresh setup, not one enormous stateful script. Some families will need separate UI-control and semantic-command modes; those are declared route variants, never silently interchangeable evidence.

| Journey ID | Base outcome / short spine | Primary interaction IDs | Parameter and interruption cases |
| --- | --- | --- | --- |
| AUT-J01 | Navigate, find and read: switch tabs → search → next/previous → close → zoom → return | NAV-01…03; SCR-23…26,37 | Script/Characters/Storyboard; text/name/alias; empty/zero/one/multiple/wrap; narrow/wide; active selection; typing/composition; menu open/dismiss; vertical/horizontal scroll |
| AUT-J02 | Write exact source: add → edit/select → split → merge → finish → shared save/undo/reopen assertions | SCR-01…08 | Dialogue/direction; first/middle/last; empty/end split; selected spans; emoji/combining/ZWJ/repeated names; placeholder consumed once; native deletion vs replacement; pending lease; draft/journal rejection; native text undo vs project undo |
| AUT-J03 | Restructure scene: select/create/rename scene → add/move source/change speaker → delete or cancel | SCR-09…22 | Single/multiple/empty scene; move ends; equal orders; no speaker; renamed/deleted character; confirm/cancel; stale menu/navigation; zero-owned source; source-owned cue/audio retention |
| AUT-J04 | Author source timing: open numeric draft → accept/cancel → preview scrub/rail → release/cancel | SCR-27…36 | Zero/1ms/hour/invalid values; owned vs coverage independence; direction/dialogue; authored words; image erasure rejection; no-motion/repeated release; gesture cancellation; delayed/denied lease; row growth while editing; stale source/context |
| AUT-J05 | Maintain character catalog: create/edit fields/colors/aliases → save → search/select → portrait → delete/cancel | CHR-01…21 | Exact Unicode and canonical-only changes; name/alias/profile byte bounds; duplicate/case/comma alias; custom color; clean/dirty close; stale authored fields; changed portrait; empty/deleted catalog; source/image/link preservation |
| AUT-J06 | Review text identities: open source review → choose/confirm/unlink → find exact occurrence → save/cancel | CHR-22…34 | Canonical/alias/ambiguous/reused name; first vs repeated occurrence; emoji/UTF-16; overlap; pending correction blocks save; pagination 40/20; no-match; source/links changed; lease denial/retry/close; wording never rewritten |
| AUT-J07 | Review pictured identities: scan setting → choose unresolved crop → existing/new character → save/ignore/skip → finish | CHR-35…48 | Provider ready/unavailable; pause/restart; multiple crops; duplicate name identity; changed image/version; repeated submit; skip persists only for session; original bytes unchanged; blocked name alert retained explicitly |
| AUT-J08 | Acquire, reuse and inspect image: add/select placement → import/choose version → inspect/tags → return to source | IMG-001…002,008…027 | Gap/interior/existing placement; PNG/JPEG/WebP/corrupt; cancel; local/missing/digest failure; search/lineage; chosen asset removed; no characters; tags autosave vs chooser cancel; historical prompt present/absent; explicit share/clipboard fixture |
| AUT-J09 | Anchor and split picture: choose source/offset → coverage preview/save → split preview/cancel/commit | IMG-028…040 | Dialogue/owned/zero-owned direction; zero/end/last-valid offset; 1ms/24h/beyond-scene authored tail; no-op; snap/on/off/Shift; delayed lease; changed source/revision; detached sheet; exact image version and source/audio preservation |
| AUT-J10 | Assign words to pictures: select/range/clear words → shared-cut preview → phrase transfer/merge/delete | IMG-003…004,041…048 | Plain/Cmd/Shift/marquee; prefix/suffix/interior/discontiguous phrase; adjacent/overlap/gap; invalid/stale/nonlocal drag payload; repeated/cancelled release; same image identities; no word retiming; cancel deletion |
| AUT-J11 | Inspect and manipulate Layers: expand → larger sheet → zoom/snap → image/audio/word drag variant → cancel/close | IMG-005…007; references IMG-030…036,041…043 and AUD-017,029…031 | Tiny/very long scene; horizontal scrolling; numeric vs geometry agreement; gestures paused/live; old shared-cut snap vs Shift-aware offset/coverage; Escape variant differences; viewport change mid-drag |
| AUT-J12 | Review then generate an image: edit visual direction → open brief → source/people/exact request → copy/close → generate | IMG-049,056…062 | Empty/multiline/Unicode override; people/aliases; missing/local/shared portraits; stale source/cue/project; invalidated copy; provider success/failure/cancel; attach vs retain; reference recovery and generation-history families rather than duplicate them |
| AUT-J13 | Import and manage local audio: open → import/cancel → select/play/mix/mute → remove/cancel → close | AUD-001…010 | Scene/dialogue; start/middle/end; positive/zero duration; silent/short/long/invalid audio; busy/close during decode; changed target/project; overlapping/missing clips; library confirmation vs direct Layers remove; preserve recording |
| AUT-J14 | Trim/place audio: open draft → trim → offset/attachment → apply/cancel → direct timeline move | AUD-011…017 | Text/stepper/waveform/custom accessibility; decimal/millisecond/NaN/negative/oversize; source-in auto-shrink; scene/entry attachment and absolute-time clamp notice; stale clip; no-op; source bytes unchanged; snap/cancel drag |
| AUT-J15 | Author word timing: open → select two neighbors → draft ranges → save/cancel → direct shift/endpoint variant | AUD-018…022,029…031 | Ordered/gap/touching/overlap/reversed/out-of-line; invalid raw draft recovery; exact IDs/text/authored markers; pending/denied lease; context switch; stale duration; word vs phrase; no commit during gesture preview |
| AUT-J16 | Play and follow the authored scene: play/pause → seek/boundaries → volume/mute → follow → tab round trip | AUD-023…028 | Every tab; zero/end scene; repeated commands; native held-key/focus loss; typing/marked text; caret restoration; overlapping cue latest-start policy; 100ms boundary threshold; volume restoration; one transport owner |

Count reconciliation: **3 navigation + 37 Script + 48 Characters + 56 Images + 31 Audio = 175 interaction groups. 16 journey families.** J11 deliberately reuses gesture steps owned by other families, not additional interactions. A journey family can have multiple independently run variants; therefore 16 is the proposed reusable base count, not the final executed-case count or a claim that all current gaps can already run. Root integration/service inventories must be merged before stating a whole-app count.

## Work backwards from old assertions, not old test names

For each frozen assertion, record: original inventory ID and assertion source/hash; destination journey and interaction IDs; parameter row and control variant; observable assertion and evidence boundary; actual-app run identity; any residual lower-layer/fault claim. One old method can feed several journeys, and one journey can absorb many old methods. Do not discard a residual claim simply because the happy-path journey passes.

Initial reverse-mapping buckets, to be expanded into the executable mapping after the interaction inventory is accepted:

| Frozen source / examples | Destination | Assertion contracts to preserve, not just broad feature labels |
| --- | --- | --- |
| `WorkspaceEndToEndTests.swift` ::0001,0008…0012,0017,0020; `WorkspaceVisualLayoutTests.swift`; `ScrivPlaybackKeyboardPolicyTests.swift` | J01/J02/J16 | Same live editor and widths/scroll across tabs; current search highlight; placeholder selection once; exact key focus/repeat gating; actual geometry at original viewport, not a substituted size |
| `ScriptUIKitTests.swift` ::0001…0005,0008…0015; `ScriptBoundaryEditingTests.swift`; `EditingTests.swift` ::0002…0009,0011,0013…0014 | J02/J03/J04/J06 | Journal-before-native-mutation; rejected-edit atomicity; exact source/selection/word/link identities; split/merge timing/anchors; source-owned coverage; unchanged unrelated records; no direct algorithm calls as e2e replacement |
| `TimingTests.swift`; `CueAnchoringTests.swift`; `ImageInteractionPolicyTests.swift`; `ImageTimelineDragTests.swift` | J04/J09/J10/J11/J16 | Owned vs forward coverage; authored vs clipped tail; correct owner at zero-time boundaries; overlap/latest-start policy; preview-only then one release; cancellation and stale-context/revision fences |
| `CharacterTeamTests.swift` ::0001…0006; `CharacterFormTests.swift`; `CharacterMentionTests.swift`; `WorkspaceEndToEndTests.swift` ::0018,0021 | J05/J06/J07/J08 | Field/encoded bounds, alias order, exact Unicode spans, stable confirmed identity on rename/delete/reuse, explicit unlink; portrait choice/removal/missing state; no source rewriting or image retargeting |
| `ImagePickerSelectionAppearanceTests.swift`; `CueAnchorOffsetTests.swift`; `WorkspaceEndToEndTests.swift` ::0013,0016,0019 | J08/J09 | Exact chooser selection and stale asset behavior; offset synchrony/zero-owned disabled control; singular count; missing-image Inspect/retry eligibility |
| `ImageImportPlacementTests.swift`; generation/brief/portrait tests found in frozen inventory | J07/J08/J12 plus integration recovery | Captured target/version/request, verified bytes, immutable history, identity/tag/crop semantics, stale attachment retained rather than silently retargeted; provider-specific authority remains service gate |
| `AudioTimingDraftTests.swift`; `AudioTrackTests.swift`; `WordTimingEditingTests.swift`; `WorkspaceEndToEndTests.swift` ::0006,0014…0015 | J13/J14/J15/J16 | Real measured waveform/source trim; exact scene/entry anchoring; retained invalid drafts/notices; atomic multiword apply; untouched images/audio/neighbor words; asset path/digest security remains separate service/fault gate |
| `WorkspaceDurabilityTests.swift`; editor/prompt journals and repository/lease tests | Shared persistence/recovery and service fault gates, referenced by all writing journeys | Journal disk failure, storage recovery, concurrent lease/account fences, crash/reopen and timing ordering are not proven by normal saved JSON alone |

The frozen 1,129 entries also contain cloud, update, security, protocol, selfcheck and verification behavior with no UI action. Those are not invented as authoring interactions and must not be deleted to reach a smaller journey count. Already retired entries remain governed by their recorded accepted mappings; this planning document retires none.

## Frozen 688-site checklist reconciliation

`cli-migration-inventory.json` remains unchanged. Its `ui_candidates` contains 688 **regex occurrences** at baseline `4d14b29f4fb49891e850fa9a8e5742dc878603c8`: control construction, action registration, selector, delegate, gesture and identifier sites. Multiple occurrences can describe one control; many controls implement the same interaction. Some are helper/dead presentation code. This review used the candidate file distribution as a checklist and then read current callsites. It did **not** mark every one of 688 candidates individually complete.

There are 470 candidate occurrences in the five directories below. This is a checklist slice, not the source of 175, not a distinct-interaction count, and not a coverage percentage. App project/integration routes and Script recovery inside that slice are cross-references. Shared keyboard/controller helpers outside it were also inspected. The remaining 218 baseline occurrences are not all outside authoring semantics: shared helpers require cross-owner reconciliation.

| Frozen source file | Candidate occurrences | Current interaction disposition |
| --- | ---: | --- |
| `apps/catalyst/ScrivUIKit/App/ScrivWorkspaceController.swift` | 44 | NAV + companion project/integration routes |
| `apps/catalyst/ScrivUIKit/App/ScrivWorkspaceHeader.swift` | 4 | NAV + companion project/integration routes |
| `apps/catalyst/ScrivUIKit/Audio/AudioClipEditorController.swift` | 12 | AUD |
| `apps/catalyst/ScrivUIKit/Audio/AudioLibraryController.swift` | 24 | AUD |
| `apps/catalyst/ScrivUIKit/Audio/AudioTransportView.swift` | 7 | AUD |
| `apps/catalyst/ScrivUIKit/Audio/AudioUIKitControls.swift` | 19 | AUD |
| `apps/catalyst/ScrivUIKit/Audio/WordTimingEditorController.swift` | 11 | AUD |
| `apps/catalyst/ScrivUIKit/Characters/CharacterEditorController.swift` | 14 | CHR; tagged-image operations → IMG; discussion → integrations |
| `apps/catalyst/ScrivUIKit/Characters/CharacterImageReviewController.swift` | 15 | CHR; tagged-image operations → IMG; discussion → integrations |
| `apps/catalyst/ScrivUIKit/Characters/CharacterLinksController.swift` | 14 | CHR; tagged-image operations → IMG; discussion → integrations |
| `apps/catalyst/ScrivUIKit/Characters/CharacterTeamUI.swift` | 4 | CHR; tagged-image operations → IMG; discussion → integrations |
| `apps/catalyst/ScrivUIKit/Characters/CharactersController.swift` | 38 | CHR; tagged-image operations → IMG; discussion → integrations |
| `apps/catalyst/ScrivUIKit/Images/CueAnchorViewController.swift` | 8 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/GenerationBriefPresentation.swift` | 5 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/GenerationBriefReviewController.swift` | 18 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/GenerationComposerViews.swift` | 2 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/ImageCoverageViewController.swift` | 2 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/ImageDurationScrubDriver.swift` | 4 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/ImageInspectorControllers.swift` | 14 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/ImagePickerViewController.swift` | 7 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/ImageSplitPreviewController.swift` | 6 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/ImageTimelineManipulationDriver.swift` | 3 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/ImageUIKitSupport.swift` | 7 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/LayerTimelineViewController.swift` | 19 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/PreviewViewController.swift` | 34 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/StoryboardViewController.swift` | 56 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Images/UIKitAssetImageView.swift` | 2 | IMG; audio/word timing → AUD; owned source timing → SCR; recovery → companion |
| `apps/catalyst/ScrivUIKit/Script/RecoveredDraftController.swift` | 8 | SCR + CHR links + IMG split + AUD playback; recovered drafts → companion recovery |
| `apps/catalyst/ScrivUIKit/Script/ScriptDirectionRails.swift` | 9 | SCR + CHR links + IMG split + AUD playback; recovered drafts → companion recovery |
| `apps/catalyst/ScrivUIKit/Script/ScriptDurationScrubDriver.swift` | 3 | SCR + CHR links + IMG split + AUD playback; recovered drafts → companion recovery |
| `apps/catalyst/ScrivUIKit/Script/ScriptScreenController.swift` | 41 | SCR + CHR links + IMG split + AUD playback; recovered drafts → companion recovery |
| `apps/catalyst/ScrivUIKit/Script/ScriptTextViews.swift` | 16 | SCR + CHR links + IMG split + AUD playback; recovered drafts → companion recovery |

Additional shared baseline checklist sources: `Shared/ScrivPlaybackKeyboardRouter.swift` (28 sites), `Shared/ScrivScreenController.swift` (2), `Shared/DurationHoldFeedback.swift` (4), `Shared/ScrivUIKitTheme.swift` (1). These contribute keyboard/dismiss/visual-feedback/control-factory variants, not 35 new interactions. File chooser and generic error presenter sites belong to integration/system presentation boundaries.

## Known uncertainties and non-invented actions

- This is a reviewed source catalog, not native reachability certification. A source reference can become unreachable through layout, menu presentation, lease state or missing data; runtime evidence must establish it before marking a route supported.
- `ScrivPlaybackControlsView` in `Images/PreviewViewController.swift:151–185` has no constructor references in the inspected checkout. Its duplicate transport controls are excluded as dormant, pending native confirmation. Active transport is AUD-023…028.
- No active Images control was found for image rotation, manual crop, pinch-zoom, generic asset deletion or editing an image label. Model capabilities alone do not add user interactions.
- Storyboard “Play word” only seeks. Script “Play from here” seeks **and** starts. A shared label must not erase that difference.
- Storyboard Escape clears words/cancels duration scrub but does not currently call its shared-cut driver. Layers Escape cancels its timing drivers. Preserve this difference until product behavior is deliberately changed and tested.
- Shift bypass is explicit for image source-offset/coverage manipulation, not the older shared-cut/audio snapping helper. Do not assert a universal Shift behavior.
- Some image controllers set `isModalInPresentation` on themselves while the shared Escape guard checks the navigation container. Prove the actual Cancel/Escape lifecycle instead of assuming equivalence.
- Character profile, source editor and visual-direction text require exact native delegate/journal ordering. An API insertion or saved outcome alone cannot prove IME, clipboard, physical key, rejected-edit and crash boundaries.
- Local synthetic runs must not turn on real pairing/runtime bootstrap, provider generation, auto-analysis, external shares or live asset recovery merely to populate fixtures. Keep integration authorization and deterministic synthetic setup explicit. No real user packages, images, recordings, credentials or recipients are fixtures.
- Availability of public `WorkspaceStore` actions does not solve missing physical automation. A typed production command layer can provide explicitly labeled semantic coverage while retaining validation, journals, undo and normal saves; it cannot be reported as proof of blocked menu/alert/gesture routes.
- Current count is intentionally revisable only through reviewed additions/deduplication. Do not multiply by values or old assertion count; do not collapse a distinct commit/cancel/recovery boundary merely to hit a desired smaller number.

## Acceptance gate for turning this plan into the suite

1. Merge companion inventories and resolve cross-owner IDs; agree the finite interaction-type and base-journey counts.
2. For every interaction, retain its explicit route matrix, preconditions, mutation boundary, result and current CLI gap. Identify unsupported physical routes without bypassing OS/security restrictions.
3. Implement/reuse one base journey at a time; parameterize route/data/state families. Keep failure cases isolated so an unresolved modal cannot contaminate later cases.
4. Map frozen assertions backwards to actual checkpoints and parameter rows. Source-only/low-level claims needing fault injection remain separate gates until their real replacements exist.
5. Run the matching actual app; capture source/bundle identity, UI and persisted evidence, negative outcomes and bounded cleanup. Only then update the existing retirement ledger. This document itself changes neither source nor retirement state.
