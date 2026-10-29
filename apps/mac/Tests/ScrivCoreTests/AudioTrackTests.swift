import XCTest
@testable import ScrivCore

final class AudioTrackTests: XCTestCase {
    private func asset(data: Data = Data("audio test bytes".utf8), duration: Int = 4000, waveform: [Float] = [0, 0.25, 0.75, 1]) -> AudioAsset {
        let hash = ScrivDigest.sha256(data)
        return AudioAsset(id: "voice", fileName: hash + ".wav", sha256: hash, byteCount: data.count, durationMs: duration, sampleRate: 48_000, channelCount: 2, waveform: waveform, originalName: "Voice.wav")
    }
    private func project() -> ScrivProject {
        ScrivProject(scenes: [ScriptScene(id: "scene")], entries: [
            ScriptEntry(id: "first", sceneId: "scene", order: 0, text: "One", ownedDurationMs: 2000),
            ScriptEntry(id: "second", sceneId: "scene", order: 1, text: "Two", ownedDurationMs: 3000)
        ], audioAssets: [asset()], audioClips: [AudioClip(id: "clip", sceneId: "scene", entryId: "second", assetId: "voice", startMs: 250, sourceStartMs: 500, durationMs: 3500)])
    }
    func testEntryAnchoringTrimSeekAndSceneEndAreRealTiming() throws {
        var p = project(); try TimingEngine.validate(p)
        let clip = try XCTUnwrap(AudioTimeline.placements(project: p, sceneId: "scene").first)
        XCTAssertEqual(clip.startMs, 2250); XCTAssertEqual(clip.endMs, 5000)
        XCTAssertNil(clip.sourcePosition(at: 2249)); XCTAssertEqual(clip.sourcePosition(at: 2250), 500)
        XCTAssertEqual(clip.sourcePosition(at: 3000), 1250); XCTAssertNil(clip.sourcePosition(at: 5000))
        p.entries[1].order = -1
        XCTAssertEqual(AudioTimeline.placements(project: p, sceneId: "scene").first?.startMs, 250)
        XCTAssertTrue(AudioTimeline.placements(project: p, sceneId: "missing").isEmpty)
    }
    func testWaveformIsMeasuredPeaksNotDecorativeAndCropsSource() {
        var accumulator = AudioWaveformAccumulator(totalFrames: 8, bins: 4)
        accumulator.add(peak: -0.2, atFrame: 0); accumulator.add(peak: 0.4, atFrame: 1)
        accumulator.add(peak: .nan, atFrame: 2); accumulator.add(peak: 2, atFrame: 6)
        accumulator.add(peak: 1, atFrame: 8)
        XCTAssertEqual(accumulator.peaks, [0.4, 0, 0, 1])
        let placement = AudioPlacement(clipId: "clip", assetId: "voice", startMs: 0, endMs: 2000, sourceStartMs: 2000)
        XCTAssertEqual(AudioTimeline.waveform(for: placement, asset: asset(), bins: 2), [0.75, 1])
        XCTAssertEqual(AudioTimeline.waveform(for: placement, asset: asset(waveform: [0, 0, 0, 0]), bins: 2), [0, 0])
    }
    func testAudioValidationRejectsBrokenReferencesTrimsAndNonfiniteVolume() throws {
        var p = project(); XCTAssertNoThrow(try AudioTimeline.validate(p))
        p.audioVolume = .nan; XCTAssertThrowsError(try AudioTimeline.validate(p)); p.audioVolume = 1
        p.audioClips[0].sourceStartMs = 4000; XCTAssertThrowsError(try AudioTimeline.validate(p)); p.audioClips[0].sourceStartMs = 500
        p.audioClips[0].entryId = "removed"; XCTAssertThrowsError(try AudioTimeline.validate(p)); p.audioClips[0].entryId = "second"
        p.audioAssets[0].fileName = "../outside.wav"; XCTAssertThrowsError(try AudioTimeline.validate(p))
    }
    func testLegacyProjectDefaultsToNoAudioAndNewMetadataRoundtrips() throws {
        let p = project(), encoded = try ScrivJSON.encoder.encode(p)
        XCTAssertEqual(try ScrivJSON.decoder.decode(ScrivProject.self, from: encoded), p)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "audioAssets"); object.removeValue(forKey: "audioClips"); object.removeValue(forKey: "audioVolume")
        let legacy = try ScrivJSON.decoder.decode(ScrivProject.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(legacy.audioAssets.isEmpty); XCTAssertTrue(legacy.audioClips.isEmpty); XCTAssertEqual(legacy.audioVolume, 1)
    }
    func testContentAddressedBytesValidateRepairAndExportWithPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root), p = project(), package = root.appendingPathComponent("project.scriv")
        let data = Data("audio test bytes".utf8)
        let stored = try AudioFileStore.store(data, fileExtension: "wav", at: package)
        XCTAssertEqual(stored.fileName, p.audioAssets[0].fileName)
        try await repo.save(p, at: package, label: "Local audio")
        XCTAssertEqual(try AudioFileStore.verifiedData(for: p.audioAssets[0], at: package), data)
        try Data(repeating: 1, count: data.count).write(to: stored.url)
        XCTAssertThrowsError(try AudioFileStore.verifiedData(for: p.audioAssets[0], at: package))
        _ = try AudioFileStore.store(data, fileExtension: "wav", at: package)
        let copy = root.appendingPathComponent("copy.scriv")
        try await repo.copyPackage(from: package, to: copy)
        let reopened = try await repo.load(at: copy)
        XCTAssertEqual(reopened.audioClips, p.audioClips)
        XCTAssertEqual(try AudioFileStore.verifiedData(for: reopened.audioAssets[0], at: copy), data)
    }
    func testAudioStorageRejectsEscapingSymlinkAndPathMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("project.scriv"), external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("audio"), withDestinationURL: external)
        XCTAssertThrowsError(try AudioFileStore.store(Data([1, 2]), fileExtension: "wav", at: package))
        var bad = asset(); bad.fileName = "../../outside.wav"
        XCTAssertThrowsError(try AudioFileStore.url(asset: bad, package: package))
    }
}
