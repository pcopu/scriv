# Scriv handoff — 2026-11-03

This records the combined Settings/menu and automatic Codex connection tasks, based on `c017c0e`. The owner requested that both workers stop, preserve all work, write this handoff, and make one combined commit without pushing. The runtime worker was confirmed idle with a completed final report before this file was written. No further tests or implementation changes were made during closeout.

**The final checkout is not green.** The runtime task stopped after adding tests for an unimplemented session-only pairing fallback. The passing results below precede those final additions and must not be presented as verification of the final combined checkout.

## Settings and app menu changes

- **Scriv → Settings…** has the standard **⌘,** shortcut. It opens a separate native UIKit/Mac Catalyst Settings window with **General**, **Account**, and **Codex** sidebar panes, following the owner's reference.
- A dedicated scene configuration and coordinator reuse the Settings window, share the workspace's existing `WorkspaceStore`, and support closing and reopening it. The workspace overflow menu no longer carries Settings; existing routed Settings links open the window.
- The panes retain their controllers and preserve an unsaved server-address draft when switching sections. Settings follows system light/dark appearance and uses grouped native controls.
- Shared account scroll layouts respect horizontal safe areas, so controls do not extend underneath the native sidebar. Presentation helpers prefer the active window scene.
- **Scriv → Check for Updates…** now calls the existing updater. App-level menu actions remain routable while a sheet owns focus. The manual check starts directly after presentation instead of waiting for a Catalyst sheet completion that left the native test stuck on Checking.
- Update signing, cancellation and durable-save policies remain in place. Ad-hoc development builds still cannot install updates.
- New native coverage checks app command dispatch, repeated update requests, the real development-build signing block, Settings window reuse/reopening, shared state, draft preservation, sidebar bounds, and light/dark rendering. Existing modal fixtures now wait for appearance and restore workspace scene activation.

Key implementation files: `ScrivSettingsPanelController.swift`, `ScrivSettingsWindowCoordinator.swift`, `ScrivSettingsController.swift`, `ScrivPlaybackKeyboardRouter.swift`, `AppDelegate.swift`, `ScrivUIKitRouter.swift`, `UIKitFileAccess.swift`, `AccountUI.swift`, and `ScrivUpdateCoordinator.swift`. Both the generated Info.plist and its generator contain the Settings/workspace scene configurations.

## Automatic Codex connection changes

The other worker's completed changes, reviewed in the shared checkout:

- `CodexController.checkAndConnect` prepares the local runtime directly instead of first validating or probing the saved WebSocket address. Manual endpoint settings belong to the explicit Advanced connection action. Already-connected runtimes refresh their account and model state.
- The previous helper is released before preparation installs the new cleanup callback. Cancellation and stale-attempt guards remain around preparation and startup.
- Executable discovery includes Codex and ChatGPT bundles under `/Applications` and the user's Applications directory, plus `~/.local/bin`, alongside the existing Homebrew and npm candidates. An explicit executable selection remains authoritative.
- The Codex setup sheet explains automatic startup. Manual WebSocket server instructions and address controls are under Advanced. Opening the sheet still starts nothing; first-use consent and authenticated pairing remain required.
- Connection, cancellation, duplicate-attempt, executable-discovery, and UI wording tests were updated, along with the README and integration documentation.

Key files: `CodexController.swift`, `CodexConnectionCheck.swift`, `ScrivCodexSetupView.swift`, `ScrivRuntimeBootstrapCoordinator.swift`, and their tests. The runtime worker's contribution to the shared `ScrivSettingsController.swift` was its bootstrap-lifetime comment; the pane changes are from the Settings task.

## Verification completed before the unfinished fallback

| Evidence | Result and scope |
| --- | --- |
| Settings worker: `node --test tests/*.test.mjs` | **147 passed**, before the runtime worker's final fallback assertion was added. |
| Settings worker: native Catalyst selected suites | **39 passed**: ApplicationUpdateMenuTests, SettingsPanelTests, UpdateModalHandoffTests, UpdatePresentationTests, CodexSetupUIKitTests, ScrivPlaybackKeyboardResponderTests, and SecondaryLayoutTests. This is a selected suite, not the full native suite. |
| Settings worker: repository integrity | `node scripts/check-repo.mjs` passed. |
| Settings worker: portable Catalyst verification | Passed integrity checks for 76 UIKit/client sources and syntax parsing for 116 source/test files. Native compilation is established separately by the native run above. |
| Settings worker: Release build | `bash scripts/build-catalyst.sh` completed, including bundle/icon/signature checks, before subsequent runtime signing experiments changed the generated product. |
| Settings visual review | Exported and inspected light/dark native UIKit render attachments; fixed the observed sidebar overlap. These are rendered content previews, not a manual physical-keyboard or signed-update-install acceptance pass. |
| Runtime worker's final report | **364 Swift tests**, **144 repository tests**, **27 native Catalyst tests**, and a Developer ID build passed before its unfinished Keychain work. These results are reported by that worker, not rerun during closeout. |

Build logs, test results, previews, caches, credentials, and generated app products are excluded from the combined commit. `scripts/__pycache__/` remains an untracked generated artifact and is deliberately not staged.

## Remaining issues and current blockers

1. **Live automatic connection is not working end to end.** The runtime worker reached the signed helper, then failed to save the authenticated pairing in Keychain. Its proposed fallback is not implemented.
2. **Swift test compilation is currently broken.** `apps/mac/Tests/ScrivCoreTests/RuntimeBridgeSessionGrantTests.swift` references `RuntimeBridgeSessionGrant`, which does not exist in the sources. Its tests specify session-only lifetime/reset, owner/capability validation, authoritative persistent grants, and refusal to replace or conflict with an approved grant. The test file is preserved as unfinished work.
3. **A repository assertion is also ahead of implementation.** The new test named “only an absent Keychain entitlement permits a verified in-memory grant” in `tests/runtime-bootstrap-integration.test.mjs` expects `sessionGrant` handling in `apps/catalyst/MacRuntimeBridge/MacRuntimeBridge.swift`. That implementation file has no corresponding changes.
4. **Integration documentation describes the unfinished behavior as working.** The process-local pairing paragraph in `docs/codex-integration.md` is premature. Reconcile it when implementing or revising the proposal.
5. **Treat the generated Release app as stale and unusable.** The runtime worker reports that its last signing experiment left restricted entitlements in the built Release product, which cannot launch without an unavailable provisioning profile. Its source edits to the signing script were reverted. Rebuild using the current checked-in script before trying the app; the earlier successful build log does not verify the product's final state. Generated binaries are not part of this commit.
6. **Signed update installation/relaunch and a real Ready Codex connection remain unverified.** The Settings tests establish native command/presentation behavior and the intended development-build update block. They do not establish successful signed update installation, live account/model readiness, or generation.

The runtime worker proposed retaining an authenticated pairing only in process memory when saving returns `errSecMissingEntitlement`. If resumed, preserve the existing first-use consent and signed/authenticated helper boundary. Locked or unreadable Keychain entries, invalid owners/capabilities, and conflicting persistent grants must still fail closed. Do not add a plaintext/preferences fallback or weaken signature checks. No such fallback has been implemented in this handoff.

After the owner resumes implementation: resolve the unfinished fallback/tests/docs together, rerun the affected Swift, repository, and native suites, rebuild the app from the current script, and repeat the live automatic connection check. Do not claim the earlier passing counts apply to the final checkout. No push, installation, publication, or further implementation was authorized by this closeout request.

## Previous handoff retained for historical context

The snapshot below is preserved verbatim. Its old repository state, test counts, running-app claims, push workflow, and computer-use advice are historical, not current instructions. Follow the current owner request and applicable AGENTS.md/skills instead.

<details>
<summary>2026-11-02 handoff (historical)</summary>

# Handoff: make Scriv fast and lean, and fix every interface bug

Last updated **2026-11-02, about 22:30**. `main` is at `7273ca6`, pushed and clean.

## The brief

> Keep working to make it fast and lean, then find any bugs in the interface and fix them all. Commit hyper often, and keep going until it's lean, mean and everything works.

The work covers the native Mac app (UIKit / Mac Catalyst, `apps/catalyst/ScrivUIKit`) and its shared model code (`apps/mac/Sources/ScrivCore`, `apps/mac/Sources/ScrivApp/Services`).

## Where things stand

- **Tests:** all 247 native UIKit tests pass on `7273ca6`.
- **Speed and memory:** measured on the current build with the owner's image-heavy project (YAM MAN, 16 entries, 56 s):
  - **Idle:** 0% CPU, zero idle wakeups, 5 threads, 146 MB memory footprint.
  - **Playback (muted):** about 16% of one core, with memory steady at about 140 MB (peak 166 MB). A 6-second sample showed Scriv's own refresh code using only about 3% of the main thread. The rest of the time goes to audio and drawing, and there is no single hot spot.
  - **Caveat:** the Mac's load average was about 4. The load comes from other apps (Codex, a WebKit page, coreaudiod), so absolute timings are noisy. Idle CPU and wakeups don't depend on that load.
- **Running app:** the owner's Scriv runs from `build/catalyst/Build/Products/Release-maccatalyst/Scriv.app`, built from `d7bb9e9`. Commits after that one changed only Escape in Review brief, VoiceOver wording and a menu tick. Rebuild to pick them up.
- **Installed app:** `/Applications/Scriv.app` is still the **1.0.3 build from Oct 31** and has none of these fixes. The question below is still waiting on the owner.

## Done: 50 commits since 2026-11-01

Every commit message describes the user-visible change. Grouped by area:

**Speed and size**
- Sample frames ship as JPEG instead of PNG (6.4 MB → 1.3 MB). Release builds strip local symbols, so the app bundle went from 24 MB to 14 MB (`718d503`, `774f8eb`).
- Scriv skips a pointless shared-jobs publish every 30 s while offline (`ff1a864`).
- Tests leave no preference files or scratch folders behind, and test mode prunes stale ones (`b32b064`, `1b9b08d`).

**Sheets and layout**
- Sheets fit the window, so their footers and buttons stay reachable on small windows. This covers form-sheet width, the navigation-bar offset, recovered-draft and character-links, word timing, Codex setup and generation review (`0374d9d`, `f166d76`, `4d374df`, `a7aa798`, `99dbcdf`, `f09c5dc`).
- A notice now grows the Word timing and Audio trim sheets instead of pushing Cancel and Save out of sight (`febc117`, `4c521e5`).
- Layout checks for wrapped words and clipped controls, plus fixes to History's tag and Layers word blocks (`75e8da1`). The Preview aspect badge never wraps (`864803d`). The Script header title no longer truncates early (`76d4441`). The Characters profile stays usable on short windows (`48950a1`).

**Script and Find**
- Find marks the current match, and Escape closes Find (`8ade436`, `27f5d4f`).
- A new line opens with its placeholder selected (`55f34e6`).
- The first line no longer offers Move up, and the last no longer offers Move down (`1ca75d2`).
- No false "Draft not applied" message when extending a direction (`8a90254`).
- Space plays with Caps Lock on, and ⌘ with keypad +/− zooms (`eb93314`).

**Storyboard and Layers**
- Current moment selects the playhead picture (`6f84f02`).
- Word pills and direction blocks open their menus on right-click, so press-and-hold drags work (`c9c1202`, `ef51f72`, `1b5bee4`, `0013ced`).
- Splitting picture 01A labels the new half 01B, not 01AB (`12b1ae9`).
- Word chips are re-measured when the text size changes, so words no longer break mid-word (`0608b63`).

**Preview and images**
- Inspect is disabled when the picture has no image (`0d3a124`).
- The split preview without an image says "No image yet" instead of showing three Retry buttons (`e62cb1b`).
- The Version picker is now covered end to end: it lists exactly the image's versions, newest first, and changes only that placement (`ccdae06`).
- Escape closes Review brief (`d2483f4`).

**Characters**
- The Characters tab shows the script exactly as the Script tab does (`f7b6605`, test `348236c`).
- Escape in the search field clears the filter (`c321139`).
- Picking a colour no longer shifts the swatches (`d3c47b9`).
- An avatar without a portrait shows only the initial, centred (`20182bb`).
- **Portrait options** is now a menu to choose the portrait from tagged images or remove it. It used to open the editor, which has no portrait fields. The line under the name now says where the portrait comes from, or "No portrait yet" (`d7bb9e9`).
- A tagged image's menu ticks "Use as … portrait" when that image is already the portrait (`7273ca6`).

**Accessibility and wording**
- Every visible button has a VoiceOver label (`a2a9a01`, `34154be`, `fb5c7a3`).
- Singular forms are correct: "1 image", "1 message mentions you", "1 unread mention", "1 overlapping placement" (`f56fa88`, `1f7f356`).

**Test reliability**
- Fixtures wait for startup before installing their project (`0fdc273`).
- New end-to-end coverage: storyboard word cuts and real audio import (`71cc551`).

### Checked by hand and found working
The picture "…" menu, splitting a picture that has an image, Review brief (Source, People and Exact request tabs), Versions, Portrait options, History, Settings, Teams, Add character, Discussion, word timing, audio trim, Inspect, the Projects browser, and the expanded Layers sheet.

## Still to do, in priority order

1. **Owner decision: install over `/Applications/Scriv.app`?** Only the installed 1.0.3 would ever show these fixes outside the dev build. The plan is to move 1.0.3 to a backup folder first, then copy the Release build in. That would be an unsigned development build. **Don't do this without the owner's yes.**
2. **Quiet-Mac speed measurement.** Repeat the idle and playback numbers once the load average is below about 1.5. Also measure each tab during playback (Script, Storyboard, Characters). `ZZWorkspaceTickBenchmarkTests.swift` was a throwaway per-tab benchmark and was never committed. Rewrite it from the description in "How to work" if needed.
3. **Escape on the update sheet** (`ScrivUpdateController`) is still not handled. It deliberately blocks dismissal (`isModalInPresentation`). Escape could trigger the secondary (Later/Cancel) button when it's visible and enabled. It wasn't done because the buttons reply to the separate updater process, so test the whole update flow (`UpdateModalHandoffTests`, `tests/update-modal-handoff.test.mjs`) before changing it.
4. **Flaky keyboard tests.** `ScrivPlaybackKeyboardResponderTests` failed 9 of its 10 tests once in a full run and passed on both reruns. The likely cause is the test window losing key focus while someone used the Mac. Make it robust, for example by making its window key and waiting for `isKeyWindow`.
5. **Continue the bug sweep** in areas not yet exercised by hand on the current build:
   - Sign in / email-code flow.
   - Codex setup and model menu.
   - Generation history / jobs (`ScrivGenerationJobsController`).
   - Audio library: import, delete, relink.
   - Cue anchor ("Picture source") sheet.
   - Character image review ("Save tag & next", "Skip for now").
   - Undo and redo across tabs.
   - Window resizing between 1080 and 2400 points on each tab.
   - Dark mode on every tab.
6. **Code sweeps that found bugs before, worth repeating after big changes:**
   - Controls that silently do nothing: `guard … else { return }` in button actions, and `button(…) {}` with no menu attached. The last sweep came back clean.
   - Count strings without `ScrivFormat.count`.
   - Sheets not built on `ScrivScreenController`, which miss the shared Escape and window-fitting rules. Only `ScrivUpdateController` is left.
   - Notices placed inside the scrolling area that can push footer buttons out of view.

## How to work

### Rules
- **Commits:** author `Peter Copu <2762285+pcopu@users.noreply.github.com>`, with **no Claude co-author or attribution lines**. Commit and push to `main` after each fix, with a message describing the user-visible change.
- **Before each commit:** run the full native suite. `commit.sh` runs only the Node tests and the repo check, and will commit even if the native suite failed, so check the result first.
- **Owner's data:** Scriv on this Mac holds test data, but don't touch `/Applications/Scriv.app` without asking. Codex computer-use targets `/Applications/Scriv.app` by name, not the dev build.
- **Using the screen:** only use the screen while the owner is away (`HIDIdleTime` of 2 minutes or more, screen unlocked). Restore what you change, such as the tab, playhead and mute.

### Helper scripts
These lived in a session scratchpad that won't survive, so they're recreated here.

**`commit.sh "message"`** runs the fast checks, then commits as pcopu:
```bash
set -euo pipefail; cd /Users/pcopu/Env/scriv
node --test --test-reporter=dot tests/*.test.mjs >/tmp/scriv-node-tests.log 2>&1 || { tail -40 /tmp/scriv-node-tests.log; exit 1; }
node scripts/check-repo.mjs >/dev/null
git add -A
GIT_AUTHOR_NAME="Peter Copu" GIT_AUTHOR_EMAIL="2762285+pcopu@users.noreply.github.com" \
GIT_COMMITTER_NAME="Peter Copu" GIT_COMMITTER_EMAIL="2762285+pcopu@users.noreply.github.com" git commit -q -m "$1"
git log --oneline -1
```

**`uitest.sh [Class[/test] …]`** runs the native UIKit tests, all of them when given no arguments (about 2 minutes):
```bash
cd /Users/pcopu/Env/scriv; L=/tmp/scriv-uitest.log
args=(); for t in "$@"; do args+=(-only-testing:ScrivUIKitTests/$t); done
xcodebuild -project apps/catalyst/ScrivUIKit.xcodeproj -scheme ScrivUIKit -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build/catalyst \
  -clonedSourcePackagesDirPath build/catalyst/SourcePackages CODE_SIGN_IDENTITY=- test "${args[@]}" > $L 2>&1
echo "exit $?"
grep -E "error: -\[" $L | sed -E 's/.*error: -\[ScrivUIKitTests\.([A-Za-z]+) ([A-Za-z0-9_]+)\] : (.{0,200}).*/\1.\2 :: \3/' | sort -u
grep -E "Executed [0-9]+ test" $L | tail -1
```

**Type-check only** is a fast compile check without `xcodebuild`:
```bash
cd /Users/pcopu/Env/scriv; OUT=/tmp/scriv-tc; mkdir -p $OUT
SDK=$(xcrun --show-sdk-path --sdk macosx); T=arm64-apple-ios17.0-macabi
X=(-Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" -I "$SDK/System/iOSSupport/usr/lib/swift")
xcrun swiftc -target $T -sdk "$SDK" -swift-version 5 "${X[@]}" -parse-as-library -module-name ScrivCore -emit-module -emit-module-path $OUT/ScrivCore.swiftmodule apps/mac/Sources/ScrivCore/*.swift 2>&1 | grep error | head
legacy=(); for x in WorkspaceStore CloudClient CloudClient+Generation CodexController CharacterAnalysisController InternetPeerMedia LocalAudioEngine ResourceBundle; do legacy+=("apps/mac/Sources/ScrivApp/Services/$x.swift"); done
legacy+=(apps/mac/Sources/ScrivApp/Views/ProjectHistoryPresentation.swift)
xcrun swiftc -typecheck -target $T -sdk "$SDK" -swift-version 5 "${X[@]}" -module-name ScrivUIKit \
  -import-objc-header apps/catalyst/UpdateBridge/ScrivUpdateBridge.h -I $OUT "${legacy[@]}" \
  $(find apps/catalyst/ScrivUIKit apps/catalyst/MacRuntimeBridge -name '*.swift') 2>&1 | grep "error:" | sort -u | head -40
```

**Build the app:** run `bash scripts/build-catalyst.sh` (a few minutes). It produces `build/catalyst/Build/Products/Release-maccatalyst/Scriv.app`.

**Packages:** run the 363 macOS package tests with `swift test` in `apps/mac` after changing ScrivCore.

### Testing patterns that work
- Native tests run only with the scheme's `--screenshots` argument, which turns on isolated storage. Wait for `store.isBootstrapping` to clear before replacing `store.project`.
- Fixture images need `sha256` set to 64 hex characters, otherwise edits fail with "Invalid image metadata".
- To run a `UIAction` handler in a test: `unsafeBitCast(action.value(forKey: "handler") as AnyObject, to: (@convention(block) (UIAction) -> Void).self)(action)`.
- To prove a fix: keep the fixed file aside, restore the old one with `git show HEAD:<file> > <file>`, show the new test failing, then put the fix back.

### Hand-testing on the real Mac
- Driving the app with `osascript` and System Events works:
  - Quit a specific copy through its menu: `click menu item "Quit Scriv" of menu 1 of menu bar item 2 of menu bar 1` for the process with that `unix id`. A ⌘Q keystroke can land in the wrong app.
  - The **first click on an inactive window only activates it**. Make the process frontmost first, or the click is lost.
  - Reading the accessibility tree with JXA (`entireContents()`, then filtering on `description`) shows controls that are off screen.
- **Synthetic scroll-wheel events don't reach the app**, whether posted from a compiled helper or from JXA. Scroll some other way or inspect through the accessibility tree.
- In the owner's 1280×802 window, the tabs sit at about y=90 on screen: Script about x=532, Characters about x=748. The playback bar is at y=786: back button about x=38, play about x=70, mute about x=1180.
- To check how busy and how idle the Mac is: `sysctl -n vm.loadavg`, and `ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1e9); exit}'`.
- To measure Scriv itself: `top -l 4 -pid <pid> -stats pid,cpu,mem,idlew,threads -s 3`, `footprint <pid>`, and `sample <pid> 6`.


</details>
