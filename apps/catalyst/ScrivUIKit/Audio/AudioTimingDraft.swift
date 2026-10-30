import Foundation
import ScrivCore

/// Millisecond precision with bounded conversion. Invalid text stays in the UI
/// until corrected; parsing never silently clamps or replaces an invalid draft.
enum AudioTimingInput {
    static func milliseconds(_ text: String, maximum: Int) -> Int? {
        guard maximum >= 0, let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite, seconds >= 0, seconds <= Double(maximum) / 1000 else { return nil }
        let milliseconds = (seconds * 1000).rounded()
        guard milliseconds.isFinite, milliseconds < Double(Int.max) else { return nil }
        let result = Int(milliseconds)
        return result <= maximum ? result : nil
    }
    static func seconds(_ milliseconds: Int) -> String { String(format: "%.3f", Double(milliseconds) / 1000) }
}

struct AudioClipTimingDraft {
    let original: AudioClip
    var entryID: String?
    var offset: String
    var source: String
    var duration: String
    init(clip: AudioClip) {
        original = clip; entryID = clip.entryId
        offset = AudioTimingInput.seconds(clip.startMs)
        source = AudioTimingInput.seconds(clip.sourceStartMs)
        duration = AudioTimingInput.seconds(clip.durationMs)
    }
    func trim(asset: AudioAsset) -> ClosedRange<Int>? {
        guard let start = AudioTimingInput.milliseconds(source, maximum: asset.durationMs),
              let length = AudioTimingInput.milliseconds(duration, maximum: asset.durationMs), length > 0,
              start < asset.durationMs, length <= asset.durationMs - start else { return nil }
        return start...(start + length)
    }
    func sceneStart(project: ScrivProject) -> Int? {
        guard let position = AudioTimingInput.milliseconds(offset, maximum: 86_400_000) else { return nil }
        return (entryID.map { project.startMs(of: $0) } ?? 0) + position
    }
    /// Returns true only if a negative offset had to move to the new line start.
    mutating func attach(to id: String?, project: ScrivProject) throws -> Bool {
        guard let absolute = sceneStart(project: project) else {
            throw ScrivError.invalid("Enter a valid placement offset before changing which line this clip follows.")
        }
        if let id, !project.entries.contains(where: { $0.id == id && $0.sceneId == original.sceneId }) {
            throw ScrivError.invalid("The selected line is no longer in this scene.")
        }
        let base = id.map { project.startMs(of: $0) } ?? 0
        entryID = id; offset = AudioTimingInput.seconds(max(0, absolute - base))
        return absolute < base
    }
    mutating func setTrim(_ range: ClosedRange<Int>) {
        source = AudioTimingInput.seconds(range.lowerBound)
        duration = AudioTimingInput.seconds(range.upperBound - range.lowerBound)
    }
    func applying(to project: ScrivProject) throws -> AudioClip {
        guard let current = project.audioClips.first(where: { $0.id == original.id }), current == original else {
            throw ScrivError.conflict("This clip changed while the editor was open. Cancel and reopen Trim & timing to review its current placement.")
        }
        guard let asset = project.audioAssets.first(where: { $0.id == original.assetId }),
              let range = trim(asset: asset), let start = AudioTimingInput.milliseconds(offset, maximum: 86_400_000) else {
            throw ScrivError.invalid("Use nonnegative times and a positive duration that fits inside the source recording. Source in and duration trim the recording; the placement offset sets where it plays in the scene.")
        }
        var result = original
        result.entryId = entryID; result.startMs = start
        result.sourceStartMs = range.lowerBound; result.durationMs = range.upperBound - range.lowerBound
        // Validate the final project without changing the original or its audio bytes.
        var candidate = project
        guard let index = candidate.audioClips.firstIndex(where: { $0.id == original.id }) else { throw ScrivError.invalid("This audio clip no longer exists.") }
        candidate.audioClips[index] = result
        try AudioTimeline.validate(candidate)
        return result
    }
}

struct ManualWordTimingDraft {
    struct Times: Equatable {
        var start: String
        var end: String
        init(word: TimedWord) { start = AudioTimingInput.seconds(word.startMs); end = AudioTimingInput.seconds(word.endMs) }
        func range(maximum: Int) -> ClosedRange<Int>? {
            guard let start = AudioTimingInput.milliseconds(start, maximum: maximum),
                  let end = AudioTimingInput.milliseconds(end, maximum: maximum), end > start else { return nil }
            return start...end
        }
    }
    let original: ScriptEntry
    var selectedWordID: String
    var times: [String: Times]
    init(entry: ScriptEntry, wordID: String) {
        original = entry; selectedWordID = wordID
        times = Dictionary(uniqueKeysWithValues: entry.words.map { ($0.id, Times(word: $0)) })
    }
    var previewWords: [TimedWord] {
        original.words.compactMap { word in
            guard let range = times[word.id]?.range(maximum: original.ownedDurationMs) else { return nil }
            var result = word; result.startMs = range.lowerBound; result.endMs = range.upperBound
            return result
        }
    }
    mutating func setSelectedRange(_ range: ClosedRange<Int>) {
        guard var value = times[selectedWordID] else { return }
        value.start = AudioTimingInput.seconds(range.lowerBound); value.end = AudioTimingInput.seconds(range.upperBound)
        times[selectedWordID] = value
    }
    func updatedWords(current: ScriptEntry) throws -> [TimedWord] {
        guard current.id == original.id, current.sceneId == original.sceneId,
              current.kind == .dialogue, current.words == original.words,
              current.ownedDurationMs == original.ownedDurationMs else {
            throw ScrivError.conflict("This dialogue changed while the editor was open. Cancel and reopen Word timing to review its current words and timing.")
        }
        var result: [TimedWord] = []
        for word in original.words {
            let label = String(word.text.prefix(70))
            guard let range = times[word.id]?.range(maximum: original.ownedDurationMs) else {
                throw ScrivError.invalid("Enter a start and end for “\(label)” within this dialogue, with end after start. Times are in seconds.")
            }
            if let previous = result.last, previous.endMs > range.lowerBound {
                throw ScrivError.invalid("“\(label)” would overlap “\(String(previous.text.prefix(70)))”. Shorten the previous word’s end or move this word’s start later. Select either word above to adjust it; all changes save together.")
            }
            var changed = word; changed.startMs = range.lowerBound; changed.endMs = range.upperBound
            if changed.startMs != word.startMs || changed.endMs != word.endMs { changed.timingSource = .authored }
            result.append(changed)
        }
        return result
    }
}
