import Foundation

public enum ScrivClock {
    /// Stable millisecond precision matches the cloud protocol and durable JSON files.
    public static var now: Date { normalized(Date()) }
    public static func normalized(_ date: Date) -> Date { Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000) }
}

public enum EntryKind: String, Codable, CaseIterable, Sendable { case dialogue, direction }
public enum WorkspaceTab: String, CaseIterable, Codable, Sendable { case script = "Script", storyboard = "Storyboard", characters = "Characters" }

public struct ScriptScene: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var order: Double
    public init(id: String = UUID().uuidString, title: String = "Untitled scene", order: Double = 0) { self.id = id; self.title = title; self.order = order }
}
public enum WordTimingSource: String, Codable, Hashable, Sendable { case authored }

public struct TimedWord: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    /// Milliseconds relative to the start of its script entry.
    public var startMs: Int
    public var endMs: Int
    /// Nil is an editorial estimate; authored timings are preserved during later edits.
    public var timingSource: WordTimingSource?
    public init(id: String = UUID().uuidString, text: String, startMs: Int, endMs: Int, timingSource: WordTimingSource? = nil) { self.id = id; self.text = text; self.startMs = startMs; self.endMs = endMs; self.timingSource = timingSource }
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
    public var characterLinks: [CharacterTextLink]?
    public init(id: String = UUID().uuidString, sceneId: String, order: Double, kind: EntryKind = .dialogue, text: String = "", characterId: String? = nil, ownedDurationMs: Int = 3000, coverageDurationMs: Int = 0, color: String = "purple", words: [TimedWord] = [], characterLinks: [CharacterTextLink]? = nil) {
        self.id = id; self.sceneId = sceneId; self.order = order; self.kind = kind; self.text = text; self.characterId = characterId
        self.ownedDurationMs = max(kind == .dialogue ? max(1, text.split(whereSeparator: { $0.isWhitespace }).count) : 0, ownedDurationMs)
        self.coverageDurationMs = max(coverageDurationMs, kind == .direction ? self.ownedDurationMs : 0)
        self.color = color; self.words = words; self.characterLinks = characterLinks
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
        self.id = id; self.version = version; self.fileName = fileName; self.sha256 = sha256; self.mimeType = mimeType; self.byteCount = byteCount; self.characterIds = characterIds; self.prompt = prompt; self.createdAt = ScrivClock.normalized(createdAt); self.previousVersionId = previousVersionId
    }
}
/// A durable script-relative edge. Cue scene milliseconds are its resolved projection.
public struct ScriptTimeAnchor: Codable, Hashable, Sendable {
    public var entryId: String
    public var offsetMs: Int
    public init(entryId: String, offsetMs: Int) { self.entryId = entryId; self.offsetMs = offsetMs }
}
public struct ImageCue: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var sceneId: String
    public var imageId: String?
    public var label: String
    public var startMs: Int
    public var endMs: Int
    public var prompt: String
    public var startAnchor: ScriptTimeAnchor?
    /// Source-owned forward extent, preserved even when the scene ends sooner.
    public var authoredDurationMs: Int?
    public var durationMs: Int { endMs - startMs }
    public init(id: String = UUID().uuidString, sceneId: String, imageId: String? = nil, label: String = "", startMs: Int, endMs: Int, prompt: String = "", startAnchor: ScriptTimeAnchor? = nil, authoredDurationMs: Int? = nil) {
        self.id = id; self.sceneId = sceneId; self.imageId = imageId; self.label = label; self.startMs = startMs; self.endMs = endMs; self.prompt = prompt; self.startAnchor = startAnchor; self.authoredDurationMs = authoredDurationMs
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
    /// Local package audio; the image-only cloud protocol does not upload these bytes.
    public var audioAssets: [AudioAsset]
    public var audioClips: [AudioClip]
    public var audioVolume: Double
    public init(id: String = UUID().uuidString, title: String = "Untitled", scenes: [ScriptScene] = [], entries: [ScriptEntry] = [], characters: [ScriptCharacter] = [], images: [ImageAsset] = [], cues: [ImageCue] = [], cloudProjectId: String? = nil, audioAssets: [AudioAsset] = [], audioClips: [AudioClip] = [], audioVolume: Double = 1) {
        self.id = id; self.title = title; self.createdAt = ScrivClock.now; self.modifiedAt = self.createdAt; self.revision = 0; self.cloudProjectId = cloudProjectId; self.scenes = scenes; self.entries = entries; self.characters = characters; self.images = images; self.cues = cues; self.audioAssets = audioAssets; self.audioClips = audioClips; self.audioVolume = audioVolume
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, title, createdAt, modifiedAt, revision, cloudProjectId, scenes, entries, characters, images, cues, audioAssets, audioClips, audioVolume }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        schemaVersion = try c.decode(Int.self,forKey:.schemaVersion); id = try c.decode(String.self,forKey:.id); title = try c.decode(String.self,forKey:.title)
        createdAt = try c.decode(Date.self,forKey:.createdAt); modifiedAt = try c.decode(Date.self,forKey:.modifiedAt); revision = try c.decode(Int.self,forKey:.revision); cloudProjectId = try c.decodeIfPresent(String.self,forKey:.cloudProjectId)
        scenes = try c.decode([ScriptScene].self,forKey:.scenes); entries = try c.decode([ScriptEntry].self,forKey:.entries); characters = try c.decode([ScriptCharacter].self,forKey:.characters)
        images = try c.decode([ImageAsset].self,forKey:.images); cues = try c.decode([ImageCue].self,forKey:.cues)
        audioAssets = try c.decodeIfPresent([AudioAsset].self,forKey:.audioAssets) ?? []; audioClips = try c.decodeIfPresent([AudioClip].self,forKey:.audioClips) ?? []; audioVolume = try c.decodeIfPresent(Double.self,forKey:.audioVolume) ?? 1
    }
    public var orderedScenes: [ScriptScene] { scenes.sorted { ($0.order, $0.id) < ($1.order, $1.id) } }
    /// Parenthetical notes are editable items, not additional authored timed slots.
    public func authoredEntryCount(in sceneId: String) -> Int { entries(in: sceneId).filter { $0.kind == .dialogue || $0.ownedDurationMs > 0 }.count }
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
    public func activeCue(at ms: Int, sceneId: String) -> ImageCue? { cues(in: sceneId).last { ms >= $0.startMs && ms < $0.endMs } }
    public func character(_ id: String?) -> ScriptCharacter? { characters.first { $0.id == id } }
    public func asset(_ id: String?) -> ImageAsset? { images.first { $0.id == id } }
}

public struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var date: Date
    public var label: String
    public var revision: Int
    public var snapshot: ScrivProject
    public init(label: String, snapshot: ScrivProject) { id = UUID().uuidString; date = ScrivClock.now; self.label = label; revision = snapshot.revision; self.snapshot = snapshot }
}
public enum ScrivError: LocalizedError, Equatable {
    case invalid(String), conflict(String), unavailable(String), permission(String)
    public var errorDescription: String? { switch self { case .invalid(let s), .conflict(let s), .unavailable(let s), .permission(let s): return s } }
}
public enum ScrivFormat {
    public static func time(_ ms: Int) -> String { String(format: "%02d:%04.1f", max(0, ms) / 60_000, Double(max(0, ms) % 60_000) / 1000) }
    public static func duration(_ ms: Int) -> String { ms == 0 ? "0s" : String(format: "%.1fs", Double(ms) / 1000) }
}
