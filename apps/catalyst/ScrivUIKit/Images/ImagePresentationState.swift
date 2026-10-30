import Foundation
import ScrivCore

/// Resolves only placements of the exact inspected version, never a successor.
enum UIKitImageContext {
    static func placement(imageID: String, cueID: String?, project: ScrivProject) -> ImageCue? {
        if let cueID, let cue = project.cues.first(where: { $0.id == cueID && $0.imageId == imageID }) { return cue }
        return project.cues.first { $0.imageId == imageID }
    }
    static func title(imageID: String, cueID: String? = nil, project: ScrivProject) -> String {
        if let cue = placement(imageID: imageID, cueID: cueID, project: project), !cue.label.isEmpty { return cue.label }
        if let person = project.characters.first(where: { $0.portraitImageId == imageID }) { return person.name + " portrait" }
        return "Image"
    }
    static func imageLanes(_ cues: [ImageCue]) -> [(cue: ImageCue, lane: Int)] {
        var ends: [Int] = []
        return cues.map { cue in
            let lane = ends.firstIndex { $0 <= cue.startMs } ?? ends.count
            if lane == ends.count { ends.append(cue.endMs) } else { ends[lane] = cue.endMs }
            return (cue, lane)
        }
    }
}
