import Foundation
import ScrivCore

/// Read-only metadata for the project browser. Nothing here opens, imports or saves a project.
struct ProjectBrowserLocalSummary: Sendable {
    let project: ScrivProject?
    let thumbnailURL: URL?
    let issue: String?

    static func load(at package: URL) -> Self {
        do {
            let root = package.resolvingSymlinksInPath().standardizedFileURL
            func member(_ path: String) throws -> URL {
                let expected = root.appendingPathComponent(path).standardizedFileURL
                guard expected == expected.resolvingSymlinksInPath().standardizedFileURL,
                      expected.path.hasPrefix(root.path + "/") else { throw ScrivError.invalid("Project metadata points outside its package.") }
                return expected
            }
            let file = try member("project.json")
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 * 1024 else { throw ScrivError.invalid("Project metadata exceeds the safety limit.") }
            let data = try Data(contentsOf: file)
            guard data.count <= 64 * 1024 * 1024 else { throw ScrivError.invalid("Project metadata exceeds the safety limit.") }
            let project = try ScrivJSON.decoder.decode(ScrivProject.self, from: data)
            try TimingEngine.validate(project)
            let cover = project.orderedScenes.lazy.compactMap { scene in project.cues(in: scene.id).compactMap { project.asset($0.imageId) }.first }.first ?? project.images.first
            var thumbnail: URL?
            if let cover, cover.fileName == URL(fileURLWithPath: cover.fileName).lastPathComponent, !cover.fileName.contains(".."),
               let url = try? member("assets/" + cover.fileName),
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == cover.byteCount, size <= 25 * 1024 * 1024,
               let bytes = try? Data(contentsOf: url), bytes.count == cover.byteCount, ScrivDigest.sha256(bytes) == cover.sha256 {
                thumbnail = url
            }
            return Self(project: project, thumbnailURL: thumbnail, issue: nil)
        } catch {
            return Self(project: nil, thumbnailURL: nil, issue: error.localizedDescription)
        }
    }
}

struct HistoryReadableField: Identifiable, Equatable {
    let label: String
    let before: String
    let after: String
    var id: String { label }
}

/// Writer-facing fields are separate from technical JSON. Missing data is never synthesized.
enum HistoryPresentation {
    static func localChanges(before: ScrivProject?, after: ScrivProject) -> [CloudChange] {
        func items(_ project: ScrivProject) -> [CloudItem] {
            var result = (try? CloudCodec.items(from: project)) ?? []
            result.append(CloudItem(id: "package:" + project.id, kind: "project", data: .object(["title": .string(project.title), "audioVolume": .number(project.audioVolume)])))
            result += project.audioAssets.compactMap { asset in (try? JSONValue.encoded(asset)).map { CloudItem(id: "audioAsset:" + asset.id, kind: "audioAsset", data: $0) } }
            result += project.audioClips.compactMap { clip in (try? JSONValue.encoded(clip)).map { CloudItem(id: "audioClip:" + clip.id, kind: "audioClip", data: $0) } }
            return result
        }
        let old = Dictionary(uniqueKeysWithValues: (before.map(items) ?? []).map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: items(after).map { ($0.id, $0) })
        return Set(old.keys).union(new.keys).sorted().compactMap { id in
            guard old[id]?.data != new[id]?.data else { return nil }
            return CloudChange(id: id, before: old[id], after: new[id])
        }
    }

    static func title(for change: CloudChange) -> String {
        let item = change.after?.deleted == true ? change.before : change.after ?? change.before
        let data = item?.data
        switch item?.kind {
        case "entry":
            let kind = data?["kind"]?.string == "direction" ? "Direction" : "Dialogue"
            return kind + (change.before?.data["text"] != change.after?.data["text"] ? " text" : " timing & details")
        case "scene": return data?["title"]?.string ?? "Scene"
        case "character": return data?["name"]?.string ?? "Character"
        case "cue": return data?["label"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "Image placement"
        case "image": return data?["version"]?.int.map { "Image version \($0)" } ?? "Image"
        case "project": return "Project details"
        case "audioAsset": return data?["originalName"]?.string ?? "Local audio"
        case "audioClip": return "Local audio placement"
        default: return "Changed item"
        }
    }

    static func operation(for change: CloudChange) -> String {
        if change.after == nil || change.after?.deleted == true { return "Removed" }
        if change.before == nil || change.before?.deleted == true { return "Added" }
        return "Updated"
    }

    static func fields(for change: CloudChange, beforeProject: ScrivProject?, afterProject: ScrivProject?) -> [HistoryReadableField] {
        let old = change.before?.deleted == true ? nil : change.before?.data
        let new = change.after?.deleted == true ? nil : change.after?.data
        let kind = change.after?.kind ?? change.before?.kind
        var fields: [HistoryReadableField] = []
        func add(_ label: String, _ key: String, format: (JSONValue) -> String = HistoryPresentation.display) {
            guard old?[key] != new?[key] else { return }
            fields.append(HistoryReadableField(label: label, before: old?[key].map(format) ?? "Not present", after: new?[key].map(format) ?? "Not present"))
        }
        func seconds(_ value: JSONValue) -> String { value.int.map(duration) ?? display(value) }
        func name(_ value: JSONValue) -> String {
            guard let id = value.string else { return display(value) }
            return afterProject?.character(id)?.name ?? beforeProject?.character(id)?.name ?? "Character not in this preview"
        }
        switch kind {
        case "entry":
            add("Text", "text"); add("Speaker", "characterId", format: name)
            add("Owned time", "ownedDurationMs", format: seconds)
            if old?["coverageDurationMs"] != new?["coverageDurationMs"] {
                func coverage(_ value: JSONValue?, project: ScrivProject?) -> String {
                    guard let duration = value?["coverageDurationMs"]?.int else { return "Not present" }
                    guard let project, project.entries.contains(where: { $0.id == change.id }) else { return Self.duration(duration) + " forward" }
                    let start = project.startMs(of: change.id)
                    return Self.duration(start).replacingOccurrences(of: " s", with: "") + "–" + Self.duration(start + duration)
                }
                fields.append(HistoryReadableField(label: "Coverage", before: coverage(old, project: beforeProject), after: coverage(new, project: afterProject)))
            }
            add("Script position", "order"); add("Line type", "kind"); add("Direction color", "color")
            if old?["words"] != new?["words"] { fields.append(HistoryReadableField(label: "Word timing", before: wordSummary(old?["words"]), after: wordSummary(new?["words"]))) }
            if old?["characterLinks"] != new?["characterLinks"] { fields.append(HistoryReadableField(label: "Character links", before: linkSummary(old?["characterLinks"]), after: linkSummary(new?["characterLinks"]))) }
        case "character":
            add("Name", "name"); add("Aliases", "aliases"); add("Biography", "biography"); add("Appearance", "appearance"); add("Color", "color")
            if old?["portraitImageId"] != new?["portraitImageId"] { fields.append(HistoryReadableField(label: "Portrait", before: old?["portraitImageId"] == nil ? "No portrait" : "Previous image", after: new?["portraitImageId"] == nil ? "No portrait" : "Selected image")) }
        case "scene": add("Title", "title"); add("Scene position", "order")
        case "cue":
            add("Label", "label"); add("Starts at", "startMs", format: seconds); add("Ends at", "endMs", format: seconds); add("Authored duration", "authoredDurationMs", format: seconds); add("Prompt", "prompt")
            if old?["imageId"] != new?["imageId"] { fields.append(HistoryReadableField(label: "Image", before: imageLabel(old?["imageId"], project: beforeProject), after: imageLabel(new?["imageId"], project: afterProject))) }
            if old?["startAnchor"] != new?["startAnchor"] { fields.append(HistoryReadableField(label: "Script anchor", before: anchorLabel(old?["startAnchor"]), after: anchorLabel(new?["startAnchor"]))) }
        case "image":
            add("Version", "version"); add("Prompt", "prompt"); add("Submitted prompt", "generationPrompt")
            if old?["characterIds"] != new?["characterIds"] { add("Visible characters", "characterIds") { $0.array?.map(name).joined(separator: ", ") ?? "None" } }
            add("File", "fileName")
        case "project": add("Title", "title"); add("Audio volume", "audioVolume")
        case "audioAsset": add("File", "originalName"); add("Duration", "durationMs", format: seconds)
        case "audioClip": add("Starts at", "startMs", format: seconds); add("Source offset", "sourceStartMs", format: seconds); add("Duration", "durationMs", format: seconds); add("Volume", "volume"); add("Muted", "isMuted")
        default: break
        }
        return fields
    }
    static func display(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text.isEmpty ? "Empty" : text
        case .number(let number): return number.rounded() == number ? String(format: "%.0f", number) : String(number)
        case .bool(let flag): return flag ? "Yes" : "No"
        case .array(let values): return values.isEmpty ? "None" : values.map(display).joined(separator: ", ")
        case .null: return "None"
        case .object: return "Updated details — expand Technical details"
        }
    }
    static func duration(_ milliseconds: Int) -> String {
        String(format: milliseconds % 100 == 0 ? "%.1f s" : "%.3f s", Double(milliseconds) / 1000)
    }
    private static func wordSummary(_ value: JSONValue?) -> String {
        guard let values = value?.array, !values.isEmpty else { return "No word timing" }
        let lines = values.prefix(12).map { word in
            let text = word["text"]?.string ?? "Word"
            return "“\(text)” \(duration(word["startMs"]?.int ?? 0))–\(duration(word["endMs"]?.int ?? 0))" + (word["timingSource"]?.string == "authored" ? " · authored" : " · estimated")
        }
        return lines.joined(separator: "\n") + (values.count > 12 ? "\n\(values.count - 12) more words in Technical details" : "")
    }
    private static func linkSummary(_ value: JSONValue?) -> String {
        guard let values = value?.array else { return "No stored links" }
        return "\(values.count) character link\(values.count == 1 ? "" : "s")"
    }
    private static func imageLabel(_ value: JSONValue?, project: ScrivProject?) -> String {
        guard let id = value?.string else { return "No image" }
        guard let asset = project?.asset(id) else { return "Selected image (see technical details)" }
        return "Version \(asset.version) · \(asset.fileName)"
    }
    private static func anchorLabel(_ value: JSONValue?) -> String {
        guard let value else { return "Scene time" }
        guard let offset = value["offsetMs"]?.int else { return "Script-relative anchor" }
        return "Script-relative · " + duration(offset) + " offset"
    }
}

/// Highlight complete extended grapheme clusters, not UTF-16 fragments. Native
/// editing continues to use its exact UTF-16 event stream independently.
enum RecoveredDraftComparison {
    static func changedRange(in draft: String, comparedTo current: String) -> NSRange? {
        let before = Array(current), after = Array(draft)
        let prefix = zip(before, after).prefix { $0 == $1 }.count
        let maximumSuffix = min(before.count, after.count) - prefix
        let suffix = zip(before.reversed(), after.reversed()).prefix(maximumSuffix).prefix { $0 == $1 }.count
        let start = draft.index(draft.startIndex, offsetBy: prefix)
        let end = draft.index(draft.endIndex, offsetBy: -suffix)
        return start < end ? NSRange(start..<end, in: draft) : nil
    }
}
