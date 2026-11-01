import UIKit
import XCTest
import ScrivCore
@testable import ScrivUIKit

@MainActor final class EditorRepairTests: XCTestCase {
    func testDigestMismatchNeverDisplaysAnotherImageAndSameURLCanRecover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let red = try imageData(.red), blue = try imageData(.blue), url = root.appendingPathComponent("picture.png")
        try red.write(to: url)
        let picture = UIKitAssetImageView()
        picture.configure(url: url, title: "Exact blue version", expectedDigest: ScrivDigest.sha256(blue))
        try await waitForLoad(picture)
        XCTAssertEqual(picture.loadPhase, .failed); XCTAssertNil(picture.loadedDigest)
        try blue.write(to: url)
        picture.configure(url: url, title: "Exact blue version", expectedDigest: ScrivDigest.sha256(blue))
        try await waitForLoad(picture)
        XCTAssertEqual(picture.loadPhase, .loaded); XCTAssertEqual(picture.loadedDigest, ScrivDigest.sha256(blue))
        picture.configure(url: url, title: "Wrong version", expectedDigest: ScrivDigest.sha256(red))
        try await waitForLoad(picture)
        XCTAssertEqual(picture.loadPhase, .failed); XCTAssertNil(picture.loadedDigest)
    }
    func testDurationTickDoesNotInstallAnOpacityAnimation() {
        let button = UIButton(type: .custom); button.frame = CGRect(x: 0, y: 0, width: 90, height: 34)
        let feedback = DurationHoldFeedback(button: button)
        button.sendActions(for: .touchDown); feedback.lockIn()
        XCTAssertTrue(feedback.isLocked)
        for value in ["7.1s", "7.2s", "7.3s"] {
            DurationHoldFeedback.tick(button, title: value)
            XCTAssertEqual(button.title(for: .normal), value); XCTAssertEqual(button.titleLabel?.alpha, 1)
            XCTAssertTrue(button.titleLabel?.layer.animationKeys()?.isEmpty ?? true)
        }
        feedback.reset(); XCTAssertFalse(feedback.isLocked)
    }
    func testFirstLineImportNavigationUndoRedoAndReopenKeepExactBytes() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification mode; never construct a live user workspace.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivImportRegression-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root)
        var project = ScrivProject(scenes: [ScriptScene(id: "s")], entries: [
            ScriptEntry(id: "first", sceneId: "s", order: 0, kind: .direction, text: "The gate opens.", ownedDurationMs: 1500, coverageDurationMs: 8500),
            ScriptEntry(id: "second", sceneId: "s", order: 1, text: "The picture must remain.", ownedDurationMs: 7000)
        ])
        let package = await repo.defaultURL(for: project)
        let old = try await repo.importAsset(data: imageData(.red), at: package)
        project.images = [old]
        project.cues = [ImageCue(id: "later", sceneId: "s", imageId: old.id, startMs: 1500, endMs: 8500, startAnchor: .init(entryId: "second", offsetMs: 0), authoredDurationMs: 15300)]
        try await repo.save(project, at: package, label: "Fixture")
        store.openLocalProject(package)
        for _ in 0..<500 where store.project.id != project.id { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.project.id, project.id)
        store.selectEntry("first"); XCTAssertNil(store.selectedCueID)
        let beforePicker = store.project, inspectedBeforePicker = store.selectedCueID
        store.togglePlayback(); XCTAssertTrue(store.isPlaying)
        let captured = try store.prepareImageImport()
        XCTAssertFalse(store.isPlaying)
        XCTAssertEqual(captured.anchor?.entryId, "first")
        XCTAssertEqual(store.selectedCueID, inspectedBeforePicker)
        XCTAssertEqual(store.project, beforePicker, "Preparing/canceling a picker never creates or retargets an image")
        let chosenBytes = try imageData(.blue), chosen = root.appendingPathComponent("chosen.png")
        try chosenBytes.write(to: chosen)
        let imported = await store.importImage(from: chosen)
        XCTAssertTrue(imported)
        let placed = try XCTUnwrap(store.selectedCue), asset = try XCTUnwrap(store.project.asset(placed.imageId))
        XCTAssertEqual(asset.sha256, ScrivDigest.sha256(chosenBytes)); XCTAssertEqual(placed.startAnchor?.entryId, "first")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.assetURL(asset))), chosenBytes)
        store.selectEntry("second"); XCTAssertEqual(store.selectedCueID, "later")
        store.selectEntry("first"); XCTAssertEqual(store.selectedCue?.imageId, asset.id)
        XCTAssertEqual(store.project.cues.first(where: { $0.id == "later" }), project.cues[0])
        XCTAssertEqual(store.project.entries, project.entries)
        store.undo(); XCTAssertNil(store.project.activeCue(at: 0, sceneId: "s"))
        store.redo(); XCTAssertEqual(store.project.activeCue(at: 0, sceneId: "s")?.imageId, asset.id)
        await store.flushPendingSaves()
        let reopened = try await repo.load(at: package)
        XCTAssertEqual(reopened.activeCue(at: 0, sceneId: "s")?.imageId, asset.id)
        XCTAssertEqual(reopened.cues.first(where: { $0.id == "later" }), project.cues[0])
    }
    func testFindKeyboardPolicyIsNonRepeatingAndProtectsTextAndComposition() {
        XCTAssertEqual(ScrivKeyboardPolicy.action(characters: "f", ignoringModifiers: "f", modifiers: .command, editingText: false), .findInScript)
        XCTAssertNil(ScrivKeyboardPolicy.action(characters: "f", ignoringModifiers: "f", modifiers: .command, editingText: true))
        XCTAssertNil(ScrivKeyboardPolicy.action(characters: "f", ignoringModifiers: "f", modifiers: .command, editingText: false, markedText: true))
        var gate = ScrivKeyboardPressGate(); gate.began(keyCode: 9, action: .findInScript)
        XCTAssertTrue(gate.consume(.findInScript)); XCTAssertFalse(gate.consume(.findInScript))
        gate.began(keyCode: 9, action: .findInScript); XCTAssertFalse(gate.consume(.findInScript))
        gate.ended(keyCode: 9); gate.began(keyCode: 9, action: .findInScript); XCTAssertTrue(gate.consume(.findInScript))
    }
    func testFindHeldAcrossModalDismissalStaysDeclinedUntilFreshPress() {
        let declined = ScrivKeyboardPolicy.action(characters: "f", ignoringModifiers: "f", modifiers: .command, editingText: false, canFindScript: false)
        XCTAssertNil(declined)
        var gate = ScrivKeyboardPressGate(); gate.began(keyCode: 9, action: declined)
        let afterDismissal = ScrivKeyboardPolicy.action(characters: "f", ignoringModifiers: "f", modifiers: .command, editingText: false, canFindScript: true)
        XCTAssertEqual(afterDismissal, .findInScript)
        gate.began(keyCode: 9, action: afterDismissal)
        XCTAssertFalse(gate.consume(.findInScript))
        gate.ended(keyCode: 9); gate.began(keyCode: 9, action: afterDismissal)
        XCTAssertTrue(gate.consume(.findInScript))
    }
    private func imageData(_ color: UIColor) throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }.pngData())
    }
    private func waitForLoad(_ view: UIKitAssetImageView) async throws {
        for _ in 0..<100 where view.loadPhase == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(view.loadPhase, .loading)
    }
}
