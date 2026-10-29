import XCTest
@testable import ScrivCore

final class WordTimingEditingTests: XCTestCase {
    private func fixture() -> ScrivProject {
        ScrivProject(scenes: [ScriptScene(id: "s")], entries: [ScriptEntry(id: "e", sceneId: "s", order: 0, text: "one two three", ownedDurationMs: 3000, words: [
            TimedWord(id: "w1", text: "one", startMs: 0, endMs: 600),
            TimedWord(id: "w2", text: "two", startMs: 1000, endMs: 1600),
            TimedWord(id: "w3", text: "three", startMs: 2200, endMs: 2800)
        ])], cues: [ImageCue(id: "c1", sceneId: "s", startMs: 0, endMs: 1500), ImageCue(id: "c2", sceneId: "s", startMs: 1500, endMs: 3000)])
    }
    func testInteriorWordRetimesWithoutMovingCutsOrNeighbors() throws {
        var project = fixture(); let original = project
        try TimingEngine.setWordTiming(&project, wordId: "w2", startMs: 1700, endMs: 2100)
        XCTAssertEqual(project.entries[0].words[1], TimedWord(id: "w2", text: "two", startMs: 1700, endMs: 2100, timingSource: .authored))
        XCTAssertEqual(project.entries[0].words[0], original.entries[0].words[0])
        XCTAssertEqual(project.entries[0].words[2], original.entries[0].words[2])
        XCTAssertEqual(project.entries[0].text, original.entries[0].text)
        XCTAssertEqual(project.cues, original.cues)
        XCTAssertEqual(project.audioAssets, original.audioAssets); XCTAssertEqual(project.audioClips, original.audioClips)
        XCTAssertEqual(project.durationMs(of: "s"), original.durationMs(of: "s"))
    }
    func testShiftPhrasePreservesDurationsAndActualSourceOrder() throws {
        var project = fixture(); let cues = project.cues
        try TimingEngine.shiftWords(&project, wordIds: ["w1", "w2"], byMs: 500)
        XCTAssertEqual(project.entries[0].words.map(\.startMs), [500, 1500, 2200])
        XCTAssertEqual(project.entries[0].words.map { $0.endMs - $0.startMs }, [600, 600, 600])
        XCTAssertEqual(project.cues, cues)
        XCTAssertEqual(project.entries[0].words.prefix(2).map(\.timingSource), [.authored, .authored])
    }
    func testIllegalTimingChangesAreTransactional() throws {
        var project = fixture(); let original = project
        XCTAssertThrowsError(try TimingEngine.setWordTiming(&project, wordId: "w2", startMs: 500, endMs: 1600))
        XCTAssertThrowsError(try TimingEngine.setWordTiming(&project, wordId: "w2", startMs: 1600, endMs: 1600))
        XCTAssertThrowsError(try TimingEngine.shiftWords(&project, wordIds: ["w1", "w3"], byMs: 100))
        XCTAssertThrowsError(try TimingEngine.shiftWords(&project, wordIds: ["w2"], byMs: Int.max))
        XCTAssertEqual(project, original)
    }
    func testAuthoredWordSurvivesTextEditDurationChangeAndSerialization() throws {
        var project = fixture()
        try TimingEngine.setWordTiming(&project, wordId: "w2", startMs: 1100, endMs: 1550)
        let authored = project.entries[0].words[1]
        try TimingEngine.updateText(&project, entryId: "e", text: "one new two three")
        XCTAssertEqual(project.entries[0].words.first { $0.id == "w2" }, authored)
        try TimingEngine.setOwnedDuration(&project, entryId: "e", durationMs: 4000)
        XCTAssertEqual(project.entries[0].words.first { $0.id == "w2" }, authored)
        let decoded = try JSONDecoder().decode(ScrivProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.entries[0].words.first { $0.id == "w2" }, authored)
        try TimingEngine.validate(decoded)
    }
    func testWhitespaceEditPreservesEveryWordTime() throws {
        var project = fixture(); let words = project.entries[0].words
        try TimingEngine.updateText(&project, entryId: "e", text: "  one\n two   three ")
        XCTAssertEqual(project.entries[0].words, words)
    }
    func testInsufficientRoomNeverErasesAuthoredTiming() throws {
        var project = fixture()
        try TimingEngine.setWordTiming(&project, wordId: "w1", startMs: 0, endMs: 600)
        let before = project
        XCTAssertThrowsError(try TimingEngine.updateText(&project, entryId: "e", text: "new one two three"))
        XCTAssertEqual(project, before)
        try TimingEngine.setWordTiming(&project, wordId: "w3", startMs: 2200, endMs: 2800)
        let pinned = project
        XCTAssertThrowsError(try TimingEngine.setOwnedDuration(&project, entryId: "e", durationMs: 2500))
        XCTAssertEqual(project, pinned)
    }
    func testLegacyWordDecodesAsEstimate() throws {
        let word = try JSONDecoder().decode(TimedWord.self, from: Data(#"{"id":"w","text":"word","startMs":0,"endMs":100}"#.utf8))
        XCTAssertNil(word.timingSource)
    }
    func testLocalUndoRestoresTimingWithoutDroppingEstablishedOwnershipMetadata() throws {
        let historical = fixture(); var current = historical
        try TimingEngine.setWordTiming(&current, wordId: "w2", startMs: 1200, endMs: 1800)
        try TimingEngine.setCueDuration(&current, cueId: "c1", durationMs: 1800)
        var restored = historical
        try TimingEngine.prepareRestoredTiming(&restored, replacing: current)
        XCTAssertEqual(restored.entries[0].words[1].startMs, historical.entries[0].words[1].startMs)
        XCTAssertEqual(restored.entries[0].words[1].endMs, historical.entries[0].words[1].endMs)
        XCTAssertEqual(restored.entries[0].words[1].timingSource, .authored)
        XCTAssertNotNil(restored.cues[0].startAnchor)
        XCTAssertEqual(restored.cues[0].authoredDurationMs, historical.cues[0].durationMs)
        try TimingEngine.validate(restored)
    }

}
