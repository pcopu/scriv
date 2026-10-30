import Foundation
import ScrivCore

/// Read-only labels shared by discussion, activity and attachments. Identity is
/// always the stored item/version ID; display names never select a recipient.
enum UIKitDiscussionPresentation {
    static func itemLabel(_ id: String?, project: ScrivProject) -> String {
        guard let id else { return "Project" }
        if let entry = project.entries.first(where: { $0.id == id }) {
            let number = (project.entries(in: entry.sceneId).firstIndex { $0.id == id } ?? 0) + 1
            return "\(entry.kind == .direction ? "Direction" : "Line") \(String(format: "%02d", number)) · " + (entry.kind == .direction ? String(entry.text.prefix(35)) : project.character(entry.characterId)?.name ?? "Dialogue")
        }
        if let character = project.character(id) { return character.name }
        if let image = project.asset(id) { return imageLabel(image, project: project) }
        if let cue = project.cues.first(where: { $0.id == id }) { return cue.label.isEmpty ? "Image placement" : cue.label }
        return "Archived item"
    }
    static func imageLabel(_ image: ImageAsset, project: ScrivProject) -> String {
        let label = project.cues.first { $0.imageId == image.id }?.label
        return (label.flatMap { $0.isEmpty ? nil : $0 } ?? "Image") + " · v\(image.version)"
    }
    static func attachmentImage(_ attachment: JSONValue, project: ScrivProject) -> ImageAsset? {
        // An explicitly attached immutable version wins over an item/root ID.
        if let version = attachment["imageVersionId"]?.string { return project.asset(version) }
        return project.asset(attachment["itemId"]?.string)
    }
    static func symbol(_ id: String?, project: ScrivProject) -> String {
        if project.asset(id) != nil { return "photo" }
        if project.character(id) != nil { return "person.fill" }
        return project.entries.first(where: { $0.id == id })?.kind == .direction ? "arrow.turn.down.right" : "text.quote"
    }
    static func threadLabel(_ thread: DiscussionThread, project: ScrivProject) -> String {
        guard let id = thread.itemId else { return "Project discussion" }
        if let entry = project.entries.first(where: { $0.id == id }) { return String(entry.text.prefix(90)) }
        return itemLabel(id, project: project)
    }
}
