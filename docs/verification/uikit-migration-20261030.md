# UIKit migration — source checkpoint and verification boundary

## Framework and preserved baseline

The user explicitly requested finishing and committing the SwiftUI checkpoint, then rewriting the UI entirely in UIKit. The preserved checkpoint is `e14c64cc50ea231bd0f10ac42f9a6b0dc19b9ea9`. Its two expression-decomposition fixes were committed, but its native rebuild could not start with roughly 243 MiB free on the available Mac. The previous native Core retry was 221/222: its remaining failure compared `/var` with `/private/var` in an artifact-path test, **not** an outstanding disk-full fixture. This source increment canonicalizes that expected URL; all rejection assertions remain.

The new target is `apps/catalyst/ScrivUIKit.xcodeproj`, app module `ScrivUIKit`, bundle ID `app.scriv.uikit`, built with UIKit and Mac Catalyst. No SwiftUI, hosting controller, legacy `App.swift` or legacy view enters this target. The previous app and history remain intact, side by side. Shared Core and cloud service code retain the existing data, authorization and image-version contracts.

## Implemented source coverage

- Workspace chrome, project actions, Script/Storyboard/Characters tabs, playback transport and opaque docked Discussion.
- Project browser/search/local/cloud/team filtering, import/export, history comparison/restore, reviewed editor recovery.
- Native UITextView editing, exact UTF-16 journal-before-acceptance, lease/context fencing, stable linked identities and source rails.
- Single-click caret, Cmd+Enter edit toggle, edit-mode newlines, atomic split/merge, source/word identity preservation and whole-project undo. Merge keeps the previous owned duration and rejects impossible timing or incompatible entry kinds rather than silently losing assets.
- Shared persisted script zoom, smaller 14-point baseline, Cmd+/Cmd= and Cmd− across script-bearing views. Space toggles playback only outside text input; text spaces and IME are preserved. Explicit pause returns the script caret after the actual paused/completed word when the script is visible. The user’s ambiguous in-edit playback shortcut is not guessed.
- Audio import/library/trim, precise word timing and batch validation, source-aligned waveform controls, volume/mute and real playback.
- Character creation/edit/link review, portraits/tagged images, team membership/roles/invitations and existing billing authorization.
- Image preview/version detail/picker/character tags, generation prompt recovery, source-anchor and authored-coverage inspectors, timeline and storyboard interactions. Source-owned image offset and duration controls preserve source identity unless re-anchoring is explicit.
- Email sign-in, account/sync/conflict state, Settings, generation jobs/retry/recovery and truthful generation stage/elapsed/cancel feedback. Decorative progress concepts were not substituted for real state.

## Runtime boundary

Actual Mac SDK checks established that Catalyst cannot use `Process.run` or named `NSXPCConnection`; it can use supported networking. The separate Foundation/Network macOS [Runtime Companion](../../apps/runtime-bridge/README.md) owns the explicitly requested local Codex child. It binds only numeric loopback, authenticates both directions with HMAC, rejects replay/clock/instance drift, bounds messages and allows only the existing restricted Codex protocol. It does not install itself, register a daemon, start on login, transmit ChatGPT credentials, or silently switch to a cloud runtime.

The user explicitly opens and pairs the companion through a private owner-only file; persistent pairing lives in device-only Keychain. Settings can explicitly adopt a single-owner legacy generation journal through a selected folder, preserving its installation identity and records. Mixed-owner or inaccessible folders are rejected. Build-time signing is development-only unless an authorized release identity is supplied.

**No native companion launch, pairing, process/stdio round-trip, installed-account generation or new screenshot parity was proven on Linux.** These remain acceptance gates on a Mac with adequate space. The existing installed Mac Codex preflight reported included usage allowed; that does not prove the new bridge or an image-generation run.

## Durable UIKit lifecycle

UIKit background/termination callbacks cannot defer shutdown like the legacy app. Accepted mutations therefore enter a private bounded immutable `PendingProjectSaveJournal` before they become current in memory. Initial projects remain discoverable before `project.json` exists. Source and target hashes, contiguous revisions, account/origin/package context and accepted history fence replay. Storage failures reject the new mutation and retain older records; no automatic eviction occurs.

Normal and recovery repository writes share a cooperative, symlink-rejecting package lock. Recovery rechecks the exact current source inside that lock, writes history before current state and flushes files/directories before acknowledgement. An already-published exact target is idempotent only with exact history proof. Diverged or wrong-account packages remain untouched and require reopening in their proper context. Existing invalid-editor and manual-prompt journals remain separate and private. These journals are not cloud metadata or package exports.

## Evidence

- **266 portable Swift Core tests passed**, including 16 pending-journal cases, five exact-source repository recovery cases and 12 atomic script-boundary cases; optimized Core build passed.
- Current UIKit/client sources exclude SwiftUI/AppKit hosting by target/source scan; all Catalyst sources/tests syntax-parse, and project/plist/scheme/build-script checks pass. Parsing is not SDK type-checking.
- Focused unchanged-source Linux harnesses passed eight audio draft tests, 13 keyboard policy/repeat tests, script session/presentation invariants and character/team helper assertions. UIKit responder, controller and Store integration tests were authored but **not run** on Linux.
- The final source pass also ran 21 Node tests, strict TypeScript/repository checks, and exact deployed-cloud input hash verification, all passing.
- Source evidence is retained under ignored `build/uikit-integration/` and feature-owner verification directories; private pairing files, credentials, runtime journals and build products are excluded from publication.
- Backend resources, authorization, paid-only binary hosting and free script/timing/prompt metadata are unchanged. The deployed Worker remains version `83ac3161-1fd4-4e1d-9070-f8a309cf84a6`; prior live cloud evidence is in [deployment verification](cloud-deployment-20261029.md). No new deployment or OTP send was needed.

## Required native acceptance

Build both targets using Xcode 26.2; run `ScrivUIKitTests`; exercise physical-key repeat/modifiers/IME, text selection/undo/split/merge, source rails/duration/offset/cuts, all modal forms, account flow, project bookmark reopening and interrupted-save recovery. Verify companion explicit launch/loopback/authentication/stop/lease/restart, migrate an explicitly selected legacy journal, and perform the authorized real generation test. Capture and compare all approved screens from the actual UIKit app. Signing/notarization and multiplayer remain separate gates. No Actions workflow was changed or dispatched; no source was edited on the user’s Mac.
