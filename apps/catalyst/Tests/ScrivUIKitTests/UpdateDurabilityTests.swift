import XCTest
import ScrivCore
@testable import ScrivUIKit

@MainActor
final class UpdateDurabilityTests: XCTestCase {
    private func isolatedStore() async throws -> WorkspaceStore {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification; never touch user projects.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        return store
    }
    func testUpdateFenceFlushesAcceptedEditsAndPreservesProjectBytes() async throws {
        let store = try await isolatedStore()
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent().deletingLastPathComponent()) }
        store.setProjectTitle("Update fixture — keep this work")
        try await store.prepareForApplicationUpdate()
        let bytes = try Data(contentsOf: package.appendingPathComponent("project.json"))
        try await store.prepareForApplicationUpdate()
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("project.json")), bytes)
        XCTAssertEqual(store.project.title, "Update fixture — keep this work")
    }
    func testUpdateFenceRefusesUnsavedDriftAndConflicts() async throws {
        let store = try await isolatedStore()
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent().deletingLastPathComponent()) }
        store.setProjectTitle("Canonical fixture"); await store.flushPendingSaves()
        let before = try Data(contentsOf: package.appendingPathComponent("project.json"))
        store.project.title = "Unaccepted in-memory test drift"
        do { try await store.prepareForApplicationUpdate(); XCTFail("Unsaved drift must block installation") } catch { }
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("project.json")), before)
        store.hasConflicts = true
        do { try await store.prepareForApplicationUpdate(); XCTFail("Unresolved conflicts must block installation") } catch { }
        XCTAssertEqual(store.project.title, "Unaccepted in-memory test drift")
    }
}
