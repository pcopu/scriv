# UIKit migration contract

The preserved SwiftUI checkpoint is `e14c64cc50ea231bd0f10ac42f9a6b0dc19b9ea9`. Its native rebuild remains pending on available Mac disk space; do not label it native-passed.

The new application target is **UIKit + Mac Catalyst only**. Do not compile SwiftUI views, hosting controllers, NSViewRepresentable, or the legacy `App.swift` into this target. Existing domain models, cloud authorization, private recovery and immutable image-version behavior must remain intact.

## Shared controller contract

- Use `ScrivScreenController.init(store:scopeToProject:)`; ordinary feature controllers expose `init(store: WorkspaceStore)`. Account-global controllers pass `scopeToProject: false`.
- Override `storeDidChange()` for idempotent rendering. Keep native text/form identity and selection stable; do not overwrite pending local edits on a publish.
- Before applying captured project-item edits, check `requireCurrentContext()` and the existing exact source/version fence. Scope forms to stable IDs. Cancellation must not mutate canonical data.
- `ScrivUIKitTheme` provides UIKit colors, fonts, stack/card/button/notice factories. No SwiftUI appearance adapters.
- Use `show(ScrivUIKitRoute)` or `ScrivUIKitRouter.shared.present(_:from:store:)`. Associated values carry one immutable request payload.
- Each feature owns an extension on `ScrivUIKitFeatures` with an explicitly named registration method accepting `ScrivUIKitRouter`. Register only your own kinds. Factories receive `(route, store)` and return a controller, or nil for a mismatched payload.

## Ownership / registration

- Coordinator: App, Shared (keyboard file owned by character/team worker); Xcode project/build configuration; WorkspaceStore, resource/presentation/file/durability adapters. `registerDiscussion(in:)` if additional routes are agreed.
- Script/project owner: Script + Projects + Discussion (docked shell panel). `registerScriptAndProjects(in:)`; kinds script, projects, history. Route links to the character-owned implementation; do not duplicate its factory.
- Audio owner: Audio. `registerAudio(in:)`; kinds audio, wordTiming.
- Character/team owner: Characters + Teams. `registerCharactersAndTeams(in:)`; kinds characters, characterEditor, characterLinks, teams. CharacterLinks ownership is here; script owner routes it, never duplicates it.
- Image owner: Images. `registerImages(in:)`; kinds storyboard, preview, imageDetail, cueAnchor.
- Auth/runtime owner: Account, MacRuntimeBridge and separate ScrivRuntimeCompanion; CodexController transport boundary. `registerAccount(in:)`; kinds signIn, account, settings, generationJobs, codex.

Do not edit another partition's service/shared files without coordination. Do not alter backend, billing gates, live credentials or cloud configuration.

## Runtime and persistence gates

Mac SDK checking established that `Process` launch and named `NSXPCConnection` are unavailable to this Catalyst target; `Pipe` and `URLSessionWebSocketTask` compile. The companion design must use a supported explicit launch path and authenticated loopback only, never a LAN listener, token in a callback URL/log, arbitrary shell RPC, privileged installation or silent autostart. Preserve local installed Codex, its account, job IDs, exact prompts, reference/output bounds and interrupted-job recovery. Existing Codex preflight does not prove the new bridge.

UIKit scene callbacks are not a substitute for the legacy deferred-termination save barrier. The coordinator must provide a tested document/write-ahead durability boundary. Project directories need explicit security-scoped access/bookmarks; never assume an old absolute path is readable from the Catalyst container. No migration may silently destroy or overwrite existing projects/journals.

## Implemented integration boundary

`UIApplicationMain` uses the public `ScrivUIKitApplication` responder implementation. Space outside text input, Cmd+/Cmd− shared script zoom and Cmd+Enter editing toggles never replace the active text responder. IME composition is exempt. In-edit playback-key changes remain pending user clarification; ordinary spaces remain input.

Catalyst accepted mutations are synchronously persisted in `PendingProjectSaveJournal` before in-memory publication. ProjectRepository compare-and-save uses one cooperative package lock for normal and recovery saves, exact source hashes and immutable accepted history; files/directories are flushed before acknowledging recovery. Initial packages remain discoverable even if their first canonical file was interrupted. Cloud-linked recovery is account/server scoped. No recovery silently overwrites a diverged package.

`App`, `Shared`, all five feature directories and the bridge client are included through synchronized source groups; shared domain services are an explicit allowlist. The separate macOS helper, legacy UI and tests are not compiled into the app UI. Native test source is included only in `ScrivUIKitTests`.
