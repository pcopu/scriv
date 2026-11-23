# Integration interactions and end-to-end journey families

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Status: source-derived design inventory, 2026-11-08. This document performs no
account connection, message send, provider request, membership change, checkout,
file permission change or update installation. It adds no scenarios, retires no
tests, and does not certify any new runtime coverage.

The unit of design is a user interaction in the actual Catalyst app, followed by
an observable result. Build a small set of coherent journeys from these units;
only then attach old assertions to their checkpoints. An old test method, a
button definition and a parameterized journey run are three different counts.

## Scope and counting contract

This slice covers Account/Settings/Codex/auth/jobs; Projects/History/import,
export and recovery; Teams; Discussion; Updates; shared document pickers,
security scopes, presentation and error handling. Script, character, image and
audio editing own their detailed creative interactions in the other inventory.
Their integration handoffs appear here without recounting their editing tools.
Service/protocol attack and fault gates belong to
`interaction-inventory-service-boundaries.md`, not this UI interaction total.

**138 deduplicated interactions map to 10 proposed journey families.** The
family count is 7.2% of the interaction count, about one family per 13.8
interactions. This is not a promise of ten test executions: each family has a
bounded case matrix, and permissions, identities or destructive boundaries may
require separate isolated sessions. Do not achieve a smaller number by omitting
state transitions, failure cases or physical-input assertions.

| ID namespace | Interactions | Scope |
| --- | ---: | --- |
| INT-ACC | 20 | Scriv account, settings and email/GitHub auth |
| INT-CDX | 23 | Codex setup, connection, account and trust lifecycle |
| INT-JOB | 11 | Local/shared generation jobs |
| INT-PRJ | 16 | Projects, persistence, interchange and cloud sync |
| INT-HIS | 19 | History and script/image-direction recovery |
| INT-TEM | 16 | Teams, invitations, roles and billing handoffs |
| INT-DSC | 20 | Conversations, context, mentions and activity |
| INT-UPD | 5 | Phase-dependent update choices |
| INT-SHR | 8 | Shared presentation, OS file boundaries and errors |
| **Total** | **138** | Count each row in the interaction tables once |

Deduplication rules:

1. Buttons, application menus, context menus and keyboard shortcuts that reach
   the same user operation share one interaction ID. Preserve each route as an
   input-mode case; a semantic action does not prove physical delivery.
2. Repeated item rows and menu values are parameters, not more interactions.
   Examples: four project sources, model IDs, invitation roles/expiry values,
   local/cloud revisions, message IDs, copied setup commands and update phases.
3. A reversible toggle's two values share one ID. Create versus rename, request
   versus verify, and choosing a document versus exporting it remain distinct
   operations. Confirmation Cancel is a required branch of its operation, not
   another bespoke scenario. Generic close/back is INT-SHR-001.
4. Visual state, automatic refresh, transport callbacks and save journals are
   result checkpoints or environmental cases, not invented buttons. Absent
   features are not counted just because a service has an API for them.
5. Shared IDs are owned here for reconciliation. If another slice lists scroll,
   close, file choice or error acknowledgment, alias it to INT-SHR rather than
   adding it again to the whole-app total. This document's 138 is a slice total,
   not an assertion that the entire app has 138 interactions.

### Review of the 688-site checklist

The frozen `cli-migration-inventory.json` contains 688 candidate source sites,
not 688 user actions. Its baseline is
`4d14b29f4fb49891e850fa9a8e5742dc878603c8`. This review covered 191 candidates
from the primary files below, plus 83 shared shell/helper candidates: **274
candidate records inspected as a checklist**. The other 414 are outside this
slice. Shared-source records include script/transport actions owned elsewhere,
so 274 is neither the interaction count nor a claim that all belong here.

| Candidate group | Records | Disposition |
| --- | ---: | --- |
| AccountUI / Account / CodexSetup / Jobs / Progress / Settings / SettingsPanel / SignIn | 65 | ACC, CDX, JOB; generic factories excluded as separate actions |
| ProjectBrowser / History | 39 | PRJ, HIS; repeated cells and metadata deduplicated |
| Teams / TeamInvitation / TeamUIKitSupport | 32 | TEM; identical invitation panel in two hosts counted once |
| Discussion controller / pickers / message views | 36 | DSC; generated message/member rows parameterized |
| UpdateController | 9 | UPD; primary/secondary choices parameterized by phase |
| UIKitFileAccess / WorkspaceErrorPresenter | 2 | SHR; delegates inspected beyond regex matches |
| RecoveredDraftController | 8 | HIS; editor entrypoint owned by script inventory |
| WorkspaceController / Header / PlaybackKeyboardRouter / ScreenController / UIKitTheme / CharacterTeamUI | 83 | Cross-surface routes mapped to existing IDs; helper, accessibility and out-of-scope editing sites not recounted |

The checklist also misses real interactions implemented in delegate callbacks,
dynamic menus and files with no matched pattern. This review additionally read
AppDelegate, SettingsWindowCoordinator, RuntimeBootstrapCoordinator,
ScrivUIKitRouter, UpdateCoordinator/Presentation/Handoff, the relevant
WorkspaceStore and CodexController entrypoints, and current CLI scenarios.
Image recovery callsites in PreviewViewController and ImageUIKitSupport were
reconciled separately with the authoring inventory: six controls map to four
operations here, without adding those shared candidate records to the 274.
Future source drift requires a delta review; do not regenerate the frozen
baseline to make the denominator move.

## Reading the interaction tables

Each row gives a stable ID, action and source callsite, precondition, observable
result and present CLI gap. Source aliases resolve to the exact paths below;
method names are stable locators when ongoing edits shift line numbers.

- **C(name)**: an existing scenario contains some applicable steps. This does
  not assert all row variants or all frozen assertions passed. Consult its
  exact-build evidence and `cli-migration-candidates.json` separately.
- **S**: existing semantic application boundary, explicitly not OS/event parity.
- **G**: no complete actual-app CLI journey/evidence found for this interaction.
- **L**: needs an approved isolated service/runtime/identity or usage lane.
- **OS**: needs real system presentation, native input, browser, file grant or
  lifecycle control beyond ordinary `activate`/`key` dispatch.

All rows inherit repeated-action, cancel/back, stale-target, ownership and
visibility checks from the cross-cutting matrix. Row results describe required
evidence, not a claim that the implementation has already passed it.

### Source aliases

All short UIKit paths below are under `apps/catalyst/ScrivUIKit/`.

| Alias | File |
| --- | --- |
| W | App/ScrivWorkspaceController.swift |
| WH | App/ScrivWorkspaceHeader.swift |
| APP | App/AppDelegate.swift |
| KEY | Shared/ScrivPlaybackKeyboardRouter.swift |
| ROUTE | Shared/ScrivUIKitRouter.swift |
| SCREEN | Shared/ScrivScreenController.swift |
| FILE | Shared/UIKitFileAccess.swift |
| ERROR | Shared/WorkspaceErrorPresenter.swift |
| ACCOUNT | Account/ScrivAccountController.swift |
| SET | Account/ScrivSettingsController.swift |
| PANE | Account/ScrivSettingsPanelController.swift |
| WIN | Account/ScrivSettingsWindowCoordinator.swift |
| AUTH | Account/ScrivSignInController.swift |
| CDX | Account/ScrivCodexSetupView.swift |
| BOOT | Account/ScrivRuntimeBootstrapCoordinator.swift |
| JOB | Account/ScrivGenerationJobsController.swift |
| PROGRESS | Account/ScrivGenerationProgressView.swift |
| BROWSE | Projects/ProjectBrowserController.swift |
| HIST | Projects/HistoryController.swift |
| DRAFT | Script/RecoveredDraftController.swift |
| PREVIEW | Images/PreviewViewController.swift |
| IMAGEUI | Images/ImageUIKitSupport.swift |
| TEAM | Teams/TeamsController.swift |
| INV | Teams/TeamInvitationController.swift |
| TP | Teams/TeamUIKitSupport.swift |
| DISC | Discussion/ScrivDiscussionController.swift |
| PICK | Discussion/DiscussionPickers.swift |
| MSG | Discussion/DiscussionMessageViews.swift |
| UPDATE | Updates/ScrivUpdateController.swift |
| UPSTATE | Updates/ScrivUpdatePresentation.swift |
| UPCOORD | Updates/ScrivUpdateCoordinator.swift |
| HANDOFF | Updates/ScrivUpdatePresentationHandoff.swift |
| STORE | apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift |
| CODEX | apps/mac/Sources/ScrivApp/Services/CodexController.swift |

## Scriv account, settings and authentication: 20

| Stable ID | Action and actual source callsite | Preconditions and observable result | Current CLI coverage / gap |
| --- | --- | --- | --- |
| INT-ACC-001 | Open account summary; W header/account menu → ACCOUNT.viewDidLoad/storeDidChange | Signed-in account shows identity, project, sync/peer state; local account route offers sign-in. Opening does not sign in or sync. | G; workspace shell snapshots are not account-flow proof |
| INT-ACC-002 | Open/focus Settings; KEY.showSettings, ROUTE.present, WIN.show; popup Advanced → SET.openAdvancedSettings | Workspace/settings source exists. Reuse one Settings scene; Advanced first dismisses popup and cancels its owned check, then selects Codex. | C(settings-navigation, native-codex-setup-popup) covers the shortcut and the workspace Codex popup's Done and Advanced controls while disconnected. Pending check cancellation, physical menu input and native scene close remain open. |
| INT-ACC-003 | Choose General/Account/Codex pane; PANE.selectPane/sidebar didSelectItemAt | Finish field editing, cancel owned prior connection check, cache/reuse pane without connecting. | C(settings-navigation); interrupted check and late completion G |
| INT-ACC-004 | Toggle follow playback; SET.viewDidLoad/buildGeneral | Visible enabled switch; preference survives pane changes and affects subsequent playback following. | C(settings-navigation) covers toggle/pane retention, not all playback outcomes |
| INT-ACC-005 | Expand/collapse server settings; SET.buildAccountIfNeeded | Account pane; preserve draft until explicitly saved, end editing before rebuild. | G |
| INT-ACC-006 | Edit server address; SET server editingChanged | Signed out. Draft visible; signed-in field disabled; changing text alone is not proof of saved service change. | G |
| INT-ACC-007 | Save server address; SET.buildAccountIfNeeded → STORE.cloudBaseURL | Signed out; valid HTTPS/local-development address accepted, invalid address alerts, pending sign-in invalidated by real cloud lifecycle. | G; service isolation L |
| INT-ACC-008 | Open Scriv sign-in; W/ACCOUNT/SET/BROWSE/TEAM/DISC → AUTH | No account; correct server/navigation context and focus; opening sends no code. | G; route duplication is one operation |
| INT-ACC-009 | Enter/edit email; AUTH.changed/updateControls | Not busy/owned elsewhere; valid normalized address enables Continue; invalid disables it; draft remains local. | G; `text` can enter data, not delivery proof |
| INT-ACC-010 | Request email code; AUTH.request, Continue/Return → STORE.requestEmailCode | Valid address, cooldown elapsed, this owner. One request, challenge shown, email retained, code cleared, duplicate submission blocked. | G/L; approved test inbox/service required |
| INT-ACC-011 | Enter verification code; AUTH.changed | Active unexpired challenge. Only six ASCII digits retained; disabled while busy/expired. No code in evidence. | G/L |
| INT-ACC-012 | Verify code; AUTH.verify, button/Return → STORE.verifyEmailCode | Six-digit valid shape, current owner/challenge. Success closes and refreshes account; wrong/expired/replayed code shows recoverable error without stale login. | G/L; browser/inbox tools and secure evidence handling |
| INT-ACC-013 | Resend code; AUTH.request/updateControls | Challenge exists, cooldown elapsed. Exactly one new request; new challenge clears prior entered code; cooldown/expiry labels truthful. | G/L; request and resend share backend but differ challenge contract |
| INT-ACC-014 | Change email; AUTH.render challenge link → cancel | Cancel owned challenge, clear code/email and return to address entry; old response cannot authenticate. | G/L |
| INT-ACC-015 | Cancel sign-in / keep writing locally; AUTH.close/cancel/viewDidDisappear | Any owned non-completed attempt; cancel task/challenge, erase transient code, retain local project; temporary browser cover is not dismissal. | G/L/OS; Close, Escape and navigation-away are route variants |
| INT-ACC-016 | Take over sign-in from another window; AUTH.render Start sign-in here | Another owner exists; explicitly cancel prior flow, clear fields and enable current owner; previous callbacks ignored. | G/L/OS; two actual windows required |
| INT-ACC-017 | Reveal/hide GitHub option; AUTH.render githubExpanded | Email entry phase; disclosure alone performs no browser auth. | G |
| INT-ACC-018 | Continue with GitHub; AUTH.github → STORE.signInWithGitHub | Current owner, not busy. System authentication browser opens; cancel/failure/success and account refresh remain owner/server/navigation fenced. | G/L/OS; no fabricated OAuth callback |
| INT-ACC-019 | Refresh Scriv account; ACCOUNT link, BROWSE Refresh → STORE.refreshAccount | Signed in; newest account/projects/team state replaces only matching context. Distinguish expired session, offline error and unchanged success. | G/L; cloud browser refresh is a route alias |
| INT-ACC-020 | Sign out of Scriv; ACCOUNT/SET → STORE.signOut | Signed-in dedicated identity; local files/drafts survive, cloud state and pending auth clear; Codex sign-in remains separate. | G/L; not interchangeable with Codex logout/disconnect |

## Codex connection, account and trust lifecycle: 23

| Stable ID | Action and actual source callsite | Preconditions and observable result | Current CLI coverage / gap |
| --- | --- | --- | --- |
| INT-CDX-001 | Open/reopen compact Codex popup; W.showCodexPopup, ROUTE.present | Mounted workspace; reuse existing popup, reflect disconnected/checking/connected/generating state without startup/login/turn. | C(codex-setup-instructions) chiefly Settings; popup/repeated route G |
| INT-CDX-002 | Toggle Installation help; CDX.buildSettings/updateDisclosures | Settings surface; expanded/collapsed state, exact public commands, scrolling remains usable. | C(codex-setup-instructions) |
| INT-CDX-003 | Copy setup instruction; CDX.commandStep | Parameter install/sign-in/custom-server command. Copy exact public instruction only; no command execution. | C(codex-setup-instructions) observes instructions, clipboard-write verification gap |
| INT-CDX-004 | Open official setup guide; SET.installCodexSetup onGuide | Explicit action opens documented external URL; no install or sign-in side effect. | G/OS |
| INT-CDX-005 | Set installed executable; SET fields/pick(false)/documentPicker/saveRuntimeFields | Disconnected/not connecting. Manual text or picked file retained; invalid/missing path fails later safely; chooser cancel preserves prior value. | G/OS; picker and text are route cases |
| INT-CDX-006 | Edit custom loopback address; SET endpoint/saveRuntimeFields | Disconnected. Preserve exact draft through scrolling/blur; connection locks edits; changing text alone does not connect. | C(codex-endpoint-validation); positive URL normalization gap |
| INT-CDX-007 | Connect/Try again using managed discovery; SET.checkConnection → CODEX.checkAndConnect + BOOT.prepare | Explicit user action, no duplicate owned task. Signed helper/discovery/init/account/models produce honest ready/sign-in-required/error state; no generation. | G/L; managed helper lane distinct from manual loopback |
| INT-CDX-008 | Cancel connection check; SET.onCancelCheck/cancelPendingConnectionCheck | Checking current attempt. Cancel task/helper ownership; late result cannot reopen readiness or cancel a newer window's attempt. | G/L; pane change/Done/Escape/scene close are cleanup variants |
| INT-CDX-009 | Connect to supplied address; SET.onConnect → CODEX.connect | Valid unprivileged numeric-loopback fixture; real initialize/account/model exchange or exact validation/protocol error; double click cannot duplicate connection. | C(codex-endpoint-validation) rejects invalid inputs; L live-codex-connection opt-in, not general pass |
| INT-CDX-010 | Open runtime companion; SET.onOpen → CODEX.openRuntimeCompanion | Not working; opens only expected companion, presents actionable failure if absent. | G/L/OS |
| INT-CDX-011 | Toggle separate pairing controls; CDX.updateDisclosures | Settings surface; reveals/hides instructions and controls without credential read/write caused merely by disclosure. | C(codex-setup-instructions) partial |
| INT-CDX-012 | Choose/import private pairing file; SET.pick(true)/documentPicker → CODEX.importRuntimePairing | Disconnected, explicitly authorized isolated pairing. Validate identity/owner/symlink/version/capability; preserve prior pairing on reject/cancel. | G/L/OS/security; never use production pairing as fixture |
| INT-CDX-013 | Start paired runtime; SET.onStart → CODEX.start | Valid pairing, canStart, no active operation. Start owned runtime through actual trust path; establish identity/account/models or visible error. | G/L; no synthetic success reply |
| INT-CDX-014 | Disconnect/Stop; SET.onStop → CODEX.stop/disconnect | UI permits operation. Managed child/helper ownership released; external server stays alive; readiness cleared, not account logout; disabled states respected during unsafe work. | L live-codex-connection covers external lane when approved/run; managed lane G |
| INT-CDX-015 | Select available model; SET.updateRuntime model menu | Connected, idle, nonempty current model list. Selected live ID reflected; stale/removed model or generating state cannot change it. | G/L; menu observation exists, general menu-item dispatch missing |
| INT-CDX-016 | Sign in with ChatGPT; SET.accountAction → CODEX.signIn | Connected signed-out dedicated runtime. Matching browser login ID opened; ready only after real completion; no duplicate pending login. | G/L/OS/security; separate from Scriv auth |
| INT-CDX-017 | Cancel ChatGPT sign-in; SET.accountAction → CODEX.cancelSignIn | Matching pending login. Cancel only it, clear pending browser state; stale completion cannot sign in newer session. | G/L/OS |
| INT-CDX-018 | Open ChatGPT account menu; SET.accountAction alert | Runtime reports account label; show Refresh/Sign out/Cancel without performing them. | G/L; redact account identity in evidence |
| INT-CDX-019 | Refresh runtime account; SET onRefreshAccount/account alert → CODEX.checkAndConnect/readAccount | Connected or sign-in-required path, not busy/pending login. Current account/model readiness refreshed; provider-not-required state distinguished from authenticated ChatGPT. | G/L |
| INT-CDX-020 | Sign out of ChatGPT; SET account alert → CODEX.signOut | Explicit approved isolated account, connected and operable. Real account/logout clears auth readiness; Scriv account/local data unaffected. | G/L/security; Disconnect is not equivalent |
| INT-CDX-021 | Rotate pairing, confirm/cancel; SET.confirmRotate → CODEX.rotateRuntimePairing | Stopped/disconnected; explicit trust change. Revoke saved capability for paired windows, require fresh original pairing; no ChatGPT credential change. | G/L/security; cancel must preserve original grant |
| INT-CDX-022 | Forget pairing, confirm/cancel; SET.confirmForget → CODEX.forgetRuntimePairing | Stopped/disconnected. Remove this app's saved copy only, preserve companion original/ChatGPT account; cancel is no-op. | G/L/security |
| INT-CDX-023 | Use existing generation history folder; SET.pickHistory/documentPicker → CODEX.useExistingGenerationFolder | Disconnected; explain future destination, choose original folder. Preserve job/artifact identity; wrong/inaccessible folder errors, cancel retains prior root. | G/OS/security; source text alone does not verify grant/durable restart |

## Durable generation jobs: 11

| Stable ID | Action and actual source callsite | Preconditions and observable result | Current CLI coverage / gap |
| --- | --- | --- | --- |
| INT-JOB-001 | Open generation history/jobs; W menu/SET.onJobs → JOB.viewDidLoad | Any connection state. Existing jobs/progress/journal issue displayed, no new generation from opening/reconnecting. | G; empty view alone cannot replace job durability |
| INT-JOB-002 | Switch This Mac/Shared project; JOB source valueChanged/render | Shared selection requests current project jobs; local selection uses journal. No cross-project results or local paths in shared state. | G/L for shared |
| INT-JOB-003 | View/hide job details; JOB.card | Captured job selected by ID; show original prompt/status/source revision/error without regeneration. | G |
| INT-JOB-004 | View exact submitted prompt; JOB.showPrompt | Stored submitted prompt differs from brief; push read-only text; Back retains selected job and no mutation. | C(codex-loopback-generation/history-prompt) opens the exact fixture-received text and verifies that edits are refused. Back navigation remains open. |
| INT-JOB-005 | Open saved artifact; JOB.open → validatedURL → FILE.preview | Artifact exists and matches hash/identity; QuickLook opens validated bytes; missing/tampered/stale artifact gives truthful error. | C(codex-loopback-generation/history-artifact) witnesses the changed-file notice, restores the exact bytes, and opens the native preview. Quick Look rendering remains an OS check. |
| INT-JOB-006 | Inspect existing turn; JOB.card/run → CODEX.inspectJob | Non-completed job, idle/not already inspecting. Read existing turn/recover result, preserve job identity; no new turn or usage-producing retry. | G/L |
| INT-JOB-007 | Use output in original project; JOB.card onRecoverJob → STORE recovery callback | Artifact and captured context, not imported, idle. Only original project/package/cue can receive exact asset; stale/wrong project rejected; duplicate action idempotent. | G/L; ordinary successful image import is not job recovery |
| INT-JOB-008 | Retry generation, confirm/cancel; JOB.confirmRetry → onRetryJob | Retryable current job, connected idle, approved new usage. Preserve old job/captured prompt/references, create one distinguishable new request; cancel sends none. | C(codex-loopback-generation/history-retry) verifies Cancel, one new request with the original prompt, intact prior journals, and exact attachment bytes. C(codex-loopback-generation/history-retry-portrait) assigns a local portrait, checks the request preview and original reference bytes in both submissions, and verifies a changed copy is refused without a new request or job. |
| INT-JOB-009 | Refresh shared jobs; JOB.shared → onRefreshSharedJobs | Current cloud project/account; loading/error/empty/new statuses fenced to source. Only owning Mac can recover/run. | G/L |
| INT-JOB-010 | Show more jobs; JOB.addMoreButton | More than current page; increase visible limit by 20 on selected source, preserve selection and bounded/cancelable thumbnails. | G; parameter local/shared and >20/>40 |
| INT-JOB-011 | Cancel current generation; PROGRESS cancel action → CODEX.cancelGeneration | Generating owned job; one cancellation request, truthful cancelling/completion race, no automatic retry or unrelated job interruption. | G/L; separately budget any real cancellation turn |

Generation submission/review/reference editing starts in the image interaction
inventory. IJ-07 must cross that real UI entrypoint to create its jobs; a file
injected into the journal cannot prove this end-to-end lifecycle.

## Projects, interchange and sync: 16

| Stable ID | Action and actual source callsite | Preconditions and observable result | Current CLI coverage / gap |
| --- | --- | --- | --- |
| INT-PRJ-001 | Open Projects; W title/menu → BROWSE.viewDidLoad | Mounted workspace. Load current local summaries and authorized cloud list, preserve active project until explicit open/new/import. | C(projects) |
| INT-PRJ-002 | Select project source; BROWSE.makeSidebar/reload | Recent/On this Mac/Scriv Cloud/Team projects. Correct dedup/filter/sort, signed-out explanation; no automatic sign-in. | G; four values one interaction |
| INT-PRJ-003 | Search/clear project title; BROWSE.searchChanged/updateEmpty | Search draft; matching rows/selection/footer update; no-match Clear restores list. | C(projects), repeated search/clear |
| INT-PRJ-004 | Select project row; BROWSE.didSelectRowAt/updateFooter | Existing row; footer metadata/cover and Open enabled state track exact stable source identity, no opening yet. | G; table delegate not generic button activation |
| INT-PRJ-005 | Open selected local project; BROWSE.openSelected → STORE.openLocalProject | Selected package. Button/double-click/Return/Command-Return routes; complete pending saves, load correct project, dismiss browser only appropriately; current project can simply close browser. | G/OS for double click; not covered by creating a project |
| INT-PRJ-006 | Open selected cloud project; BROWSE.openSelected → STORE.openCloudProject | Signed-in authorized remote; flush/reconcile local data, fetch true project state or retain prior workspace with error; no stale late navigation. | G/L |
| INT-PRJ-007 | Create project; W menu/Command-N/BROWSE header → STORE.newProject | Finish current editor normally; unique blank template saved, old projects preserved, browser closes on project change. | C(project-creation), repeated semantic UI creation |
| INT-PRJ-008 | Rename project, confirm/cancel; W.renameProject → STORE.setProjectTitle | Current navigation captured. Title input persisted with new revision; cancel/stale confirmation cannot rename a different project. | G; alert controls/menu item reachability gap |
| INT-PRJ-009 | Save current work; W.saveProject/Command-S → UIKitPresentation.finishEditing + STORE.saveProject | Current store/editor. Accepted content reaches durable package/journal; failure visible; unrelated window editing untouched. | C(project-creation and other scenarios); failure/multiwindow/physical-key gaps |
| INT-PRJ-010 | Open external package; W/BROWSE/Command-O → STORE.openProject/openUserSelectedProject; APP URL contexts | Genuine picked or scene-delivered `.scriv`/folder grant. Remember before I/O, load validated package/checkpoint/history; failed grant/read retains work and reports stage. | G/OS; no arbitrary-path CLI open replacement |
| INT-PRJ-011 | Import script document; W/BROWSE → STORE.importScript/from | Supported Fountain/spmd/UTF-8/JSON, size/format valid. Validate before new project install; invalid input leaves current/saved state unchanged. | S(import-fountain/import-json); C(fountain-* and json-*); picker/security scope OS gap |
| INT-PRJ-012 | Export Fountain script; W → STORE.exportScript → FILE.export | Finish edits; production serialized file offered; completion/cancel cleans only its temporary artifact. | S(export-fountain), C(fountain-export/roundtrips); actual save destination OS gap |
| INT-PRJ-013 | Export project / safety copy; W/SET/ACCOUNT → STORE.exportProject | Flush accepted saves and copy durable package with media/history/recovery contract; current scope fenced; cancel/error cleanup safe. | G/OS; Fountain export is not package export |
| INT-PRJ-014 | Browse current package location; SET.revealPackage | Existing project URL; read-only chooser starts near package; choosing/canceling does not replace current project. | G/OS |
| INT-PRJ-015 | Launch/reopen last project; APP scene setup → STORE.bootstrap/open | Fresh/returning installation and valid access. Restore retained scope and pending saves; absent/malformed/stale bookmark or journal gives recoverable staged error, no silent replacement. | G/OS; launch fresh CLI sample is not cold reopen of retained package |
| INT-PRJ-016 | Sync script / retry saved cloud commands; ACCOUNT/DISC → STORE.syncProject/retryCloudSync | Signed-in current account/server, no active sync. Save fence, new/existing cloud identity, conflicts/replay/offline recovery observed without lost draft or duplicate commit. | G/L; same operation from multiple labels, not two tests |

## History and recovered draft review: 19

| Stable ID | Action and actual source callsite | Preconditions and observable result | Current CLI coverage / gap |
| --- | --- | --- | --- |
| INT-HIS-001 | Open History; W menu → HIST.viewDidLoad | Current project; working/local timeline and read-only selection shown, underlying accessibility hidden then restored on close. | G; shell route availability alone insufficient |
| INT-HIS-002 | Switch history source; HIST.sourceChanged | This Mac/Cloud. Cancel obsolete preview, correct events/empty state; Cloud refresh only for linked project. | G/L for cloud |
| INT-HIS-003 | Select revision/event; HIST.didSelectRowAt/choose | Current project/selection. Load correct snapshot or discussion-only explanation; late previews cannot overwrite newer selection. | G; table selection route needed |
| INT-HIS-004 | Switch Changes/Revision preview; HIST.detailChanged/renderDetail | Read-only current selection; exact delta versus full saved snapshot, no restore side effect. | G |
| INT-HIS-005 | Refresh cloud history; HIST.refresh → STORE.refreshDiscussionActivity | Linked current project, not already refreshing; update events/errors without changing unrelated context. | G/L |
| INT-HIS-006 | Show remaining change cards; HIST.renderDetail | More than first eight changes. Reveal all remaining once, preserve current selection and layout. | G |
| INT-HIS-007 | Toggle diagnostic detail section; HIST.toggleTechnical/changeCard/renderDetail | Parameter word timing/item technical/event metadata. Exact stored values shown with declared truncation, no authored changes. | G; three section kinds one operation |
| INT-HIS-008 | Expand character in revision preview; HIST.renderSnapshot | Character exists in selected snapshot; biography/appearance from that revision, not live edited profile. | G |
| INT-HIS-009 | Restore reviewed revision, confirm/cancel; HIST.confirmRestore → STORE.restoreHistory/restoreCloudHistory | Non-current restorable selection, context unchanged and preview valid. New revision preserves old work; cloud ends leases/does not rewind discussion/billing/membership/local audio; concurrent new edit retained. | G/L for cloud; local/cloud are mandatory distinct cases |
| INT-HIS-010 | Return recovered draft to editing; DRAFT Edit draft/onEditDraft | Matching reviewed scope, session active, not applying. Dismiss review into same editor with draft retained. | G; upstream editor creation belongs to script journey |
| INT-HIS-011 | Keep recovered draft for later; DRAFT.keep/presentationControllerDidDismiss | Matching recovery session. Dismiss without applying; reopening same line reoffers retained draft. | G; close/interactive-dismiss cleanup variants |
| INT-HIS-012 | Rebase draft on current saved line; DRAFT rebase → session.rebase | needsRebase and not applying. Preserve intended draft, current timing, explicitly review changed links; no silent old-base apply. | G |
| INT-HIS-013 | Apply reviewed draft; DRAFT apply → session.applyReviewed | Current scope, not applying/rebase-needed. Validate/save exact reviewed source, preserve owned timing, clear only accepted recovery; error retains draft. | G/L for lease conflict variants |
| INT-HIS-014 | Discard local draft, confirm/cancel; DRAFT.confirmDiscard | Matching current reviewed scope. Delete only this recovery copy; canonical script/autosaved work unchanged; cancel retains it. | G; recoverable deletion authorization for executing future cases |
| INT-HIS-015 | Toggle recovery explanation; DRAFT.storeDidChange explanationExpanded | Review visible; reason/source revision appear/disappear without changing draft/apply state. | G |
| INT-HIS-016 | Retry retaining rejected visual-direction text; PREVIEW recovery, Retry retaining this text at line 262 | Recovery ready, same cue scope and exact rejected text still retained in memory. Actual production draft write must succeed before text replaces the field; otherwise preserve prior accepted field and rejected text warning. | G; journal-failure fixture and durable result observation needed |
| INT-HIS-017 | Use recovered visual-direction draft; PREVIEW recovery, Use this draft at line 270 → STORE.rebaseGenerationPrompt | Matching cue, exact draft and review state unchanged; recovery ready. Rebase the reviewed draft on current saved direction, clear review gate only after successful durable handling; unrelated cue untouched. | G; case in IJ-03, ordinary direction editing owned by image journey |
| INT-HIS-018 | Retry visual-direction save/preparation; PREVIEW recovery, Retry save at line 270 → STORE.prepareGenerationPromptForPresentation(force:true) | Recovery issue without review gate, same captured scope/draft/state. Retry actual recovery preparation; success/error visible without silently accepting stale text. | G; separate from rebase because precondition and production action differ |
| INT-HIS-019 | Discard visual-direction draft, request/confirm/cancel; PREVIEW line 271 → IMAGEUI.confirm → STORE.discardGenerationPrompt | Current recovery scope. Prompt states saved picture direction stays unchanged; Cancel retains draft; confirm rechecks readiness/scope/exact draft, removes only local recovery, restores displayed saved direction and clears rejected text. | G; three physical controls are required branches of one operation, not three counted interactions |

## Teams, invitations, membership and billing: 16

| Stable ID | Action and actual source callsite | Preconditions and observable result | Current CLI coverage / gap |
| --- | --- | --- | --- |
| INT-TEM-001 | Open Teams & sharing; W share/menu → TEAM.viewDidLoad | Signed-out explanation or current team/plan/member data; no automatic team creation/subscription. | G; generic sheet coverage is not role evidence |
| INT-TEM-002 | Choose team; TEAM.selectTeam/menu | Signed in, idle, listed team. Clear previous details/fresh-link secret, fetch matching team; late prior response ignored. | G/L; menu selection gap |
| INT-TEM-003 | Choose Overview/Members/Invitations; TEAM segments/renderBody, Invite people → INV | Correct current team/account. Same invitation editor contracts in tab and nested sheet; readonly role restrictions visible. | G/L; two hosts are route variants |
| INT-TEM-004 | Create team, confirm/cancel; TEAM.nameTeam(nil) | Signed in idle; 1–100 UTF-16 name. Create/select team without subscription or charge; invalid/cancel no server mutation. | G/L |
| INT-TEM-005 | Rename team, confirm/cancel; TEAM.nameTeam(team) | Owner/admin according to current policy; captured account. Persist intended team name, preserve others; reject stale role/account. | G/L |
| INT-TEM-006 | Join via invitation/token; TEAM.joinTeam; APP URL → STORE.handleOpenURL/joinTeam | Signed-in allowed test identity, matching server invitation. Reusable valid link joins exact team; invalid/wrong-origin/revoked/expired fails without membership drift. | G/L/OS for external-link route |
| INT-TEM-007 | Refresh members/details; TEAM.reload(refreshAccount:true) | Not working/loading. Latest roles/membership/plan shown, mismatched team response rejected, account switch cancels old work. | G/L |
| INT-TEM-008 | Change member role; TEAM.memberRow/setRole | Owner may choose admin/member/viewer; admin only member/viewer on eligible target; owner protected. UI and server agree; stale removal/demotion rejected. | G/L; real second identity needed for effective authorization |
| INT-TEM-009 | Remove member / leave team, confirm/cancel; TEAM.confirmRemoval | Eligible actor/target; self case excludes owner affordance. Access ends immediately while history remains; links not silently revoked; cancel no mutation. | G/L; self/other and owner/admin/viewer cases |
| INT-TEM-010 | Choose invitation access; TP.invitationPanel → TEAM/INV onRole | Editable panel idle. Member/viewer choice persists to next creation, no link issued by menu choice. | G/L |
| INT-TEM-011 | Choose invitation lifetime; TP.invitationPanel → onDays | 1/7/30 days, idle. Selected duration used exactly, no creation yet. | G/L |
| INT-TEM-012 | Create and copy invitation; TEAM.createInvitation / INV.createLink | Owner/admin, active paid team, idle, captured account/team. One reusable link with chosen role/expiry, copy fresh URL, list refresh; old secrets never reconstructed. | G/L/security; sanitize URL out of evidence |
| INT-TEM-013 | Copy freshly created invitation again; TEAM.copyInvitation / INV onCopy | Fresh URL belongs to current still-open team/account. Copy same link only; close/team/account switch removes access to transient URL. | G/L; clipboard observation required |
| INT-TEM-014 | Revoke invitation; TEAM.revokeInvitation / INV.revoke | Active listed link, authorized manager. Stops new joins, clears fresh-link display, existing members retain access. | G/L; existing UI sends directly, no invented app confirmation |
| INT-TEM-015 | Share current project/team copy, confirm/cancel; TEAM.confirmShare → STORE.shareProjectWithTeam | Paid team, non-viewer, not syncing; project/account/navigation unchanged. New local share or separate cloud-linked copy, original/history preserved, no accidental different-team share. | G/L; current-team Open project is PRJ-005 dismissal alias |
| INT-TEM-016 | Open subscription checkout or billing portal; TEAM.confirmCheckout/openBilling | Owner and eligible plan. Checkout confirmation states recurring terms; attention states route to existing portal, not duplicate checkout; browser failure and verified billing return refresh handled. | G/L/OS; checkout/portal are mode cases, payment completion outside this UI and separately authorized |

## Discussion, context, mentions and activity: 20

| Stable ID | Action and actual source callsite | Preconditions and observable result | Current CLI coverage / gap |
| --- | --- | --- | --- |
| INT-DSC-001 | Open/close discussion panel; W.toggleDiscussion, DISC close | Local/signed-out explanation or actual cloud conversation. Closing ends editor focus but retains scoped unsent draft; no send on open/close. | G; workspace presence alone not conversation coverage |
| INT-DSC-002 | Select Project/This item scope; DISC.scopeChanged | Current selected entry/character/cue/image or fallback to project. Correct stable thread identity and separate draft restored; navigation closes stale picker. | G/L |
| INT-DSC-003 | Choose another context item; DISC.contextMenu | Current navigation; line/direction/character/image menu values. Load exact thread, preserve prior draft, renamed/moved item identity stable. | G/L; dynamic menu execution gap |
| INT-DSC-004 | Edit discussion draft; DISC UITextView delegates/renderComposer | Ready scope and matching navigation. Exact UTF-16 text/selection/IME retained; blank/>8000 disables Send; count near limit; playback refresh does not rebuild active input. | G/L; text/type/selection primitives only |
| INT-DSC-005 | Set/cancel reply target; MSG Reply → DISC cell callback; renderComposer Cancel reply | Current message/draft scope. Reply chip targets exact message; cancel removes only reply metadata, preserves body/mentions/attachments. | G/L |
| INT-DSC-006 | Attach selected project item; DISC.attachmentMenu → STORE.addDiscussionAttachment | Current scope; line/direction, character or exact image version; max eight, dedup policy retained, no unrelated file upload. | G/L; parameterized kinds, not three journeys |
| INT-DSC-007 | Clear draft attachments; DISC.renderComposer Clear | Current captured draft; remove only attachments, body/reply/mentions unchanged. | G/L |
| INT-DSC-008 | Open mention picker; DISC.openMentions → PICK.UIKitDiscussionMentionPicker | Signed-in cloud project; correct scoped member list, loading/error/empty state, no mention sent merely by opening. | G/L |
| INT-DSC-009 | Search project members; PICK render/search target | Matching picker scope; case-insensitive name/role filter, no-match state, no stale team/account members. | G/L |
| INT-DSC-010 | Add/remove selected mention; PICK.didSelectRowAt; DISC mention chip | Valid member and scope; max 20, selected rows still removable at limit, no identity guessed from display name; remove chip same operation. | G/L; table selection gap |
| INT-DSC-011 | Clear all draft mentions; PICK Clear | Valid scope; clear mentioned IDs only, retain draft/reply/attachments and member list. | G/L |
| INT-DSC-012 | Retry member loading; PICK.reload/Retry | Valid scope, not loading; fresh actual members or actionable error; dismissal cancels task and no late mutation. | G/L |
| INT-DSC-013 | Send message; DISC.send, button/Command-Return → STORE.sendMessage | Ready, not loading/sending, nonblank ≤8000 UTF-16. One durable message with exact scoped metadata; repeat/timeout retry uses idempotency, retained newer draft not cleared; failure visible. | G/L; explicit approved synthetic recipients; no implicit send from Return/type |
| INT-DSC-014 | Filter mentions of current user / show all; DISC.filterButton/renderMessages | Current conversation, existing or active empty filter. Correct set, filter remains reversible if last mention disappears. | G/L |
| INT-DSC-015 | Open project activity; DISC.openActivity → PICK.UIKitDiscussionActivityController | Ready cloud project; actual mentions/conversations and unread counts, no email/push generated. | G/L |
| INT-DSC-016 | Select activity Mentions/Conversations; PICK activity tabs/render | Current navigation; correct list/empty/resolved labels; stale selection cannot navigate another project. | G/L |
| INT-DSC-017 | Refresh activity; PICK activity reload → STORE.refreshDiscussionActivity | Current project, no duplicate loading. Latest threads/mentions or truthful error, canceled on disappearance. | G/L |
| INT-DSC-018 | Open activity mention/conversation; PICK activity didSelectRowAt → STORE.openDiscussionMention/openDiscussionThread | Valid row/context. Open correct scope, focus mentioned message, update appropriate unread receipt, retain independent draft; missing anchor remains inspectable. | G/L; two row kinds one navigation operation |
| INT-DSC-019 | Resolve/reopen conversation; DISC.renderResolution → STORE.resolveThread | Existing nonempty current thread. Toggle exact thread, preserve messages/drafts and role enforcement; stale closure no-op. | G/L |
| INT-DSC-020 | Open attached item/version from message; MSG configure → DISC.openAttachment callback | Attachment resolvable in current project. Navigate discussion to exact item; unavailable immutable image version shows unavailable, never substituted latest version. | G/L; image bytes/digest gate separate |

## Updates: 5 phase-dependent interactions

| Stable ID | Action and actual source callsite | Preconditions and observable result | Current CLI coverage / gap |
| --- | --- | --- | --- |
| INT-UPD-001 | Check for Updates / focus existing check; KEY.checkForUpdates → UPCOORD.show/check | Explicit action. One sheet/session; valid signing/plugin required, otherwise truthful blocked notice and no download. Repeated check focuses retained session. | C(native-update-check) dispatches the registered menu action on the isolated build without a release key. Native menu input and signed feed remain separate. |
| INT-UPD-002 | Download & Update; UPDATE.choosePrimary available → plugin reply install | Actual signed compatible offer; one reply, download/progress/verify state; prepared-install-on-quit consequences shown. | G/L/OS; approved isolated signed feed/bundle needed |
| INT-UPD-003 | Cancel/defer/keep working; UPDATE.chooseSecondary/cancelFromEscape | Phase checking/downloading/available/ready/retryQuit with live reply. Plugin owns real cancellation; no independent dismissal or false cancellation during verifying/saving/installing; nested modal owns Escape. | G/OS; physical Escape remains distinct from semantic key |
| INT-UPD-004 | Update & Relaunch / retry quit; UPDATE.choosePrimary ready/retryQuit → UPCOORD prepare + HANDOFF | Verified prepared update. Fence every registered store, dismiss complete modal chain, fence again, quit/install/relaunch correct bundle; failed save blocks without lost work; no repeated install reply. | G/L/OS; build signature, lifecycle and durable recovery evidence required |
| INT-UPD-005 | Close terminal/blocked/error notice; UPDATE.choosePrimary/closeIfIdle | Phase current/complete/blocked/error/retryBlocked; close appropriate notice, preserve prepared update state where applicable and workspace. | C(native-update-check) covers Done on the signing-blocked sheet and preserves the loaded and saved project. Other terminal phases remain open. |

## Shared UI, OS and file boundaries: 8

| Stable ID | Action and actual source callsite | Preconditions and observable result | Current CLI coverage / gap |
| --- | --- | --- | --- |
| INT-SHR-001 | Close/back/dismiss current non-update surface; SCREEN.closeFromEscape plus feature Done/Close delegates, WIN.sceneDidDisconnect | Topmost eligible surface only; modal busy locks respected, owned work canceled, draft preserved, accessibility/focus restored; child Back returns parent rather than workspace. | C(projects/settings-navigation) partial; physical Escape/native window close/popover dismissal OS |
| INT-SHR-002 | Focus/switch/background/foreground app-owned window; WIN.show/scene callbacks, APP.sceneDidEnterBackground | Actual multiple windows/scenes. Route to active store, finish/flush only relevant editor, cancel only owned checks; no unrelated window keystroke/save leakage. | G/OS; current driver starts one workspace and observes associated Settings |
| INT-SHR-003 | Resize window/sheet/content environment; WIN scene geometry, SCREEN/ScrivSheetFitting | Supported bounds/dynamic type/appearance. Controls remain visible/reachable, scroll/focus intact; modal state preserved. | G/OS; snapshots report geometry but no generic resize driver |
| INT-SHR-004 | Scroll interaction surface/list/text; relevant UIScrollView/UITableView/UITextView | Mounted active surface. Reveal intended offscreen content without background/occluded targeting; discussion reader position preserved when not at bottom. | `scroll` primitive; scenario-specific C; wheel/trackpad/keyboard physical gaps |
| INT-SHR-005 | Select/copy read-only text; HIST.selectable, JOB.showPrompt, CDX response, MSG read-only text | Actual selectable text view, current content. Exact source/technical prompt text copied without edit or secret evidence capture. | `selection` primitive partial; copy/responder/clipboard semantics G/OS |
| INT-SHR-006 | Choose/cancel opening document/folder; FILE.choose/delegates; SET own picker | One active picker, intended type, genuine authorized URL. Exactly one callback; no replacement from cancel; retain project scope before queued I/O, release one-shot import scope; stale selection fenced. | G/OS; semantic import does not exercise permission/bookmark boundary |
| INT-SHR-007 | Choose/cancel export destination; FILE.export/delegates | Production temporary artifact, no concurrent picker. Export as copy, completion exactly once on choose/cancel, only owned temporary cleanup, overwrite/system confirmation separately honored. | S Fountain handoff capture only; actual destination/export OS gap |
| INT-SHR-008 | Acknowledge queued error with OK; ERROR.enqueue/presentNext, STORE error subscription | Frontmost real alert; preserve underlying draft, dedup same pending message, older dismissal cannot clear newer error, next queued alert presented. | JSON scenarios observe error without dismissal; generic UIKit alert action dispatch may be unavailable, no native adapter fallback |

## Ten proposed journey families

These are test design groupings, not ten new files to create immediately. A
family should share its expensive launch/auth/context setup where it remains
safe, use named checkpoints, and run only the needed isolated cases. Test
selection can slice a family by capability without changing the interaction
taxonomy or claiming omitted checkpoints passed.

### IJ-01: Create, locate, save and reopen local work

Primary IDs: INT-PRJ-001–010 and 015; shared close/scroll/window cases.

Start with clean local startup, create a project, rename, perform a small real
editor change, save, browse all local/recent cases, search/no-match/clear, select
and reopen another saved project, return to the first and relaunch it. Validate
the actual durable package and rendered content at each switch. Parameterize
blank/sample/multiple projects, Unicode titles, missing/corrupt metadata,
same-project reopen, duplicate button/shortcut, two windows, and interrupted
save. External package route runs only in the authorized picker lane.

Backfill assertions: sample/blank validity, project creation/preservation,
project-browser sorting and identity, save/journal publication, startup/open
stage errors, window-scoped finish editing. Do not count separately for each
legacy fixture shape or every title string.

### IJ-02: Import, round-trip and export across file boundaries

Primary IDs: INT-PRJ-010–014, INT-SHR-006–007.

Create/save a sentinel project, import a document through the production
boundary, inspect the rendered and persisted result, export its Fountain,
reimport and compare the intended invariants, then export/reopen the complete
package. Reject invalid documents without changing the sentinel/current saved
set. Parameterize Fountain/spmd/text/JSON, empty/title-only/BOM/CRLF/Unicode,
fallback filename, full timing/character metadata, malformed JSON/model,
oversize, canceled picker/export, stale navigation and inaccessible URL.

Two explicit input modes share checkpoints: semantic bounded synthetic file
input for broad parser/model cases, and actual OS picker/grant/export for
boundary parity. The first must never be reported as the second. Fold existing
Fountain and JSON assertion cases into this family rather than designing a
journey per original method. Keep exact frozen input/expected output and named
intentional corrections visible within its parameter data.

### IJ-03: Review history, recover interrupted work and synchronize

Primary IDs: INT-HIS-001–019, INT-PRJ-009/015/016, account safety-copy route.

Make several real edits, inspect working/local history, compare revision views,
expand timing/technical/profile detail, cancel then commit restore, verify a
new revision preserves prior history. Induce an authorized isolated interruption
through the real durability boundary; review draft, keep/reopen/edit/rebase/apply
or discard only that copy. Repeat the recovery checkpoint for visual direction:
reject a failed journal write without accepting field text, retry retention, use
a reviewed draft, retry preparation, and cancel/confirm discard without changing
the saved direction. On a dedicated local service lane, sync, disconnect,
edit offline, reconnect/replay, inspect cloud history and restore while another
client changes the source. Parameterize local/cloud, lease conflict, journal
failure, stale version, matching draft, rebase-needed and pending save at exit.

Backfill persistence, history presentation, editor/prompt recovery, atomic
rejection, optimistic concurrency and exact UTF-16 assertions. Audio not in cloud
history and discussion/membership/billing not being rewound are mandatory
negative checkpoints. Protocol-only adversarial histories remain separate
service gates, not a fake successful UI path.

### IJ-04: Scriv identity, service selection and account lifecycle

Primary IDs: INT-ACC-001–020; shared presentation/file-independent cases.

Open settings while local, visit panes/toggle preference, inspect/save service
address, open sign-in, enter address/request challenge, exercise code editing,
resend/change/cancel, authenticate dedicated identity, refresh, sync a synthetic
project and sign out. Parameterize email versus approved GitHub browser flow,
bad address/code, cooldown/expiry, server change, active task duplicate click,
browser cancellation, two-window ownership takeover and stale callbacks.

Do not merge the two identities: Scriv sign-out must not imply ChatGPT sign-out.
Existing settings-only/invalid-address cases can run without any live identity.
Real message delivery and OAuth use approved synthetic fixtures and cannot be
replaced by forcing the account model to signed-in.

### IJ-05: Discover, connect, disconnect and reconnect Codex

Primary IDs: INT-CDX-001–015, INT-ACC-002/003; instructions and model checkpoints.

Read-only popup/Settings navigation first, reveal/copy instructions, then run
one of two explicit lanes: managed signed-helper discovery/start or a harness-
owned real external loopback server. Connect, observe account/models and no
generation, disconnect, prove external listener survives where applicable,
reconnect three times, change supported model, cancel a delayed attempt and
recover from real owned transport loss. Parameterize not-found/incompatible,
signed-out/authenticated/provider-no-account, empty/stale model list, malformed
endpoint, startup error, pane/window closure and a newer competing attempt.

Source live-codex-connection currently offers only the opt-in external lane;
configuration checks are not runtime evidence. Reconnect must inspect state,
not restart a generation turn. Physical menus, model-menu selection and actual
helper trust need their own route evidence inside the same family.

### IJ-06: Isolated Codex account, pairing and history ownership

Primary IDs: INT-CDX-010–023; INT-SHR-006 and browser/window lifecycle cases.

With an approved dedicated OS/runtime identity, show pairing controls, choose the
original private pairing file, start, perform approved ChatGPT sign-in/cancel/
refresh/logout, stop, rotate or forget with cancel/commit branches, reconnect
using the original/new valid file, and select existing synthetic generation
history. Parameterize corrupt/inaccessible/stale/wrong-owner pairing, another
window's grant, canceled file choice, inaccessible history and changed account.

This family must remain separately runnable from read-only settings checks:
credential/grant operations change persistent access. HOME/CODEX_HOME alone do
not prove XPC/Keychain isolation. Never import a user's production credential or
pairing to make tests pass; never bypass signing/Library Validation failures.

### IJ-07: One real generation through durable job review and recovery

Primary IDs: INT-JOB-001–011 plus the image inventory's actual review/submit route.

On an authorized isolated standard-service provider lane, use synthetic script
and bounded approved generation, observe real stages/elapsed time, leave/reopen
job UI, inspect captured versus exact submitted prompt, decode output, and prove
the correct original cue receives the immutable asset. Visit local/shared pages,
show more and verify only owner can recover. Separate budgeted cases cover
cancel/completion race, transport loss, inspect existing turn, wrong-context
recovery, already-imported output and confirmed retry creating a new request.

Do not manufacture completed jobs, substitute mock provider output, silently
change provider/model, enable Fast, or make an unapproved second turn. Actual
provider failure/quota cases require real observed or supported controlled
service failures; do not pretend a disconnected UI covers them. Current
live-codex-image is an intentionally blocked scaffold, not coverage.

### IJ-08: Team access, invitation lifecycle and billing handoff

Primary IDs: INT-TEM-001–016 plus account and project-copy checkpoints.

On a dedicated test service, create/select/rename a team, inspect tabs and plan,
choose role/expiry, create and copy a reusable invitation, join from a second
authorized identity, share a synthetic project, change role and verify actual
read/edit/discussion rights, revoke link, remove/leave member and verify access
loss without erased history. Parameterize owner/admin/member/viewer, free/paid/
attention/canceled plan, expired/revoked/wrong-server link, stale account/team,
concurrent demotion and duplicate creation/retry.

Billing is a mode of this journey only through an authorized test checkout or
portal and verified return. Opening the browser is not paying; subscription
renewal/webhooks/transaction authorization remain service/permission gates.
Neither source text nor an enabled Subscribe button proves billing correctness.

### IJ-09: Scoped conversations with replies, attachments and mentions

Primary IDs: INT-DSC-001–020 plus file-free account/sync prerequisites.

Use two authorized synthetic collaborators. Open project/item scopes, preserve
independent unsent drafts across navigation, compose, attach exact item/version,
choose mentions, send once, reply, filter, open activity/unread target, resolve
and reopen. Parameterize line/direction/character/image/project, renamed/moved/
deleted anchors, duplicate display names, membership loss, 20-mention/8-attachment/
8000-UTF16 limits, IME, duplicate send, offline retry and incoming messages while
reading above bottom. Verify authored messages and metadata on both clients.

Current message UI has Reply and attachment navigation, not a visible edit or
delete-message control. Do not invent such interactions because service APIs
support them. Mention actions create in-app metadata, not email/push outreach.

### IJ-10: Explicit signed update with save and modal handoff

Primary IDs: INT-UPD-001–005; INT-SHR modal/window cases; PRJ durability checks.

With an approved isolated signed update fixture, check, repeat/focus, inspect
offer, cancel, download, cancel prepared update, prepare again, install/relaunch
and verify exact new bundle plus unchanged/recovered projects. Parameterize
current/blocked/error, download/signature failure, ready-on-quit, canceled quit,
retryQuit/retryBlocked, multiple registered stores, open editor and nested modal.
Reconfirm saved state after dismissing the modal chain before process exit.

Run semantic button/key and physical Escape/native modal cases independently
within this family. No UI dismissal can count as cancellation unless the native
plugin accepted it. Package/signature/entitlement/negative trust checks remain
exact-build gates. No permission weakening or substitute unsigned success path.

## Cross-cutting cases and evidence requirements

Apply these dimensions where behavior differs; do not take the full Cartesian
product or multiply journey families for cosmetic values.

| Dimension | Required cases and observation |
| --- | --- |
| Availability | Signed out/in, disconnected/checking/connected/generating, no projects/jobs/messages, local/cloud/team, valid/expired membership. Disabled/hidden action must stay uncallable; visible explanation must be truthful. |
| Repeat and ordering | Double click, repeated open, cancel then retry, prior callback after new attempt, change pane/project/account/server/team during request, response from wrong identity. One intended mutation and exact current owner. |
| Presentation/input | Button, menu, shortcut where actually exposed; real Escape, Return/Command-Return, back, Done, native close, popover click-outside; no action behind another modal. Preserve first responder, selection/IME and accessibility on dismissal. |
| Layout/readability | Actual window bounds, narrow/wide supported sizes, long titles/prompts/errors, dynamic type, scroll. Logical snapshot plus screenshot/physical input where geometry or event routing is the invariant. |
| Durability | Observe real package/journal/service acknowledgment; close/reopen/relaunch. In-memory title, dispatched=true or one successful snapshot is not sufficient. Preserve unrelated project/account/window state. |
| Files/access | Picker cancel, wrong type, oversized/corrupt document, symlink/path escape, stale/revoked bookmark, grant failure, delayed save after selection, export completion exactly once. No path-only substitute after denied scope. |
| Network/provider | Owned real transport loss/reconnect, offline/replay, duplicate receipt, invalid/stale protocol, quota/failure, provider account not-required versus truly authenticated. Count submitted turns; no auto retry with usage. |
| Safety/privacy | Dedicated synthetic identities and collaborators, explicit task authorization, standard service only, optional telemetry disabled where supported; no credentials/codes/login URLs/invitation secrets/account identifiers in general evidence. |

Every checkpoint should name: journey/case ID, interaction IDs, input route,
build/source identity, precondition, observation, durable invariant and status.
Use PASS, FAIL, BLOCKED, NOT RUN and UNSUPPORTED distinctly. Pure source,
fixture-authoring and transport checks remain labeled as such. A family can
have passing local cases and blocked live/OS cases without the family being
fully complete.

## Current CLI reachability versus coverage

`Automation/ScrivCLI.swift` currently advertises `completeInterfaceParity:false`.
Its `activate`, `text`, `type`, `selection`, `toggle`, `select`, `slider`, `scroll`,
`key` and `return` cover specific UIKit control/responder/public-delegate paths,
not arbitrary native input. `menu` describes menus without invoking providers
or selecting general menu items. Table-row/double-click, system browser/picker,
external URL delivery, real window resize/activation/close and process-relaunch
control remain material gaps. Do not silently invoke private actions or assign
the store to compensate.

The native accessibility adapter has a known Library Validation loading denial
in the current runtime. Its advertised command is **not** a usable fallback;
do not retry loading it or alter security/signing settings to unblock this
inventory. UIKit snapshot observations remain permitted. Alert text can be
observed in its own modal subtree with a covered workspace without pretending
that the native OK/menu action is reachable.

Relevant existing scenario clusters:

- `tests/e2e/projects.mjs`: repeated browser search/clear/close, covered-control
  rejection. No actual project-row open or file picker proof.
- `tests/e2e/project-creation.mjs`: repeat blank creation, save, original sample
  preservation and duration observation; not cold restart or recovery.
- `tests/e2e/settings-navigation.mjs`: separate Settings scene, pane navigation,
  isolated follow preference and disconnected display; no connection/auth.
- `tests/e2e/codex-setup-instructions.mjs` and
  `codex-endpoint-validation.mjs`: instructions/read-only setup and invalid
  manual endpoint rejection. These do not establish successful runtime/provider
  integration, pairing or account lifecycle.
- `tests/e2e/fountain-*.mjs`: production semantic import/export and parser
  assertion cases, now natural IJ-02 parameters instead of separate journeys.
- `tests/e2e/json-model-validation.mjs` and `json-character-links.mjs`: bounded
  document validation and real error/package preservation candidates; not
  picker automation or exhaustive validator equivalence.
- `tests/live-e2e/codex-connection.mjs`: opt-in real owned-loopback connection
  cycles with prerequisite attestations; not managed helper or live sign-in.
- `tests/live-e2e/codex-image.mjs`: blocked scaffold; cannot be counted as an
  executed generation journey. See `live-codex-image-plan.md` for isolation gates.

No complete actual-app CLI journey was found for History/recovery, Teams,
Discussion, true OS file exchange or the signed update lifecycle. Legacy
XCTest/node/provider doubles may protect pieces, but those are not evidence
that the proposed UI journeys run.

## Backward assertion mapping, after journey design

Use a many-to-many checkpoint ledger, not one replacement file per old test.
Each frozen assertion retains its exact source ID, source hash, original input
and expected result. Attach it to the narrowest existing journey checkpoint;
one checkpoint can discharge many compatible assertions. A frozen method can
span multiple checkpoints/families; keep it until every original assertion has
real evidence or an explicitly documented approved contract correction.

| Existing assertion cluster | Journey/checkpoint destination | What must stay separate |
| --- | --- | --- |
| FountainTests, JSON timing/orphan/duplicate/character-link validation | IJ-02 import/roundtrip/reject parameters | OS picker/grants, unrepresentable nonfinite values, mutable operation atomicity |
| Sample/blank, Editing/Persistence, PendingProjectSaveJournal, startup/package opening | IJ-01 creation/save/reopen and IJ-03 interruption/replay | Fault injection/hostile filesystem state and service-only durability gates |
| ProjectHistoryPresentation, recovery/draft/lease tests | IJ-03 read-only preview/rebase/restore/apply checkpoints | Cloud authorization/races that no legal UI can originate |
| EmailSignInFlow, cloud email auth and account UI cases | IJ-04 challenge/owner/verify/cancel checkpoints | Replay/rate-limit/identity collision adversarial server tests |
| CodexConnectionCheck, setup presentation, runtime bootstrap/session grants | IJ-05 connection state and IJ-06 trust/account checkpoints | Signed helper identity, credential-store isolation and permission-denial gates |
| GenerationJournal/Context/Prompt, artifact checks, job/UI cancellation | IJ-07 submission/inspect/output/recover/retry checkpoints | Adversarial RPC/prompt bounds and service failure fixtures not actually exposed by UI |
| TeamInvitation, team billing/membership tests | IJ-08 join/roles/links/billing checkpoints | Webhooks, financial transaction authorization, cross-tenant direct API attacks |
| DiscussionState, mention/reply/activity tests | IJ-09 scoped draft/send/read/resolve checkpoints | Unsupported message-edit API and direct protocol hostility |
| Update policy/modal/save/release tests | IJ-10 phase/physical cancellation/relaunch checkpoints | Exact signed artifact, trust, packaging, installer and release-channel gates |

For example, TimingTests::0010's two rejection assertions, both
CueAnchoringTests::0006/0013 rejection groups, and CharacterMentionTests::0013's
valid-plus-invalid cases are parameters of one IJ-02 rejection checkpoint,
not four independent journeys. Conversely, a helper test about NaN validation
cannot be retired merely because JSONDecoder rejects an unrepresentable token
before the validator. Preserve its gate until a genuine supported boundary
exercises the same invariant.

## Remaining uncertainty and next design decisions

1. This count is defensible for inspected current callsites, not mechanically
   proven exhaustive. OS-supplied browser/picker/QuickLook controls and Sparkle
   native windows are not fully enumerated by Swift source; record their actual
   supported user choices in the route matrix when safely inspected.
2. Table, general menu, native-close and physical-event reachability must be
   resolved before assigning full coverage, without loading the denied adapter
   or substituting direct model mutations. The honest status meanwhile is gap.
3. Exact-build runtime evidence lives in the existing ledger. This document
   does not freeze the current number of retired tests, transfer a source-only
   pass into a runtime pass, or authorize another deletion.
4. Split permission-bearing live cases from safe local cases within families.
   A ten-family plan must not make ordinary test discovery send email, use a
   provider, create access, modify membership or install software implicitly.
5. Merge sibling inventories by interaction identity and the shared operation
   aliases above. Then estimate the case matrix and launch cost; do not sum
   candidate-site counts, UI goals, service gates and test files together.

Next work is to reconcile these interaction IDs with the editor/media and
service inventories, settle journey checkpoints and safe fixture boundaries,
then map frozen assertions backward. No further scenario-per-method expansion
or old-test deletion is implied by this inventory.

### Final checklist reconciliation note

`Account/AccountUI.swift` contributes two frozen candidate sites. They are generic
button-construction helpers, not additional user intents; the concrete callsites
and actions using them are cataloged above. Across this document and the authoring
catalog, every source filename in the frozen 688-site UI candidate list is now
referenced. This filename reconciliation is a completeness aid, not proof that
every candidate line is mapped or every native route has executed.
