import XCTest
import ScrivCore
#if canImport(ScrivUIKit)
@testable import ScrivUIKit
#elseif canImport(ScrivAudioTimingDraft)
@testable import ScrivAudioTimingDraft
#endif

final class AudioTimingDraftTests: XCTestCase {
    private func fixture() -> ScrivProject {
        let data = Data("local source recording".utf8), hash = ScrivDigest.sha256(data)
        let asset = AudioAsset(id: "audio", fileName: hash + ".wav", sha256: hash, byteCount: data.count, durationMs: 4000, sampleRate: 48_000, channelCount: 1, waveform: [0, 0.3, 0.9, 0], originalName: "Voice.wav")
        let first = ScriptEntry(id: "line1", sceneId: "scene", order: 0, text: "one two three", ownedDurationMs: 3000, words: [
            TimedWord(id: "w1", text: "one", startMs: 0, endMs: 600),
            TimedWord(id: "w2", text: "two", startMs: 1000, endMs: 1600),
            TimedWord(id: "w3", text: "three", startMs: 2200, endMs: 2800)
        ])
        return ScrivProject(scenes: [ScriptScene(id: "scene")], entries: [first, ScriptEntry(id: "line2", sceneId: "scene", order: 1, text: "four", ownedDurationMs: 2000)],
            cues: [ImageCue(id: "image1", sceneId: "scene", startMs: 0, endMs: 3000), ImageCue(id: "image2", sceneId: "scene", startMs: 3000, endMs: 5000)],
            audioAssets: [asset], audioClips: [AudioClip(id: "clip", sceneId: "scene", entryId: "line1", assetId: "audio", startMs: 250, sourceStartMs: 500, durationMs: 2500)])
    }
    func testSecondsParsingRejectsInvalidAndOversizedDrafts() {
        XCTAssertEqual(AudioTimingInput.milliseconds(" 1.234 \n", maximum: 5000), 1234)
        XCTAssertEqual(AudioTimingInput.milliseconds("0.0006", maximum: 5000), 1)
        XCTAssertEqual(AudioTimingInput.seconds(1234), "1.234")
        for text in ["", "nan", "inf", "-0.1", "1e200", "5.001", "not time"] {
            XCTAssertNil(AudioTimingInput.milliseconds(text, maximum: 5000), text)
        }
        XCTAssertNil(AudioTimingInput.milliseconds(String(Double(Int.max) / 1000), maximum: Int.max))
        XCTAssertNil(AudioTimingInput.milliseconds("1", maximum: -1))
    }
    func testAudioDraftCancellationAndTrimmingDoNotMutateRecordingOrPlacement() throws {
        let project = fixture(), original = project
        var draft = AudioClipTimingDraft(clip: project.audioClips[0])
        draft.setTrim(1000...3000)
        XCTAssertEqual(project, original)
        let result = try draft.applying(to: project)
        XCTAssertEqual(result.sourceStartMs, 1000); XCTAssertEqual(result.durationMs, 2000)
        XCTAssertEqual(result.startMs, 250); XCTAssertEqual(result.entryId, "line1")
        XCTAssertEqual(project.audioAssets, original.audioAssets); XCTAssertEqual(project.audioClips, original.audioClips)
        XCTAssertEqual(project.cues, original.cues); XCTAssertEqual(project.entries, original.entries)
    }
    func testAudioAnchorMaintainsAbsoluteTimeOrExplainsPositiveOffsetClamp() throws {
        let project = fixture(); var draft = AudioClipTimingDraft(clip: project.audioClips[0])
        XCTAssertFalse(try draft.attach(to: nil, project: project))
        XCTAssertEqual(draft.offset, "0.250"); XCTAssertEqual(draft.sceneStart(project: project), 250)
        XCTAssertTrue(try draft.attach(to: "line2", project: project))
        XCTAssertEqual(draft.offset, "0.000"); XCTAssertEqual(draft.sceneStart(project: project), 3000)
        XCTAssertFalse(try draft.attach(to: nil, project: project))
        XCTAssertEqual(draft.offset, "3.000"); XCTAssertEqual(draft.sceneStart(project: project), 3000)
        let before = draft.entryID
        XCTAssertThrowsError(try draft.attach(to: "removed", project: project)); XCTAssertEqual(draft.entryID, before)
    }
    func testAudioInvalidAndStaleDraftsNeverOverwriteCurrentClip() throws {
        var project = fixture(); var draft = AudioClipTimingDraft(clip: project.audioClips[0])
        draft.source = "3.900"; draft.duration = "0.200"
        XCTAssertNil(draft.trim(asset: project.audioAssets[0])); XCTAssertThrowsError(try draft.applying(to: project))
        draft.source = "0.500"; draft.duration = "0.000"
        XCTAssertThrowsError(try draft.applying(to: project))
        draft.duration = "2.500"; draft.offset = "nan"
        XCTAssertThrowsError(try draft.attach(to: nil, project: project)); XCTAssertEqual(draft.entryID, "line1")
        draft.offset = "0.250"; project.audioClips[0].volume = 0.2
        let newer = project
        XCTAssertThrowsError(try draft.applying(to: project)); XCTAssertEqual(project, newer)
    }
    func testWordSelectionRetainsEveryPendingDraftAndCancelLeavesProjectUntouched() throws {
        let project = fixture(), entry = project.entries[0]
        var draft = ManualWordTimingDraft(entry: entry, wordID: "w1")
        draft.setSelectedRange(100...700); draft.selectedWordID = "w2"; draft.setSelectedRange(1200...1700)
        draft.selectedWordID = "w1"
        XCTAssertEqual(draft.times["w1"]?.start, "0.100"); XCTAssertEqual(draft.times["w2"]?.end, "1.700")
        XCTAssertEqual(project.entries[0], entry)
        let words = try draft.updatedWords(current: entry)
        XCTAssertEqual(words.map(\.startMs), [100, 1200, 2200])
        XCTAssertEqual(words.prefix(2).map(\.timingSource), [.authored, .authored]); XCTAssertNil(words[2].timingSource)
    }
    func testNeighborWordDraftsSaveTogetherAndPreserveAudioAndImages() throws {
        var project = fixture(); let original = project
        var draft = ManualWordTimingDraft(entry: project.entries[0], wordID: "w1")
        draft.setSelectedRange(0...1200)
        XCTAssertThrowsError(try draft.updatedWords(current: project.entries[0]))
        draft.selectedWordID = "w2"; draft.setSelectedRange(1200...1600)
        let updated = try draft.updatedWords(current: project.entries[0])
        try TimingEngine.setWordTimings(&project, entryId: "line1", expectedWords: draft.original.words, expectedDurationMs: draft.original.ownedDurationMs, updatedWords: updated)
        XCTAssertEqual(project.entries[0].words, updated)
        XCTAssertEqual(project.audioAssets, original.audioAssets); XCTAssertEqual(project.audioClips, original.audioClips)
        XCTAssertEqual(project.cues, original.cues); XCTAssertEqual(project.entries[0].text, original.entries[0].text)
    }
    func testInvalidRawWordDraftIsRetainedAndNeverDrawnAsInventedTiming() throws {
        let entry = fixture().entries[0]; var draft = ManualWordTimingDraft(entry: entry, wordID: "w2")
        draft.times["w2"]?.start = "nan"
        XCTAssertThrowsError(try draft.updatedWords(current: entry))
        XCTAssertEqual(draft.times["w2"]?.start, "nan")
        XCTAssertFalse(draft.previewWords.contains { $0.id == "w2" })
        draft.times["w2"]?.start = "1.600"; draft.times["w2"]?.end = "1.6004"
        XCTAssertThrowsError(try draft.updatedWords(current: entry))
    }
    func testWordDraftRejectsStaleLineAndPreservesExistingAuthoredMarkers() throws {
        var entry = fixture().entries[0]; entry.words[0].timingSource = .authored
        let draft = ManualWordTimingDraft(entry: entry, wordID: "w1")
        XCTAssertEqual(try draft.updatedWords(current: entry), entry.words)
        var newer = entry; newer.words[1].endMs = 1700
        XCTAssertThrowsError(try draft.updatedWords(current: newer))
        newer = entry; newer.ownedDurationMs += 100
        XCTAssertThrowsError(try draft.updatedWords(current: newer))
        newer = entry; newer.sceneId = "different"
        XCTAssertThrowsError(try draft.updatedWords(current: newer))
    }
}
