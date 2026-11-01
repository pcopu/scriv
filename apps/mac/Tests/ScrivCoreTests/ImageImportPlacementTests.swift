import XCTest
@testable import ScrivCore

final class ImageImportPlacementTests: XCTestCase {
    private func fixture() -> ScrivProject {
        ScrivProject(scenes: [ScriptScene(id: "s")], entries: [
            ScriptEntry(id: "direction", sceneId: "s", order: 0, kind: .direction, text: "A gate opens.", ownedDurationMs: 1500, coverageDurationMs: 8500),
            ScriptEntry(id: "dialogue", sceneId: "s", order: 1, text: "Every word stays intact.", ownedDurationMs: 7000)
        ], images: [ImageAsset(id: "old", fileName: "old.png", sha256: String(repeating: "a", count: 64), byteCount: 1)],
        cues: [ImageCue(id: "later", sceneId: "s", imageId: "old", label: "Existing picture", startMs: 1500, endMs: 8500, startAnchor: ScriptTimeAnchor(entryId: "dialogue", offsetMs: 0), authoredDurationMs: 15300)])
    }
    private func addAsset(_ project: inout ScrivProject) {
        project.images.append(ImageAsset(id: "imported", fileName: "new.png", sha256: String(repeating: "b", count: 64), byteCount: 2))
    }
    func testFirstLineImportCreatesPlacementWithoutChangingLaterImageTimingOrWords() throws {
        var project = fixture(); let before = project
        let target = try ImageImportPlacement(project: project, cueID: nil, sceneID: "s", entryID: "direction", atMs: 0, newCueID: "first")
        addAsset(&project); try target.attach(imageID: "imported", to: &project)
        XCTAssertEqual(project.activeCue(at: 0, sceneId: "s")?.imageId, "imported")
        XCTAssertEqual(project.activeCue(at: 1500, sceneId: "s")?.imageId, "old")
        XCTAssertEqual(project.activeCue(at: 0, sceneId: "s")?.imageId, "imported", "Line 1 → line 2 → line 1 keeps the imported picture")
        XCTAssertEqual(project.cues.first, before.cues.first)
        XCTAssertEqual(project.entries, before.entries)
        XCTAssertEqual(project.cues.last?.startAnchor?.entryId, "direction")
        XCTAssertEqual(project.cues.last?.endMs, 1500)
        XCTAssertEqual(project.images.first, before.images.first)
    }
    func testExplicitReplacementTargetsExactCueAndRejectsDelayedChangedTarget() throws {
        var project = fixture()
        let target = try ImageImportPlacement(project: project, cueID: "later", sceneID: "s", entryID: "direction", atMs: 0)
        addAsset(&project); try target.attach(imageID: "imported", to: &project)
        XCTAssertEqual(project.cues.count, 1); XCTAssertEqual(project.cues[0].imageId, "imported")
        XCTAssertEqual(project.cues[0].startMs, 1500); XCTAssertEqual(project.cues[0].authoredDurationMs, 15300)
        XCTAssertFalse(target.isCurrent(in: project))
        XCTAssertThrowsError(try target.attach(imageID: "old", to: &project))
        XCTAssertEqual(project.cues[0].imageId, "imported")
    }
    func testCapturedSourceRejectsRemovalRetimingAndProjectChange() throws {
        let original = fixture()
        let target = try ImageImportPlacement(project: original, cueID: nil, sceneID: "s", entryID: "direction", atMs: 0)
        var next = original; next.entries[0].ownedDurationMs = 1600
        XCTAssertFalse(target.isCurrent(in: next))
        next = original; next.entries.removeFirst(); XCTAssertFalse(target.isCurrent(in: next))
        next = original; next.id = "another-project"; XCTAssertFalse(target.isCurrent(in: next))
        next = original; next.cues.append(ImageCue(id: "newer", sceneId: "s", startMs: 0, endMs: 1000))
        XCTAssertFalse(target.isCurrent(in: next), "A delayed import must not silently create an overlap after another placement was added")
    }
    func testZeroOwnedDirectionGetsItsOwnAnchorWithoutChangingSharedStartPictures() throws {
        var project = fixture(); try TimingEngine.setOwnedDuration(&project, entryId: "direction", durationMs: 0)
        let existing = project.cues
        let target = try ImageImportPlacement(project: project, cueID: nil, sceneID: "s", entryID: "direction", atMs: 0, newCueID: "direction-picture")
        addAsset(&project); try target.attach(imageID: "imported", to: &project)
        XCTAssertEqual(project.cues.filter { $0.id != "direction-picture" }, existing)
        XCTAssertEqual(project.cues.last?.startAnchor, ScriptTimeAnchor(entryId: "direction", offsetMs: 0))
        XCTAssertEqual(project.cues.last?.imageId, "imported")
        try TimingEngine.validate(project)
    }
    func testSaveReopenAndHistoryPreserveExactFirstLinePlacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root)
        var project = fixture(); let original = project
        let package = await repo.defaultURL(for: project)
        try await repo.save(project, at: package, label: "Before import")
        let target = try ImageImportPlacement(project: project, cueID: nil, sceneID: "s", entryID: "direction", atMs: 0)
        addAsset(&project); try target.attach(imageID: "imported", to: &project); project.revision += 1
        try await repo.save(project, at: package, label: "Attach image")
        let reopened = try await repo.load(at: package), history = try await repo.history(at: package)
        XCTAssertEqual(reopened, project); XCTAssertEqual(reopened.activeCue(at: 0, sceneId: "s")?.imageId, "imported")
        XCTAssertEqual(history.last?.snapshot, original); XCTAssertEqual(history.first?.snapshot, project)
        // Undo/redo snapshots restore exact identities, not inferred successors.
        var restored = history.last!.snapshot; XCTAssertNil(restored.activeCue(at: 0, sceneId: "s"))
        restored = history.first!.snapshot; XCTAssertEqual(restored.activeCue(at: 0, sceneId: "s")?.imageId, "imported")
    }
}
