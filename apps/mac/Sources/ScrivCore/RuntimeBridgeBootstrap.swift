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

/// A validated, explicitly approved capability for this application process.
/// Only the authenticated bootstrap boundary may retain a grant. Storage is
/// delegated to the caller; this cannot make a failed Keychain read safe:
/// callers must establish a readable persistent grant (or definite absence)
/// before resolving it. Conflicting grants require an explicit reset.
public struct RuntimeBridgeSessionGrant: Sendable {
    /// The storage adapter maps only these exact create outcomes. All other
    /// failures throw; a read error is never represented by an absent grant.
    public enum CreateResult: Sendable { case saved, duplicate, missingEntitlement }
    private var approved: RuntimeBridgePairing?
    public init() {}

    /// Authenticated bootstrap is create-only. Keeping this policy independent
    /// of Security.framework permits synthetic coverage without real secrets
    /// or changes to the user's Keychain.
    public mutating func importBootstrapped(_ incoming: RuntimeBridgePairing, ownerUID: UInt32,
                                           readPersistent: () throws -> RuntimeBridgePairing?,
                                           createPersistent: (RuntimeBridgePairing) throws -> CreateResult) throws {
        try incoming.validate(ownerUID: ownerUID)
        let existing = try resolve(persistent: readPersistent(), ownerUID: ownerUID)
        try RuntimeBridgeBootstrapSigning.validateImport(existing: existing, incoming: incoming, ownerUID: ownerUID)
        if existing != nil { return }
        switch try createPersistent(incoming) {
        case .saved: return
        case .duplicate:
            guard let raced = try readPersistent() else { throw ScrivError.conflict("Local pairing changed. Try again.") }
            try RuntimeBridgeBootstrapSigning.validateImport(existing: raced, incoming: incoming, ownerUID: ownerUID)
        case .missingEntitlement:
            // A failed add says nothing about a concurrently created or now
            // inaccessible grant. Only definite absence permits memory storage.
            let raced = try readPersistent()
            try RuntimeBridgeBootstrapSigning.validateImport(existing: raced, incoming: incoming, ownerUID: ownerUID)
            if raced == nil { try retain(incoming, ownerUID: ownerUID) }
        }
    }

    public mutating func retain(_ incoming: RuntimeBridgePairing, ownerUID: UInt32) throws {
        try RuntimeBridgeBootstrapSigning.validateImport(existing: approved, incoming: incoming, ownerUID: ownerUID)
        approved = incoming
    }

    public func resolve(persistent: RuntimeBridgePairing?, ownerUID: UInt32) throws -> RuntimeBridgePairing? {
        if let persistent { try persistent.validate(ownerUID: ownerUID) }
        if let approved {
            try approved.validate(ownerUID: ownerUID)
            try RuntimeBridgeBootstrapSigning.validateImport(existing: persistent, incoming: approved, ownerUID: ownerUID)
        }
        return persistent ?? approved
    }

    public mutating func reset() { approved = nil }
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
