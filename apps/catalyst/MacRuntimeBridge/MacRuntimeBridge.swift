import Foundation
import UIKit
import Network
import Security
import Darwin
import ScrivCore

/// The Catalyst process cannot launch children. An explicitly opened, separately
/// installed same-user companion owns Process; this channel never grants shell
/// commands, LAN access, implicit model requests, or access to cloud credentials.
@MainActor
final class MacRuntimeBridge {
    private let pairing: RuntimeBridgePairing
    private let sessionID = UUID()
    private var polling: Task<Void, Never>?
    private var running = false
    private var cursor = 0
    private var instanceID: UUID?
    var onMessage: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    static var isPaired: Bool { (try? loadPairing()) != nil }
    init() throws { pairing = try Self.loadPairing() }
    static func importPairing(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 4096 else { throw ScrivError.invalid("Choose the companion's small .scrivbridge pairing file.") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(), ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw ScrivError.permission("The pairing file must be private to your Mac account (0600). Select the original file in the companion's Application Support folder, not a shared copy.") }
        let data = try Data(contentsOf: url), pairing = try JSONDecoder().decode(RuntimeBridgePairing.self, from: data)
        try pairing.validate(ownerUID: geteuid())
        let encoded = try JSONEncoder().encode(pairing)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Scriv.LocalRuntimeBridge", kSecAttrAccount as String: "same-user-pairing"]
        var result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: encoded] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = encoded; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(item as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw ScrivError.unavailable("The local runtime pairing could not be saved to this Mac's Keychain. The previous pairing was kept.") }
    }
    static func forgetPairing() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Scriv.LocalRuntimeBridge", kSecAttrAccount as String: "same-user-pairing"] as CFDictionary)
    }
    private static func loadPairing() throws -> RuntimeBridgePairing {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Scriv.LocalRuntimeBridge", kSecAttrAccount as String: "same-user-pairing", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, data.count <= 4096 else { throw ScrivError.unavailable("Open the separately installed Scriv Runtime Companion, then choose Pair companion in Settings. No runtime has started.") }
        let pairing = try JSONDecoder().decode(RuntimeBridgePairing.self, from: data); try pairing.validate(ownerUID: geteuid()); return pairing
    }
    static func openCompanion() async throws {
        guard let url = URL(string: "scriv-runtime-companion://open") else { return }
        let opened = await UIApplication.shared.open(url)
        guard opened else { throw ScrivError.unavailable("Scriv Runtime Companion is not installed or its URL handler is unavailable. Install the separately signed companion from this Scriv build, open it explicitly, then import its pairing file. Scriv does not download or install helpers automatically.") }
    }
    func start(executable: String, generationRoot: URL) async throws {
        guard !running else { throw ScrivError.conflict("The owned runtime is already connected.") }
        let status = try await request(.init(.status, sessionID: sessionID))
        guard let instance = status.instanceID else { throw ScrivError.permission("The companion did not provide its current process identity.") }; instanceID = instance
        let reply = try await request(.init(.start, sessionID: sessionID, executable: executable, generationRoot: generationRoot.path))
        guard reply.running else { throw ScrivError.unavailable("The companion did not start Codex.") }
        running = true; cursor = 0
        polling = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled, self.running {
                    let reply = try await self.request(.init(.poll, sessionID: self.sessionID, after: self.cursor))
                    guard !Task.isCancelled, self.running else { return }
                    for event in reply.events where event.sequence > self.cursor { self.cursor = event.sequence; self.onMessage?(event.message) }
                    if !reply.running { throw ScrivError.unavailable("The local Codex process stopped.") }
                    try await Task.sleep(for: .milliseconds(200))
                }
            } catch is CancellationError {} catch {
                guard self.running else { return }; self.running = false; self.onClose?(error.localizedDescription)
            }
        }
    }
    func send(_ data: Data) async throws {
        guard running else { throw ScrivError.unavailable("The local runtime companion is not connected.") }
        _ = try await request(.init(.send, sessionID: sessionID, message: data))
    }
    /// Captures the ownership capability before returning. Stop is never sent to
    /// an external WebSocket server; the helper also checks the exact session.
    func stop() {
        polling?.cancel(); polling = nil; let wasRunning = running; running = false
        guard wasRunning else { return }
        Task { _ = try? await request(.init(.stop, sessionID: sessionID)) }
    }
    func rotatePairing() async throws {
        guard !running else { throw ScrivError.conflict("Stop Codex before rotating local pairing.") }
        let status = try await request(.init(.status, sessionID: sessionID)); instanceID = status.instanceID
        guard instanceID != nil else { throw ScrivError.permission("The companion identity is missing.") }
        _ = try await request(.init(.rotatePairing, sessionID: sessionID)); Self.forgetPairing()
    }
    private func request(_ original: RuntimeBridgeCommand) async throws -> RuntimeBridgeReply {
        try Task.checkCancellation()
        var command = original; command.instanceID = instanceID
        let request = try RuntimeBridgeEnvelope(payload: JSONEncoder().encode(command), secret: pairing.secret)
        let bytes = try await RuntimeBridgeExchange(port: pairing.port).exchange(try JSONEncoder().encode(request))
        let response = try JSONDecoder().decode(RuntimeBridgeEnvelope.self, from: bytes)
        try response.verify(secret: pairing.secret, response: true, expectedNonce: request.nonce)
        let reply = try JSONDecoder().decode(RuntimeBridgeReply.self, from: response.payload)
        if let error = reply.error { throw ScrivError.unavailable(error) }; return reply
    }
}

/// One bounded frame per connection; a hostile local listener gets no secret and
/// cannot forge a response. There are no redirects, cookies, DNS or proxy routes.
private final class RuntimeBridgeExchange: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Scriv.RuntimeBridge.exchange")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Data, Error>?
    private var timeout: DispatchWorkItem?
    private var received = Data()
    private var expected: Int?
    private var cancelled = false
    init(port: UInt16) { connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp) }
    func exchange(_ payload: Data) async throws -> Data {
        guard payload.count <= RuntimeBridgeEnvelope.maximumFrameBytes else { throw ScrivError.invalid("The local runtime request is too large.") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.cancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    let timer = DispatchWorkItem { self.finish(.failure(ScrivError.unavailable("The local companion did not respond. Open it on this Mac, or pair again if its capability was rotated."))) }; self.timeout = timer; self.queue.asyncAfter(deadline: .now() + 15, execute: timer)
                    self.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            var count = UInt32(payload.count).bigEndian; let prefix = withUnsafeBytes(of: &count) { Data($0) }
                            self.connection.send(content: prefix + payload, completion: .contentProcessed { error in
                                if let error { self.finish(.failure(error)) } else { self.receive() }
                            })
                        case .failed(let error): self.finish(.failure(error))
                        case .cancelled: self.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                    self.connection.start(queue: self.queue)
                }
            }
        } onCancel: { self.queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) } }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            if let data { self.received.append(data) }
            if self.expected == nil, self.received.count >= 4 {
                let size = self.received.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; self.received.removeFirst(4)
                guard size > 0, size <= RuntimeBridgeEnvelope.maximumFrameBytes else { self.finish(.failure(ScrivError.invalid("Invalid local runtime frame."))); return }; self.expected = Int(size)
            }
            guard self.received.count <= RuntimeBridgeEnvelope.maximumFrameBytes else { self.finish(.failure(ScrivError.invalid("Oversized local runtime frame."))); return }
            if let expected = self.expected, self.received.count >= expected {
                guard self.received.count == expected else { self.finish(.failure(ScrivError.invalid("Unexpected local runtime data."))); return }
                self.finish(.success(self.received)); return
            }
            if let error { self.finish(.failure(error)) } else if complete { self.finish(.failure(ScrivError.unavailable("The local runtime closed before answering."))) } else { self.receive() }
        }
    }
    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }; self.continuation = nil; timeout?.cancel(); timeout = nil; connection.stateUpdateHandler = nil; connection.cancel(); continuation.resume(with: result)
    }
}
