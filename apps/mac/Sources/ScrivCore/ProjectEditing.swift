import Foundation

/// Transactional editing operations shared by the script, storyboard and history UI.
/// Rejected edits leave the caller's document byte-for-byte unchanged.
public enum ProjectEditing {
    private static func edit(_ project: inout ScrivProject, _ operation: (inout ScrivProject) throws -> Void) throws {
        var next = project
        try operation(&next)
        try TimingEngine.validate(next)
        project = next
    }

    public static func insertEntry(_ project: inout ScrivProject, entry: ScriptEntry, after entryID: String? = nil) throws {
        try edit(&project) { next in
            guard next.scenes.contains(where: { $0.id == entry.sceneId }), !next.entries.contains(where: { $0.id == entry.id }) else { throw ScrivError.invalid("Choose an existing scene and a new line identity.") }
            var sequence = next.entries(in: entry.sceneId)
            let insertion: Int
            if let entryID {
                guard let index = sequence.firstIndex(where: { $0.id == entryID }) else { throw ScrivError.invalid("The insertion line no longer exists in this scene.") }
                insertion = index + 1
            } else { insertion = sequence.count }
            let start = sequence.prefix(insertion).reduce(0) { $0 + $1.ownedDurationMs }
            let oldDuration = next.durationMs(of: entry.sceneId)
            // Earlier coverage is anchored in scene time; later directions move as a whole.
            for index in next.entries.indices where next.entries[index].sceneId == entry.sceneId && next.entries[index].kind == .direction {
                let source = next.startMs(of: next.entries[index].id)
                let precedesInsertion = sequence.prefix(insertion).contains { $0.id == next.entries[index].id }
                if precedesInsertion && source + next.entries[index].coverageDurationMs > start {
                    next.entries[index].coverageDurationMs += entry.ownedDurationMs
                }
            }
            for index in next.cues.indices where next.cues[index].sceneId == entry.sceneId {
                if next.cues[index].startMs > start { next.cues[index].startMs += entry.ownedDurationMs }
                if next.cues[index].endMs > start || start == oldDuration && next.cues[index].endMs == start { next.cues[index].endMs += entry.ownedDurationMs }
            }
            sequence.insert(entry, at: insertion)
            next.entries.append(entry)
            assignOrder(in:&next,sequence:sequence,changedId:entry.id)
            if next.cues(in: entry.sceneId).isEmpty && entry.ownedDurationMs > 0 {
                next.cues.append(ImageCue(sceneId: entry.sceneId, label: "01A", startMs: 0, endMs: next.durationMs(of: entry.sceneId)))
            }
        }
    }

    public static func deleteEntry(_ project: inout ScrivProject, entryId: String) throws {
        try edit(&project) { next in
            guard let entry = next.entries.first(where: { $0.id == entryId }) else { throw ScrivError.invalid("Line not found.") }
            let start = next.startMs(of: entryId), end = start + entry.ownedDurationMs
            func mapped(_ time: Int) -> Int { time <= start ? time : time < end ? start : time - entry.ownedDurationMs }
            for index in next.entries.indices where next.entries[index].sceneId == entry.sceneId && next.entries[index].kind == .direction && next.entries[index].id != entryId {
                let source = next.startMs(of: next.entries[index].id)
                next.entries[index].coverageDurationMs = max(next.entries[index].ownedDurationMs, mapped(source + next.entries[index].coverageDurationMs) - mapped(source))
            }
            for index in next.cues.indices where next.cues[index].sceneId == entry.sceneId {
                next.cues[index].startMs = mapped(next.cues[index].startMs)
                next.cues[index].endMs = mapped(next.cues[index].endMs)
            }
            next.cues.removeAll { $0.endMs <= $0.startMs }
            next.entries.removeAll { $0.id == entryId }
            next.audioClips.removeAll { $0.entryId == entryId }
        }
    }

    public static func moveEntry(_ project: inout ScrivProject, entryId: String, offset: Int) throws {
        try edit(&project) { next in
            guard let entry = next.entries.first(where: { $0.id == entryId }) else { throw ScrivError.invalid("Line not found.") }
            var sequence = next.entries(in: entry.sceneId)
            guard let index = sequence.firstIndex(where: { $0.id == entryId }), offset >= -index, offset < sequence.count - index else { throw ScrivError.invalid("This line cannot move beyond its scene.") }
            guard offset != 0 else { return }
            sequence.insert(sequence.remove(at:index),at:index + offset)
            assignOrder(in:&next,sequence:sequence,changedId:entryId)
            // Images stay on the scene clock; direction anchors and their coverage move
            // with the authored source. No spoken word is rewritten or retimed.
        }
    }

    public static func deleteScene(_ project: inout ScrivProject, sceneId: String) throws {
        try edit(&project) { next in
            guard next.scenes.contains(where: { $0.id == sceneId }) else { throw ScrivError.invalid("Scene not found.") }
            next.scenes.removeAll { $0.id == sceneId }
            next.entries.removeAll { $0.sceneId == sceneId }
            next.cues.removeAll { $0.sceneId == sceneId }
            next.audioClips.removeAll { $0.sceneId == sceneId }
            // Assets and character profiles survive so history and galleries keep their identities.
        }
    }

    /// Fill the gap containing the playhead, or split the existing cue at that point.
    @discardableResult
    public static func addCue(_ project: inout ScrivProject, sceneId: String, atMs: Int) throws -> String {
        let id = UUID().uuidString
        try edit(&project) { next in
            let duration = next.durationMs(of: sceneId)
            guard atMs >= 0, atMs < duration else { throw ScrivError.invalid("Place the playhead inside a scene with positive duration.") }
            let cues = next.cues(in: sceneId)
            if let existing = cues.first(where: { atMs >= $0.startMs && atMs < $0.endMs }) {
                guard atMs > existing.startMs else { throw ScrivError.invalid("Move inside the image before adding a cut.") }
                let index = next.cues.firstIndex { $0.id == existing.id }!
                next.cues[index].endMs = atMs
                var split = existing; split.id = id; split.startMs = atMs; split.label = uniqueCueLabel(in: next, base: existing.label)
                next.cues.append(split)
            } else {
                let start = cues.last(where: { $0.endMs <= atMs })?.endMs ?? 0
                let end = cues.first(where: { $0.startMs > atMs })?.startMs ?? duration
                next.cues.append(ImageCue(id: id, sceneId: sceneId, label: uniqueCueLabel(in: next, base: "Image"), startMs: start, endMs: end))
            }
        }
        return id
    }
    public static func deleteCue(_ project: inout ScrivProject, cueId: String) throws {
        try edit(&project) { next in
            guard next.cues.contains(where: { $0.id == cueId }) else { throw ScrivError.invalid("Image cue not found.") }
            next.cues.removeAll { $0.id == cueId }
        }
    }
    /// The left cue keeps its image/version; all script words and total scene time stay fixed.
    public static func mergeCues(_ project: inout ScrivProject, leftCueId: String, rightCueId: String) throws {
        try edit(&project) { next in
            guard let left = next.cues.firstIndex(where: { $0.id == leftCueId }), let right = next.cues.first(where: { $0.id == rightCueId }), next.cues[left].sceneId == right.sceneId, next.cues[left].endMs == right.startMs else { throw ScrivError.invalid("Only neighboring image cues can be merged.") }
            next.cues[left].endMs = right.endMs
            next.cues.removeAll { $0.id == rightCueId }
        }
    }
    public static func setCueImage(_ project: inout ScrivProject, cueId: String, imageId: String?) throws {
        try edit(&project) { next in
            guard let index = next.cues.firstIndex(where: { $0.id == cueId }) else { throw ScrivError.invalid("Image cue not found.") }
            next.cues[index].imageId = imageId
        }
    }
    public static func setPortrait(_ project: inout ScrivProject, characterId: String, imageId: String?) throws {
        try edit(&project) { next in
            guard let index = next.characters.firstIndex(where: { $0.id == characterId }) else { throw ScrivError.invalid("Character not found.") }
            next.characters[index].portraitImageId = imageId
            if let imageId, let image = next.images.firstIndex(where: { $0.id == imageId }), !next.images[image].characterIds.contains(characterId) { next.images[image].characterIds.append(characterId) }
        }
    }
    public static func imageVersions(in project: ScrivProject, imageId: String) -> [ImageAsset] {
        let byID = Dictionary(project.images.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func root(_ image: ImageAsset) -> String {
            var current = image, seen: Set<String> = [image.id]
            while let previous = current.previousVersionId, let parent = byID[previous], seen.insert(previous).inserted { current = parent }
            return current.id
        }
        guard let selected = byID[imageId] else { return [] }
        let lineage = root(selected)
        return project.images.filter { root($0) == lineage }.sorted { ($0.version, $0.createdAt, $0.id) > ($1.version, $1.createdAt, $1.id) }
    }
    /// Most edits change only the moved item's order, keeping independent cloud
    /// leases and the 100-operation command budget intact. Normalize only if
    /// repeated insertions exhausted representable space between neighbors.
    private static func assignOrder(in project: inout ScrivProject, sequence: [ScriptEntry], changedId: String) {
        guard let target = sequence.firstIndex(where: { $0.id == changedId }), let stored = project.entries.firstIndex(where: { $0.id == changedId }) else { return }
        let lower = target > 0 ? sequence[target-1].order : nil
        let upper = target+1 < sequence.count ? sequence[target+1].order : nil
        let candidate: Double
        if let lower, let upper { candidate = lower/2 + upper/2 }
        else if let lower { candidate = lower+1 > lower ? lower+1 : lower.nextUp }
        else if let upper { candidate = upper-1 < upper ? upper-1 : upper.nextDown }
        else { candidate = 0 }
        if candidate.isFinite, lower.map({ candidate > $0 }) ?? true, upper.map({ candidate < $0 }) ?? true {
            project.entries[stored].order = candidate
        } else {
            let orders = Dictionary(uniqueKeysWithValues:sequence.enumerated().map { ($0.element.id,Double($0.offset)) })
            for index in project.entries.indices { if let order = orders[project.entries[index].id] { project.entries[index].order = order } }
        }
    }
    private static func uniqueCueLabel(in project: ScrivProject, base: String) -> String {
        let labels = Set(project.cues.map(\.label)); var suffix = 2
        while labels.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }
}
