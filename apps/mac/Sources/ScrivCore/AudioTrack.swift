import Foundation

/// Immutable local audio bytes. Audio is packaged with the project, not uploaded by
/// the image-only cloud media protocol. Waveform values are peaks of decoded PCM.
public struct AudioAsset: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var fileName: String
    public var sha256: String
    public var byteCount: Int
    public var durationMs: Int
    public var sampleRate: Double
    public var channelCount: Int
    public var waveform: [Float]
    public var originalName: String
    public init(id: String = UUID().uuidString, fileName: String, sha256: String, byteCount: Int, durationMs: Int, sampleRate: Double, channelCount: Int, waveform: [Float], originalName: String) {
        self.id = id; self.fileName = fileName; self.sha256 = sha256; self.byteCount = byteCount
        self.durationMs = durationMs; self.sampleRate = sampleRate; self.channelCount = channelCount
        self.waveform = waveform; self.originalName = originalName
    }
}

public struct AudioClip: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sceneId: String
    /// When present, startMs is relative to this entry, so speech follows script reordering.
    public var entryId: String?
    public var assetId: String
    public var startMs: Int
    public var sourceStartMs: Int
    public var durationMs: Int
    public var volume: Double
    public var isMuted: Bool
    public init(id: String = UUID().uuidString, sceneId: String, entryId: String? = nil, assetId: String, startMs: Int = 0, sourceStartMs: Int = 0, durationMs: Int, volume: Double = 1, isMuted: Bool = false) {
        self.id = id; self.sceneId = sceneId; self.entryId = entryId; self.assetId = assetId
        self.startMs = startMs; self.sourceStartMs = sourceStartMs; self.durationMs = durationMs
        self.volume = volume; self.isMuted = isMuted
    }
}

public struct AudioPlacement: Identifiable, Hashable, Sendable {
    public var id: String { clipId }
    public var clipId: String
    public var assetId: String
    public var startMs: Int
    public var endMs: Int
    public var sourceStartMs: Int
    public var durationMs: Int { endMs - startMs }
    public func sourcePosition(at playheadMs: Int) -> Int? {
        guard playheadMs >= startMs, playheadMs < endMs else { return nil }
        return sourceStartMs + playheadMs - startMs
    }
}

public enum AudioTimeline {
    public static let maximumFileBytes = 100 * 1024 * 1024
    public static let maximumDurationMs = 30 * 60 * 1000
    public static let supportedExtensions: Set<String> = ["wav", "aif", "aiff", "m4a", "mp3", "caf", "aac", "flac"]

    public static func placements(project: ScrivProject, sceneId: String) -> [AudioPlacement] {
        let sceneDuration = project.durationMs(of: sceneId)
        return project.audioClips.compactMap { clip in
            guard clip.sceneId == sceneId, let asset = project.audioAssets.first(where: { $0.id == clip.assetId }),
                  clip.startMs >= 0, clip.sourceStartMs >= 0, clip.durationMs > 0,
                  clip.sourceStartMs < asset.durationMs else { return nil }
            var base = 0
            if let entryId = clip.entryId {
                guard let entry = project.entries.first(where: { $0.id == entryId && $0.sceneId == sceneId }) else { return nil }
                base = project.startMs(of: entry.id)
            }
            let (start, overflow) = base.addingReportingOverflow(clip.startMs)
            guard !overflow, start < sceneDuration else { return nil }
            let duration = min(clip.durationMs, asset.durationMs - clip.sourceStartMs, sceneDuration - start)
            guard duration > 0 else { return nil }
            return AudioPlacement(clipId: clip.id, assetId: clip.assetId, startMs: start, endMs: start + duration, sourceStartMs: clip.sourceStartMs)
        }.sorted { ($0.startMs, $0.clipId) < ($1.startMs, $1.clipId) }
    }

    /// Crops/resamples measured source peaks; silence stays silent and is never decorative noise.
    public static func waveform(for placement: AudioPlacement, asset: AudioAsset, bins requestedBins: Int = 128) -> [Float] {
        guard asset.durationMs > 0, !asset.waveform.isEmpty, placement.durationMs > 0,
              placement.sourceStartMs >= 0, placement.sourceStartMs < asset.durationMs,
              placement.durationMs <= asset.durationMs - placement.sourceStartMs else { return [] }
        let bins = min(2048, max(1, requestedBins)), sourceCount = asset.waveform.count
        return (0..<bins).map { index in
            let begin = Double(placement.sourceStartMs) + Double(placement.durationMs) * Double(index) / Double(bins)
            let end = Double(placement.sourceStartMs) + Double(placement.durationMs) * Double(index + 1) / Double(bins)
            let low = min(sourceCount - 1, max(0, Int(floor(begin / Double(asset.durationMs) * Double(sourceCount)))))
            let high = min(sourceCount, max(low + 1, Int(ceil(end / Double(asset.durationMs) * Double(sourceCount)))))
            return asset.waveform[low..<high].filter(\.isFinite).map { min(1, max(0, $0)) }.max() ?? 0
        }
    }

    public static func validate(_ project: ScrivProject) throws {
        try validate(assets: project.audioAssets, clips: project.audioClips, scenes: project.scenes, entries: project.entries, volume: project.audioVolume)
    }

    public static func validate(assets: [AudioAsset], clips: [AudioClip], scenes: [ScriptScene], entries: [ScriptEntry], volume: Double) throws {
        guard volume.isFinite, (0...1).contains(volume), assets.count <= 512, clips.count <= 2048,
              Set(assets.map(\.id)).count == assets.count, Set(clips.map(\.id)).count == clips.count else {
            throw ScrivError.invalid("Audio metadata has invalid volume, duplicate IDs or too many clips.")
        }
        for asset in assets {
            let ext = URL(fileURLWithPath: asset.fileName).pathExtension.lowercased()
            guard !asset.id.isEmpty, asset.sha256.count == 64, asset.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  supportedExtensions.contains(ext), asset.fileName == asset.sha256 + "." + ext,
                  asset.byteCount > 0, asset.byteCount <= maximumFileBytes,
                  asset.durationMs > 0, asset.durationMs <= maximumDurationMs,
                  asset.sampleRate.isFinite, (1...192_000).contains(asset.sampleRate), (1...8).contains(asset.channelCount),
                  !asset.waveform.isEmpty, asset.waveform.count <= 2048,
                  asset.waveform.allSatisfy({ $0.isFinite && (0...1).contains($0) }), asset.originalName.count <= 256 else {
                throw ScrivError.invalid("An audio asset has invalid timing, waveform or content-addressed file metadata.")
            }
        }
        for clip in clips {
            guard !clip.id.isEmpty, scenes.contains(where: { $0.id == clip.sceneId }),
                  let asset = assets.first(where: { $0.id == clip.assetId }),
                  clip.entryId == nil || entries.contains(where: { $0.id == clip.entryId && $0.sceneId == clip.sceneId }),
                  (0...86_400_000).contains(clip.startMs), clip.sourceStartMs >= 0, clip.sourceStartMs < asset.durationMs,
                  clip.durationMs > 0, clip.durationMs <= asset.durationMs - clip.sourceStartMs,
                  clip.volume.isFinite, (0...1).contains(clip.volume) else {
                throw ScrivError.invalid("An audio clip has an invalid source, entry, trim or volume.")
            }
        }
    }
}

/// Incremental extraction keeps long files bounded to a fixed number of peaks.
public struct AudioWaveformAccumulator: Sendable {
    public private(set) var peaks: [Float]
    private let totalFrames: Int64
    public init(totalFrames: Int64, bins: Int = 512) {
        self.totalFrames = max(1, totalFrames)
        self.peaks = Array(repeating: 0, count: min(2048, max(1, bins)))
    }
    public mutating func add(peak: Float, atFrame frame: Int64) {
        guard frame >= 0, frame < totalFrames, peak.isFinite else { return }
        let index = min(peaks.count - 1, Int(Double(frame) / Double(totalFrames) * Double(peaks.count)))
        peaks[index] = max(peaks[index], min(1, abs(peak)))
    }
}
