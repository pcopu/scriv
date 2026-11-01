import Foundation

/// Capture the destination before opening a picker or awaiting file I/O. A
/// missing cue means a new source-owned placement, never an unattached import
/// followed by a fallback to an unrelated picture.
public struct ImageImportPlacement: Equatable, Sendable {
    public let projectID: String
    public let sceneID: String
    public let existingCue: ImageCue?
    public let sourceEntry: ScriptEntry?
    public let newCueID: String
    public let anchor: ScriptTimeAnchor?
    public let durationMs: Int
    private let capturedCues: [ImageCue]

    public init(project: ScrivProject, cueID: String?, sceneID: String, entryID: String?, atMs: Int, newCueID: String = UUID().uuidString) throws {
        projectID = project.id; self.sceneID = sceneID; self.newCueID = newCueID
        capturedCues = project.cues(in: sceneID)
        if let cueID {
            guard let cue = project.cues.first(where: { $0.id == cueID && $0.sceneId == sceneID }) else { throw ScrivError.invalid("The target picture placement no longer exists.") }
            existingCue = cue; sourceEntry = nil; anchor = nil; durationMs = 0
        } else {
            existingCue = nil
            guard let entry = project.entries.first(where: { $0.id == entryID && $0.sceneId == sceneID }) ?? project.activeEntry(at: atMs, sceneId: sceneID) else { throw ScrivError.invalid("Choose a script line before importing a picture.") }
            sourceEntry = entry
            let start = project.startMs(of: entry.id)
            let offset = atMs >= start && atMs < start + entry.ownedDurationMs ? atMs - start : 0
            anchor = ScriptTimeAnchor(entryId: entry.id, offsetMs: offset)
            // Stop at the next existing start by default; never move that start
            // or shorten any existing authored coverage.
            let available = max(0, project.durationMs(of: sceneID) - start - offset)
            let nextStart = project.cues(in: sceneID).filter { $0.startMs > start + offset }.map(\.startMs).min()
            let extent = max(entry.ownedDurationMs - offset, entry.kind == .direction ? entry.coverageDurationMs - offset : 0)
            durationMs = min(min(max(1, extent), max(1, available)), nextStart.map { $0 - start - offset } ?? max(1, available))
        }
    }

    public func isCurrent(in project: ScrivProject) -> Bool {
        guard project.id == projectID, project.scenes.contains(where: { $0.id == sceneID }) else { return false }
        if let existingCue { return project.cues.first(where: { $0.id == existingCue.id }) == existingCue }
        guard project.cues(in: sceneID) == capturedCues else { return false }
        return sourceEntry.map { original in project.entries.first(where: { $0.id == original.id }) == original } ?? false
    }

    @discardableResult public func attach(imageID: String, to project: inout ScrivProject) throws -> String {
        guard isCurrent(in: project), project.asset(imageID) != nil else { throw ScrivError.conflict("The import destination changed. The image was not placed.") }
        if let existingCue {
            try ProjectEditing.setCueImage(&project, cueId: existingCue.id, imageId: imageID)
            return existingCue.id
        }
        guard let anchor else { throw ScrivError.invalid("Choose a source line for this picture.") }
        var next = project
        let start = next.startMs(of: anchor.entryId) + anchor.offsetMs
        next.cues.append(ImageCue(id: newCueID, sceneId: sceneID, imageId: imageID, label: "Image \(next.cues(in: sceneID).count + 1)", startMs: start, endMs: min(next.durationMs(of: sceneID), start + durationMs), startAnchor: anchor, authoredDurationMs: durationMs))
        try TimingEngine.validate(next); project = next
        return newCueID
    }
}
