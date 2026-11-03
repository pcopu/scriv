import XCTest
import UIKit
import ScrivCore
@testable import ScrivUIKit

/// Synthetic controller/control tests only. Native UIKit execution is required;
/// source checks do not establish a measured performance improvement.
@MainActor final class CharacterReviewLayoutLifetimeTests: XCTestCase {
    func testRepeatedProjectRefreshKeepsOneSaveHeightConstraint() async throws {
        try await withFixture { store, controller in
            let save = try saveButton(in: controller)
            let height = try XCTUnwrap(saveHeightConstraints(save).first)
            XCTAssertEqual(saveHeightConstraints(save).count, 1)
            for index in 0..<30 {
                store.project.title = "Synthetic refresh \(index)"
                let expected = store.project
                controller.storeDidChange()
                let current = try saveButton(in: controller)
                XCTAssertTrue(current === save, "Rendering must retain the real action control")
                let constraints = saveHeightConstraints(current)
                XCTAssertEqual(constraints.count, 1, "Refresh \(index) must not append a layout rule")
                XCTAssertTrue(constraints.first === height)
                XCTAssertEqual(store.project, expected, "Rendering must not alter tags or project data")
            }
        }
    }

    func testRepeatedCandidateSwitchAndSkipPreserveConstraintAndProject() async throws {
        try await withFixture { store, controller in
            let original = store.project, save = try saveButton(in: controller)
            let height = try XCTUnwrap(saveHeightConstraints(save).first)
            for index in 0..<20 {
                let candidates = descendants(controller.view).compactMap { $0 as? UIButton }
                    .filter { $0.accessibilityLabel == "Review unknown character" }
                XCTAssertEqual(candidates.count, 2)
                try XCTUnwrap(candidates.indices.contains(index % 2) ? candidates[index % 2] : nil)
                    .sendActions(for: .touchUpInside)
                XCTAssertTrue(try saveButton(in: controller) === save)
                XCTAssertEqual(saveHeightConstraints(save).count, 1)
                XCTAssertTrue(saveHeightConstraints(save).first === height)
                XCTAssertEqual(store.project, original)
            }
            for _ in 0..<2 {
                let skip = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }
                    .first { $0.configuration?.title == "Skip for now" })
                skip.sendActions(for: .touchUpInside)
                XCTAssertEqual(saveHeightConstraints(save).count, 1)
            }
            XCTAssertFalse(descendants(controller.view).contains { $0 === save }, "Nothing remains to review in this sheet")
            XCTAssertEqual(store.project, original, "Skipping does not save tags or consume candidates")
            let reopened = CharacterImageReviewController(store: store); reopened.loadViewIfNeeded()
            let reopenedSave = try saveButton(in: reopened)
            XCTAssertFalse(reopenedSave === save)
            XCTAssertEqual(saveHeightConstraints(reopenedSave).count, 1)
            XCTAssertEqual(store.characterAnalysis.reviewItems.count, 2)
            XCTAssertEqual(store.project, original)
        }
    }

    private func withFixture(_ check: (WorkspaceStore, CharacterImageReviewController) throws -> Void) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else {
            throw XCTSkip("Requires isolated verification storage; never construct a live user workspace.")
        }
        let store = WorkspaceStore()
        let scratch = try XCTUnwrap(store.projectURL).deletingLastPathComponent().deletingLastPathComponent()
        defer {
            if ProcessInfo.processInfo.environment["SCRIV_VERIFICATION_ROOT"] == nil,
               scratch.lastPathComponent.hasPrefix("ScrivVerification-"),
               scratch.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL {
                try? FileManager.default.removeItem(at: scratch)
            }
        }
        for _ in 0..<500 where store.isBootstrapping { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBootstrapping)
        guard !store.isBootstrapping else { return }
        let image = ImageAsset(id: "review-image", fileName: "absent-synthetic.png", sha256: String(repeating: "a", count: 64), byteCount: 1)
        var project = ScrivProject(id: "review-layout-fixture", title: "Synthetic review",
            characters: [ScriptCharacter(id: "mara", name: "Mara")], images: [image])
        try CharacterImageAnalysis.apply(.init(detections: [
            .init(region: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.3), kind: .obscured, confidence: 0.4, reason: "Synthetic first candidate"),
            .init(region: .init(x: 0.6, y: 0.1, width: 0.2, height: 0.3), kind: .obscured, confidence: 0.4, reason: "Synthetic second candidate")
        ]), to: &project, imageID: image.id, version: image.version, sha256: image.sha256, providerID: "synthetic-layout-test")
        store.project = project
        let controller = CharacterImageReviewController(store: store); controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 760, height: 930)
        XCTAssertEqual(store.characterAnalysis.reviewItems.count, 2)
        try check(store, controller)
    }

    private func saveButton(in controller: UIViewController) throws -> UIButton {
        try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "character-review-save" })
    }
    private func saveHeightConstraints(_ save: UIButton) -> [NSLayoutConstraint] {
        save.constraints.filter {
            $0.isActive && ($0.firstItem as? UIView) === save && $0.firstAttribute == .height &&
            $0.relation == .greaterThanOrEqual && $0.secondItem == nil && $0.constant == 44
        }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
