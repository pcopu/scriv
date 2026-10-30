import XCTest
import ScrivCore
@testable import ScrivUIKit

@MainActor
final class WorkspaceDurabilityTests: XCTestCase {
    private func isolatedStore() async throws -> WorkspaceStore {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires the isolated verification launch argument; never mutate a user's workspace in tests.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        return store
    }
    func testAcceptedEditIsJournaledBeforeAsynchronousPackageSave() async throws {
        let store = try await isolatedStore(), before = store.project
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at:package.deletingLastPathComponent().deletingLastPathComponent()) }
        store.setProjectTitle("Durable accepted title")
        XCTAssertEqual(store.project.title,"Durable accepted title")
        let journal = try PendingProjectSaveJournal(root:package.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PendingProjectSaves"))
        let records = try journal.load(package:package)
        XCTAssertEqual(records.last?.before,before)
        XCTAssertEqual(records.last?.after,store.project)
        await store.flushPendingSaves()
        XCTAssertTrue(try journal.load(package:package).isEmpty)
        let repository = try ProjectRepository(root:package.deletingLastPathComponent())
        let canonical = try await repository.load(at:package)
        XCTAssertEqual(canonical,store.project)
    }
    func testStorageFailureDoesNotAcceptMutationOrUndoEntry() async throws {
        let store = try await isolatedStore(), before = store.project
        let package = try XCTUnwrap(store.projectURL), root = package.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        try Data("not a directory".utf8).write(to:root.appendingPathComponent("PendingProjectSaves"))
        store.setProjectTitle("Must not be accepted")
        XCTAssertEqual(store.project,before)
        XCTAssertFalse(store.canUndo)
        XCTAssertNotNil(store.errorMessage)
    }
    func testNewProjectIsRecoverableBeforeItsFirstPackageWrite() async throws {
        let store = try await isolatedStore()
        store.newProject()
        let package = try XCTUnwrap(store.projectURL), root = package.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = try PendingProjectSaveJournal(root:root.appendingPathComponent("PendingProjectSaves"))
        let records = try journal.load(package:package)
        XCTAssertEqual(records.count,1); XCTAssertNil(records.first?.before)
        XCTAssertEqual(records.first?.after,store.project)
        XCTAssertTrue(try journal.allPackages().contains(package))
        await store.flushPendingSaves()
    }
    func testZoomIsAUserPreferenceNotProjectContent() async throws {
        let store = try await isolatedStore(), before = store.project
        let original = store.scriptZoom
        defer { store.setScriptZoom(original) }
        store.setScriptZoom(1.3)
        XCTAssertEqual(store.scriptFontSize,18.2,accuracy:0.001)
        XCTAssertEqual(store.project,before)
        store.setScriptZoom(.infinity); XCTAssertEqual(store.scriptZoom,1.3)
        store.setScriptZoom(100); XCTAssertEqual(store.scriptZoom,2)
        store.setScriptZoom(0); XCTAssertEqual(store.scriptZoom,0.7)
    }
}
