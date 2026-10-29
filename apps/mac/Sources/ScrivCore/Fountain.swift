import Foundation

public enum Fountain {
    private static func isSceneHeading(_ text: String) -> Bool {
        let upper = text.uppercased()
        return ["INT.", "EXT.", "INT/EXT.", "I/E.", "EST."].contains { upper.hasPrefix($0) }
    }
    public static func export(_ project: ScrivProject) -> String {
        var lines = ["Title: \(project.title)", "", ""]
        for scene in project.orderedScenes {
            lines += [isSceneHeading(scene.title) ? scene.title : "." + scene.title, ""]
            for entry in project.entries(in: scene.id) {
                if entry.kind == .dialogue {
                    lines += ["@" + (project.character(entry.characterId)?.name.uppercased() ?? "SPEAKER"), entry.text, ""]
                } else {
                    // Forced action avoids interpreting an uppercase action, @-prefixed
                    // note or scene-looking direction as a different Fountain element.
                    lines += ["!" + entry.text, ""]
                }
                lines += ["[[scriv duration=\(entry.ownedDurationMs) coverage=\(entry.coverageDurationMs)]]", ""]
            }
        }
        return lines.joined(separator: "\n")
    }
    public static func parse(_ text: String, title: String = "Imported script") -> ScrivProject {
        var project = ScrivProject(title: title)
        var scene = ScriptScene(title: "INT. SCENE — DAY", order: 0), hasAuthoredScene = false
        project.scenes = [scene]
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var speaker: ScriptCharacter?, buffer: [String] = [], kind = EntryKind.direction
        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { buffer = []; return }
            let estimated = min(3_600_000, max(1000, body.split(whereSeparator: { $0.isWhitespace }).count * 375))
            project.entries.append(ScriptEntry(sceneId: scene.id, order: Double(project.entries.count), kind: kind, text: body, characterId: kind == .dialogue ? speaker?.id : nil, ownedDurationMs: body.hasPrefix("(") && kind == .direction ? 0 : estimated, coverageDurationMs: kind == .direction ? estimated : 0))
            buffer = []
        }
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Title:"), project.entries.isEmpty, buffer.isEmpty, !hasAuthoredScene {
                let value = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { project.title = value }; continue
            }
            if line.hasPrefix("[[scriv "), line.hasSuffix("]]") {
                flush()
                guard !project.entries.isEmpty else { continue }
                let i = project.entries.count - 1
                var duration = project.entries[i].ownedDurationMs, coverage = project.entries[i].coverageDurationMs
                for field in line.dropFirst(8).dropLast(2).split(separator: " ") {
                    let parts = field.split(separator: "=")
                    guard parts.count == 2, let value = Int(parts[1]), value >= 0 else { continue }
                    if parts[0] == "duration", value <= 3_600_000 { duration = max(project.entries[i].kind == .dialogue ? max(1,project.entries[i].words.count) : 0,value) }
                    if parts[0] == "coverage", value <= 86_400_000 { coverage = value }
                }
                project.entries[i].ownedDurationMs = duration
                project.entries[i].coverageDurationMs = project.entries[i].kind == .direction ? max(duration,coverage) : coverage
                if project.entries[i].kind == .dialogue { project.entries[i].words = TimingEngine.retimeWords(text:project.entries[i].text,durationMs:duration,preserving:project.entries[i].words) }
                continue
            }
            if line.isEmpty { flush(); speaker = nil; kind = .direction; continue }
            if line.hasPrefix("!") {
                flush(); speaker = nil; kind = .direction; buffer.append(String(line.dropFirst())); continue
            }
            let forcedScene = line.hasPrefix(".") && !line.hasPrefix("..")
            if isSceneHeading(line) || forcedScene {
                flush()
                let heading = forcedScene ? String(line.dropFirst()) : line
                if !hasAuthoredScene && project.entries.isEmpty { project.scenes[0].title = heading; scene = project.scenes[0] }
                else { scene = ScriptScene(title:heading,order:Double(project.scenes.count)); project.scenes.append(scene) }
                hasAuthoredScene = true; speaker = nil; kind = .direction; continue
            }
            let forced = line.hasPrefix("@") && !line.dropFirst().trimmingCharacters(in:.whitespaces).isEmpty
            let looksLikeName = line == line.uppercased() && line.count <= 50 && line.contains(where: { $0.isLetter }) && !line.hasSuffix("TO:")
            let nextNonempty = index+1 < lines.count && !lines[index+1].trimmingCharacters(in:.whitespaces).isEmpty
            if forced || looksLikeName && nextNonempty && buffer.isEmpty {
                flush()
                var name = (forced ? String(line.dropFirst()) : line).trimmingCharacters(in:.whitespaces)
                // Continuation/voice annotations do not create a second character profile.
                for suffix in [" (CONT'D)", " (CONT’D)", " (V.O.)", " (O.S.)"] where name.uppercased().hasSuffix(suffix) { name = String(name.dropLast(suffix.count)).trimmingCharacters(in:.whitespaces) }
                if name.isEmpty { kind = .direction; buffer.append(line); continue }
                if let found = project.characters.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.aliases.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) }) { speaker = found }
                else { let character = ScriptCharacter(name:name.capitalized); project.characters.append(character); speaker = character }
                kind = .dialogue; continue
            }
            if line.hasPrefix("("), line.hasSuffix(")"), kind == .dialogue {
                flush()
                project.entries.append(ScriptEntry(sceneId:scene.id,order:Double(project.entries.count),kind:.direction,text:line,ownedDurationMs:0,coverageDurationMs:3000))
                continue
            }
            buffer.append(line)
        }
        flush()
        for s in project.scenes { let duration = project.durationMs(of:s.id); if duration > 0 { project.cues.append(ImageCue(sceneId:s.id,label:"01A",startMs:0,endMs:duration)) } }
        return project
    }
}
