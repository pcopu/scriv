import Foundation

/// Local-only capability file. The secret is never sent over the connection;
/// both peers prove possession by signing each exact payload and request nonce.
public struct RuntimeBridgePairing: Codable, Equatable, Sendable {
    public let version: Int
    public let ownerUID: UInt32
    public let port: UInt16
    public let secret: Data
    public let installationID: UUID
    public init(ownerUID: UInt32, port: UInt16, secret: Data, installationID: UUID = UUID()) {
        version = 1; self.ownerUID = ownerUID; self.port = port; self.secret = secret; self.installationID = installationID
    }
    public func validate(ownerUID: UInt32) throws {
        guard version == 1, self.ownerUID == ownerUID, port >= 1024, secret.count == 32 else { throw ScrivError.permission("Choose the pairing file created by the Scriv runtime companion under your current Mac account.") }
    }
}

public struct RuntimeBridgeEnvelope: Codable, Sendable {
    public static let maximumPayloadBytes = 34 * 1024 * 1024
    public static let maximumFrameBytes = 48 * 1024 * 1024
    public let version: Int
    public let nonce: UUID
    public let timestamp: Int64
    public let direction: String
    public let payload: Data
    public let signature: Data
    public init(payload: Data, secret: Data, nonce: UUID = UUID(), timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000), response: Bool = false) throws {
        guard payload.count <= Self.maximumPayloadBytes, secret.count == 32 else { throw ScrivError.invalid("The local runtime message exceeded its safety limit.") }
        version = 1; self.nonce = nonce; self.timestamp = timestamp; direction = response ? "response" : "request"; self.payload = payload
        signature = Self.hmac(Self.signingBytes(nonce: nonce, timestamp: timestamp, direction: direction, payload: payload), key: secret)
    }
    public func verify(secret: Data, response: Bool, expectedNonce: UUID? = nil, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        guard version == 1, secret.count == 32, payload.count <= Self.maximumPayloadBytes,
              direction == (response ? "response" : "request"), expectedNonce == nil || nonce == expectedNonce,
              timestamp >= now - 60_000, timestamp <= now + 60_000 else { throw ScrivError.permission("The local runtime response was stale or invalid. Reopen the companion and reconnect.") }
        let expected = Self.hmac(Self.signingBytes(nonce: nonce, timestamp: timestamp, direction: direction, payload: payload), key: secret)
        guard Self.constantTimeEqual(signature, expected) else { throw ScrivError.permission("The local runtime could not prove its identity. Pair with the companion on this Mac again.") }
    }
    private static func signingBytes(nonce: UUID, timestamp: Int64, direction: String, payload: Data) -> Data {
        Data("ScrivRuntimeBridge/1\n\(direction)\n\(nonce.uuidString.lowercased())\n\(timestamp)\n".utf8) + payload
    }
    public static func hmac(_ message: Data, key: Data) -> Data {
        var bytes = key.count > 64 ? ScrivDigest.bytes(key) : Array(key)
        bytes += Array(repeating: 0, count: 64 - bytes.count)
        let inner = Data(bytes.map { $0 ^ 0x36 }) + message
        return Data(ScrivDigest.bytes(Data(bytes.map { $0 ^ 0x5c }) + Data(ScrivDigest.bytes(inner))))
    }
    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }; var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }; return difference == 0
    }
}

/// Replay state is process-local. Every stateful command also carries a fresh
/// companion instance ID, so restart never makes recorded commands replayable.
public struct RuntimeBridgeReplayWindow: Sendable {
    private var seen: [UUID: Int64] = [:]
    public init() {}
    public mutating func accept(_ envelope: RuntimeBridgeEnvelope, secret: Data, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        try envelope.verify(secret: secret, response: false, now: now)
        seen = seen.filter { $0.value >= now - 120_000 }
        guard seen[envelope.nonce] == nil, seen.count < 4096 else { throw ScrivError.permission("A duplicate or excessive runtime request was rejected.") }
        seen[envelope.nonce] = now
    }
}

public struct RuntimeBridgeCommand: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case status, start, send, poll, stop, rotatePairing }
    public var operation: Operation
    public var sessionID: UUID
    public var instanceID: UUID?
    public var executable: String?
    public var generationRoot: String?
    public var message: Data?
    public var after: Int?
    public init(_ operation: Operation, sessionID: UUID, executable: String? = nil, generationRoot: String? = nil, message: Data? = nil, after: Int? = nil, instanceID: UUID? = nil) {
        self.operation = operation; self.sessionID = sessionID; self.executable = executable; self.generationRoot = generationRoot; self.message = message; self.after = after; self.instanceID = instanceID
    }
}
public struct RuntimeBridgeEvent: Codable, Sendable {
    public let sequence: Int
    public let message: Data
    public init(sequence: Int, message: Data) { self.sequence = sequence; self.message = message }
}
public struct RuntimeBridgeReply: Codable, Sendable {
    public var running: Bool
    public var instanceID: UUID?
    public var events: [RuntimeBridgeEvent]
    public var error: String?
    public init(running: Bool, events: [RuntimeBridgeEvent] = [], error: String? = nil, instanceID: UUID? = nil) { self.running = running; self.events = events; self.error = error; self.instanceID = instanceID }
}

public enum RuntimeBridgePolicy {
    public static func requireInstance(_ command: RuntimeBridgeCommand, current: UUID) throws {
        guard command.operation == .status || command.instanceID == current else { throw ScrivError.permission("The companion restarted. Reconnect before controlling its runtime.") }
    }
    /// The authenticated channel is still not an arbitrary-shell endpoint. Only
    /// the existing image workflow crosses it, with no per-turn sandbox escape
    /// or automatic approval of runtime permission requests.
    public static func validateCodexMessage(_ data: Data, generationRoot: URL) throws {
        guard data.count <= 32 * 1024 * 1024 else { throw ScrivError.invalid("Oversized Codex message.") }
        let value = try ScrivJSON.decoder.decode(JSONValue.self, from: data)
        guard let method = value["method"]?.string else {
            guard value["id"] != nil else { throw ScrivError.invalid("A runtime reply needs its original request identity.") }
            if value["error"]?["code"]?.int == -32601 { return }
            guard let result = value["result"], result == .object(["decision": .string("decline")]) || result == .object(["permissions": .object([:]), "scope": .string("turn")]) || result == .object(["action": .string("decline"), "content": .null]) || result == .object(["answers": .object([:])]) else { throw ScrivError.permission("Scriv never grants additional runtime permissions automatically.") }
            return
        }
        let allowed: Set<String> = ["initialize", "initialized", "model/list", "account/read", "account/login/start", "account/login/cancel", "account/logout", "thread/start", "thread/read", "turn/start", "turn/interrupt"]
        guard allowed.contains(method) else { throw ScrivError.permission("This companion accepts only Scriv's local image workflow, not arbitrary runtime commands.") }
        if method == "thread/start" {
            guard case .object(let params) = value["params"], Set(params.keys).isSubset(of: ["cwd", "approvalPolicy", "sandbox", "model"]), params["approvalPolicy"] == .string("never"), params["sandbox"] == .string("workspace-write"), let path = params["cwd"]?.string else { throw ScrivError.permission("The image thread must use the restricted Scriv workspace.") }
            let directory = URL(fileURLWithPath: path).standardizedFileURL
            guard directory.deletingLastPathComponent() == generationRoot.standardizedFileURL, UUID(uuidString: directory.lastPathComponent) != nil, directory == directory.resolvingSymlinksInPath() else { throw ScrivError.permission("The image thread cannot leave its original generation folder.") }
        }
        if method == "turn/start" {
            guard case .object(let params) = value["params"], Set(params.keys) == ["threadId", "input"], let threadID = params["threadId"]?.string, !threadID.isEmpty, threadID.utf8.count <= 256, let items = params["input"]?.array, !items.isEmpty, items.count <= 6 else { throw ScrivError.permission("The image turn cannot override its workspace or approval policy.") }
            var textCount = 0
            for item in items {
                switch item["type"]?.string {
                case "text": guard item["text"]?.string?.isEmpty == false else { throw ScrivError.invalid("The image direction is empty.") }; textCount += 1
                case "localImage":
                    guard let path = item["path"]?.string else { throw ScrivError.invalid("The reference image has no local path.") }
                    let file = URL(fileURLWithPath: path).standardizedFileURL, directory = file.deletingLastPathComponent()
                    guard directory.deletingLastPathComponent() == generationRoot.standardizedFileURL, UUID(uuidString: directory.lastPathComponent) != nil, file == file.resolvingSymlinksInPath(), file.lastPathComponent.hasPrefix("reference-") else { throw ScrivError.permission("The reference image must stay in this generation's local folder.") }
                default: throw ScrivError.permission("Only the captured text and local image references may be submitted.")
                }
            }
            guard textCount == 1 else { throw ScrivError.invalid("An image turn requires one exact captured prompt.") }
        }
    }
}
