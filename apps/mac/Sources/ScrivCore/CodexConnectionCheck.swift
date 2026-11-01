import Foundation

/// A check is not a connection, and a connection is not a signed-in account.
/// The attempt token fences cancelled/replaced checks and late transport replies.
public struct CodexConnectionCheck: Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, checking, notFound, incompatible, signInRequired, ready, cancelled }
    public private(set) var phase: Phase = .idle
    public private(set) var attempt: UUID?
    public init() {}
    @discardableResult public mutating func begin() -> UUID? {
        guard attempt == nil else { return nil }
        let id = UUID(); attempt = id; phase = .checking; return id
    }
    public func accepts(_ id: UUID) -> Bool { attempt == id }
    public mutating func finish(_ phase: Phase, attempt id: UUID) {
        guard accepts(id), phase != .checking else { return }
        self.phase = phase; attempt = nil
    }
    public mutating func cancel() { attempt = nil; phase = .cancelled }
    public mutating func reset() { attempt = nil; phase = .idle }
}

public enum CodexLocalSetup {
    /// Host-side discovery only. Catalyst passes this choice to its paired
    /// companion, which retains executable ownership/name/permission checks.
    public static let automaticExecutable = "automatic"
    public static func resolveExecutable(preferredPath: String? = nil, homeDirectory: URL? = nil, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        #if targetEnvironment(macCatalyst)
        // The client has no host-home discovery authority. Only explicit
        // synthetic roots may exercise this pure policy in Catalyst tests.
        guard let homeDirectory else { return nil }
        #else
        let homeDirectory = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        #endif
        if let preferredPath, preferredPath != automaticExecutable {
            guard preferredPath.hasPrefix("/"), isExecutable(preferredPath) else { return nil }
            return preferredPath
        }
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            homeDirectory.appendingPathComponent(".npm-global/bin/codex").path
        ]
        return candidates.first(where: isExecutable)
    }
    public static let defaultEndpoint = "ws://127.0.0.1:4500"
    public static let installCommand = "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
    public static let signInCommand = "codex"
    public static let serverCommand = "codex app-server --listen ws://127.0.0.1:4500"
    /// No credentials, redirects, LAN addresses, or command text are accepted.
    /// localhost is normalized to numeric loopback instead of resolved via DNS.
    public static func endpointURL(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["ws", "wss"].contains(parts.scheme ?? ""),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(parts.host ?? ""),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.query == nil, parts.port.map({ (1024...65535).contains($0) }) ?? false else {
            throw ScrivError.permission("Use an unprivileged loopback Codex app-server address on this Mac, without credentials or query parameters.")
        }
        if parts.host == "localhost" { parts.host = "127.0.0.1" }
        guard let url = parts.url else { throw ScrivError.invalid("The local Codex address is invalid.") }
        return url
    }
}

/// Explicit catalog evidence for future image-analysis providers. Connection or
/// image-generation support alone never grants image-input capability.
public struct CodexModelCapabilities: Equatable, Sendable {
    public let model: String
    public let inputModalities: Set<String>?
    public var supportsImageInput: Bool { inputModalities?.contains("image") == true }
    public init(model: String, inputModalities: Set<String>?) { self.model = model; self.inputModalities = inputModalities }
}

/// Decode readiness without reading credentials or inferring sign-in from an
/// installed app. Shared with regression fixtures and the actual RPC client.
public struct CodexAccountReadiness: Equatable, Sendable {
    public let label: String?
    public let requiresAuthentication: Bool
    public var isReady: Bool { label != nil || !requiresAuthentication }
    public init(response: JSONValue) throws {
        guard case .object = response, let account = response["account"] else { throw ScrivError.invalid("This runtime did not return a compatible account status. No sign-in conclusion was made.") }
        requiresAuthentication = response["requiresOpenaiAuth"] != .bool(false)
        if account == .null { label = nil }
        else {
            guard case .object = account, let type = account["type"]?.string, !type.isEmpty else { throw ScrivError.invalid("This runtime returned an invalid account identity.") }
            label = account["email"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? type
        }
    }
    public static func validateInitialize(_ response: JSONValue) throws {
        guard case .object = response, response["userAgent"]?.string?.isEmpty == false else { throw ScrivError.invalid("This listener did not return a compatible Codex app-server handshake. Update Codex and check again.") }
    }
}
