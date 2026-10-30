import Foundation
import ScrivCore

/// Pointer movement is a local preview only. A finished/cancelled draft cannot
/// issue a second mutation, and exact source/context fences reject stale drags.
struct ImageDurationScrubDraft {
    let original: ImageCue
    let navigationContext: Int
    let projectRevision: Int?
    private(set) var proposedDurationMs: Int
    private(set) var finished = false
    static let millisecondsPerPoint: Double = 20
    static let minimumDurationMs = 1
    static let maximumDurationMs = 86_400_000
    init(cue: ImageCue, navigationContext: Int, projectRevision: Int? = nil) {
        original = cue; self.navigationContext = navigationContext; self.projectRevision = projectRevision
        proposedDurationMs = cue.authoredDurationMs ?? cue.durationMs
    }
    mutating func update(translationY: Double) {
        guard !finished, translationY.isFinite else { return }
        let value = Double(original.authoredDurationMs ?? original.durationMs) - translationY * Self.millisecondsPerPoint
        proposedDurationMs = Int(min(Double(Self.maximumDurationMs), max(Double(Self.minimumDurationMs), value)).rounded())
    }
    mutating func cancel() { finished = true }
    mutating func finish(currentCue: ImageCue?, navigation: Int, sceneID: String, projectRevision: Int? = nil) -> Int? {
        guard !finished else { return nil }; finished = true
        guard self.projectRevision == nil || self.projectRevision == projectRevision else { return nil }
        guard navigation == navigationContext, sceneID == original.sceneId, currentCue == original,
              proposedDurationMs != (original.authoredDurationMs ?? original.durationMs) else { return nil }
        return proposedDurationMs
    }
}

struct StoryboardWordTransfer: Codable {
    var type = "scriv.words.v2"
    let projectID: String
    let sceneID: String
    let navigation: Int
    let revision: Int
    let cueID: String
    let wordIDs: [String]
    func canApply(to project: ScrivProject, navigation: Int, destination: ImageCue) -> Bool {
        type == "scriv.words.v2" && self.navigation == navigation && projectID == project.id && sceneID == destination.sceneId
            && revision == project.revision && project.cues.first(where: { $0.id == destination.id }) == destination
            && project.cues.contains(where: { $0.id == cueID && $0.sceneId == sceneID })
            && !wordIDs.isEmpty && Set(wordIDs).count == wordIDs.count
    }
}
