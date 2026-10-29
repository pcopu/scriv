import XCTest
@testable import ScrivCore

final class CueAnchoringTests: XCTestCase {
    private func fixture() throws -> ScrivProject {
        var project = ScrivProject(scenes: [ScriptScene(id: "s")], entries: [
            ScriptEntry(id: "a", sceneId: "s", order: 0, kind: .direction, text: "Watch the road", ownedDurationMs: 1000, coverageDurationMs: 2500),
            ScriptEntry(id: "b", sceneId: "s", order: 1, text: "Move me", ownedDurationMs: 1000),
            ScriptEntry(id: "c", sceneId: "s", order: 2, text: "Stay here", ownedDurationMs: 1000),
            ScriptEntry(id: "d", sceneId: "s", order: 3, text: "Then leave", ownedDurationMs: 1000)
        ], cues: [ImageCue(id: "parent", sceneId: "s", label: "Parent", startMs: 0, endMs: 2500), ImageCue(id: "child", sceneId: "s", label: "Child", startMs: 1000, endMs: 2500)])
        try CueAnchoring.materialize(&project, sceneId: "s")
        try TimingEngine.validate(project)
        return project
    }
    func testIncomingOverlapStaysWithParentAndOutgoingTravelsWithMovedChild() throws {
        var project = try fixture(); let original = project
        try ProjectEditing.moveEntry(&project, entryId: "b", offset: 2)
        XCTAssertEqual(project.entries(in: "s").map(\.id), ["a", "c", "d", "b"])
        XCTAssertEqual(project.cues.first { $0.id == "parent" }, original.cues.first { $0.id == "parent" })
        let moved = try XCTUnwrap(project.cues.first { $0.id == "child" })
        XCTAssertEqual(moved.startMs, 3000); XCTAssertEqual(moved.endMs, 4000)
        XCTAssertEqual(moved.authoredDurationMs, 1500); XCTAssertEqual(moved.startAnchor?.entryId, "b")
        XCTAssertEqual(project.activeCue(at: 1200, sceneId: "s")?.id, "parent")
        XCTAssertEqual(project.entries.first { $0.id == "a" }?.coverageDurationMs, 2500)
        XCTAssertEqual(project.entries.flatMap(\.words), original.entries.flatMap(\.words))
        XCTAssertEqual(project.audioClips, original.audioClips); XCTAssertEqual(project.images, original.images)
        XCTAssertEqual(Set(project.cues.map(\.id)), Set(original.cues.map(\.id)))
    }
    func testMovedDirectionCarriesItsOwnCoverageAndRestoresTailWhenMovedBack() throws {
        var project = try fixture(); let original = project
        try ProjectEditing.moveEntry(&project, entryId: "a", offset: 2)
        XCTAssertEqual(project.startMs(of: "a"), 2000)
        XCTAssertEqual(project.entries.first { $0.id == "a" }?.coverageDurationMs, 2500)
        let cue = try XCTUnwrap(project.cues.first { $0.id == "parent" })
        XCTAssertEqual(cue.startMs, 2000); XCTAssertEqual(cue.endMs, 4000); XCTAssertEqual(cue.authoredDurationMs, 2500)
        try ProjectEditing.moveEntry(&project, entryId: "a", offset: -2)
        XCTAssertEqual(project.cues, original.cues)
        XCTAssertEqual(project.entries.map(\.ownedDurationMs), original.entries.map(\.ownedDurationMs))
    }
    func testForegroundIsDeterministicAndUnderlyingCueResumes() throws {
        var project = try fixture()
        try TimingEngine.setCueDuration(&project, cueId: "child", durationMs: 500)
        XCTAssertEqual(project.activeCue(at: 999, sceneId: "s")?.id, "parent")
        XCTAssertEqual(project.activeCue(at: 1000, sceneId: "s")?.id, "child")
        XCTAssertEqual(project.activeCue(at: 1500, sceneId: "s")?.id, "parent")
        XCTAssertEqual(project.cues.count, 2)
    }
    func testMigrationAnchorsExactBoundaryToFollowingOwnedEntryNotZeroNote() throws {
        var project = ScrivProject(scenes: [ScriptScene(id: "s")], entries: [
            ScriptEntry(id: "a", sceneId: "s", order: 0, text: "First", ownedDurationMs: 1000),
            ScriptEntry(id: "note", sceneId: "s", order: 1, kind: .direction, text: "Aside", ownedDurationMs: 0, coverageDurationMs: 1000),
            ScriptEntry(id: "b", sceneId: "s", order: 2, text: "Second", ownedDurationMs: 1000)
        ], cues: [ImageCue(id: "cue", sceneId: "s", startMs: 1000, endMs: 2000)])
        try ProjectEditing.moveEntry(&project, entryId: "b", offset: -2)
        XCTAssertEqual(project.cues[0].startAnchor, ScriptTimeAnchor(entryId: "b", offsetMs: 0))
        XCTAssertEqual(project.cues[0].startMs, 0); XCTAssertEqual(project.cues[0].authoredDurationMs, 1000)
    }
    func testAuthoredCoverageRestoresWhenSceneGrowsWithoutRetargeting() throws {
        var project = try fixture()
        try TimingEngine.setCueDuration(&project, cueId: "child", durationMs: 10_000)
        XCTAssertEqual(project.cues[1].endMs, 4000)
        try ProjectEditing.insertEntry(&project, entry: ScriptEntry(id: "tail", sceneId: "s", order: 4, text: "More", ownedDurationMs: 2000))
        XCTAssertEqual(project.cues[1].startAnchor?.entryId, "b")
        XCTAssertEqual(project.cues[1].authoredDurationMs, 10_000)
        XCTAssertEqual(project.cues[1].endMs, 6000)
    }
    func testInvalidAnchorsAndUnanchoredOverlapRejected() throws {
        var project = try fixture(); project.cues[0].startAnchor?.entryId = "missing"
        XCTAssertThrowsError(try TimingEngine.validate(project))
        project = try fixture(); project.cues[0].startAnchor?.offsetMs = 1000
        XCTAssertThrowsError(try TimingEngine.validate(project))
        project = try fixture(); project.cues[0].authoredDurationMs = nil
        XCTAssertThrowsError(try TimingEngine.validate(project))
        project = try fixture(); project.cues[0].startAnchor = nil; project.cues[0].authoredDurationMs = nil
        XCTAssertThrowsError(try TimingEngine.validate(project))
    }
    func testOverlappingImageCutIsRejectedWithoutChangingAnything() throws {
        var project = try fixture(); let original = project
        XCTAssertFalse(TimingEngine.canMoveBoundary(project, leftCueId: "parent", rightCueId: "child"))
        XCTAssertThrowsError(try TimingEngine.moveBoundary(&project, leftCueId: "parent", rightCueId: "child", toMs: 1500))
        XCTAssertEqual(project, original)
    }
    func testLegacyAndAnchoredRoundtripPreserveOwnership() throws {
        let legacy = try JSONDecoder().decode(ImageCue.self, from: Data(#"{"id":"cue","sceneId":"s","label":"A","startMs":0,"endMs":1000,"prompt":""}"#.utf8))
        XCTAssertNil(legacy.startAnchor); XCTAssertNil(legacy.authoredDurationMs)
        let project = try fixture()
        let decoded = try JSONDecoder().decode(ScrivProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded, project); try TimingEngine.validate(decoded)
    }
    func testZeroOwnedResizeDoesNotStealFollowingImageOrLoseParentCoverage() throws {
        var project = try fixture()
        try TimingEngine.setOwnedDuration(&project, entryId: "a", durationMs: 0)
        XCTAssertEqual(project.cues[0].startAnchor?.entryId, "a")
        XCTAssertEqual(project.cues[0].authoredDurationMs, 1500)
        XCTAssertEqual(project.cues[1].startAnchor?.entryId, "b")
        XCTAssertEqual(project.cues[1].startMs, 0)
        try TimingEngine.setOwnedDuration(&project, entryId: "a", durationMs: 1000)
        XCTAssertEqual(project.cues[0].startAnchor?.entryId, "a")
        XCTAssertEqual(project.cues[1].startAnchor?.entryId, "b")
        XCTAssertEqual(project.cues[1].startMs, 1000)
        try TimingEngine.validate(project)
    }
    func testDurationCollapseRejectsRatherThanDeletingImageIdentity() throws {
        var project = try fixture()
        try TimingEngine.setCueDuration(&project, cueId: "parent", durationMs: 500)
        let before = project
        XCTAssertThrowsError(try TimingEngine.setOwnedDuration(&project, entryId: "a", durationMs: 0))
        XCTAssertEqual(project, before)
    }

    func testExplicitZeroOwnedDirectionOwnsItsImageAfterReorder() throws {
        var project = try fixture()
        project.entries.append(ScriptEntry(id: "note", sceneId: "s", order: -1, kind: .direction, text: "Quietly", ownedDurationMs: 0, coverageDurationMs: 1500))
        try TimingEngine.setCueAnchor(&project, cueId: "child", entryId: "note")
        try ProjectEditing.moveEntry(&project, entryId: "note", offset: 2)
        XCTAssertEqual(project.cues[1].startAnchor?.entryId, "note")
        XCTAssertEqual(project.cues[1].startMs, project.startMs(of: "note"))
        XCTAssertEqual(project.cues[1].authoredDurationMs, 1500)
        XCTAssertEqual(project.entries.first { $0.id == "note" }?.coverageDurationMs, 1500)
    }

    func testZeroOwnedSourceAtSceneEndKeepsDormantCueUntilFollowingTimeExists() throws {
        var project = try fixture()
        project.entries.append(ScriptEntry(id: "note", sceneId: "s", order: -1, kind: .direction, text: "Keep watching", ownedDurationMs: 0, coverageDurationMs: 1500))
        try TimingEngine.setCueAnchor(&project, cueId: "child", entryId: "note")
        try ProjectEditing.moveEntry(&project, entryId: "note", offset: 4)
        XCTAssertEqual(project.cues[1].startMs, 4000); XCTAssertEqual(project.cues[1].endMs, 4000)
        XCTAssertEqual(project.cues[1].authoredDurationMs, 1500)
        XCTAssertNil(project.activeCue(at: 4000, sceneId: "s"))
        try TimingEngine.validate(project)
        try ProjectEditing.insertEntry(&project, entry: ScriptEntry(id: "tail", sceneId: "s", order: 5, text: "Continue", ownedDurationMs: 2000))
        XCTAssertEqual(project.cues[1].startMs, 4000); XCTAssertEqual(project.cues[1].endMs, 5500)
        XCTAssertEqual(project.activeCue(at: 4100, sceneId: "s")?.id, "child")
        XCTAssertEqual(project.cues[1].startAnchor?.entryId, "note")
    }
    func testLegacyOrMidSceneZeroProjectionIsInvalid() throws {
        var project = try fixture()
        project.cues[0].endMs = project.cues[0].startMs
        XCTAssertThrowsError(try TimingEngine.validate(project))
        project.cues[0].startAnchor = nil; project.cues[0].authoredDurationMs = nil
        XCTAssertThrowsError(try TimingEngine.validate(project))
    }

    func testReorderAndWordTimingPreserveActualVersionLineageAndAudioRecords() throws {
        var project = try fixture()
        project.images = [
            ImageAsset(id: "image1", fileName: "one.png", sha256: String(repeating: "a", count: 64), byteCount: 12),
            ImageAsset(id: "image2", version: 2, fileName: "two.png", sha256: String(repeating: "b", count: 64), byteCount: 15, previousVersionId: "image1")
        ]
        project.cues[1].imageId = "image1"; project.cues[1].prompt = "Keep this version"
        project.audioAssets = [AudioAsset(id: "audio", fileName: String(repeating: "c", count: 64) + ".wav", sha256: String(repeating: "c", count: 64), byteCount: 1000, durationMs: 2000, sampleRate: 48000, channelCount: 1, waveform: [0, 0.4, 0], originalName: "Voice")]
        project.audioClips = [AudioClip(id: "clip", sceneId: "s", entryId: "b", assetId: "audio", startMs: 0, sourceStartMs: 100, durationMs: 900)]
        let before = project
        try ProjectEditing.moveEntry(&project, entryId: "b", offset: 2)
        try TimingEngine.setWordTiming(&project, wordId: project.entries.first { $0.id == "b" }!.words[0].id, startMs: 10, endMs: 100)
        XCTAssertEqual(project.images, before.images)
        XCTAssertEqual(project.audioAssets, before.audioAssets); XCTAssertEqual(project.audioClips, before.audioClips)
        XCTAssertEqual(project.cues[1].id, before.cues[1].id); XCTAssertEqual(project.cues[1].imageId, "image1")
        XCTAssertEqual(project.cues[1].prompt, "Keep this version")
        XCTAssertEqual(project.entries.flatMap(\.words).map(\.id), before.entries.flatMap(\.words).map(\.id))
        XCTAssertEqual(project.entries.map(\.text), before.entries.map(\.text))
        XCTAssertEqual(AudioTimeline.placements(project: project, sceneId: "s").first?.startMs, 3000)
    }

}
