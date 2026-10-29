import XCTest
@testable import ScrivCore

final class TimingTests: XCTestCase {
    func testSampleAndBlankAreValid() throws {
        try TimingEngine.validate(.example())
        try TimingEngine.validate(.blank())
        XCTAssertEqual(ScrivProject.example().durationMs(of: "scene-farm"), 17_600)
    }
    func testCoverageDoesNotCreateSequenceTime() throws {
        var project = ScrivProject.example()
        let duration = project.durationMs(of: "scene-farm"), cues = project.cues, words = TimingEngine.absoluteWords(project, sceneId: "scene-farm")
        try TimingEngine.setCoverage(&project, entryId: "direction-08", endMs: 15_000)
        XCTAssertEqual(project.durationMs(of: "scene-farm"), duration)
        XCTAssertEqual(project.cues, cues)
        XCTAssertEqual(TimingEngine.absoluteWords(project, sceneId: "scene-farm"), words)
        XCTAssertEqual(project.entries.first { $0.id == "direction-08" }?.ownedDurationMs, 0)
    }
    func testCoverageCannotReachBeforeAuthoredStartOrOwnedEnd() throws {
        var project = ScrivProject.example()
        XCTAssertThrowsError(try TimingEngine.setCoverage(&project, entryId: "direction-08", endMs: 2999))
        XCTAssertThrowsError(try TimingEngine.setCoverage(&project, entryId: "line-09", endMs: 10_399))
        XCTAssertThrowsError(try TimingEngine.setCoverage(&project, entryId: "line-08", endMs: 10_000))
    }
    func testOwnedDirectionResizesRuntimeAndFollowingEntries() throws {
        var project = ScrivProject.example()
        try TimingEngine.setOwnedDuration(&project, entryId: "line-09", durationMs: 3400)
        XCTAssertEqual(project.durationMs(of: "scene-farm"), 18_600)
        XCTAssertEqual(project.startMs(of: "line-10"), 11_400)
        XCTAssertEqual(project.cues.first { $0.id == "cue-09a" }?.durationMs, 3400)
        try TimingEngine.validate(project)
        try TimingEngine.setOwnedDuration(&project, entryId: "line-09", durationMs: 1400)
        XCTAssertEqual(project.startMs(of: "line-10"), 9400)
        try TimingEngine.validate(project)
    }
    func testZeroOwnedInsertionKeepsFollowingDirectionCoverageLength() throws {
        let scene = ScriptScene(id: "s", title: "INT. ROOM", order: 0)
        let a = ScriptEntry(id: "a", sceneId: "s", order: 0, kind: .direction, text: "Turn", ownedDurationMs: 0, coverageDurationMs: 3000)
        let b = ScriptEntry(id: "b", sceneId: "s", order: 1, kind: .direction, text: "Look", ownedDurationMs: 0, coverageDurationMs: 2000)
        let c = ScriptEntry(id: "c", sceneId: "s", order: 2, text: "Hello there", ownedDurationMs: 3000)
        var project = ScrivProject(scenes: [scene], entries: [a,b,c], cues: [ImageCue(sceneId: "s", startMs: 0, endMs: 3000)])
        try TimingEngine.setOwnedDuration(&project, entryId: "a", durationMs: 1000)
        XCTAssertEqual(project.startMs(of: "b"), 1000)
        XCTAssertEqual(project.entries.first { $0.id == "b" }?.coverageDurationMs, 2000)
        XCTAssertEqual(project.durationMs(of: "s"), 4000)
        try TimingEngine.validate(project)
    }
    func testApprovedWordBoundaryTransferPreservesEveryWordAndTime() throws {
        var project = ScrivProject.example()
        try TimingEngine.moveBoundary(&project, leftCueId: "cue-08a", rightCueId: "cue-08b", toMs: 5000)
        let entries = project.entries, total = project.durationMs(of: "scene-farm")
        try TimingEngine.moveWords(&project, wordIds: ["word-08-4", "word-08-5"], fromCueId: "cue-08a", toCueId: "cue-08b")
        XCTAssertEqual(project.cues.first { $0.id == "cue-08a" }?.durationMs, 1400)
        XCTAssertEqual(project.cues.first { $0.id == "cue-08b" }?.durationMs, 2400)
        XCTAssertEqual(project.entries, entries)
        XCTAssertEqual(project.durationMs(of: "scene-farm"), total)
    }
    func testRejectNonContiguousWordsAndNonAdjacentImages() throws {
        var project = ScrivProject.example()
        XCTAssertThrowsError(try TimingEngine.moveWords(&project, wordIds: ["word-08-4", "word-08-6"], fromCueId: "cue-08b", toCueId: "cue-08a"))
        XCTAssertThrowsError(try TimingEngine.moveBoundary(&project, leftCueId: "cue-08a", rightCueId: "cue-08c", toMs: 4500))
        XCTAssertThrowsError(try TimingEngine.moveBoundary(&project, leftCueId: "cue-08a", rightCueId: "cue-08b", toMs: 3000))
    }
    func testMiddleWordDragDoesNotSilentlyMoveUnselectedWords() throws {
        var project = ScrivProject.example()
        let original = project
        XCTAssertThrowsError(try TimingEngine.moveWords(&project,wordIds:["word-08-6"],fromCueId:"cue-08b",toCueId:"cue-08c"))
        XCTAssertEqual(project,original)
        XCTAssertThrowsError(try TimingEngine.moveWords(&project,wordIds:["word-08-6"],fromCueId:"cue-08b",toCueId:"cue-08a"))
        XCTAssertEqual(project,original)
    }
    func testWordIdentitySurvivesRepeatedWordsAndInsertion() {
        let original = TimingEngine.retimeWords(text: "the cat and the dog", durationMs: 2000)
        let next = TimingEngine.retimeWords(text: "the small cat and the dog", durationMs: 3000, preserving: original)
        XCTAssertEqual(next[0].id, original[0].id)
        XCTAssertEqual(next[4].id, original[3].id)
        XCTAssertEqual(next[5].id, original[4].id)
        XCTAssertEqual(Set(next.map(\.id)).count, 6)
        XCTAssertEqual(next.last?.endMs, 3000)
    }
    func testOrphanCueAndDuplicateWordAreRejected() throws {
        var project = ScrivProject.example()
        project.cues[0].sceneId = "missing"
        XCTAssertThrowsError(try TimingEngine.validate(project))
        project = .example()
        project.entries[2].words[0].id = project.entries[0].words[0].id
        XCTAssertThrowsError(try TimingEngine.validate(project))
    }
    func testSplittingKeepsAssetIdentityAndTotalImageTime() throws {
        var project = ScrivProject.example()
        let before = project.cues.reduce(0) { $0 + $1.durationMs }
        try TimingEngine.splitCue(&project, cueId: "cue-08b", atMs: 5600)
        XCTAssertEqual(project.cues.reduce(0) { $0 + $1.durationMs }, before)
        XCTAssertEqual(project.cues.count, 10)
        try TimingEngine.validate(project)
    }
}
