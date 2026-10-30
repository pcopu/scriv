import XCTest
@testable import ScrivCore

/// Supporting-sheet actions must preserve the source-owned scene underneath.
final class ImageInspectorInvariantTests: XCTestCase {
    func testChoosingHistoricalVersionChangesOnlyTheTargetPlacement() throws {
        var project = fixture()
        let original = project
        try ProjectEditing.setCueImage(&project, cueId: "foreground", imageId: "v1")
        XCTAssertEqual(project.cues.first { $0.id == "foreground" }?.imageId, "v1")
        XCTAssertEqual(project.cues.first { $0.id == "background" }, original.cues.first { $0.id == "background" })
        XCTAssertEqual(project.entries, original.entries)
        XCTAssertEqual(project.images, original.images)
        XCTAssertEqual(project.characters, original.characters)
        XCTAssertEqual(project.audioAssets, original.audioAssets)
        XCTAssertEqual(project.audioClips, original.audioClips)
        for cue in project.cues {
            let previous = try XCTUnwrap(original.cues.first { $0.id == cue.id })
            XCTAssertEqual(cue.startAnchor, previous.startAnchor)
            XCTAssertEqual(cue.authoredDurationMs, previous.authoredDurationMs)
            XCTAssertEqual(cue.startMs, previous.startMs)
            XCTAssertEqual(cue.endMs, previous.endMs)
            XCTAssertEqual(cue.prompt, previous.prompt)
        }
    }

    func testVersionGalleryKeepsExactCapturedAndManualPromptsSeparate() {
        let project = fixture()
        let versions = ProjectEditing.imageVersions(in: project, imageId: "v1")
        XCTAssertEqual(versions.map(\.id), ["v2", "v1"])
        XCTAssertEqual(versions.map(\.version), [2, 1])
        XCTAssertEqual(versions[1].prompt, "Manual direction one")
        XCTAssertEqual(versions[1].generationPrompt, "Exact submitted prompt one\nSource at generation time.")
        XCTAssertEqual(versions[0].prompt, "Manual direction two")
        XCTAssertNil(versions[0].generationPrompt)
        XCTAssertEqual(versions[0].previousVersionId, "v1")
    }

    func testSelectingAVersionDoesNotChangeLatestStartPlaybackOrOverlap() throws {
        var project = fixture()
        try ProjectEditing.setCueImage(&project, cueId: "background", imageId: "v2")
        XCTAssertEqual(project.activeCue(at: 500, sceneId: "scene")?.id, "background")
        XCTAssertEqual(project.activeCue(at: 1500, sceneId: "scene")?.id, "foreground")
        XCTAssertEqual(project.activeCue(at: 2500, sceneId: "scene")?.id, "background")
        XCTAssertEqual(project.cues.count, 2)
        XCTAssertEqual(project.cues.map(\.authoredDurationMs), [3000, 1000])
    }

    private func fixture() -> ScrivProject {
        ScrivProject(scenes: [ScriptScene(id: "scene")], entries: [
            ScriptEntry(id: "a", sceneId: "scene", order: 0, text: "First source", ownedDurationMs: 1000),
            ScriptEntry(id: "b", sceneId: "scene", order: 1, text: "Second source", ownedDurationMs: 2000)
        ], images: [
            ImageAsset(id: "v1", version: 1, fileName: "one.png", sha256: String(repeating: "a", count: 64), byteCount: 1, prompt: "Manual direction one", generationPrompt: "Exact submitted prompt one\nSource at generation time."),
            ImageAsset(id: "v2", version: 2, fileName: "two.png", sha256: String(repeating: "b", count: 64), byteCount: 1, prompt: "Manual direction two", previousVersionId: "v1")
        ], cues: [
            ImageCue(id: "background", sceneId: "scene", imageId: "v1", label: "Background", startMs: 0, endMs: 3000, prompt: "Current cue direction", startAnchor: ScriptTimeAnchor(entryId: "a", offsetMs: 0), authoredDurationMs: 3000),
            ImageCue(id: "foreground", sceneId: "scene", imageId: "v2", label: "Foreground", startMs: 1000, endMs: 2000, startAnchor: ScriptTimeAnchor(entryId: "b", offsetMs: 0), authoredDurationMs: 1000)
        ])
    }
}
