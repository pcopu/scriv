import Foundation

public extension ScrivProject {
    static func blank(title: String = "Untitled") -> ScrivProject {
        let scene = ScriptScene(title: "INT. LOCATION — DAY")
        return ScrivProject(title: title, scenes: [scene], entries: [ScriptEntry(sceneId: scene.id, order: 0, kind: .direction, text: "Describe the opening moment.", ownedDurationMs: 0, coverageDurationMs: 3000), ScriptEntry(sceneId: scene.id, order: 1, text: "Your first line.")], cues: [ImageCue(sceneId: scene.id, label: "01A", startMs: 0, endMs: 3000)])
    }
    static func example() -> ScrivProject {
        let scene = ScriptScene(id: "scene-farm", title: "INT. FRANKLIN'S FARM — DAY", order: 0)
        let randy = ScriptCharacter(id: "character-randy", name: "Randy", biography: "The enthusiastic negotiator.", appearance: "Curly hair, faded gray hoodie.", color: "blue")
        let franklin = ScriptCharacter(id: "character-franklin", name: "Farmer Franklin", aliases: ["Franklin"], biography: "A cautious farmer, weighing the boys' proposal.", appearance: "Sun-worn cap, blue plaid shirt, overalls.", color: "orange")
        let miyazaki = ScriptCharacter(id: "character-miyazaki", name: "Miyazaki", biography: "Quietly observes the negotiation.", appearance: "Dark hair, plaid shirt, holding the invoice.", color: "teal")
        var entries: [ScriptEntry] = [
            ScriptEntry(id: "line-07", sceneId: scene.id, order: 0, text: "Calm down, Miyazaki. This is America.", characterId: randy.id, ownedDurationMs: 3000),
            ScriptEntry(id: "direction-08", sceneId: scene.id, order: 1, kind: .direction, text: "(To the farmer)", ownedDurationMs: 0, coverageDurationMs: 5400, color: "purple"),
            ScriptEntry(id: "line-08", sceneId: scene.id, order: 2, text: "He gets a little gung ho with our flavor of capitalism.", characterId: randy.id, ownedDurationMs: 5000),
            ScriptEntry(id: "line-09", sceneId: scene.id, order: 3, kind: .direction, text: "Franklin looks between the boys and the invoice.", ownedDurationMs: 2400, coverageDurationMs: 5200, color: "coral"),
            ScriptEntry(id: "direction-10", sceneId: scene.id, order: 4, kind: .direction, text: "(Re: Miyazaki)", ownedDurationMs: 0, coverageDurationMs: 3200, color: "teal"),
            ScriptEntry(id: "line-10", sceneId: scene.id, order: 5, text: "Can I trust this guy?", characterId: franklin.id, ownedDurationMs: 2800),
            ScriptEntry(id: "line-11", sceneId: scene.id, order: 6, text: "Yeah, you can trust this guy.", characterId: randy.id, ownedDurationMs: 2800),
            ScriptEntry(id: "line-12", sceneId: scene.id, order: 7, text: "Are you sure?", characterId: franklin.id, ownedDurationMs: 1600)
        ]
        let timings = [0,250,600,750,1400,1700,2000,2350,2700,3450,3800,5000]
        entries[2].words = entries[2].words.enumerated().map { index, word in TimedWord(id: "word-08-\(index)", text: word.text, startMs: timings[index], endMs: timings[index+1]) }
        let question = [0,400,700,1500,2000,2800]
        entries[5].words = entries[5].words.enumerated().map { index, word in TimedWord(id: "word-10-\(index)", text: word.text, startMs: question[index], endMs: question[index+1]) }
        let cuts = [0,3000,4400,6800,8000,10400,11900,13200,16000,17600]
        let labels = ["07A","08A","08B","08C","09A","10A","10B","11A","12A"]
        let cues = labels.enumerated().map { index,label in ImageCue(id: "cue-\(label.lowercased())", sceneId: scene.id, label: label, startMs: cuts[index], endMs: cuts[index+1], prompt: "Cinematic storyboard, warm natural light in a farm office. \(index == 4 ? "Franklin studies the invoice." : "Randy, Miyazaki, and Farmer Franklin discuss an invoice.")") }
        return ScrivProject(title: "YAM MAN", scenes: [scene], entries: entries, characters: [randy,franklin,miyazaki], cues: cues)
    }
}
