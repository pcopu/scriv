import Foundation
import XCTest
import ScrivCore
@testable import ScrivUIKit

final class ImageTimelineDragTests: XCTestCase {
    func testBodyDragChangesOffsetNotOwnerCoverageOrProjectDuringPreview() throws {
        let project = fixture(), before = project
        var draft = try ImageTimelineDragDraft(project: project, cueID: "picture", mode: .offset, navigation: 7)
        draft.update(translationX: 20, pointsPerMillisecond: 0.04, snapping: false)
        XCTAssertEqual(draft.offsetMs, 500); XCTAssertEqual(draft.authoredDurationMs, 3800); XCTAssertEqual(draft.originalAnchor.entryId, "direction"); XCTAssertEqual(project, before)
        XCTAssertEqual(draft.finish(project: project, navigation: 7, sceneID: "scene"), .offset(entryID: "direction", milliseconds: 500))
        XCTAssertNil(draft.finish(project: project, navigation: 7, sceneID: "scene"))
    }
    func testOwnerBoundaryClampsWithoutSilentlyReparenting() throws {
        let project = fixture(); var draft = try ImageTimelineDragDraft(project: project, cueID: "picture", mode: .offset, navigation: 7)
        draft.update(translationX: 200, pointsPerMillisecond: 0.04, snapping: true)
        XCTAssertEqual(draft.offsetMs, 2199); XCTAssertTrue(draft.atOwnerBoundary); XCTAssertEqual(draft.source.id, "direction")
        draft.update(translationX: -200, pointsPerMillisecond: 0.04, snapping: true); XCTAssertEqual(draft.offsetMs, 0); XCTAssertTrue(draft.atOwnerBoundary)
    }
    func testZeroOwnedDirectionKeepsOffsetZeroButCoverageIsIndependent() throws {
        var project = fixture(); project.entries.insert(ScriptEntry(id: "note", sceneId: "scene", order: -1, kind: .direction, text: "Aside", ownedDurationMs: 0, coverageDurationMs: 1000), at: 0)
        project.cues[0].startAnchor = ScriptTimeAnchor(entryId: "note", offsetMs: 0)
        var draft = try ImageTimelineDragDraft(project: project, cueID: "picture", mode: .offset, navigation: 7); draft.update(translationX: 100, pointsPerMillisecond: 0.04, snapping: true)
        XCTAssertEqual(draft.offsetMs, 0); XCTAssertEqual(draft.source.id, "note"); XCTAssertNil(draft.finish(project: project, navigation: 7, sceneID: "scene"))
        draft = try ImageTimelineDragDraft(project: project, cueID: "picture", mode: .coverage, navigation: 7); draft.update(translationX: 40, pointsPerMillisecond: 0.04, snapping: false)
        XCTAssertEqual(draft.authoredDurationMs, 4800); XCTAssertEqual(draft.offsetMs, 0)
    }
    func testWordSnappingAndShiftBypassHaveExactDifferentResults() throws {
        var project = fixture(); project.entries[0] = ScriptEntry(id: "direction", sceneId: "scene", order: 0, text: "one two three", ownedDurationMs: 3000, words: [TimedWord(id: "one", text: "one", startMs: 0, endMs: 1000), TimedWord(id: "two", text: "two", startMs: 1000, endMs: 2000), TimedWord(id: "three", text: "three", startMs: 2000, endMs: 3000)])
        try CueAnchoring.resolve(&project, sceneId: "scene")
        var snapped = try ImageTimelineDragDraft(project: project, cueID: "picture", mode: .offset, navigation: 7)
        var free = snapped; snapped.update(translationX: 39, pointsPerMillisecond: 0.04, snapping: true); free.update(translationX: 39, pointsPerMillisecond: 0.04, snapping: false)
        XCTAssertEqual(snapped.offsetMs, 1000); XCTAssertEqual(free.offsetMs, 975)
    }
    func testRightEdgeKeepsAuthoredTailBeyondSceneInsteadOfClampingItAway() throws {
        let project = fixture(); var draft = try ImageTimelineDragDraft(project: project, cueID: "picture", mode: .coverage, navigation: 7)
        draft.update(translationX: 200, pointsPerMillisecond: 0.04, snapping: false)
        XCTAssertEqual(draft.authoredDurationMs, 8800); XCTAssertEqual(draft.previewEndMs, 5200); XCTAssertTrue(draft.hasClippedTail)
        XCTAssertEqual(draft.finish(project: project, navigation: 7, sceneID: "scene"), .coverage(milliseconds: 8800))
    }
    func testRenderedGeometryMatchesOffsetOwnerSlotAndVisibleVsAuthoredTail() throws {
        let project = fixture(); var draft = try ImageTimelineDragDraft(project: project, cueID: "picture", mode: .offset, navigation: 7)
        draft.update(translationX: 20, pointsPerMillisecond: 0.04, snapping: false)
        var geometry = draft.geometry(pointsPerMillisecond: 0.04)
        XCTAssertEqual(geometry.startX, 90); XCTAssertEqual(geometry.visibleWidth, 150); XCTAssertEqual(geometry.ownerStartX, 70); XCTAssertEqual(geometry.ownerWidth, 88)
        draft = try ImageTimelineDragDraft(project: project, cueID: "picture", mode: .coverage, navigation: 7); draft.update(translationX: 200, pointsPerMillisecond: 0.04, snapping: false)
        geometry = draft.geometry(pointsPerMillisecond: 0.04); XCTAssertEqual(geometry.visibleWidth, 206); XCTAssertEqual(geometry.authoredWidth, 350)
    }
    func testCancelRevisionSceneAndExactSourceFencesRejectCommit() throws {
        let project = fixture(); var draft = try ImageTimelineDragDraft(project: project, cueID: "picture", mode: .offset, navigation: 7); draft.update(translationX: 20, pointsPerMillisecond: 0.04, snapping: false)
        var cancelled = draft; cancelled.cancel(); XCTAssertNil(cancelled.finish(project: project, navigation: 7, sceneID: "scene"))
        var changed = project; changed.revision += 1; var attempt = draft; XCTAssertNil(attempt.finish(project: changed, navigation: 7, sceneID: "scene"))
        changed = project; changed.entries[0].text += " Changed"; attempt = draft; XCTAssertNil(attempt.finish(project: changed, navigation: 7, sceneID: "scene"))
        attempt = draft; XCTAssertNil(attempt.finish(project: project, navigation: 8, sceneID: "scene"))
        attempt = draft; XCTAssertNil(attempt.finish(project: project, navigation: 7, sceneID: "elsewhere"))
    }
    func testApplyingOffsetThroughCorePreservesOtherCuesWordsAndLatestStartPolicy() throws {
        var project = fixture(); let before = project
        var draft = try ImageTimelineDragDraft(project: project, cueID: "picture", mode: .offset, navigation: 7); draft.update(translationX: 20, pointsPerMillisecond: 0.04, snapping: false)
        guard case let .offset(entryID, ms) = draft.finish(project: project, navigation: 7, sceneID: "scene") else { return XCTFail("Expected one offset commit") }
        try TimingEngine.setCueAnchor(&project, cueId: "picture", entryId: entryID, offsetMs: ms)
        XCTAssertEqual(project.cues[0].startAnchor, ScriptTimeAnchor(entryId: "direction", offsetMs: 500)); XCTAssertEqual(project.cues[0].authoredDurationMs, 3800)
        XCTAssertEqual(project.cues[1], before.cues[1]); XCTAssertEqual(project.entries, before.entries); XCTAssertEqual(project.images, before.images); XCTAssertEqual(project.audioClips, before.audioClips)
        XCTAssertEqual(project.activeCue(at: 2400, sceneId: "scene")?.id, "foreground")
    }
    func testLegacyOwnerUsesExistingCoreMigrationRuleWithoutMutatingBeforeRelease() throws {
        var project = fixture(); project.cues[0].startAnchor = nil; project.cues[0].authoredDurationMs = nil; let before = project
        let draft = try ImageTimelineDragDraft(project: project, cueID: "picture", mode: .offset, navigation: 7)
        XCTAssertEqual(draft.originalAnchor, try CueAnchoring.anchor(atMs: 0, in: project, sceneId: "scene")); XCTAssertEqual(project, before)
    }
    func testInvalidSamplesAndCoverageBoundsAreSafe() throws {
        let project = fixture(); var draft = try ImageTimelineDragDraft(project: project, cueID: "picture", mode: .coverage, navigation: 7)
        draft.update(translationX: .greatestFiniteMagnitude, pointsPerMillisecond: 0.04, snapping: false); XCTAssertEqual(draft.authoredDurationMs, 86_400_000)
        draft.update(translationX: -.greatestFiniteMagnitude, pointsPerMillisecond: 0.04, snapping: false); XCTAssertEqual(draft.authoredDurationMs, 1)
        draft.update(translationX: .nan, pointsPerMillisecond: 0.04, snapping: false); XCTAssertEqual(draft.authoredDurationMs, 1)
        draft.update(translationX: 10, pointsPerMillisecond: 0, snapping: true); XCTAssertEqual(draft.authoredDurationMs, 1)
    }
    private func fixture() -> ScrivProject {
        ScrivProject(id: "project", scenes: [ScriptScene(id: "scene")], entries: [ScriptEntry(id: "direction", sceneId: "scene", order: 0, kind: .direction, text: "Mara opens a small blue gate.", ownedDurationMs: 2200, coverageDurationMs: 3800), ScriptEntry(id: "dialogue", sceneId: "scene", order: 1, text: "The test is ready.", ownedDurationMs: 3000)], cues: [ImageCue(id: "picture", sceneId: "scene", label: "01A", startMs: 0, endMs: 3800, startAnchor: ScriptTimeAnchor(entryId: "direction", offsetMs: 0), authoredDurationMs: 3800), ImageCue(id: "foreground", sceneId: "scene", startMs: 2200, endMs: 4200, startAnchor: ScriptTimeAnchor(entryId: "dialogue", offsetMs: 0), authoredDurationMs: 2000)])
    }
}
