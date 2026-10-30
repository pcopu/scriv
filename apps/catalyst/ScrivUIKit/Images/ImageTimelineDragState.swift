import Foundation
import ScrivCore

struct ImageTimelineDragDraft {
    enum Mode { case offset, coverage }
    enum Commit: Equatable { case offset(entryID: String, milliseconds: Int), coverage(milliseconds: Int) }
    let mode: Mode
    let original: ImageCue
    let source: ScriptEntry
    let originalAnchor: ScriptTimeAnchor
    let sourceStartMs: Int
    let sceneDurationMs: Int
    let projectID: String
    let revision: Int
    let navigation: Int
    let snapTimes: [Int]
    private(set) var offsetMs: Int
    private(set) var authoredDurationMs: Int
    private(set) var atOwnerBoundary = false
    private(set) var finished = false
    var previewStartMs: Int { sourceStartMs + offsetMs }
    var previewEndMs: Int { min(sceneDurationMs, previewStartMs + authoredDurationMs) }
    var hasClippedTail: Bool { previewStartMs + authoredDurationMs > sceneDurationMs }
    var maximumOffsetMs: Int { max(0, source.ownedDurationMs - 1) }

    init(project: ScrivProject, cueID: String, mode: Mode, navigation: Int) throws {
        guard let cue = project.cues.first(where: { $0.id == cueID }) else { throw ScrivError.invalid("This picture no longer exists.") }
        let anchor = try cue.startAnchor ?? CueAnchoring.anchor(atMs: cue.startMs, in: project, sceneId: cue.sceneId)
        guard let source = project.entries.first(where: { $0.id == anchor.entryId && $0.sceneId == cue.sceneId }) else { throw ScrivError.invalid("Choose this picture’s source before moving its offset.") }
        self.mode = mode; original = cue; self.source = source; originalAnchor = anchor
        sourceStartMs = project.startMs(of: source.id); sceneDurationMs = project.durationMs(of: cue.sceneId)
        projectID = project.id; revision = project.revision; self.navigation = navigation
        offsetMs = anchor.offsetMs; authoredDurationMs = cue.authoredDurationMs ?? cue.durationMs
        let words = TimingEngine.absoluteWords(project, sceneId: cue.sceneId)
        snapTimes = Array(Set([sourceStartMs, sceneDurationMs] + project.entries(in: cue.sceneId).map { project.startMs(of: $0.id) } + words.flatMap { [$0.startMs, $0.endMs] })).sorted()
    }
    struct Geometry: Equatable {
        let startX: Double
        let visibleWidth: Double
        let authoredWidth: Double
        let ownerStartX: Double
        let ownerWidth: Double
    }
    func geometry(pointsPerMillisecond scale: Double, origin: Double = 70) -> Geometry {
        Geometry(startX: origin + Double(previewStartMs) * scale,
                 visibleWidth: max(3, Double(max(0, previewEndMs - previewStartMs)) * scale - 2),
                 authoredWidth: max(3, Double(authoredDurationMs) * scale - 2),
                 ownerStartX: origin + Double(sourceStartMs) * scale,
                 ownerWidth: max(3, Double(source.ownedDurationMs) * scale))
    }
    mutating func update(translationX: Double, pointsPerMillisecond: Double, snapping: Bool) {
        guard !finished, translationX.isFinite, pointsPerMillisecond.isFinite, pointsPerMillisecond > 0 else { return }
        let delta = translationX / pointsPerMillisecond
        let threshold = min(300, max(1, Int(min(300, 7 / pointsPerMillisecond))))
        switch mode {
        case .offset:
            let proposed = Double(originalAnchor.offsetMs) + delta
            atOwnerBoundary = proposed < 0 || proposed > Double(maximumOffsetMs)
            var clamped = Int(min(Double(maximumOffsetMs), max(0, proposed)).rounded())
            if snapping, !atOwnerBoundary {
                let candidates = snapTimes.filter { $0 >= sourceStartMs && $0 <= sourceStartMs + maximumOffsetMs }
                clamped = nearest(sourceStartMs + clamped, in: candidates, threshold: threshold) - sourceStartMs
            }
            offsetMs = clamped
        case .coverage:
            let proposed = Double(original.authoredDurationMs ?? original.durationMs) + delta
            var duration = Int(min(86_400_000, max(1, proposed)).rounded())
            if snapping { duration = max(1, nearest(original.startMs + duration, in: snapTimes.filter { $0 > original.startMs }, threshold: threshold) - original.startMs) }
            authoredDurationMs = duration
        }
    }
    func isCurrent(project: ScrivProject, navigation: Int, sceneID: String) -> Bool {
        project.id == projectID && project.revision == revision && navigation == self.navigation && sceneID == original.sceneId
            && project.cues.first(where: { $0.id == original.id }) == original
            && project.entries.first(where: { $0.id == source.id }) == source
    }
    mutating func cancel() { finished = true }
    mutating func finish(project: ScrivProject, navigation: Int, sceneID: String) -> Commit? {
        guard !finished else { return nil }; finished = true
        guard isCurrent(project: project, navigation: navigation, sceneID: sceneID) else { return nil }
        switch mode {
        case .offset: return offsetMs == originalAnchor.offsetMs ? nil : .offset(entryID: source.id, milliseconds: offsetMs)
        case .coverage: return authoredDurationMs == (original.authoredDurationMs ?? original.durationMs) ? nil : .coverage(milliseconds: authoredDurationMs)
        }
    }
    private func nearest(_ target: Int, in values: [Int], threshold: Int) -> Int {
        guard let closest = values.min(by: { abs($0 - target) < abs($1 - target) }), abs(closest - target) <= threshold else { return target }; return closest
    }
}
