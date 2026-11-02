import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const root = new URL('../', import.meta.url);
const read = path => readFile(new URL(path, root), 'utf8');
const storePath = 'apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift';
const tracePath = 'apps/mac/Sources/ScrivCore/StartupTrace.swift';
const harnessPath = 'apps/catalyst/ScrivUIKit/Shared/WorkspaceStartupTestHarness.swift';
const nativePath = 'apps/catalyst/Tests/ScrivUIKitTests/WorkspaceStartupDiagnosticsTests.swift';

// These are portable source contracts, not execution of Swift, UIKit or flock.
test('startup evidence is opt-in, bounded, local and restricted to a fixed schema', async () => {
  const trace = await read(tracePath);
  assert.match(trace, /enabled: ProcessInfo\.processInfo\.arguments\.contains\("--scriv-startup-trace"\)/);
  assert.match(trace, /maximumEvents: Int = 128/);
  assert.match(trace, /limit = min\(256, max\(0, maximumEvents\)\)/);
  assert.match(trace, /guard enabled else \{ return \}/);
  assert.match(trace, /guard sequence < limit else/);
  const fields = trace.split('public struct Event:')[1].split('public static let process')[0];
  assert.deepEqual([...fields.matchAll(/public let (\w+):/g)].map(x => x[1]), ['sequence', 'stage', 'elapsedMilliseconds', 'errorFamily', 'errorCode', 'underlyingFamily', 'underlyingCode']);
  assert.doesNotMatch(fields, /:\s*(String|URL|Data|NSError|Error)\b/);
  assert.match(trace, /default: return \.other/);
  assert.doesNotMatch(trace, /URLSession|FileHandle|Data\(contentsOf|createFile|UserDefaults|environment\[/);
  const log = trace.split('private static func localLog')[1];
  assert.match(log, /Logger\(subsystem: "app\.scriv\.startup", category: "local-startup"\)/);
  assert.doesNotMatch(log, /error\.localizedDescription|source\?\.|cause\?\.|\.userInfo|\.path/);
});
test('scene construction observes the existing order and schedules only two bounded main-queue probes', async () => {
  const app = await read('apps/catalyst/ScrivUIKit/App/AppDelegate.swift'), trace = await read(tracePath);
  const order = ['.storeConstructionBegin', 'trace.scheduleHeartbeats()', 'WorkspaceStore()', '.storeConstructionEnd', 'UIWindow(windowScene:', '.windowCreated', 'window.makeKeyAndVisible()', '.windowVisibilityRequested'];
  let previous = -1;
  for (const token of order) { const index = app.indexOf(token); assert.ok(index > previous, token); previous = index; }
  assert.doesNotMatch(app, /await .*bootstrap|waitUntil.*bootstrap/);
  const beats = trace.split('public func scheduleHeartbeats()')[1].split('private static func family')[0];
  assert.match(beats, /guard !heartbeatsScheduled/);
  assert.equal((beats.match(/DispatchQueue\.main\.async/g) ?? []).length, 2);
  assert.doesNotMatch(beats, /Timer|while|repeat|asyncAfter.*scheduleHeartbeats/s);
});
test('pre-window account and generation markers retain verification credential guards', async () => {
  const codex = await read('apps/mac/Sources/ScrivApp/Services/CodexController.swift');
  const cloud = await read('apps/mac/Sources/ScrivApp/Services/CloudClient.swift');
  assert.match(codex, /if !verification \{ bridgePaired = MacRuntimeBridge\.isPaired \}/);
  for (const marker of ['codexInitializationBegin', 'pairingReadBegin', 'pairingReadEnd', 'generationBookmarkBegin', 'generationJournalBegin', 'generationJournalEnd']) assert.ok(codex.includes(`.${marker}`));
  assert.match(codex, /if !verification, let data = UserDefaults\.standard\.data\(forKey: "ScrivUIKitGenerationLocation\.v1"\)/);
  assert.match(cloud, /if !ProcessInfo\.processInfo\.arguments\.contains\("--screenshots"\), !ProcessInfo\.processInfo\.arguments\.contains\("--peer-smoke"\) \{\s*startupTrace\.record\(\.cloudTokenReadBegin\)\s*token = try\? KeychainToken\.read/);
});
test('injection is DEBUG XCTest-only with a generated private root, not a production environment override', async () => {
  const harness = await read(harnessPath), store = await read(storePath);
  assert.ok(harness.startsWith('#if DEBUG\n')); assert.ok(harness.trimEnd().endsWith('#endif'));
  assert.match(harness, /private init\(root: URL/);
  assert.match(harness, /static func make\(trace: StartupTrace\)/);
  assert.match(harness, /arguments\.contains\("--screenshots"\).*NSClassFromString\("XCTestCase"\)/);
  assert.match(harness, /temporaryDirectory\.resolvingSymlinksInPath\(\)/);
  assert.match(harness, /\.posixPermissions: 0o700/);
  assert.match(harness, /canonical == canonical\.resolvingSymlinksInPath\(\)/);
  assert.match(harness, /canonical\.path\.hasPrefix\(root\.path \+ "\/Projects\/"\)/);
  assert.doesNotMatch(harness, /environment\[|standard\.set|setenv|chmod|startAccessingSecurityScopedResource/);
  assert.match(store, /#if targetEnvironment\(macCatalyst\) && DEBUG\s+private var startupTestHarness/);
  assert.match(store, /private var skipStartupRecovery: Bool \{\s*#if DEBUG\s*if startupTestHarness != nil \{ return false \}\s*#endif\s*return verificationMode/);
  assert.match(store, /if verificationMode \{\s*let output = ProcessInfo\.processInfo\.environment\["SCRIV_VERIFICATION_ROOT"\][\s\S]*?\} else \{ rootURL = FileManager\.default\.urls\(for:\.applicationSupportDirectory/);
  assert.equal((store.match(/environment\["SCRIV_VERIFICATION_ROOT"\]/g) ?? []).length, 1);
  assert.match(store, /private var projectFileAccess:[\s\S]*?#endif\s*return \.shared/);
  assert.match(store, /private var startupDefaults:[\s\S]*?#endif\s*return \.standard/);
});
test('real bootstrap and repository recovery remain in use with a narrow metadata-denial seam', async () => {
  const store = await read(storePath), harness = await read(harnessPath);
  const bootstrap = store.split('private func bootstrap() async')[1].split('private func pendingSaveJournal()')[0];
  assert.match(bootstrap, /defer \{ isBootstrapping = false; startupTrace\.record\(\.bootstrapEnd\) \}/);
  assert.match(bootstrap, /let journal = try pendingSaveJournal\(\)\s*let pending = try journal\.allPackages\(\)/);
  assert.match(bootstrap, /if let startupTestHarness \{ await startupTestHarness\.restoreAccount\(\) \}\s*else \{ await cloud\.restoreSession\(\) \}\s*#else\s*await cloud\.restoreSession\(\)/);
  assert.match(store, /#if DEBUG\s*try startupTestHarness\?\.beforeMetadataRead\(package\)\s*#endif\s*let value = try await repo\(\)\.load\(at:package\)/);
  assert.match(store, /try await repo\(\)\.saveRecovering\(record,at:package\)\s*guard try journal\.acknowledge\(record\)/);
  assert.match(harness, /NSFileReadNoPermissionError/);
  assert.doesNotMatch(harness, /func (bootstrap|recoverPendingSaves|load|saveRecovering|acknowledge)\(/);
  // Preserve source702's user-authorized picker/scene entry and default writes.
  assert.match(store, /try UIKitFileAccess\.shared\.rememberProject\(url\)/);
  assert.match(store, /if !verificationMode \{ UserDefaults\.standard\.set\(url\.path,forKey:"lastProjectURL"\)/);
});
test('native tests cover normal bootstrap failure, exact retention, replay, pending account and real contention', async () => {
  const native = await read(nativePath);
  for (const name of ['testNormalBootstrapPermissionFailureRetainsPendingRecordAndCanonicalBytes', 'testNormalBootstrapReplaysAcceptedDataThenAcknowledgesExactRecord', 'testAwaitingAccountDoesNotPreventSyntheticWindowBindingOrMainQueueHeartbeat', 'testRealPendingJournalContentionIsObservedWithoutChangingLockPolicy', 'testInjectionCannotReadAnOutsidePackageOrSymlinkTarget']) assert.ok(native.includes(`func ${name}`));
  assert.equal((native.match(/func test/g) ?? []).length, 5);
  assert.doesNotMatch(native, /XCTSkip|setenv\(|UserDefaults\.standard\.set|chmod\(|kill\(/);
  assert.match(native, /XCTAssertFalse\(stages\.contains\(\.verificationBootstrapSkipped\)\)/);
  assert.match(native, /XCTAssertEqual\(try Data\(contentsOf: recordURL\), pendingBefore\)/);
  assert.match(native, /XCTAssertEqual\(try f\.journal\.load\(package: f\.package\), \[record\]\)/);
  assert.match(native, /window\.rootViewController = controller; window\.isHidden = false/);
  assert.match(native, /XCTAssertNotNil\(controller\.viewIfLoaded\?\.window\)/);
  assert.match(native, /\.pendingInventoryBegin \{ observation\.began\(\) \}/);
  assert.match(native, /asyncAfter\(deadline: \.now\(\) \+ 5\).*release\(observed: false\)/);
  assert.match(native, /end\.elapsedMilliseconds - begin\.elapsedMilliseconds, 150/);
});
test('journal contention remains blocking, package contention remains nonblocking, and tests have a real separate descriptor', async () => {
  const journal = await read('apps/mac/Sources/ScrivCore/PendingProjectSaveJournal.swift');
  const repository = await read('apps/mac/Sources/ScrivCore/ProjectRepository.swift');
  const native = await read(nativePath);
  assert.match(journal, /while flock\(lock, LOCK_EX\) != 0 \{ if errno != EINTR \{ throw posixError\(\) \} \}/);
  assert.doesNotMatch(journal, /LOCK_NB|StartupTrace|startupTestHarness/);
  assert.match(repository, /LOCK_EX \| LOCK_NB/);
  assert.match(native, /descriptor = open\(root\.appendingPathComponent\("\.journal-lock"\)/);
  assert.match(native, /flock\(descriptor, LOCK_EX \| LOCK_NB\)/);
  assert.match(native, /flock\(descriptor, LOCK_UN\); close\(descriptor\)/);
});
test('native trace tests assert serialized privacy, disabled sink, hard cap and one-shot probes', async () => {
  const native = await read('apps/mac/Tests/ScrivCoreTests/StartupTraceTests.swift');
  assert.equal((native.match(/func test/g) ?? []).length, 4);
  for (const token of ['JSONEncoder().encode(event)', 'XCTAssertFalse(text.contains("PRIVATE"))', 'XCTAssertTrue(captured.events.isEmpty)', 'DispatchQueue.concurrentPerform(iterations: 600)', 'XCTAssertEqual(captured.events.count, 256)', '[.heartbeatScheduled, .heartbeatFirst, .heartbeatSecond]']) assert.ok(native.includes(token));
});

test('integration retains verification-only autoplay and current-main recovery history optimization', async () => {
  const store = await read(storePath);
  const bootstrap = store.split('private func bootstrap() async')[1].split('private func pendingSaveJournal()')[0];
  const isolated = bootstrap.split('if skipStartupRecovery {')[1].split('// Account identity is restored')[0];
  assert.ok(isolated.includes('startupTrace.record(.verificationBootstrapSkipped)'));
  assert.ok(isolated.includes('environment["SCRIV_VERIFICATION_AUTOPLAY"] == "1"'));
  assert.ok(isolated.includes('while !Task.isCancelled'));
  assert.match(isolated, /return\s*\}\s*$/);
  assert.equal((store.match(/SCRIV_VERIFICATION_AUTOPLAY/g) ?? []).length, 1);
  assert.match(store, /if startupTestHarness != nil \{ return false \}/);
  const recovery = store.split('private func recoverPendingSaves(at package:')[1].split('func flushPendingSaves')[0];
  assert.match(recovery, /records\.contains \{ \$0\.after\.revision <= saved\.revision \}/);
  assert.match(recovery, /let accepted = needsHistory \? try await repo\(\)\.history\(at:package\)\.map\(\\\.snapshot\) : \[\]/);
  assert.match(recovery, /canonical = try await loadProjectForOpening\(at:package\)/);
});

test('startup lifecycle marker does not replace current-main adaptive panel layout', async () => {
  const controller = await read('apps/catalyst/ScrivUIKit/App/ScrivWorkspaceController.swift');
  assert.match(controller, /private final class LayoutReportingView: UIView/);
  assert.match(controller, /contentContainer\.onLayout = \{ \[weak self\] in self\?\.updatePanelLayout\(\) \}/);
  assert.match(controller, /if statusLabel\.text != status \{ statusLabel\.text = status \}/);
  assert.match(controller, /super\.viewDidAppear\(animated\)\s*StartupTrace\.process\.record\(\.rootViewAppeared\)/);
});
