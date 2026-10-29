import Foundation
import AVFoundation
import ScrivCore

/// Import only user-selected files. No microphone, account, TTS or network access.
enum LocalAudioImporter {
    static func importFile(at source: URL, into package: URL) async throws -> AudioAsset {
        try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard source.isFileURL else { throw ScrivError.invalid("Choose a local audio file.") }
            let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= AudioTimeline.maximumFileBytes else {
                throw ScrivError.invalid("Choose an audio file no larger than 100 MiB.")
            }
            try Task.checkCancellation()
            let data = try Data(contentsOf: source)
            let stored = try AudioFileStore.store(data, fileExtension: source.pathExtension, at: package)
            // Analyze the immutable package copy, not a source that might be edited mid-import.
            let file = try AVAudioFile(forReading: stored.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat, frames = file.length
            guard frames > 0, format.sampleRate.isFinite, (1...192_000).contains(format.sampleRate),
                  (1...8).contains(Int(format.channelCount)) else { throw ScrivError.invalid("This audio format cannot be imported. Use up to eight channels at 192 kHz or less.") }
            let milliseconds = ceil(Double(frames) / format.sampleRate * 1000)
            guard milliseconds.isFinite, milliseconds > 0, milliseconds <= Double(AudioTimeline.maximumDurationMs) else {
                throw ScrivError.invalid("Audio clips must be no longer than 30 minutes.")
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw ScrivError.unavailable("The audio decoder could not allocate its sample buffer.") }
            var waveform = AudioWaveformAccumulator(totalFrames: frames)
            var consumed: Int64 = 0
            while consumed < frames {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, frames - consumed)))
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw ScrivError.invalid("The audio file ended before its declared duration.") }
                for frame in 0..<Int(buffer.frameLength) {
                    var peak: Float = 0
                    for channel in 0..<Int(format.channelCount) {
                        let sample = channels[channel][frame]
                        if sample.isFinite { peak = max(peak, abs(sample)) }
                    }
                    waveform.add(peak: peak, atFrame: consumed + Int64(frame))
                }
                consumed += Int64(buffer.frameLength)
            }
            return AudioAsset(fileName: stored.fileName, sha256: stored.sha256, byteCount: data.count,
                              durationMs: Int(milliseconds), sampleRate: format.sampleRate, channelCount: Int(format.channelCount),
                              waveform: waveform.peaks, originalName: String(source.lastPathComponent.prefix(256)))
        }.value
    }
}

/// Real local playback follows the existing monotonic scene clock. Seek, pause,
/// scene/project switches and clip removal retire old players and pending loads.
@MainActor
final class LocalAudioEngine {
    var onError: ((String) -> Void)?
    private struct PlayerSlot {
        let signature: String
        let player: AVAudioPlayer
    }
    private struct Request {
        let project: ScrivProject
        let sceneId: String
        let playheadMs: Int
        let isPlaying: Bool
        let package: URL
    }
    private var request: Request?
    private var context = ""
    private var generation = UUID()
    private var players: [String: PlayerSlot] = [:]
    private var pending: [String: Task<Void, Never>] = [:]
    private var loadIDs: [String: UUID] = [:]
    private var pendingKeys: [String: String] = [:]
    private var failed: Set<String> = []

    func synchronize(project: ScrivProject, sceneId: String, playheadMs: Int, isPlaying: Bool, package: URL?) {
        guard let package else { stop(); return }
        let nextContext = project.id + "|" + sceneId + "|" + package.standardizedFileURL.path
        if context != nextContext { stop(); context = nextContext }
        // An explicit new play attempt may retry a previously missing/repaired file.
        if isPlaying && request?.isPlaying != true { failed.removeAll() }
        request = Request(project: project, sceneId: sceneId, playheadMs: playheadMs, isPlaying: isPlaying, package: package)
        apply()
    }

    func stop() {
        generation = UUID()
        for slot in players.values { slot.player.stop() }
        for task in pending.values { task.cancel() }
        players.removeAll(); pending.removeAll(); loadIDs.removeAll(); pendingKeys.removeAll(); failed.removeAll()
        request = nil; context = ""
    }

    private func signature(_ asset: AudioAsset) -> String { asset.id + "|" + asset.sha256 + "|" + String(asset.byteCount) }

    private func apply() {
        guard let request else { return }
        guard request.isPlaying else {
            for slot in players.values { slot.player.pause() }
            for task in pending.values { task.cancel() }
            pending.removeAll(); loadIDs.removeAll(); pendingKeys.removeAll()
            return
        }
        let placements = AudioTimeline.placements(project: request.project, sceneId: request.sceneId)
        let active = placements.filter { $0.sourcePosition(at: request.playheadMs) != nil }
        let activeIDs = Set(active.map(\.clipId))
        for id in Array(players.keys) where !activeIDs.contains(id) { players.removeValue(forKey: id)?.player.stop() }
        for id in Array(pending.keys) where !activeIDs.contains(id) { pending.removeValue(forKey: id)?.cancel(); loadIDs.removeValue(forKey: id); pendingKeys.removeValue(forKey: id) }
        for placement in active {
            guard let clip = request.project.audioClips.first(where: { $0.id == placement.clipId }),
                  let asset = request.project.audioAssets.first(where: { $0.id == placement.assetId }),
                  let position = placement.sourcePosition(at: request.playheadMs) else { continue }
            let key = signature(asset)
            if let pendingKey = pendingKeys[clip.id], pendingKey != key {
                pending.removeValue(forKey: clip.id)?.cancel(); loadIDs.removeValue(forKey: clip.id); pendingKeys.removeValue(forKey: clip.id)
            }
            if let slot = players[clip.id], slot.signature != key { slot.player.stop(); players.removeValue(forKey: clip.id) }
            if let slot = players[clip.id] {
                let player = slot.player, seconds = Double(position) / 1000
                // Correct drift, but don't continuously restart healthy playback on every UI tick.
                if !player.isPlaying || abs(player.currentTime - seconds) > 0.080 { player.currentTime = seconds }
                player.volume = Float(clip.isMuted ? 0 : min(1, max(0, clip.volume * request.project.audioVolume)))
                if !player.isPlaying, !player.play() {
                    player.stop(); players.removeValue(forKey: clip.id)
                    if failed.insert(key).inserted { onError?("Audio output could not start for \(asset.originalName). Check the Mac's audio output device.") }
                }
            } else if pending[clip.id] == nil && !failed.contains(key) {
                load(asset: asset, clipId: clip.id, package: request.package)
            }
        }
    }

    private func load(asset: AudioAsset, clipId: String, package: URL) {
        let epoch = generation, loadID = UUID(), key = signature(asset)
        loadIDs[clipId] = loadID; pendingKeys[clipId] = key
        pending[clipId] = Task { [weak self] in
            do {
                let data = try await Task.detached(priority: .userInitiated) { try AudioFileStore.verifiedData(for: asset, at: package) }.value
                try Task.checkCancellation()
                guard let self, self.generation == epoch, self.loadIDs[clipId] == loadID,
                      let current = self.request, current.isPlaying,
                      current.project.audioClips.contains(where: { $0.id == clipId && $0.assetId == asset.id }),
                      current.project.audioAssets.contains(where: { $0.id == asset.id && self.signature($0) == key }) else { return }
                // Playback receives the verified bytes, avoiding a second unverified path read.
                let player = try AVAudioPlayer(data: data)
                guard player.prepareToPlay() else { throw ScrivError.unavailable("The audio output device could not prepare this clip.") }
                self.players[clipId] = PlayerSlot(signature: key, player: player)
                self.pending.removeValue(forKey: clipId); self.loadIDs.removeValue(forKey: clipId); self.pendingKeys.removeValue(forKey: clipId)
                self.apply()
            } catch {
                guard let self, self.generation == epoch, self.loadIDs[clipId] == loadID else { return }
                self.pending.removeValue(forKey: clipId); self.loadIDs.removeValue(forKey: clipId); self.pendingKeys.removeValue(forKey: clipId)
                guard !(error is CancellationError) else { return }
                if self.failed.insert(key).inserted { self.onError?("\(asset.originalName): \(error.localizedDescription) Audio remains local to this project package.") }
            }
        }
    }
}
