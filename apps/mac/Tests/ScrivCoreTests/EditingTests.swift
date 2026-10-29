import XCTest
@testable import ScrivCore

final class EditingTests: XCTestCase {
    private func fixture() -> ScrivProject {
        ScrivProject(scenes: [ScriptScene(id: "s", title: "INT. ROOM")], entries: [
            ScriptEntry(id: "note", sceneId: "s", order: 0, kind: .direction, text: "Keep watching", ownedDurationMs: 0, coverageDurationMs: 2500),
            ScriptEntry(id: "a", sceneId: "s", order: 1, text: "One two", ownedDurationMs: 1000),
            ScriptEntry(id: "b", sceneId: "s", order: 2, text: "Three four", ownedDurationMs: 1000),
            ScriptEntry(id: "later", sceneId: "s", order: 3, kind: .direction, text: "Look away", ownedDurationMs: 0, coverageDurationMs: 1000),
            ScriptEntry(id: "c", sceneId: "s", order: 4, text: "Five six", ownedDurationMs: 1000)
        ], cues: [ImageCue(id: "first", sceneId: "s", startMs: 0, endMs: 1000), ImageCue(id: "second", sceneId: "s", startMs: 1000, endMs: 3000)])
    }
    func testFullApprovedSampleTextAndTimings() throws {
        let sample = ScrivProject.example()
        XCTAssertEqual(sample.authoredEntryCount(in: "scene-farm"), 16)
        XCTAssertEqual(sample.entries.count, 18)
        XCTAssertEqual(sample.durationMs(of: "scene-farm"), 56_300)
        for (id, time) in [("line-01", 0), ("line-02", 3200), ("line-03", 5600), ("line-04", 13200), ("line-05", 18500), ("line-06", 19900), ("line-07", 22300), ("direction-08", 25300), ("line-08", 25300), ("line-09", 30300), ("direction-10", 32700), ("line-10", 32700), ("line-11", 35500), ("line-12", 38300), ("line-13", 39900), ("line-14", 49700), ("line-15", 52300), ("line-16", 54100)] {
            XCTAssertEqual(sample.startMs(of: id), time, id)
        }
        XCTAssertEqual(sample.entries.first { $0.id == "line-01" }?.text, "Miyazaki, do you have any questions?")
        XCTAssertEqual(sample.entries.first { $0.id == "line-13" }?.text, "Listen, this guy is a left-handed pitcher. He throws the baseball better than any American. 87. 88. MPH.")
        XCTAssertEqual(sample.cues(in: "scene-farm").map(\.durationMs).reduce(0, +), 56_300)
        try TimingEngine.validate(sample)
    }
    func testInsertionPreservesImageOwnersAndReanchorsDirectionCoverage() throws {
        var p = fixture()
        let words = p.entries.flatMap(\.words)
        try ProjectEditing.insertEntry(&p, entry: ScriptEntry(id: "insert", sceneId: "s", order: 42, text: "New", ownedDurationMs: 500), after: "a")
        XCTAssertEqual(p.entries(in: "s").map(\.id), ["note", "a", "insert", "b", "later", "c"])
        XCTAssertEqual(p.startMs(of: "b"), 1500)
        XCTAssertEqual(p.startMs(of: "later"), 2500)
        XCTAssertEqual(p.entries.first { $0.id == "note" }?.coverageDurationMs, 3000)
        XCTAssertEqual(p.entries.first { $0.id == "later" }?.coverageDurationMs, 1000)
        XCTAssertEqual(p.cues(in: "s").map(\.startMs), [0, 1500])
        XCTAssertEqual(p.cues(in: "s").map(\.endMs), [1000, 3500])
        XCTAssertEqual(p.entries.filter { $0.id != "insert" }.flatMap(\.words), words)
    }
    func testInsertionDoesNotSilentlyAssignExistingPicturesToNewOwners() throws {
        var p = fixture()
        try ProjectEditing.insertEntry(&p, entry: ScriptEntry(id: "intro", sceneId: "s", order: 0, text: "Start", ownedDurationMs: 500), after: "note")
        XCTAssertEqual(p.cues.first { $0.id == "first" }?.startMs, 500)
        XCTAssertEqual(p.cues.first { $0.id == "first" }?.endMs, 1500)
        try ProjectEditing.insertEntry(&p, entry: ScriptEntry(id: "outro", sceneId: "s", order: 0, text: "End", ownedDurationMs: 700))
        XCTAssertEqual(p.cues(in: "s").last?.endMs, 3500)
        XCTAssertEqual(p.durationMs(of: "s"), 4200)
    }
    func testDeleteLineRemapsCrossingCoverageAndPreservesLaterLength() throws {
        var p = fixture()
        try ProjectEditing.deleteEntry(&p, entryId: "b")
        XCTAssertEqual(p.durationMs(of: "s"), 2000)
        XCTAssertEqual(p.entries.first { $0.id == "note" }?.coverageDurationMs, 1500)
        XCTAssertEqual(p.startMs(of: "later"), 1000)
        XCTAssertEqual(p.entries.first { $0.id == "later" }?.coverageDurationMs, 1000)
        XCTAssertEqual(p.cues(in: "s").map(\.endMs), [1000])
        XCTAssertFalse(p.cues.contains { $0.id == "second" })
    }
    func testDeleteZeroOwnedNoteChangesNoTiming() throws {
        var p = fixture(); let cues = p.cues, words = TimingEngine.absoluteWords(p, sceneId: "s")
        try ProjectEditing.deleteEntry(&p, entryId: "note")
        XCTAssertEqual(p.cues, cues)
        XCTAssertEqual(TimingEngine.absoluteWords(p, sceneId: "s"), words)
    }
    func testTextGrowthResizesBeforeValidationAndPreservesIdentities() throws {
        var p = ScrivProject(scenes: [ScriptScene(id: "s")], entries: [ScriptEntry(id: "a", sceneId: "s", order: 0, text: "a", ownedDurationMs: 1)], cues: [ImageCue(sceneId: "s", startMs: 0, endMs: 1)])
        let oldID = p.entries[0].words[0].id
        try TimingEngine.updateText(&p, entryId: "a", text: "a b c")
        XCTAssertEqual(p.entries[0].ownedDurationMs, 3)
        XCTAssertEqual(p.entries[0].words[0].id, oldID)
        XCTAssertEqual(p.cues[0].endMs, 3)
        XCTAssertEqual(p.entries[0].words.map(\.endMs), [1, 2, 3])
        try TimingEngine.validate(p)
    }
    func testInitializerNeverProducesWordsBeyondDialogueDuration() throws {
        let entry = ScriptEntry(sceneId: "s", order: 0, text: "one two three", ownedDurationMs: 1)
        XCTAssertEqual(entry.ownedDurationMs, 3)
        XCTAssertEqual(entry.words.last?.endMs, 3)
    }
    func testRejectedEditsAreAtomic() throws {
        var p = fixture(); let before = p
        XCTAssertThrowsError(try ProjectEditing.insertEntry(&p, entry: ScriptEntry(sceneId: "missing", order: 0, text: "No")))
        XCTAssertEqual(p, before)
        XCTAssertThrowsError(try ProjectEditing.moveEntry(&p, entryId: "a", offset: Int.max))
        XCTAssertEqual(p, before)
        XCTAssertThrowsError(try ProjectEditing.mergeCues(&p, leftCueId: "second", rightCueId: "first"))
        XCTAssertEqual(p, before)
        XCTAssertThrowsError(try TimingEngine.setOwnedDuration(&p, entryId: "a", durationMs: 1))
        XCTAssertEqual(p, before)
        // Rejection after mutation (coverage would exceed its one-day limit).
        p.entries[0].coverageDurationMs = 86_400_000
        let maximumCoverage = p
        XCTAssertThrowsError(try TimingEngine.setOwnedDuration(&p, entryId: "a", durationMs: 2000))
        XCTAssertEqual(p, maximumCoverage)
    }
    func testMoveNormalizesEqualOrdersWithoutRewritingWords() throws {
        var p = fixture()
        p.entries = p.entries.map { var e = $0; e.order = 0; return e }
        let initial = p.entries(in: "s"), originalWords = p.entries.flatMap(\.words)
        let id = initial[0].id
        try ProjectEditing.moveEntry(&p, entryId: id, offset: 3)
        var expected = initial.map(\.id); expected.insert(expected.removeFirst(), at: 3)
        XCTAssertEqual(p.entries(in: "s").map(\.id), expected)
        XCTAssertEqual(p.entries.flatMap(\.words), originalWords)
        XCTAssertEqual(Set(p.entries.map(\.order)).count, p.entries.count)
    }
    func testDeleteCueCreatesRecoverableGapAndAddFillsIt() throws {
        var p = fixture(); let entries = p.entries
        try ProjectEditing.deleteCue(&p, cueId: "first")
        let newID = try ProjectEditing.addCue(&p, sceneId: "s", atMs: 400)
        let cue = try XCTUnwrap(p.cues.first { $0.id == newID })
        XCTAssertEqual(cue.startMs, 0); XCTAssertEqual(cue.endMs, 1000)
        XCTAssertEqual(p.entries, entries)
        let splitID = try ProjectEditing.addCue(&p, sceneId: "s", atMs: 500)
        try ProjectEditing.mergeCues(&p, leftCueId: newID, rightCueId: splitID)
        XCTAssertEqual(p.cues.first { $0.id == newID }?.endMs, 1000)
        XCTAssertEqual(p.entries, entries)
    }
    func testRemoveScenePreservesUnrelatedContentAndImages() throws {
        var p = fixture(); let other = ScriptScene(id: "other", title: "EXT. FIELD")
        p.scenes.append(other); p.entries.append(ScriptEntry(id: "other-line", sceneId: other.id, order: 0, text: "Stay"))
        try ProjectEditing.deleteScene(&p, sceneId: "s")
        XCTAssertEqual(p.scenes, [other]); XCTAssertEqual(p.entries.map(\.id), ["other-line"]); XCTAssertTrue(p.cues.isEmpty)
    }
    func testPortraitTaggingAndVersionLineageDoNotRetargetExistingCues() throws {
        var p = fixture()
        let character = ScriptCharacter(id: "person", name: "Person")
        let first = ImageAsset(id: "v1", fileName: "v1.png", sha256: String(repeating: "a", count: 64), byteCount: 12)
        let second = ImageAsset(id: "v2", version: 2, fileName: "v2.png", sha256: String(repeating: "b", count: 64), byteCount: 12, previousVersionId: first.id)
        let branch = ImageAsset(id: "branch", version: 2, fileName: "branch.png", sha256: String(repeating: "c", count: 64), byteCount: 12, previousVersionId: first.id)
        p.characters = [character]; p.images = [first, second, branch]
        try ProjectEditing.setCueImage(&p, cueId: "first", imageId: first.id)
        try ProjectEditing.setPortrait(&p, characterId: character.id, imageId: second.id)
        XCTAssertEqual(p.characters[0].portraitImageId, second.id)
        XCTAssertEqual(p.images.first { $0.id == second.id }?.characterIds, [character.id])
        XCTAssertEqual(p.cues[0].imageId, first.id)
        XCTAssertEqual(Set(ProjectEditing.imageVersions(in: p, imageId: second.id).map(\.id)), [first.id, second.id, branch.id])
        let before = p
        XCTAssertThrowsError(try ProjectEditing.setPortrait(&p, characterId: character.id, imageId: "unknown")); XCTAssertEqual(p, before)
        p.images[0].previousVersionId = second.id
        XCTAssertThrowsError(try TimingEngine.validate(p))
    }
    func testTerminalZeroOwnedDirectionCanGrowWithoutBlackImageGap() throws {
        var p = fixture()
        p.entries.append(ScriptEntry(id:"last-note",sceneId:"s",order:5,kind:.direction,text:"Fade",ownedDurationMs:0,coverageDurationMs:1000))
        try TimingEngine.setOwnedDuration(&p,entryId:"last-note",durationMs:700)
        XCTAssertEqual(p.durationMs(of:"s"),3700)
        XCTAssertEqual(p.cues(in:"s").last?.endMs,3700)
        XCTAssertEqual(p.entries.first { $0.id == "last-note" }?.coverageDurationMs,1700)
        try TimingEngine.validate(p)
    }
    func testRoutineReorderDoesNotTouchEveryOtherCloudItem() throws {
        var p = ScrivProject(scenes:[ScriptScene(id:"s")],entries:(0..<300).map { ScriptEntry(id:"line-\($0)",sceneId:"s",order:Double($0),text:"Word",ownedDurationMs:10) })
        let before = Dictionary(uniqueKeysWithValues:p.entries.map { ($0.id,$0) })
        try ProjectEditing.moveEntry(&p,entryId:"line-0",offset:250)
        XCTAssertEqual(p.entries.filter { before[$0.id] != $0 }.count,1)
        XCTAssertEqual(p.entries(in:"s")[250].id,"line-0")
    }

}
