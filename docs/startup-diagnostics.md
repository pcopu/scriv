# Local startup evidence and isolated native recovery tests

This slice observes startup; it does **not** change normal storage, account restoration, bookmark grants, replay, journal locking, window order, or timeout policy. A UI-control binding timeout alone is not evidence of a Scriv hang, absent window, or journal contention.

## Opt-in local trace

The exact launch argument `--scriv-startup-trace` enables a process-local `OSLog` category:

- subsystem `app.scriv.startup`, category `local-startup`;
- at most 128 events (the reusable recorder is capped at 256);
- fixed stage enum, sequence, monotonic elapsed milliseconds, allowlisted error families (`cocoa`, `posix`, `url`, `other`) and numeric codes;
- no account IDs, token/bookmark bytes, project text, file paths, arbitrary domain strings, localized messages or external telemetry;
- exactly two main-queue heartbeat observations, queued once, the second after 250 ms. This is not a repeating watchdog or a timeout/recovery mechanism.

Without the argument, the recorder calls no sink and queues no heartbeat. No diagnostic file is created by the app. Unified logging has ordinary system retention/delivery limits. Event sequence is process-wide; concurrent sink delivery can be reordered, so sort by sequence. Multiple scenes share the budget and are not individually identified. Missing events alone do not prove a blocked operation: the process may have exited, events may not have been retained, or the budget may have been exhausted.

For a normal-profile observation, the native owner must first use the ordinary save/Quit flow and confirm the earlier process ended; never create a competing normal instance or force-terminate one for this test. Launch the exact candidate with only the trace argument added, using the existing authorized normal profile. **This still accesses the normal account and project storage.** Do not add `--screenshots` or `--peer-smoke` and call that normal startup. `SCRIV_VERIFICATION_ROOT` alone does not redirect a normal launch and is deliberately not a production isolation switch.

Keep evidence local. A narrowly filtered local observation is:

```sh
log stream --style compact --level info --predicate 'subsystem == "app.scriv.startup" AND category == "local-startup"'
```

Do not capture or upload broad system logs, private project data, saved credentials, or error messages. The trace is intentionally insufficient to identify a user's document.

### Interpreting the boundaries

1. `storeConstructionBegin` precedes Codex pairing/Keychain, generation bookmark/journal, cloud token/Keychain and project storage construction. Their paired markers identify the last reached boundary, not its cause.
2. `storeConstructionEnd`, `windowCreated` and `windowVisibilityRequested` distinguish construction from the call requesting visibility. `windowBecameKey` and `rootViewAppeared` are UIKit lifecycle observations, not proof of composited pixels or accessibility/control-service binding.
3. `bootstrapBegin` then account restoration, pending inventory, access restoration, pending recovery, metadata, checkpoint and history stages cover the actual normal recovery path. `verificationBootstrapSkipped` explicitly identifies the synthetic early return.
4. End markers in `defer` mean a scope returned or threw, not that it succeeded. Look for its failure marker. Metadata failures are recorded before wrapping into a project-open stage, preserving allowlisted underlying codes without logging the error text.
5. `bootstrapEnd` follows release of the readiness gate even on a recovery error. Alert queued/presented/dismissed markers distinguish delayed presentation from window construction.
6. Heartbeats show only that the main queue executed those two early closures. Their delay is not unique to a journal lock; their success does not rule out later stalls. A run-loop sample is likewise not causal evidence.

Pair these observations with actual native screenshots and independent control-service/window evidence. If UIKit lifecycle and heartbeat markers advance but Scriv and unrelated Finder/system bindings all time out, retain control-service failure as a competing explanation. Do not change storage permissions, discard pending records, skip validation, or change lock semantics on that basis.

## Native tests (must actually be run on macOS)

`WorkspaceStartupDiagnosticsTests` uses a DEBUG-only, private-constructor capability. Its factory requires XCTest and the existing `--screenshots` host profile, allocates a new private temporary directory and unique preferences suite, accepts **no external root parameter**, and rejects paths outside its generated Projects directory or through symlinks. Release builds contain no harness or injection initializer. It does not introduce a production environment/path bypass.

The host profile isolates existing credential/service dependencies. The capability explicitly disables the recovery early return for its store, injects synthetic account restoration, and then runs the **same normal bootstrap/inventory/open/recovery implementation** against a real temporary ProjectRepository and PendingProjectSaveJournal. It does not stub replay, saving, acknowledgement or flock. A narrow metadata-read denial injects Cocoa permission/POSIX codes; it tests fail-closed behavior, not operating-system sandbox permission enforcement. Fixture error values remain observable without presenting alerts over the test host's other window.

Five native tests cover:

- permission failure: normal branch reached, readiness released, pending-record bytes and canonical project bytes retained exactly, standard last-project preference untouched;
- successful accepted-edit replay and exact acknowledgement, with history retained;
- pending async account restoration while a synthetic UIWindow/root controller is bound and the main queue advances;
- actual pending-journal contention held by an independent file descriptor, fixed-stage elapsed observation, utility-queue release and an independent five-second failsafe. The production blocking lock is unchanged; this proves only the synthetic boundary, not contention in any affected launch;
- rejection of outside and symlink fixture targets.

The synthetic fixture directories/preferences are intentionally not automatically removed by this slice. No user package is mutated or deleted. Four `StartupTraceTests` additionally exercise disabled recording, serialized privacy, concurrent unique sequence/hard event cap and one-shot main-queue probes.

Run in an isolated receiving source checkout after the source transfer guard. The checked-in test scheme already supplies `--screenshots` (keep it). With a local Xcode/macOS SDK and existing authorized development-signing setup:

```sh
swift test --package-path apps/mac --filter StartupTraceTests
python3 scripts/generate-catalyst-project.py
xcodebuild -project apps/catalyst/ScrivUIKit.xcodeproj -scheme ScrivUIKit \
  -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/startup-diagnostics-native \
  -resultBundlePath build/startup-diagnostics-native-results \
  -only-testing:ScrivUIKitTests/WorkspaceStartupDiagnosticsTests test
```

Use a fresh result-bundle path on subsequent runs rather than deleting existing evidence. Do not weaken signing/sandbox/Keychain controls to make tests pass. Then run existing package-open, prompt-recovery, update-durability, playback and image regressions, and a Release compile to verify the injection surface is excluded. Compilation or portable source contracts alone are not native test results.

Remaining independent acceptance: real normal-profile Keychain/generation-folder and last-project recovery, fresh-process external picker/bookmark access, actual denied permissions, alert dismissal/relaunch, actual screenshot and control binding, and process exit/update handoff. These tests neither certify those flows nor establish an updater acceptance result.
