import Foundation

public enum EntryKind: String, Codable, CaseIterable, Sendable { case dialogue, direction }
public enum WorkspaceTab: String, CaseIterable, Codable, Sendable { case script = "Script", storyboard = "Storyboard", characters = "Characters" }

public struct ScriptScene: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var order: Double
    public init(id: String = UUID().uuidString, title: String = "Untitled scene", order: Double = 0) { self.id = id; self.title = title; self.order = order }
}
public struct TimedWord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    /// Milliseconds relative to the start of its script entry.
    public var startMs: Int
    public var endMs: Int
    public init(id: String = UUID().uuidString, text: String, startMs: Int, endMs: Int) { self.id = id; self.text = text; self.startMs = startMs; self.endMs = endMs }
}
public struct ScriptEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sceneId: String
    public var order: Double
    public var kind: EntryKind
    public var text: String
    public var characterId: String?
    public var ownedDurationMs: Int
    /// Forward coverage length from authored start, independent of owned time.
    public var coverageDurationMs: Int
    public var color: String
    public var words: [TimedWord]
    public init(id: String = UUID().uuidString, sceneId: String, order: Double, kind: EntryKind = .dialogue, text: String = "", characterId: String? = nil, ownedDurationMs: Int = 3000, coverageDurationMs: Int = 0, color: String = "purple", words: [TimedWord] = []) {
        self.id = id; self.sceneId = sceneId; self.order = order; self.kind = kind; self.text = text; self.characterId = characterId
        self.ownedDurationMs = max(kind == .dialogue ? 1 : 0, ownedDurationMs)
        self.coverageDurationMs = max(coverageDurationMs, kind == .direction ? self.ownedDurationMs : 0)
        self.color = color; self.words = words
        if kind == .dialogue && words.isEmpty { self.words = TimingEngine.retimeWords(text: text, durationMs: self.ownedDurationMs) }
    }
}
public struct ScriptCharacter: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var aliases: [String]
    public var biography: String
    public var appearance: String
    public var color: String
    public var portraitImageId: String?
    public init(id: String = UUID().uuidString, name: String, aliases: [String] = [], biography: String = "", appearance: String = "", color: String = "blue", portraitImageId: String? = nil) {
        self.id = id; self.name = name; self.aliases = aliases; self.biography = biography; self.appearance = appearance; self.color = color; self.portraitImageId = portraitImageId
    }
}
public struct ImageAsset: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var version: Int
    public var fileName: String
    public var sha256: String
    public var mimeType: String
    public var byteCount: Int
    public var characterIds: [String]
    public var prompt: String
    public var createdAt: Date
    public var previousVersionId: String?
    public init(id: String = UUID().uuidString, version: Int = 1, fileName: String, sha256: String, mimeType: String = "image/png", byteCount: Int, characterIds: [String] = [], prompt: String = "", createdAt: Date = Date(), previousVersionId: String? = nil) {
        self.id = id; self.version = version; self.fileName = fileName; self.sha256 = sha256; self.mimeType = mimeType; self.byteCount = byteCount; self.characterIds = characterIds; self.prompt = prompt; self.createdAt = createdAt; self.previousVersionId = previousVersionId
    }
}
public struct ImageCue: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sceneId: String
    public var imageId: String?
    public var label: String
    public var startMs: Int
    public var endMs: Int
    public var prompt: String
    public var durationMs: Int { endMs - startMs }
    public init(id: String = UUID().uuidString, sceneId: String, imageId: String? = nil, label: String = "", startMs: Int, endMs: Int, prompt: String = "") {
        self.id = id; self.sceneId = sceneId; self.imageId = imageId; self.label = label; self.startMs = startMs; self.endMs = endMs; self.prompt = prompt
    }
}
public struct ScrivProject: Identifiable, Codable, Hashable, Sendable {
    public var schemaVersion: Int = 1
    public var id: String
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var revision: Int
    public var cloudProjectId: String?
    public var scenes: [ScriptScene]
    public var entries: [ScriptEntry]
    public var characters: [ScriptCharacter]
    public var images: [ImageAsset]
    public var cues: [ImageCue]
    public init(id: String = UUID().uuidString, title: String = "Untitled", scenes: [ScriptScene] = [], entries: [ScriptEntry] = [], characters: [ScriptCharacter] = [], images: [ImageAsset] = [], cues: [ImageCue] = [], cloudProjectId: String? = nil) {
        self.id = id; self.title = title; self.createdAt = Date(); self.modifiedAt = Date(); self.revision = 0; self.cloudProjectId = cloudProjectId; self.scenes = scenes; self.entries = entries; self.characters = characters; self.images = images; self.cues = cues
    }
    public func entries(in sceneId: String) -> [ScriptEntry] { entries.filter { $0.sceneId == sceneId }.sorted { ($0.order, $0.id) < ($1.order, $1.id) } }
    public func cues(in sceneId: String) -> [ImageCue] { cues.filter { $0.sceneId == sceneId }.sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) } }
    public func durationMs(of sceneId: String) -> Int { entries(in: sceneId).reduce(0) { $0 + $1.ownedDurationMs } }
    public func startMs(of entryId: String) -> Int {
        guard let entry = entries.first(where: { $0.id == entryId }) else { return 0 }
        var clock = 0
        for item in entries(in: entry.sceneId) { if item.id == entryId { return clock }; clock += item.ownedDurationMs }
        return clock
    }
    public func activeEntry(at ms: Int, sceneId: String) -> ScriptEntry? {
        let sequence = entries(in: sceneId)
        var clock = 0
        for entry in sequence { let end = clock + entry.ownedDurationMs; if ms >= clock && ms < end { return entry }; clock = end }
        return ms == clock ? sequence.last : nil
    }
    public func activeCue(at ms: Int, sceneId: String) -> ImageCue? { cues(in: sceneId).first { ms >= $0.startMs && ms < $0.endMs } }
    public func character(_ id: String?) -> ScriptCharacter? { characters.first { $0.id == id } }
    public func asset(_ id: String?) -> ImageAsset? { images.first { $0.id == id } }
}

public struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var date: Date
    public var label: String
    public var revision: Int
    public var snapshot: ScrivProject
    public init(label: String, snapshot: ScrivProject) { id = UUID().uuidString; date = Date(); self.label = label; revision = snapshot.revision; self.snapshot = snapshot }
}
public enum ScrivError: LocalizedError, Equatable {
    case invalid(String), conflict(String), unavailable(String), permission(String)
    public var errorDescription: String? { switch self { case .invalid(let s), .conflict(let s), .unavailable(let s), .permission(let s): return s } }
}
public enum ScrivFormat {
    public static func time(_ ms: Int) -> String { String(format: "%02d:%04.1f", max(0, ms) / 60_000, Double(max(0, ms) % 60_000) / 1000) }
    public static func duration(_ ms: Int) -> String { ms == 0 ? "0s" : String(format: "%.1fs", Double(ms) / 1000) }
}
