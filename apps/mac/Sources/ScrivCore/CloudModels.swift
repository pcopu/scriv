import Foundation

public enum JSONValue: Codable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); switch self { case .null: try c.encodeNil(); case .bool(let b): try c.encode(b); case .number(let n): try c.encode(n); case .string(let s): try c.encode(s); case .array(let a): try c.encode(a); case .object(let o): try c.encode(o) } }
    public subscript(_ key: String) -> JSONValue? { if case .object(let object) = self { return object[key] }; return nil }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var int: Int? { if case .number(let value) = self, value.isFinite, value.rounded(.towardZero) == value, value >= Double(Int.min), value < Double(Int.max) { return Int(value) }; return nil }
    public var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public static func encoded<T: Encodable>(_ value: T) throws -> JSONValue { try ScrivJSON.decoder.decode(JSONValue.self, from: ScrivJSON.encoder.encode(value)) }
    public func decoded<T: Decodable>(_ type: T.Type) throws -> T { try ScrivJSON.decoder.decode(type, from: ScrivJSON.encoder.encode(self)) }
}
public enum ScrivJSON {
    public static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .millisecondsSince1970; return e }
    public static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }
}
public struct CloudUser: Codable, Identifiable, Hashable, Sendable { public var id: String; public var name: String; public var email: String?; public var avatarUrl: String? }
public struct CloudTeam: Codable, Identifiable, Hashable, Sendable { public var id: String; public var name: String; public var role: String?; public var plan: String?; public var status: String?; public var isPaid: Bool { plan == "team" } }
public struct CloudProject: Codable, Identifiable, Hashable, Sendable { public var id: String; public var title: String; public var teamId: String?; public var ownerId: String? }
public struct CloudItem: Codable, Identifiable, Hashable, Sendable { public var id: String; public var kind: String; public var version: Int; public var data: JSONValue; public var deleted: Bool?; public init(id: String, kind: String, version: Int = 0, data: JSONValue, deleted: Bool = false) { self.id = id; self.kind = kind; self.version = version; self.data = data; self.deleted = deleted } }
public struct CloudSnapshot: Codable, Sendable { public var projectId: String; public var epoch: Int; public var headSeq: Int; public var timingVersion: Int?; public var items: [CloudItem]; public var threads: [DiscussionThread]?; public var deletedItems: [CloudItem]?; public var canImport: Bool?; public var hasMore: Bool?; public var nextCursor: String?
    public var allItems: [CloudItem] { items + (deletedItems ?? []) }
    public func validatedItems(for expectedProjectId: String) throws -> [CloudItem] {
        let all = allItems
        guard projectId == expectedProjectId, epoch >= 1, headSeq >= 0, (timingVersion ?? 0) >= 0,
              Set(all.map(\.id)).count == all.count,
              items.allSatisfy({ $0.deleted != true }), (deletedItems ?? []).allSatisfy({ $0.deleted == true }),
              all.allSatisfy({ !$0.id.isEmpty && $0.version >= 0 }), canImport != true || all.isEmpty else {
            throw ScrivError.invalid("The cloud snapshot has invalid identity, version or deletion metadata.")
        }
        return all
    }
}
public struct CloudChange: Codable, Sendable { public var id: String; public var before: CloudItem?; public var after: CloudItem?; public init(id: String, before: CloudItem?, after: CloudItem?) { self.id = id; self.before = before; self.after = after } }
public struct CloudEvent: Codable, Identifiable, Sendable { public var seq: Int; public var epoch: Int; public var commandId: String; public var actorId: String; public var kind: String; public var at: Int; public var changes: [CloudChange]; public var data: JSONValue?; public var id: Int { seq }; public var label: String { data?["label"]?.string ?? kind } }
public struct EditLease: Codable, Identifiable, Sendable { public var itemId: String; public var sessionId: String; public var token: String?; public var fence: Int; public var expiresAt: Int; public var epoch: Int?; public var userId: String; public var name: String?; public var id: String { itemId } }
public struct PresencePeer: Codable, Identifiable, Sendable {
    public var connectionId: String?; public var deviceId: String?; public var userId: String; public var name: String; public var itemId: String?; public var cursor: JSONValue?; public var selection: JSONValue?; public var updatedAt: Int?
    public var id: String { connectionId ?? deviceId ?? userId }
}
public struct DiscussionThread: Codable, Identifiable, Hashable, Sendable { public var id: String; public var itemId: String?; public var resolved: Bool; public var anchor: JSONValue?; public var createdAt: Int? }
public struct DiscussionMember: Codable, Identifiable, Hashable, Sendable {
    public var id: String; public var name: String; public var role: String
    public init(id: String, name: String, role: String) { self.id = id; self.name = name; self.role = role }
}
public struct DiscussionMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: String; public var threadId: String; public var userId: String?; public var authorId: String?; public var name: String?; public var body: String
    public var createdAt: Int?; public var at: Int?; public var replyToId: String?; public var attachments: [JSONValue]?; public var mentionedUserIds: [String]
    public var timestamp: Date { Date(timeIntervalSince1970: Double(createdAt ?? at ?? 0)/1000) }
    private enum CodingKeys: String, CodingKey { case id, threadId, userId, authorId, name, body, createdAt, at, replyToId, attachments, mentionedUserIds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decode(String.self,forKey:.id); threadId = try c.decode(String.self,forKey:.threadId); body = try c.decode(String.self,forKey:.body)
        userId = try c.decodeIfPresent(String.self,forKey:.userId); authorId = try c.decodeIfPresent(String.self,forKey:.authorId); name = try c.decodeIfPresent(String.self,forKey:.name)
        createdAt = try c.decodeIfPresent(Int.self,forKey:.createdAt); at = try c.decodeIfPresent(Int.self,forKey:.at); replyToId = try c.decodeIfPresent(String.self,forKey:.replyToId)
        attachments = try c.decodeIfPresent([JSONValue].self,forKey:.attachments); mentionedUserIds = try c.decodeIfPresent([String].self,forKey:.mentionedUserIds) ?? []
    }
}
public struct PeerSignal: Codable, Sendable { public var fromDeviceId: String?; public var toDeviceId: String; public var type: String; public var payload: JSONValue; public init(fromDeviceId: String? = nil, toDeviceId: String, type: String, payload: JSONValue) { self.fromDeviceId = fromDeviceId; self.toDeviceId = toDeviceId; self.type = type; self.payload = payload } }

public enum CloudCodec {
    public static func items(from project: ScrivProject) throws -> [CloudItem] {
        try TimingEngine.validate(project)
        var items = try project.scenes.map { CloudItem(id: $0.id, kind: "scene", data: try .encoded($0)) }
        items += try project.entries.map { CloudItem(id: $0.id, kind: "entry", data: try .encoded($0)) }
        items += try project.characters.map { CloudItem(id: $0.id, kind: "character", data: try .encoded($0)) }
        items += try project.images.map { CloudItem(id: $0.id, kind: "image", data: try .encoded($0)) }
        items += try project.cues.map { CloudItem(id: $0.id, kind: "cue", data: try .encoded($0)) }
        return items
    }
    public static func applying(_ items: [CloudItem], to project: ScrivProject) throws -> ScrivProject {
        guard Set(items.map(\.id)).count == items.count else { throw ScrivError.invalid("The server returned duplicate item identities.") }
        var result = project
        result.scenes = []; result.entries = []; result.characters = []; result.images = []; result.cues = []
        for item in items where item.deleted != true {
            guard item.data["id"]?.string == item.id else { throw ScrivError.invalid("Item identity does not match its contents.") }
            switch item.kind {
            case "scene": result.scenes.append(try item.data.decoded(ScriptScene.self))
            case "entry": result.entries.append(try item.data.decoded(ScriptEntry.self))
            case "character": result.characters.append(try item.data.decoded(ScriptCharacter.self))
            case "image": result.images.append(try item.data.decoded(ImageAsset.self))
            case "cue": result.cues.append(try item.data.decoded(ImageCue.self))
            default: throw ScrivError.invalid("Unknown item kind \(item.kind); update Scriv before editing this project.")
            }
        }
        // Audio remains local, but clips cannot keep dangling deleted script anchors.
        let localSceneIDs = Set(result.scenes.map(\.id)), localEntryScenes = Dictionary(uniqueKeysWithValues:result.entries.map { ($0.id,$0.sceneId) })
        result.audioClips.removeAll { clip in !localSceneIDs.contains(clip.sceneId) || (clip.entryId != nil && localEntryScenes[clip.entryId!] != clip.sceneId) }
        result.scenes.sort { $0.order < $1.order }
        try TimingEngine.validate(result)
        return result
    }
}
