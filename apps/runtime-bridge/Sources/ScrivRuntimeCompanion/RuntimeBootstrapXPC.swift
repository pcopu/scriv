import Foundation
import Security
import Darwin
// Bundled native targets compile the canonical Core sources in this module.
// Standalone SwiftPM builds retain their normal package dependency.
#if !SCRIV_EMBEDDED_NATIVE_CORE
import ScrivCore
#endif

@objc(ScrivRuntimeBootstrapProtocol)
protocol ScrivRuntimeBootstrapProtocol {
    func authorizeConnection(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func holdConnection(withReply reply: @escaping () -> Void)
}

/// Resolves this process's validated Developer ID team, never a bundle-plist
/// claim. Ad-hoc/unsigned development binaries cannot release pairing material.
func runtimeBootstrapTeam(expectedIdentifier: String) throws -> String {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw ScrivError.permission("Scriv's local helper signature could not be verified.") }
    var raw: CFDictionary?, staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
          let information = raw as? [String: Any], let team = information[kSecCodeInfoTeamIdentifier as String] as? String else { throw ScrivError.permission("Guided connection requires a team-signed Scriv release.") }
    let text = try RuntimeBridgeBootstrapSigning.requirement(teamIdentifier: team, bundleIdentifier: expectedIdentifier)
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
          SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw ScrivError.permission("Scriv's local helper identity did not match its signed release.") }
    return team
}

final class RuntimeBootstrapService: NSObject, NSXPCListenerDelegate {
    private let runtime: RuntimeCompanion
    private let queue = DispatchQueue(label: "Scriv.RuntimeBootstrap.consent")
    private var replay = RuntimeBridgeBootstrapReplayWindow()
    private var activeSession: UUID?
    private let clientRequirement: String
    init(runtime: RuntimeCompanion) throws {
        self.runtime = runtime
        let team = try runtimeBootstrapTeam(expectedIdentifier: RuntimeBridgeBootstrapSigning.serviceIdentifier)
        clientRequirement = try RuntimeBridgeBootstrapSigning.requirement(teamIdentifier: team, bundleIdentifier: RuntimeBridgeBootstrapSigning.clientIdentifier)
        super.init()
    }
    func run() {
        let listener = NSXPCListener.service(); listener.delegate = self
        withExtendedLifetime(self) { listener.resume() }
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        let id = UUID()
        let accepted = queue.sync { () -> Bool in
            guard activeSession == nil else { return false }; activeSession = id; return true
        }
        guard accepted else { return false }
        // Applied before resume; the OS checks every incoming peer message.
        connection.setCodeSigningRequirement(clientRequirement)
        let session = RuntimeBootstrapSession(service: self, id: id)
        connection.exportedInterface = NSXPCInterface(with: ScrivRuntimeBootstrapProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { session.invalidate() }
        connection.resume(); return true
    }
    fileprivate func clientEnded(_ id: UUID) {
        queue.sync {
            guard activeSession == id else { return }
            // Exactly one bootstrap client owns this service. Stop its owned
            // child before releasing the XPC activity on disconnect/crash.
            runtime.endBootstrapSession(); activeSession = nil
        }
    }
    fileprivate func authorize(_ data: Data, sessionID: UUID, reply: @escaping (Data?, NSError?) -> Void) {
        queue.async {
            do {
                guard self.activeSession == sessionID else { throw ScrivError.unavailable("The local confirmation was cancelled.") }
                guard data.count <= 4096 else { throw ScrivError.invalid("The local confirmation request is invalid.") }
                let request = try JSONDecoder().decode(RuntimeBridgeBootstrapRequest.self, from: data)
                try self.replay.accept(request)
                // No listener, pairfile, Keychain operation or child is started
                // until the signed caller's explicit consent has been validated.
                self.runtime.bootstrapPairing { result in
                    do {
                        let pair = try result.get()
                        let response = RuntimeBridgeBootstrapResponse(requestID: request.requestID, pairing: pair)
                        reply(try JSONEncoder().encode(response), nil)
                    } catch { reply(nil, error as NSError) }
                }
            } catch { reply(nil, error as NSError) }
        }
    }
}

private final class RuntimeBootstrapSession: NSObject, ScrivRuntimeBootstrapProtocol {
    private let service: RuntimeBootstrapService
    private let id: UUID
    private let lock = NSLock()
    private var heldReply: (() -> Void)?
    init(service: RuntimeBootstrapService, id: UUID) { self.service = service; self.id = id }
    func authorizeConnection(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) { service.authorize(request, sessionID: id, reply: reply) }
    /// Outstanding work keeps this XPC service active while the client owns its
    /// bridge. Invalidation releases it; the existing runtime lease still bounds
    /// an abandoned model connection and never resubmits interrupted work.
    func holdConnection(withReply reply: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard heldReply == nil else { reply(); return }; heldReply = reply
    }
    func invalidate() {
        service.clientEnded(id)
        lock.lock(); let reply = heldReply; heldReply = nil; lock.unlock(); reply?()
    }
}
