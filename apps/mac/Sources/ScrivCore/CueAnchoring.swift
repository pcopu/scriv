import Foundation

/// Image coverage belongs to its authored start, never to a child it happens to cover.
/// Milliseconds are a resolved projection for playback and compatibility, not ownership.
public enum CueAnchoring {
    public static func anchor(atMs time: Int, in project: ScrivProject, sceneId: String) throws -> ScriptTimeAnchor {
        var start = 0
        for entry in project.entries(in: sceneId) {
            if time >= start && time < start + entry.ownedDurationMs { return ScriptTimeAnchor(entryId: entry.id, offsetMs: time - start) }
            start += entry.ownedDurationMs
        }
        throw ScrivError.invalid("An image must start inside an owned script slot.")
    }
    /// Legacy files migrate lazily, in the same transaction as the first timeline edit.
    public static func materialize(_ project: inout ScrivProject, sceneId: String) throws {
        for index in project.cues.indices where project.cues[index].sceneId == sceneId && project.cues[index].startAnchor == nil {
            project.cues[index].startAnchor = try anchor(atMs: project.cues[index].startMs, in: project, sceneId: sceneId)
            project.cues[index].authoredDurationMs = project.cues[index].durationMs
        }
    }
    public static func resolve(_ project: inout ScrivProject, sceneId: String) throws {
        let entries = project.entries(in: sceneId)
        var starts: [String: Int] = [:], clock = 0
        for entry in entries { starts[entry.id] = clock; clock += entry.ownedDurationMs }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in project.cues.indices where project.cues[index].sceneId == sceneId {
            guard let anchor = project.cues[index].startAnchor, let duration = project.cues[index].authoredDurationMs,
                  let start = starts[anchor.entryId], let entry = byID[anchor.entryId],
                  anchor.offsetMs >= 0, (anchor.offsetMs < entry.ownedDurationMs || entry.kind == .direction && entry.ownedDurationMs == 0 && anchor.offsetMs == 0), start + anchor.offsetMs <= clock, duration > 0, duration <= 86_400_000 else {
                throw ScrivError.invalid("Image timing has a missing or invalid script anchor.")
            }
            project.cues[index].startMs = start + anchor.offsetMs
            project.cues[index].endMs = min(clock, start + anchor.offsetMs + duration)
        }
    }
    static func validate(_ cue: ImageCue, project: ScrivProject, starts: [String: Int], entries: [String: ScriptEntry], sceneDuration: Int) throws {
        guard (cue.startAnchor == nil) == (cue.authoredDurationMs == nil) else { throw ScrivError.invalid("Image timing needs both its source anchor and authored extent.") }
        guard let anchor = cue.startAnchor, let duration = cue.authoredDurationMs else { return }
        guard let entry = entries[anchor.entryId], entry.sceneId == cue.sceneId, let start = starts[anchor.entryId],
              anchor.offsetMs >= 0, (anchor.offsetMs < entry.ownedDurationMs || entry.kind == .direction && entry.ownedDurationMs == 0 && anchor.offsetMs == 0), duration > 0, duration <= 86_400_000,
              cue.startMs == start + anchor.offsetMs, cue.endMs == min(sceneDuration, cue.startMs + duration) else {
            throw ScrivError.invalid("An image's resolved timing must match its source-owned script anchor.")
        }
    }
}

extension TimingEngine {
    /// Explicitly choose the source, including a zero-owned direction with forward coverage.
    public static func setCueAnchor(_ project: inout ScrivProject, cueId: String, entryId: String, offsetMs: Int = 0) throws {
        var next = project
        guard let index = next.cues.firstIndex(where: { $0.id == cueId }),
              let entry = next.entries.first(where: { $0.id == entryId }), entry.sceneId == next.cues[index].sceneId else {
            throw ScrivError.invalid("Choose an image and a source line in the same scene.")
        }
        let sceneId = entry.sceneId
        try CueAnchoring.materialize(&next, sceneId: sceneId)
        next.cues[index].startAnchor = ScriptTimeAnchor(entryId: entryId, offsetMs: offsetMs)
        try CueAnchoring.resolve(&next, sceneId: sceneId)
        try validate(next); project = next
    }
    /// Changing forward coverage changes this picture only; overlapping pictures remain intact.
    public static func setCueDuration(_ project: inout ScrivProject, cueId: String, durationMs: Int) throws {
        var next = project
        guard let index = next.cues.firstIndex(where: { $0.id == cueId }), durationMs > 0, durationMs <= 86_400_000 else {
            throw ScrivError.invalid("Image coverage must be positive and at most 24 hours.")
        }
        let sceneId = next.cues[index].sceneId
        try CueAnchoring.materialize(&next, sceneId: sceneId)
        next.cues[index].authoredDurationMs = durationMs
        try CueAnchoring.resolve(&next, sceneId: sceneId)
        try validate(next); project = next
    }
    public static func canMoveBoundary(_ project: ScrivProject, leftCueId: String, rightCueId: String) -> Bool {
        guard let left = project.cues.first(where: { $0.id == leftCueId }), let right = project.cues.first(where: { $0.id == rightCueId }),
              left.sceneId == right.sceneId, left.durationMs > 0, right.durationMs > 0, left.endMs == right.startMs,
              left.authoredDurationMs.map({ left.startMs + $0 == left.endMs }) ?? true,
              right.authoredDurationMs.map({ right.startMs + $0 == right.endMs }) ?? true else { return false }
        return !project.cues.contains { $0.sceneId == left.sceneId && $0.id != left.id && $0.id != right.id && $0.startMs < right.endMs && $0.endMs > left.startMs }
    }
}
