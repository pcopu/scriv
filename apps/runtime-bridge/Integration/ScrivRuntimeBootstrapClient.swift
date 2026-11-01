// Compile into the packaging owner's macOS adapter target, never the Catalyst
// target. All macOS-only APIs stay on this side of the platform boundary.
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

@objc(ScrivRuntimeBootstrapClient)
public final class ScrivRuntimeBootstrapClient: NSObject {
    private var connection: NSXPCConnection?
    private var activeID: UUID?
    private var pendingCompletion: ((Data?, NSError?) -> Void)?
    private var timeout: DispatchWorkItem?
    private let lock = NSLock()

    /// Invoke only after explicit first-use Allow, or a deliberate reconnect
    /// under the same valid saved local grant. Never call at app launch.
    /// Returns pairing JSON for Scriv's private Keychain import routine.
    @objc public func connectAfterUserConsent(_ approved: Bool, completion: @escaping (Data?, NSError?) -> Void) {
        guard approved else { completion(nil, ScrivError.permission("Local Codex connection was not approved.") as NSError); return }
        let request = RuntimeBridgeBootstrapRequest(userApproved: true), id = UUID()
        lock.lock()
        guard activeID == nil else { lock.unlock(); completion(nil, ScrivError.conflict("A local connection is already active.") as NSError); return }
        activeID = id; pendingCompletion = completion; lock.unlock()
        do {
            var code: SecCode?, raw: CFDictionary?, staticCode: SecStaticCode?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                  SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                  SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
                  let information = raw as? [String: Any], let team = information[kSecCodeInfoTeamIdentifier as String] as? String else { throw ScrivError.permission("Guided connection requires a team-signed Scriv release.") }
            let ownText = try RuntimeBridgeBootstrapSigning.requirement(teamIdentifier: team, bundleIdentifier: RuntimeBridgeBootstrapSigning.clientIdentifier)
            var ownRequirement: SecRequirement?
            guard SecRequirementCreateWithString(ownText as CFString, [], &ownRequirement) == errSecSuccess,
                  SecCodeCheckValidity(code, [], ownRequirement) == errSecSuccess else { throw ScrivError.permission("The running Scriv release could not prove its identity.") }
            let peerText = try RuntimeBridgeBootstrapSigning.requirement(teamIdentifier: team, bundleIdentifier: RuntimeBridgeBootstrapSigning.serviceIdentifier)
            let bytes = try JSONEncoder().encode(request)
            let c = NSXPCConnection(serviceName: RuntimeBridgeBootstrapSigning.serviceIdentifier)
            c.setCodeSigningRequirement(peerText)
            c.remoteObjectInterface = NSXPCInterface(with: ScrivRuntimeBootstrapProtocol.self)
            c.invalidationHandler = { [weak self] in self?.end(id, error: ScrivError.unavailable("The signed local helper connection ended.") as NSError) }
            c.interruptionHandler = { [weak self] in self?.end(id, error: ScrivError.unavailable("The signed local helper was interrupted.") as NSError) }
            let timer = DispatchWorkItem { [weak self] in self?.end(id, error: ScrivError.unavailable("The signed local helper did not respond. Retry Check & connect.") as NSError) }
            lock.lock()
            guard activeID == id else { lock.unlock(); c.invalidate(); return }
            connection = c; timeout = timer; lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timer)
            c.resume()
            guard let proxy = c.remoteObjectProxyWithErrorHandler({ [weak self] error in self?.end(id, error: error as NSError) }) as? ScrivRuntimeBootstrapProtocol else { throw ScrivError.unavailable("The bundled local helper is unavailable.") }
            proxy.holdConnection { }
            proxy.authorizeConnection(bytes) { [weak self] data, error in
                guard let self else { return }
                do {
                    if let error { throw error }
                    guard let data, data.count <= 8192 else { throw ScrivError.invalid("The signed helper returned an invalid local connection.") }
                    let response = try JSONDecoder().decode(RuntimeBridgeBootstrapResponse.self, from: data)
                    try response.validate(requestID: request.requestID, ownerUID: geteuid())
                    self.succeed(id, data: try JSONEncoder().encode(response.pairing))
                } catch { self.end(id, error: error as NSError) }
            }
        } catch { end(id, error: error as NSError) }
    }
    private func succeed(_ id: UUID, data: Data) {
        lock.lock(); guard activeID == id else { lock.unlock(); return }
        let callback = pendingCompletion; pendingCompletion = nil; timeout?.cancel(); timeout = nil; lock.unlock()
        if let callback { DispatchQueue.main.async { callback(data, nil) } }
    }
    private func end(_ id: UUID, error: NSError) {
        lock.lock(); guard activeID == id else { lock.unlock(); return }
        let callback = pendingCompletion, c = connection
        activeID = nil; pendingCompletion = nil; connection = nil; timeout?.cancel(); timeout = nil; lock.unlock()
        c?.invalidate(); if let callback { DispatchQueue.main.async { callback(nil, error) } }
    }
    @objc public func disconnect() {
        lock.lock(); let id = activeID; lock.unlock()
        if let id { end(id, error: ScrivError.unavailable("Local connection cancelled.") as NSError) }
    }
    deinit { connection?.invalidate(); timeout?.cancel() }
}
