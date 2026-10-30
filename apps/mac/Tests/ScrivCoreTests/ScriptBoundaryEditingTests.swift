import XCTest
@testable import ScrivCore

final class ScriptBoundaryEditingTests: XCTestCase {
    private func fixture(_ text: String = "One two three") -> ScrivProject {
        ScrivProject(scenes: [ScriptScene(id: "s")], entries: [ScriptEntry(id: "a", sceneId: "s", order: 0, text: text, ownedDurationMs: 3000)], cues: [ImageCue(id: "cue", sceneId: "s", startMs: 1700, endMs: 3000)])
    }
    func testSplitPreservesExactTextWordIDsAndTotalTime() throws {
        var p = fixture("One  two\tthree"); let original = p.entries[0], duration = p.durationMs(of: "s")
        let id = try ScriptBoundaryEditing.split(project: &p, entryID: "a", atUTF16Offset: 5, expectedText: original.text)
        let rows = p.entries(in: "s")
        XCTAssertEqual(rows.map(\.text), ["One  ", "two\tthree"])
        XCTAssertEqual(rows.map(\.text).joined(), original.text); XCTAssertEqual(rows.flatMap(\.words).map(\.id), original.words.map(\.id))
        XCTAssertEqual(p.durationMs(of: "s"), duration); XCTAssertEqual(rows[1].id, id)
        XCTAssertEqual(p.cues[0].startMs, 1700); XCTAssertEqual(p.cues[0].endMs, 3000)
        try TimingEngine.validate(p)
    }
    func testSplitInsideWordKeepsUntouchedIdentityAndAuthoredMarkers() throws {
        var p = fixture("Hello world"); p.entries[0].words[0].timingSource = .authored
        let old = p.entries[0].words
        _ = try ScriptBoundaryEditing.split(project: &p, entryID: "a", atUTF16Offset: 2, expectedText: "Hello world")
        let rows = p.entries(in: "s")
        XCTAssertEqual(rows.map(\.text), ["He", "llo world"])
        XCTAssertEqual(rows.flatMap(\.words).map(\.text), ["He", "llo", "world"])
        XCTAssertEqual(rows[1].words.last?.id, old[1].id)
        XCTAssertEqual(rows[0].words[0].timingSource, .authored); XCTAssertEqual(rows[1].words[0].timingSource, .authored)
        XCTAssertEqual(p.durationMs(of: "s"), 3000)
    }
    func testSplitCharacterIdentityAcrossBoundaryAndEmojiOffset() throws {
        var p = fixture("🙂 Alex Alex"); p.characters = [ScriptCharacter(id: "person", name: "Alex")]
        p.entries[0].characterLinks = [CharacterTextLink(id: "first", characterId: "person", location: 3, length: 4, text: "Alex"), CharacterTextLink(id: "second", characterId: "person", location: 8, length: 4, text: "Alex")]
        _ = try ScriptBoundaryEditing.split(project: &p, entryID: "a", atUTF16Offset: 5, expectedText: p.entries[0].text)
        let rows = p.entries(in: "s")
        XCTAssertEqual(rows[0].characterLinks?.first?.text, "Al"); XCTAssertEqual(rows[1].characterLinks?.first?.text, "ex")
        XCTAssertEqual(rows[0].characterLinks?.first?.characterId, "person"); XCTAssertEqual(rows[1].characterLinks?.last?.id, "second")
        XCTAssertEqual(rows[1].characterLinks?.last?.location, 3); XCTAssertTrue(rows.flatMap { $0.characterLinks ?? [] }.allSatisfy(\.isConfirmed))
    }
    func testEmptyEndSplitUsesExistingTimeAndKeepsAllWords() throws {
        for offset in [0, 3] {
            var p = fixture("One"); let words = p.entries[0].words
            _ = try ScriptBoundaryEditing.split(project: &p, entryID: "a", atUTF16Offset: offset, expectedText: "One")
            XCTAssertEqual(p.durationMs(of: "s"), 3000); XCTAssertEqual(p.entries.flatMap(\.words).map(\.id), words.map(\.id)); XCTAssertEqual(p.entries.count, 2)
            XCTAssertTrue(p.entries.allSatisfy { $0.ownedDurationMs >= 1 }); try TimingEngine.validate(p)
        }
    }
    func testSplitReanchorsImageAndAudioWithoutChangingBytesOrPlacement() throws {
        var p = fixture(); let hash = String(repeating: "a", count: 64)
        p.audioAssets = [AudioAsset(id: "audio", fileName: hash + ".wav", sha256: hash, byteCount: 20, durationMs: 3000, sampleRate: 44100, channelCount: 1, waveform: [0.2], originalName: "Test")]
        p.audioClips = [AudioClip(id: "clip", sceneId: "s", entryId: "a", assetId: "audio", startMs: 1600, sourceStartMs: 300, durationMs: 1000)]
        let original = p, placement = AudioTimeline.placements(project: p, sceneId: "s")
        let id = try ScriptBoundaryEditing.split(project: &p, entryID: "a", atUTF16Offset: 4, expectedText: p.entries[0].text)
        XCTAssertEqual(p.cues[0].id, original.cues[0].id); XCTAssertEqual(p.cues[0].startAnchor?.entryId, id)
        XCTAssertEqual(p.audioAssets, original.audioAssets); XCTAssertEqual(p.audioClips[0].entryId, id)
        XCTAssertEqual(AudioTimeline.placements(project: p, sceneId: "s"), placement)
    }
    func testMergeKeepsPreviousDurationAndExactTextRetimesAuthoredWords() throws {
        var p = fixture("One "); p.entries.append(ScriptEntry(id: "b", sceneId: "s", order: 1, text: "two three", ownedDurationMs: 2000))
        p.entries[0].words[0].timingSource = .authored; p.entries[1].words[1].timingSource = .authored
        let words = p.entries.flatMap(\.words), result = try ScriptBoundaryEditing.mergeIntoPrevious(project: &p, entryID: "b", expectedText: "two three")
        XCTAssertEqual(result.entryID, "a"); XCTAssertEqual(result.caretUTF16Offset, 4)
        XCTAssertEqual(p.entries[0].text, "One two three"); XCTAssertEqual(p.entries[0].ownedDurationMs, 3000)
        XCTAssertEqual(p.entries[0].words.map(\.id), words.map(\.id)); XCTAssertEqual(p.entries[0].words.map(\.timingSource), words.map(\.timingSource))
        XCTAssertEqual(p.entries[0].words.last?.endMs, 3000); try TimingEngine.validate(p)
    }
    func testMergeDoesNotInventWhitespaceOrLoseCharacterAnnotations() throws {
        var p = fixture("Alex"); p.characters = [ScriptCharacter(id: "person", name: "Alex")]
        p.entries[0].characterLinks = [CharacterTextLink(id: "link", characterId: "person", location: 0, length: 4, text: "Alex")]
        p.entries.append(ScriptEntry(id: "b", sceneId: "s", order: 1, text: "Alex", ownedDurationMs: 1000, characterLinks: [CharacterTextLink(id: "link", characterId: "person", location: 0, length: 4, text: "Alex")]))
        _ = try ScriptBoundaryEditing.mergeIntoPrevious(project: &p, entryID: "b", expectedText: "Alex")
        XCTAssertEqual(p.entries[0].text, "AlexAlex"); XCTAssertEqual(p.entries[0].words.count, 1)
        XCTAssertEqual(p.entries[0].characterLinks?.map(\.location), [0, 4]); XCTAssertEqual(Set(p.entries[0].characterLinks!.map(\.id)).count, 2)
    }
    func testMergePreservesEveryImageCueAndRemapsRemovedOwner() throws {
        var p = fixture("One "); p.entries.append(ScriptEntry(id: "b", sceneId: "s", order: 1, text: "two", ownedDurationMs: 2000))
        p.cues.append(ImageCue(id: "second", sceneId: "s", startMs: 3500, endMs: 5000))
        _ = try ScriptBoundaryEditing.mergeIntoPrevious(project: &p, entryID: "b", expectedText: "two")
        XCTAssertEqual(Set(p.cues.map(\.id)), ["cue", "second"]); XCTAssertTrue(p.cues.allSatisfy { $0.startAnchor?.entryId == "a" })
        XCTAssertEqual(p.cues.last?.authoredDurationMs, 1500); XCTAssertEqual(p.cues.last?.startMs, 2100)
    }
    func testZeroOwnedDirectionsSplitAndMergePreserveCoverage() throws {
        var p = ScrivProject(scenes: [ScriptScene(id: "s")], entries: [ScriptEntry(id: "a", sceneId: "s", order: 0, kind: .direction, text: "Keep watching", ownedDurationMs: 0, coverageDurationMs: 5000), ScriptEntry(id: "spoken", sceneId: "s", order: 1, text: "One", ownedDurationMs: 6000)])
        let id = try ScriptBoundaryEditing.split(project: &p, entryID: "a", atUTF16Offset: 5, expectedText: "Keep watching")
        XCTAssertEqual(p.entries(in: "s").prefix(2).map(\.ownedDurationMs), [0, 0])
        _ = try ScriptBoundaryEditing.mergeIntoPrevious(project: &p, entryID: id, expectedText: "watching")
        XCTAssertEqual(p.entries.first?.text, "Keep watching"); XCTAssertEqual(p.entries.first?.coverageDurationMs, 5000)
    }
    func testRejectedOperationsAreAtomicAndExactUTF16Fenced() throws {
        var p = fixture("🙂 e\u{301}"); let before = p
        for offset in [1, 4, -1, 999] { XCTAssertThrowsError(try ScriptBoundaryEditing.split(project: &p, entryID: "a", atUTF16Offset: offset, expectedText: before.entries[0].text)); XCTAssertEqual(p, before) }
        XCTAssertThrowsError(try ScriptBoundaryEditing.split(project: &p, entryID: "a", atUTF16Offset: 3, expectedText: "🙂 é")); XCTAssertEqual(p, before)
        XCTAssertThrowsError(try ScriptBoundaryEditing.mergeIntoPrevious(project: &p, entryID: "a", expectedText: before.entries[0].text)); XCTAssertEqual(p, before)
        p.entries.append(ScriptEntry(id: "b", sceneId: "s", order: 1, kind: .direction, text: "Action", ownedDurationMs: 0)); let mixed = p
        XCTAssertThrowsError(try ScriptBoundaryEditing.mergeIntoPrevious(project: &p, entryID: "b", expectedText: "Action")); XCTAssertEqual(p, mixed)
    }
    func testInsufficientDurationDoesNotSilentlyIncreasePreviousOrSceneTime() throws {
        var p = ScrivProject(scenes: [ScriptScene(id: "s")], entries: [ScriptEntry(id: "a", sceneId: "s", order: 0, text: "x ", ownedDurationMs: 1), ScriptEntry(id: "b", sceneId: "s", order: 1, text: "y z", ownedDurationMs: 2)])
        let before = p
        XCTAssertThrowsError(try ScriptBoundaryEditing.split(project: &p, entryID: "a", atUTF16Offset: 1, expectedText: "x ")); XCTAssertEqual(p, before)
        XCTAssertThrowsError(try ScriptBoundaryEditing.mergeIntoPrevious(project: &p, entryID: "b", expectedText: "y z")); XCTAssertEqual(p, before)
    }
    func testCaretWordMappingUsesExactUTF16AndStableIdentity() {
        let p = fixture("🙂 one one"), entry = p.entries[0], last = entry.words[2]
        XCTAssertEqual(ScriptBoundaryEditing.utf16Range(ofWordID: last.id, in: entry), NSRange(location: 7, length: 3))
        XCTAssertEqual(ScriptBoundaryEditing.caretTime(in: entry, utf16Offset: 7), last.startMs)
        XCTAssertEqual(ScriptBoundaryEditing.caretTime(in: entry, utf16Offset: entry.text.utf16.count), entry.ownedDurationMs)
    }
}
