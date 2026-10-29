import Foundation

extension TimingEngine {
    /// A deliberate local history restore is a new authored edit, not an old-client metadata downgrade.
    public static func prepareRestoredTiming(_ project: inout ScrivProject, replacing current: ScrivProject) throws {
        var next = project
        let authoredIDs = Set(current.entries.flatMap(\.words).filter { $0.timingSource == .authored }.map(\.id))
        for entryIndex in next.entries.indices {
            for wordIndex in next.entries[entryIndex].words.indices where authoredIDs.contains(next.entries[entryIndex].words[wordIndex].id) {
                next.entries[entryIndex].words[wordIndex].timingSource = .authored
            }
        }
        for scene in next.scenes { try CueAnchoring.materialize(&next, sceneId: scene.id) }
        try validate(next); project = next
    }

    /// Edits actual spoken-word metadata, not image assignments. No audio alignment is implied.
    public static func setWordTiming(_ project: inout ScrivProject, wordId: String, startMs: Int, endMs: Int) throws {
        var next = project
        guard let entryIndex = next.entries.firstIndex(where: { $0.words.contains { $0.id == wordId } }),
              let wordIndex = next.entries[entryIndex].words.firstIndex(where: { $0.id == wordId }) else {
            throw ScrivError.invalid("The selected word no longer exists.")
        }
        let entry = next.entries[entryIndex]
        let lower = wordIndex == 0 ? 0 : entry.words[wordIndex - 1].endMs
        let upper = wordIndex + 1 == entry.words.count ? entry.ownedDurationMs : entry.words[wordIndex + 1].startMs
        guard startMs >= lower, endMs > startMs, endMs <= upper else {
            throw ScrivError.invalid("Keep this word inside its line and between neighboring words (\(lower)–\(upper)ms). Adjust a neighbor first to make room.")
        }
        next.entries[entryIndex].words[wordIndex].startMs = startMs
        next.entries[entryIndex].words[wordIndex].endMs = endMs
        next.entries[entryIndex].words[wordIndex].timingSource = .authored
        try validate(next)
        project = next
    }

    /// Move one word or a contiguous phrase through available silence without changing image cuts.
    public static func shiftWords(_ project: inout ScrivProject, wordIds: Set<String>, byMs: Int) throws {
        var next = project
        guard !wordIds.isEmpty, let entryIndex = next.entries.firstIndex(where: { $0.words.contains { wordIds.contains($0.id) } }) else {
            throw ScrivError.invalid("Select a word or phrase to retime.")
        }
        let entry = next.entries[entryIndex]
        let indices = entry.words.indices.filter { wordIds.contains(entry.words[$0].id) }
        guard indices.count == wordIds.count, let first = indices.first, let last = indices.last, last - first + 1 == indices.count else {
            throw ScrivError.invalid("Retime a contiguous phrase within one line; source wording and order stay fixed.")
        }
        let lower = first == 0 ? 0 : entry.words[first - 1].endMs
        let upper = last + 1 == entry.words.count ? entry.ownedDurationMs : entry.words[last + 1].startMs
        guard byMs >= lower - entry.words[first].startMs, byMs <= upper - entry.words[last].endMs else {
            throw ScrivError.invalid("This phrase would cross another word or leave its line. Shorten a word or adjust neighboring timing to make room.")
        }
        for index in indices {
            next.entries[entryIndex].words[index].startMs += byMs
            next.entries[entryIndex].words[index].endMs += byMs
            next.entries[entryIndex].words[index].timingSource = .authored
        }
        try validate(next)
        project = next
    }

    /// Re-estimate only unpinned spans. User-authored word endpoints are never silently overwritten.
    static func retimePreservingAuthored(text: String, durationMs: Int, preserving old: [TimedWord]) throws -> [TimedWord] {
        var result = retimeWords(text: text, durationMs: durationMs, preserving: old)
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in result.indices {
            if let prior = oldByID[result[index].id], prior.timingSource == .authored { result[index] = prior }
        }
        let pins = result.indices.filter { result[$0].timingSource == .authored }
        guard !pins.isEmpty else { return result }
        var nextIndex = 0, lower = 0
        for pin in pins + [result.count] {
            let upper = pin < result.count ? result[pin].startMs : durationMs
            let count = pin - nextIndex
            guard upper >= lower, upper - lower >= count,
                  pin == result.count || result[pin].endMs <= durationMs else {
                throw ScrivError.invalid("This edit would overwrite authored word timing. Adjust word times or increase the line duration first.")
            }
            if count > 0 {
                let span = Array(result[nextIndex..<pin])
                let estimated = retimeWords(text: span.map(\.text).joined(separator: " "), durationMs: upper - lower, preserving: span)
                for offset in estimated.indices {
                    result[nextIndex + offset] = TimedWord(id: span[offset].id, text: span[offset].text, startMs: lower + estimated[offset].startMs, endMs: lower + estimated[offset].endMs)
                }
            }
            if pin < result.count { lower = result[pin].endMs; nextIndex = pin + 1 }
        }
        return result
    }
}
