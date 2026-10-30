import Foundation
import XCTest
import ScrivCore
@testable import ScrivUIKit

final class ImageInteractionPolicyTests: XCTestCase {
    private var cue: ImageCue { ImageCue(id: "picture", sceneId: "scene", imageId: "version", startMs: 1000, endMs: 4800, startAnchor: ScriptTimeAnchor(entryId: "source", offsetMs: 0), authoredDurationMs: 3800) }
    func testVerticalUpAddsAndDownRemovesFromAuthoredDuration() {
        var draft = ImageDurationScrubDraft(cue: cue, navigationContext: 4)
        draft.update(translationY: -50); XCTAssertEqual(draft.proposedDurationMs, 4800)
        draft.update(translationY: 50); XCTAssertEqual(draft.proposedDurationMs, 2800)
        XCTAssertEqual(draft.original, cue); XCTAssertEqual(draft.original.startAnchor?.entryId, "source")
    }
    func testScrubUsesAuthoredDurationNotSceneClippedProjection() {
        var source = cue; source.endMs = 1800; source.authoredDurationMs = 9000
        var draft = ImageDurationScrubDraft(cue: source, navigationContext: 1); draft.update(translationY: -10)
        XCTAssertEqual(draft.proposedDurationMs, 9200); XCTAssertEqual(draft.original.durationMs, 800)
    }
    func testScrubClampsSafelyAtCoreBoundsAndIgnoresInvalidPointerSamples() {
        var draft = ImageDurationScrubDraft(cue: cue, navigationContext: 4)
        draft.update(translationY: .greatestFiniteMagnitude); XCTAssertEqual(draft.proposedDurationMs, 1)
        draft.update(translationY: -.greatestFiniteMagnitude); XCTAssertEqual(draft.proposedDurationMs, 86_400_000)
        draft.update(translationY: .nan); XCTAssertEqual(draft.proposedDurationMs, 86_400_000)
        draft.update(translationY: .infinity); XCTAssertEqual(draft.proposedDurationMs, 86_400_000)
    }
    func testOneEndCommitAndNoFurtherPointerWrites() {
        var draft = ImageDurationScrubDraft(cue: cue, navigationContext: 4)
        for point in [-1.0, -10, -20, -30] { draft.update(translationY: point); XCTAssertFalse(draft.finished) }
        XCTAssertEqual(draft.finish(currentCue: cue, navigation: 4, sceneID: "scene"), 4400)
        XCTAssertNil(draft.finish(currentCue: cue, navigation: 4, sceneID: "scene"))
        draft.update(translationY: -100); XCTAssertEqual(draft.proposedDurationMs, 4400)
    }
    func testCancelAndUnchangedClickNeverCommit() {
        var draft = ImageDurationScrubDraft(cue: cue, navigationContext: 4); draft.update(translationY: -100); draft.cancel()
        XCTAssertNil(draft.finish(currentCue: cue, navigation: 4, sceneID: "scene"))
        draft = ImageDurationScrubDraft(cue: cue, navigationContext: 4)
        XCTAssertNil(draft.finish(currentCue: cue, navigation: 4, sceneID: "scene"))
    }
    func testNewProjectSceneOrSourceRejectsDragWithoutMutation() {
        var changed = cue; changed.startAnchor?.offsetMs = 1
        for (current, navigation, scene) in [(Optional(cue), 5, "scene"), (Optional(cue), 4, "other"), (Optional(changed), 4, "scene"), (nil, 4, "scene")] {
            var draft = ImageDurationScrubDraft(cue: cue, navigationContext: 4); draft.update(translationY: -25)
            XCTAssertNil(draft.finish(currentCue: current, navigation: navigation, sceneID: scene)); XCTAssertEqual(draft.original, cue)
        }
    }
    func testProjectRevisionFenceRejectsDurationDragAfterAnotherEdit() {
        var draft = ImageDurationScrubDraft(cue: cue, navigationContext: 4, projectRevision: 10); draft.update(translationY: -25)
        XCTAssertNil(draft.finish(currentCue: cue, navigation: 4, sceneID: "scene", projectRevision: 11))
        draft = ImageDurationScrubDraft(cue: cue, navigationContext: 4, projectRevision: 10); draft.update(translationY: -25)
        XCTAssertEqual(draft.finish(currentCue: cue, navigation: 4, sceneID: "scene", projectRevision: 10), 4300)
    }
    func testDurationCommitPreservesAnchorOverlapWordsImagesAndAudio() throws {
        var project = ScrivProject(scenes: [ScriptScene(id: "scene")], entries: [ScriptEntry(id: "source", sceneId: "scene", order: 0, text: "One two three", ownedDurationMs: 5000)], cues: [ImageCue(id: "picture", sceneId: "scene", startMs: 0, endMs: 3800, startAnchor: ScriptTimeAnchor(entryId: "source", offsetMs: 0), authoredDurationMs: 3800), ImageCue(id: "overlap", sceneId: "scene", startMs: 1000, endMs: 2500, startAnchor: ScriptTimeAnchor(entryId: "source", offsetMs: 1000), authoredDurationMs: 1500)])
        let before = project; var draft = ImageDurationScrubDraft(cue: project.cues[0], navigationContext: 4); draft.update(translationY: -100)
        let value = try XCTUnwrap(draft.finish(currentCue: project.cues[0], navigation: 4, sceneID: "scene"))
        try TimingEngine.setCueDuration(&project, cueId: "picture", durationMs: value)
        XCTAssertEqual(project.cues[0].authoredDurationMs, 5800); XCTAssertEqual(project.cues[0].endMs, 5000)
        XCTAssertEqual(project.cues[0].startAnchor, before.cues[0].startAnchor); XCTAssertEqual(project.cues[1], before.cues[1]); XCTAssertEqual(project.entries, before.entries); XCTAssertEqual(project.images, before.images); XCTAssertEqual(project.audioClips, before.audioClips)
        XCTAssertEqual(project.activeCue(at: 1500, sceneId: "scene")?.id, "overlap")
    }
    func testWordDropRequiresOriginalProjectRevisionSceneAndDestination() {
        var project = ScrivProject(id: "project", scenes: [ScriptScene(id: "scene")], cues: [cue])
        let payload = StoryboardWordTransfer(projectID: "project", sceneID: "scene", navigation: 4, revision: project.revision, cueID: cue.id, wordIDs: ["word"])
        XCTAssertTrue(payload.canApply(to: project, navigation: 4, destination: cue))
        XCTAssertFalse(payload.canApply(to: project, navigation: 5, destination: cue))
        project.revision += 1; XCTAssertFalse(payload.canApply(to: project, navigation: 4, destination: cue))
        project.revision -= 1; project.id = "another"; XCTAssertFalse(payload.canApply(to: project, navigation: 4, destination: cue))
        project.id = "project"; var moved = cue; moved.startMs += 1; XCTAssertFalse(payload.canApply(to: project, navigation: 4, destination: moved))
    }
    func testWordTransferDoesNotExportSourceTextOrPrompt() throws {
        let payload = StoryboardWordTransfer(projectID: "project", sceneID: "scene", navigation: 4, revision: 1, cueID: "picture", wordIDs: ["word"])
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        XCTAssertFalse(json.contains("prompt")); XCTAssertFalse(json.contains("text")); XCTAssertEqual(try JSONDecoder().decode(StoryboardWordTransfer.self, from: Data(json.utf8)).wordIDs, ["word"])
    }
}
