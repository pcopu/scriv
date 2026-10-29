import Foundation

public enum TimingEngine {
    /// Deterministic editorial timing. Existing IDs survive matched words; no speech-recognition accuracy is implied.
    public static func retimeWords(text: String, durationMs: Int, preserving old: [TimedWord] = []) -> [TimedWord] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let duration = max(durationMs, tokens.count)
        var matched: [Int: String] = [:]
        // LCS preserves the identity of repeated source words, unlike a dictionary keyed by text.
        if old.count * tokens.count <= 250_000 {
            var table = Array(repeating: Array(repeating: 0, count: tokens.count + 1), count: old.count + 1)
            if !old.isEmpty {
                for i in (0..<old.count).reversed() { for j in (0..<tokens.count).reversed() { table[i][j] = old[i].text == tokens[j] ? table[i+1][j+1]+1 : max(table[i+1][j], table[i][j+1]) } }
                var i = 0, j = 0
                while i < old.count && j < tokens.count { if old[i].text == tokens[j] { matched[j] = old[i].id; i += 1; j += 1 } else if table[i+1][j] >= table[i][j+1] { i += 1 } else { j += 1 } }
            }
        }
        let weights = tokens.map { max(1, $0.count) }
        let total = weights.reduce(0,+)
        let spare = max(0, duration - tokens.count)
        var consumed = 0
        return tokens.enumerated().map { index, token in
            let start = index + consumed * spare / total
            consumed += weights[index]
            let end = index + 1 + consumed * spare / total
            return TimedWord(id: matched[index] ?? UUID().uuidString, text: token, startMs: start, endMs: end)
        }
    }
    public static func validate(_ project: ScrivProject) throws {
        guard project.schemaVersion == 1 else { throw ScrivError.invalid("This project needs a newer version of Scriv.") }
        let ids = project.scenes.map(\.id) + project.entries.map(\.id) + project.characters.map(\.id) + project.images.map(\.id) + project.cues.map(\.id)
        guard Set(ids).count == ids.count else { throw ScrivError.invalid("Project contains duplicate item identities.") }
        let sceneIds = Set(project.scenes.map(\.id)), characterIds = Set(project.characters.map(\.id)), imageIds = Set(project.images.map(\.id))
        for entry in project.entries {
            guard sceneIds.contains(entry.sceneId), entry.order.isFinite, entry.ownedDurationMs >= (entry.kind == .dialogue ? 1 : 0), entry.ownedDurationMs <= 3_600_000 else { throw ScrivError.invalid("Invalid script timing or scene reference.") }
            if let id = entry.characterId, !characterIds.contains(id) { throw ScrivError.invalid("A speaker no longer exists.") }
            if entry.kind == .direction {
                guard entry.coverageDurationMs >= entry.ownedDurationMs, entry.coverageDurationMs <= 86_400_000, entry.words.isEmpty else { throw ScrivError.invalid("Direction coverage must extend forward beyond its owned time and contain no spoken words.") }
            } else {
                guard Set(entry.words.map(\.id)).count == entry.words.count, entry.words.map(\.text) == entry.text.split(whereSeparator: { $0.isWhitespace }).map(String.init) else { throw ScrivError.invalid("Word timing must preserve the script wording and order.") }
                var end = 0
                for word in entry.words {
                    guard word.startMs >= end, word.endMs > word.startMs, word.endMs <= entry.ownedDurationMs else { throw ScrivError.invalid("Spoken word times overlap or exceed their line.") }
                    end = word.endMs
                }
            }
        }
        for image in project.images {
            guard image.byteCount > 0, image.sha256.count == 64, image.sha256.allSatisfy({ $0.isHexDigit }), image.fileName == URL(fileURLWithPath: image.fileName).lastPathComponent, !image.fileName.contains(".."), image.characterIds.allSatisfy(characterIds.contains) else { throw ScrivError.invalid("Invalid image metadata or character tags.") }
        }
        for scene in project.scenes {
            var end = 0
            for cue in project.cues(in: scene.id) {
                guard cue.startMs >= end, cue.endMs > cue.startMs, cue.endMs <= project.durationMs(of: scene.id), cue.imageId == nil || imageIds.contains(cue.imageId!) else { throw ScrivError.invalid("Image cues must be ordered, non-overlapping, and inside the scene.") }
                end = cue.endMs
            }
        }
    }
    public static func updateText(_ project: inout ScrivProject, entryId: String, text: String) throws {
        guard let i = project.entries.firstIndex(where: { $0.id == entryId }) else { throw ScrivError.invalid("Line not found.") }
        let previous = project.entries[i].words
        project.entries[i].text = text
        if project.entries[i].kind == .dialogue {
            let count = text.split(whereSeparator: { $0.isWhitespace }).count
            if count > project.entries[i].ownedDurationMs { try setOwnedDuration(&project, entryId: entryId, durationMs: count) }
            project.entries[i].words = retimeWords(text: text, durationMs: project.entries[i].ownedDurationMs, preserving: previous)
        }
    }
    /// Resize an owned slot; map cues by anchored scene time so the image sequence follows the script.
    public static func setOwnedDuration(_ project: inout ScrivProject, entryId: String, durationMs: Int) throws {
        guard let i = project.entries.firstIndex(where: { $0.id == entryId }) else { throw ScrivError.invalid("Line not found.") }
        let entry = project.entries[i]
        let minimum = entry.kind == .dialogue ? max(1, entry.words.count) : 0
        guard durationMs >= minimum, durationMs <= 3_600_000 else { throw ScrivError.invalid("Duration must be between \(minimum)ms and one hour.") }
        let start = project.startMs(of: entry.id), oldEnd = start + entry.ownedDurationMs, delta = durationMs - entry.ownedDurationMs
        func mapped(_ time: Int) -> Int {
            if time <= start { return time }
            if time >= oldEnd { return time + delta }
            if entry.ownedDurationMs == 0 { return time + delta }
            return start + Int((Double(time - start) * Double(durationMs) / Double(entry.ownedDurationMs)).rounded())
        }
        // Coverage endpoints are absolute temporal anchors; changing their source slot remaps their length.
        for j in project.entries.indices where project.entries[j].sceneId == entry.sceneId && project.entries[j].kind == .direction {
            let source = project.startMs(of: project.entries[j].id)
            let oldCoverageEnd = source + project.entries[j].coverageDurationMs
            let newSource = project.entries[j].id == entryId ? start : mapped(source)
            project.entries[j].coverageDurationMs = max(project.entries[j].ownedDurationMs, mapped(oldCoverageEnd) - newSource)
        }
        project.entries[i].ownedDurationMs = durationMs
        if entry.kind == .dialogue { project.entries[i].words = retimeWords(text: entry.text, durationMs: durationMs, preserving: entry.words) }
        else { project.entries[i].coverageDurationMs = max(durationMs, project.entries[i].coverageDurationMs) }
        for j in project.cues.indices where project.cues[j].sceneId == entry.sceneId { project.cues[j].startMs = mapped(project.cues[j].startMs); project.cues[j].endMs = mapped(project.cues[j].endMs) }
        project.cues.removeAll { $0.endMs <= $0.startMs }
        try validate(project)
    }
    public static func setCoverage(_ project: inout ScrivProject, entryId: String, endMs: Int) throws {
        guard let i = project.entries.firstIndex(where: { $0.id == entryId }), project.entries[i].kind == .direction else { throw ScrivError.invalid("Only directions have coverage handles.") }
        let start = project.startMs(of: entryId), minimum = start + project.entries[i].ownedDurationMs
        guard endMs >= minimum, endMs - start <= 86_400_000 else { throw ScrivError.invalid("Direction coverage can only extend forward from its source.") }
        project.entries[i].coverageDurationMs = endMs - start
    }
    public static func moveBoundary(_ project: inout ScrivProject, leftCueId: String, rightCueId: String, toMs: Int) throws {
        guard let l = project.cues.firstIndex(where: { $0.id == leftCueId }), let r = project.cues.firstIndex(where: { $0.id == rightCueId }), project.cues[l].sceneId == project.cues[r].sceneId, project.cues[l].endMs == project.cues[r].startMs else { throw ScrivError.invalid("Only adjacent image cuts can share time.") }
        guard toMs > project.cues[l].startMs, toMs < project.cues[r].endMs else { throw ScrivError.invalid("Both images must retain positive duration.") }
        project.cues[l].endMs = toMs; project.cues[r].startMs = toMs
    }
    public static func moveWords(_ project: inout ScrivProject, wordIds: Set<String>, fromCueId: String, toCueId: String) throws {
        guard !wordIds.isEmpty, let from = project.cues.first(where: { $0.id == fromCueId }), let to = project.cues.first(where: { $0.id == toCueId }), from.sceneId == to.sceneId else { throw ScrivError.invalid("Choose words and a neighboring image.") }
        let words = absoluteWords(project, sceneId: from.sceneId)
        let selected = words.filter { wordIds.contains($0.id) }
        guard selected.count == wordIds.count, selected.allSatisfy({ $0.startMs >= from.startMs && $0.startMs < from.endMs }) else { throw ScrivError.invalid("All selected words must belong to the source image.") }
        let indices = words.indices.filter { wordIds.contains(words[$0].id) }
        guard let first = indices.first, let last = indices.last, last - first + 1 == indices.count else { throw ScrivError.invalid("Drag a contiguous phrase; source order is always preserved.") }
        if from.endMs == to.startMs { try moveBoundary(&project, leftCueId: from.id, rightCueId: to.id, toMs: selected.first!.startMs) }
        else if to.endMs == from.startMs { try moveBoundary(&project, leftCueId: to.id, rightCueId: from.id, toMs: selected.last!.endMs) }
        else { throw ScrivError.invalid("Words can move only to the previous or next image.") }
    }
    public static func absoluteWords(_ project: ScrivProject, sceneId: String) -> [TimedWord] {
        var clock = 0, result: [TimedWord] = []
        for entry in project.entries(in: sceneId) {
            result += entry.words.map { TimedWord(id: $0.id, text: $0.text, startMs: clock + $0.startMs, endMs: clock + $0.endMs) }
            clock += entry.ownedDurationMs
        }
        return result
    }
    public static func splitCue(_ project: inout ScrivProject, cueId: String, atMs: Int) throws {
        guard let i = project.cues.firstIndex(where: { $0.id == cueId }), atMs > project.cues[i].startMs, atMs < project.cues[i].endMs else { throw ScrivError.invalid("Place the playhead inside an image to split it.") }
        var next = project.cues[i]; next.id = UUID().uuidString; next.startMs = atMs; next.label += "B"
        project.cues[i].endMs = atMs; project.cues.append(next)
    }
}
