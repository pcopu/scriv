import UIKit
import XCTest
import Darwin
import ScrivCore
@testable import ScrivUIKit

private final class StartupTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [StartupTrace.Event] = []
    func append(_ event: StartupTrace.Event) { lock.lock(); values.append(event); lock.unlock() }
    var events: [StartupTrace.Event] { lock.lock(); defer { lock.unlock() }; return values.sorted { $0.sequence < $1.sequence } }
}

/// Holds only a freshly generated fixture's actual journal lock. A utility-queue
/// failsafe, independent of the main actor, prevents a bad test from hanging it.
private final class StartupTestLockLease: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32
    private var armed = false
    private var normalRelease = false
    init(root: URL) throws {
        descriptor = open(root.appendingPathComponent(".journal-lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(descriptor); descriptor = -1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5) { [self] in release(observed: false) }
    }
    func releaseAfterInventoryStarts() {
        mutex.lock(); let shouldArm = !armed; armed = true; mutex.unlock()
        guard shouldArm else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [self] in release(observed: true) }
    }
    func release(observed: Bool = false) {
        mutex.lock(); defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        normalRelease = observed
        _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1
    }
    var releasedAfterObservation: Bool { mutex.lock(); defer { mutex.unlock() }; return normalRelease }
    deinit { release() }
}

private final class StartupInventoryObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: StartupTestLockLease?
    func install(_ value: StartupTestLockLease) { lock.lock(); lease = value; lock.unlock() }
    func began() { lock.lock(); let value = lease; lock.unlock(); value?.releaseAfterInventoryStarts() }
}

@MainActor
private final class StartupAccountGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

/// The XCTest host still uses --screenshots to avoid real credentials/services.
/// A DEBUG-only capability replaces storage/account restoration and explicitly
/// runs the real normal bootstrap, inventory, open and recovery implementation.
/// This is not a fresh-process sandbox bookmark or installed-app acceptance test.
@MainActor
final class WorkspaceStartupDiagnosticsTests: XCTestCase {
    private struct Fixture {
        let harness: WorkspaceStartupTestHarness
        let repository: ProjectRepository
        let package: URL
        let journal: PendingProjectSaveJournal
        let baseline: ScrivProject
    }
    private func fixture(trace: StartupTrace) async throws -> Fixture {
        // Failing the host profile is intentional: this suite must not silently
        // skip its recovery coverage or run against ordinary account storage.
        XCTAssertTrue(ProcessInfo.processInfo.arguments.contains("--screenshots"))
        let harness = try WorkspaceStartupTestHarness.make(trace: trace)
        addTeardownBlock { @MainActor in harness.discard() }
        let repository = try ProjectRepository(root: harness.root.appendingPathComponent("Projects"))
        let baseline = ScrivProject(id: "startup-fixture", title: "Synthetic startup", scenes: [ScriptScene(id: "scene-test")],
            entries: [ScriptEntry(id: "line-test", sceneId: "scene-test", order: 0, text: "Synthetic fixture words", ownedDurationMs: 2000)])
        let package = await repository.defaultURL(for: baseline)
        try await repository.save(baseline, at: package, label: "Synthetic baseline")
        let journal = try PendingProjectSaveJournal(root: harness.root.appendingPathComponent("PendingProjectSaves"))
        harness.defaults.set(package.path, forKey: "lastProjectURL")
        return Fixture(harness: harness, repository: repository, package: package, journal: journal, baseline: baseline)
    }
    private func pending(_ f: Fixture) throws -> PendingProjectSaveRecord {
        var changed = f.baseline; changed.title = "Synthetic accepted edit"; changed.revision += 1
        return try f.journal.persist(scope: PendingProjectSaveScope(packagePath: f.package.path, projectID: f.baseline.id),
                                     before: f.baseline, after: changed, label: "Synthetic accepted edit")
    }
    private func awaitBootstrap(_ store: WorkspaceStore) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 7
        while store.isBootstrapping && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBootstrapping, "Normal bootstrap must finish or fail closed within this synthetic test")
    }
    func testNormalBootstrapPermissionFailureRetainsPendingRecordAndCanonicalBytes() async throws {
        let events = StartupTestEvents(), trace = StartupTrace(enabled: true) { events.append($0) }
        let f = try await fixture(trace: trace), record = try pending(f)
        let canonicalBefore = try Data(contentsOf: f.package.appendingPathComponent("project.json"))
        let recordURL = f.journal.root.appendingPathComponent(record.id + ".json")
        let pendingBefore = try Data(contentsOf: recordURL)
        let standardLastProject = UserDefaults.standard.string(forKey: "lastProjectURL")
        f.harness.denyMetadataRead = true
        let store = try WorkspaceStore(startupTestHarness: f.harness)
        try await awaitBootstrap(store)
        let stages = events.events.map(\.stage)
        XCTAssertFalse(stages.contains(.verificationBootstrapSkipped))
        for stage in [StartupTrace.Stage.accountRestoreEnd, .pendingInventoryEnd, .pendingRecoveryBegin, .metadataReadFailed, .bootstrapFailed, .bootstrapEnd] { XCTAssertTrue(stages.contains(stage)) }
        let failure = try XCTUnwrap(events.events.first { $0.stage == .metadataReadFailed })
        XCTAssertEqual(failure.errorFamily, .cocoa); XCTAssertEqual(failure.errorCode, NSFileReadNoPermissionError)
        XCTAssertEqual(failure.underlyingFamily, .posix); XCTAssertEqual(failure.underlyingCode, 1)
        XCTAssertTrue(store.errorMessage?.contains("No pending changes were discarded") == true)
        XCTAssertEqual(try Data(contentsOf: recordURL), pendingBefore)
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent("project.json")), canonicalBefore)
        XCTAssertEqual(try f.journal.load(package: f.package), [record])
        XCTAssertEqual(UserDefaults.standard.string(forKey: "lastProjectURL"), standardLastProject)
    }
    func testNormalBootstrapReplaysAcceptedDataThenAcknowledgesExactRecord() async throws {
        let events = StartupTestEvents(), trace = StartupTrace(enabled: true) { events.append($0) }
        let f = try await fixture(trace: trace), record = try pending(f)
        let store = try WorkspaceStore(startupTestHarness: f.harness)
        try await awaitBootstrap(store)
        XCTAssertNil(store.errorMessage); XCTAssertEqual(store.project, record.after)
        let saved = try await f.repository.load(at: f.package)
        XCTAssertEqual(saved, record.after); XCTAssertTrue(try f.journal.load(package: f.package).isEmpty)
        let history = try await f.repository.history(at: f.package)
        XCTAssertEqual(history.map(\.revision), [record.after.revision, f.baseline.revision])
        XCTAssertFalse(events.events.contains { $0.stage == .verificationBootstrapSkipped || $0.stage == .bootstrapFailed })
        XCTAssertTrue(events.events.contains { $0.stage == .historyReadEnd })
    }
    func testAwaitingAccountDoesNotPreventSyntheticWindowBindingOrMainQueueHeartbeat() async throws {
        let events = StartupTestEvents(), trace = StartupTrace(enabled: true) { events.append($0) }
        let f = try await fixture(trace: trace), gate = StartupAccountGate()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        f.harness.restoreAccount = { await gate.wait() }
        let store = try WorkspaceStore(startupTestHarness: f.harness)
        let window = UIWindow(windowScene: scene), controller = ScrivWorkspaceController(store: store)
        window.rootViewController = controller; window.isHidden = false
        defer { gate.release(); window.isHidden = true; window.rootViewController = nil }
        trace.scheduleHeartbeats()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while (!gate.entered || !events.events.contains { $0.stage == .heartbeatSecond }) && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.entered); XCTAssertTrue(store.isBootstrapping)
        XCTAssertNotNil(controller.viewIfLoaded?.window); XCTAssertFalse(window.isHidden)
        XCTAssertTrue(events.events.contains { $0.stage == .accountRestoreBegin })
        XCTAssertFalse(events.events.contains { $0.stage == .accountRestoreEnd })
        XCTAssertTrue(events.events.contains { $0.stage == .heartbeatSecond })
        gate.release(); try await awaitBootstrap(store)
        XCTAssertEqual(store.project, f.baseline)
    }
    func testRealPendingJournalContentionIsObservedWithoutChangingLockPolicy() async throws {
        let events = StartupTestEvents(), observation = StartupInventoryObservation()
        let trace = StartupTrace(enabled: true) {
            events.append($0)
            if $0.stage == .pendingInventoryBegin { observation.began() }
        }
        let f = try await fixture(trace: trace)
        let lease = try StartupTestLockLease(root: f.journal.root); defer { lease.release() }
        observation.install(lease)
        // The real inventory call blocks on this independent descriptor, not a
        // fake sleep in bootstrap. Release is triggered by its begin marker.
        let canonicalBefore = try Data(contentsOf: f.package.appendingPathComponent("project.json"))
        let store = try WorkspaceStore(startupTestHarness: f.harness)
        trace.scheduleHeartbeats()
        try await awaitBootstrap(store)
        let begin = try XCTUnwrap(events.events.first { $0.stage == .pendingInventoryBegin })
        let end = try XCTUnwrap(events.events.first { $0.stage == .pendingInventoryEnd })
        XCTAssertTrue(lease.releasedAfterObservation, "The bounded failsafe must not substitute for the observed release")
        XCTAssertGreaterThanOrEqual(end.elapsedMilliseconds - begin.elapsedMilliseconds, 150)
        XCTAssertNil(store.errorMessage); XCTAssertEqual(store.project, f.baseline)
        XCTAssertEqual(try Data(contentsOf: f.package.appendingPathComponent("project.json")), canonicalBefore)
        XCTAssertTrue(try f.journal.allPackages().isEmpty)
    }
    func testInjectionCannotReadAnOutsidePackageOrSymlinkTarget() async throws {
        let f = try await fixture(trace: StartupTrace(enabled: false) { _ in })
        XCTAssertThrowsError(try f.harness.validatePackage(f.harness.root.appendingPathComponent("outside.scriv")))
        let link = f.harness.root.appendingPathComponent("Projects/alias.scriv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.package)
        XCTAssertThrowsError(try f.harness.validatePackage(link))
        // No outside URL is read; ordinary Foundation errors are not bypassed.
        XCTAssertNoThrow(try f.harness.validatePackage(f.package))
    }
}
