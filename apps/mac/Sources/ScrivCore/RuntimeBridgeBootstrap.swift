import Foundation

/// Created only after the first-use confirmation is accepted. This is not a
/// replacement for signed XPC peer authentication and never contains a secret.
public struct RuntimeBridgeBootstrapRequest: Codable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let timestamp: Int64
    public let userApproved: Bool
    public init(userApproved: Bool, requestID: UUID = UUID(), timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        version = 1; self.userApproved = userApproved; self.requestID = requestID; self.timestamp = timestamp
    }
    public func validate(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        guard version == 1, userApproved, timestamp >= now - 60_000, timestamp <= now + 5_000 else {
            throw ScrivError.permission("Confirm the local Codex connection in Scriv before continuing.")
        }
    }
}

public struct RuntimeBridgeBootstrapReplayWindow: Sendable {
    private var seen: [UUID: Int64] = [:]
    public init() {}
    public mutating func accept(_ request: RuntimeBridgeBootstrapRequest, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        try request.validate(now: now)
        seen = seen.filter { $0.value >= now - 60_000 }
        guard seen[request.requestID] == nil, seen.count < 4096 else { throw ScrivError.permission("This local connection confirmation was already used. Confirm again in Scriv.") }
        seen[request.requestID] = request.timestamp
    }
}

/// Pairing bytes travel only over mutually code-signing-constrained XPC, never
/// in URLs, arguments, logs, pasteboard, project files, or an unauthenticated port.
public struct RuntimeBridgeBootstrapResponse: Codable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let pairing: RuntimeBridgePairing
    public init(requestID: UUID, pairing: RuntimeBridgePairing) { version = 1; self.requestID = requestID; self.pairing = pairing }
    public func validate(requestID: UUID, ownerUID: UInt32) throws {
        guard version == 1, self.requestID == requestID else { throw ScrivError.permission("The local connection confirmation did not match this request.") }
        try pairing.validate(ownerUID: ownerUID)
    }
}

public enum RuntimeBridgeBootstrapSigning {
    /// The guided path may create an app-private saved copy or reuse the same
    /// one. Replacing a different capability needs the existing explicit reset
    /// workflow; first-use setup never performs rotation or overwrite.
    public static func validateImport(existing: RuntimeBridgePairing?, incoming: RuntimeBridgePairing, ownerUID: UInt32) throws {
        try incoming.validate(ownerUID: ownerUID)
        guard existing == nil || existing == incoming else { throw ScrivError.conflict("An existing local pairing was preserved. Reconnect it or use the explicit pairing-reset controls before changing companions.") }
    }
    public static let serviceIdentifier = "com.scriv.runtime-companion.bootstrap"
    public static let clientIdentifier = "app.scriv.uikit"
    public static func requirement(teamIdentifier: String, bundleIdentifier: String) throws -> String {
        let teamCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let identifierCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        guard teamIdentifier.utf8.count == 10, teamIdentifier.unicodeScalars.allSatisfy({ teamCharacters.contains($0) }),
              !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 255,
              bundleIdentifier.unicodeScalars.allSatisfy({ identifierCharacters.contains($0) }) else {
            throw ScrivError.permission("Guided local connection requires a correctly team-signed Scriv release.")
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(bundleIdentifier)\""
    }
}

/// A verified capability for this process when the build cannot save to Keychain.
/// Persistent grants remain authoritative; conflicts never replace either grant.
public struct RuntimeBridgeSessionGrant: Sendable {
    private var pairing: RuntimeBridgePairing?
    public init() {}
    public mutating func retain(_ incoming: RuntimeBridgePairing, ownerUID: UInt32) throws {
        try RuntimeBridgeBootstrapSigning.validateImport(existing: pairing, incoming: incoming, ownerUID: ownerUID)
        pairing = incoming
    }
    public func resolve(persistent: RuntimeBridgePairing?, ownerUID: UInt32) throws -> RuntimeBridgePairing? {
        if let persistent {
            try RuntimeBridgeBootstrapSigning.validateImport(existing: pairing, incoming: persistent, ownerUID: ownerUID)
            return persistent
        }
        if let pairing { try pairing.validate(ownerUID: ownerUID) }
        return pairing
    }
    public mutating func reset() { pairing = nil }
}
