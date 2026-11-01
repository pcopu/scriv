import UIKit
import XCTest
@testable import ScrivUIKit

@MainActor
final class LocalSaveStatusTests: XCTestCase {
    func testUnavailableProjectStorageNeverReportsSaved() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated storage.") }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivSaveStatus-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let blocked = fixture.appendingPathComponent("blocked-root")
        try Data("owned test blocker".utf8).write(to: blocked)
        let prior = ProcessInfo.processInfo.environment["SCRIV_VERIFICATION_ROOT"]
        setenv("SCRIV_VERIFICATION_ROOT", blocked.path, 1)
        defer { if let prior { setenv("SCRIV_VERIFICATION_ROOT", prior, 1) } else { unsetenv("SCRIV_VERIFICATION_ROOT") } }
        let store = WorkspaceStore()
        let controller = ScriptScreenController(store: store)
        controller.loadViewIfNeeded(); controller.storeDidChange()
        let statuses = imageLabels(in: controller.view)
        XCTAssertFalse(statuses.contains("Saved on this Mac"))
        XCTAssertTrue(statuses.contains("Local storage unavailable"))
    }

    func testPromptJournalFailureRemainsVisibleThroughProjectSaveAndClearsAfterRecovery() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated storage.") }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivSaveStatus-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let blocked = fixture.appendingPathComponent("CuePromptDrafts")
        try Data("owned test blocker".utf8).write(to: blocked)
        let prior = ProcessInfo.processInfo.environment["SCRIV_VERIFICATION_ROOT"]
        setenv("SCRIV_VERIFICATION_ROOT", fixture.path, 1)
        defer { if let prior { setenv("SCRIV_VERIFICATION_ROOT", prior, 1) } else { unsetenv("SCRIV_VERIFICATION_ROOT") } }
        let store = WorkspaceStore()
        let cue = try XCTUnwrap(store.project.cues.first)
        store.selectedCueID = cue.id
        store.prepareGenerationPrompt()
        XCTAssertNotNil(store.generationPromptIssue)
        store.saveProject()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, store.statusMessage != "Saving…" { await Task.yield() }
        await store.flushPendingSaves()
        let controller = ScriptScreenController(store: store)
        controller.loadViewIfNeeded(); controller.storeDidChange()
        XCTAssertFalse(imageLabels(in: controller.view).contains("Saved on this Mac"))
        XCTAssertTrue(imageLabels(in: controller.view).contains("Direction recovery needs attention"))
        // Remove only this fixture's blocker and verify successful journal access
        // clears the warning. No pending record or user package is deleted.
        try FileManager.default.removeItem(at: blocked)
        store.retryGenerationPrompt(); controller.storeDidChange()
        XCTAssertNil(store.generationPromptIssue)
        XCTAssertTrue(imageLabels(in: controller.view).contains("Saved on this Mac"))
    }

    private func imageLabels(in root: UIView) -> [String] {
        var pending = [root], labels: [String] = []
        while let view = pending.popLast() {
            if let image = view as? UIImageView, let label = image.accessibilityLabel { labels.append(label) }
            pending.append(contentsOf: view.subviews)
        }
        return labels
    }
}
