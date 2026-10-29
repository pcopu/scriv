import Foundation

public enum Fountain {
    public static func export(_ project: ScrivProject) -> String {
        var lines = ["Title: \(project.title)", "", ""]
        for scene in project.scenes.sorted(by: { $0.order < $1.order }) {
            lines += [scene.title, ""]
            for entry in project.entries(in: scene.id) {
                if entry.kind == .dialogue {
                    lines += ["@" + (project.character(entry.characterId)?.name.uppercased() ?? "SPEAKER"), entry.text, ""]
                } else { lines += [entry.text, ""] }
                lines += ["[[scriv duration=\(entry.ownedDurationMs) coverage=\(entry.coverageDurationMs)]]", ""]
            }
        }
        return lines.joined(separator: "\n")
    }
    public static func parse(_ text: String, title: String = "Imported script") -> ScrivProject {
        var project = ScrivProject(title: title)
        var scene = ScriptScene(title: "INT. SCENE — DAY", order: 0)
        project.scenes = [scene]
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var speaker: ScriptCharacter?, buffer: [String] = [], kind = EntryKind.direction
        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { buffer = []; return }
            let estimated = max(1000, body.split(whereSeparator: { $0.isWhitespace }).count * 375)
            project.entries.append(ScriptEntry(sceneId: scene.id, order: Double(project.entries.count), kind: kind, text: body, characterId: kind == .dialogue ? speaker?.id : nil, ownedDurationMs: body.hasPrefix("(") && kind == .direction ? 0 : estimated, coverageDurationMs: kind == .direction ? estimated : 0))
            buffer = []
        }
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Title:"), project.entries.isEmpty { project.title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
            if line.hasPrefix("[[scriv "), line.hasSuffix("]]"), !project.entries.isEmpty {
                for field in line.dropFirst(8).dropLast(2).split(separator: " ") { let parts = field.split(separator: "="); if parts.count == 2, let value = Int(parts[1]), value >= 0, value <= 3_600_000 { let i = project.entries.count-1; if parts[0] == "duration" { project.entries[i].ownedDurationMs = max(project.entries[i].kind == .dialogue ? max(1,project.entries[i].words.count) : 0,value); if project.entries[i].kind == .dialogue { project.entries[i].words = TimingEngine.retimeWords(text: project.entries[i].text, durationMs: project.entries[i].ownedDurationMs, preserving: project.entries[i].words) } }; if parts[0] == "coverage" { project.entries[i].coverageDurationMs = max(project.entries[i].ownedDurationMs,value) } } }
                continue
            }
            if line.isEmpty { flush(); speaker = nil; kind = .direction; continue }
            if line.hasPrefix("INT.") || line.hasPrefix("EXT.") || line.hasPrefix("INT/EXT.") || line.hasPrefix(".") && !line.hasPrefix("..") {
                flush()
                if project.entries.isEmpty && project.scenes.count == 1 { project.scenes[0].title = line; scene = project.scenes[0] }
                else { scene = ScriptScene(title: line, order: Double(project.scenes.count)); project.scenes.append(scene) }
                speaker = nil; kind = .direction; continue
            }
            let forced = line.hasPrefix("@"), looksLikeName = line == line.uppercased() && line.count <= 50 && line.contains(where: { $0.isLetter }) && !line.hasSuffix("TO:")
            let nextNonempty = index+1 < lines.count && !lines[index+1].trimmingCharacters(in: .whitespaces).isEmpty
            if forced || looksLikeName && nextNonempty && buffer.isEmpty {
                flush(); let name = forced ? String(line.dropFirst()) : line
                if let found = project.characters.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { speaker = found }
                else { let character = ScriptCharacter(name: name.capitalized); project.characters.append(character); speaker = character }
                kind = .dialogue; continue
            }
            if line.hasPrefix("("), line.hasSuffix(")"), kind == .dialogue, buffer.isEmpty {
                project.entries.append(ScriptEntry(sceneId: scene.id, order: Double(project.entries.count), kind: .direction, text: line, ownedDurationMs: 0, coverageDurationMs: 3000)); continue
            }
            buffer.append(line)
        }
        flush()
        for s in project.scenes { let duration = project.durationMs(of: s.id); if duration > 0 { project.cues.append(ImageCue(sceneId: s.id, label: "01A", startMs: 0, endMs: duration)) } }
        return project
    }
}
