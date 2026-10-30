import Foundation
import Combine
import WebKit
import ScrivCore

/// Headless WebKit supplies Apple's WebRTC stack without shipping a second runtime.
/// The host authorizes every hash against the currently open project's image catalog.
@MainActor
final class PeerMediaBridge: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published private(set) var status = "Peer transfer stopped"
    var onSignal: ((PeerSignal) -> Void)?
    var onAsset: ((String, Data) -> Void)?
    var onError: ((Error) -> Void)?
    var onTransferError: ((_ peer: String, _ hash: String, _ error: Error) -> Void)?
    private var view: WKWebView?
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var knownHashes: Set<String> = []
    private var availableAssets: [String: URL] = [:]
    private struct Request: Hashable { let peer: String; let hash: String }
    private var requests: Set<Request> = []
    private var generation = 0
    private let limit = 25 * 1024 * 1024

    func authorize(knownHashes: Set<String>, localAssets: [String: URL]) {
        self.knownHashes = knownHashes
        requests = requests.filter { knownHashes.contains($0.hash) }
        availableAssets = localAssets.filter { knownHashes.contains($0.key) && $0.value.isFileURL }
    }

    func start(deviceId: String, iceServers: JSONValue) async throws {
        disconnect()
        generation += 1
        let current = generation
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "scrivPeer")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        view = webView
        guard let url = Bundle.scrivResources.url(forResource: "bridge", withExtension: "html", subdirectory: "PeerTransfer") ?? Bundle.scrivResources.url(forResource: "bridge", withExtension: "html") else {
            throw ScrivError.unavailable("The peer transfer resource is missing from this build.")
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        do { try await awaitReady() }
        catch { if generation == current { disconnect() }; throw error }
        guard generation == current, view === webView else { throw CancellationError() }
        let servers = try JSONSerialization.jsonObject(with: ScrivJSON.encoder.encode(iceServers))
        _ = try await webView.callAsyncJavaScript("ScrivPeer.configure({deviceId, iceServers, maxBytes});", arguments: ["deviceId": deviceId, "iceServers": servers, "maxBytes": limit], in: nil, contentWorld: .page)
        guard generation == current, view === webView else { throw CancellationError() }
        status = "Ready for peer images"
    }

    private func awaitReady() async throws {
        if ready { return }
        let current = generation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyWaiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.generation == current, !self.ready else { return }
                self.finishReady(ScrivError.unavailable("WebRTC could not initialize on this Mac."))
            }
        }
    }

    private func finishReady(_ error: Error? = nil) {
        let waiters = readyWaiters; readyWaiters.removeAll()
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    func requestAsset(hash: String, fromDeviceId: String) async throws {
        guard knownHashes.contains(hash), hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ScrivError.permission("This image does not belong to the open project.") }
        guard ready, let view else { throw ScrivError.unavailable("Peer transfer is not connected.") }
        let current = generation
        let request = Request(peer: fromDeviceId, hash: hash)
        requests.insert(request)
        status = "Receiving image from another Mac…"
        do {
            _ = try await view.callAsyncJavaScript("return await ScrivPeer.requestAsset(hash, peer);", arguments: ["hash": hash, "peer": fromDeviceId], in: nil, contentWorld: .page)
            guard generation == current, self.view === view else { throw CancellationError() }
        } catch {
            if generation == current, requests.remove(request) != nil { onTransferError?(fromDeviceId, hash, error) }
            throw error
        }
    }

    /// Discovery query/available messages stay with WorkspaceStore. Only the
    /// explicit connect action joins SDP and ICE on the WebRTC transport path.
    static func isTransportSignal(_ signal: PeerSignal) -> Bool {
        ["offer", "answer", "ice"].contains(signal.type) || signal.type == "asset-request" && signal.payload["action"]?.string == "connect"
    }

    func handleSignal(_ signal: PeerSignal) async throws {
        guard let from = signal.fromDeviceId, !from.isEmpty, Self.isTransportSignal(signal), ready, let view else { return }
        let payload = try JSONSerialization.jsonObject(with: ScrivJSON.encoder.encode(signal.payload))
        _ = try await view.callAsyncJavaScript("return await ScrivPeer.handleSignal(message);", arguments: ["message": ["fromDeviceId": from, "type": signal.type, "payload": payload]], in: nil, contentWorld: .page)
    }

    func disconnect() {
        generation += 1
        if let view { view.evaluateJavaScript("globalThis.ScrivPeer?.disconnect()") { _, _ in }; view.configuration.userContentController.removeScriptMessageHandler(forName: "scrivPeer"); view.stopLoading() }
        view = nil; ready = false; requests.removeAll(); knownHashes.removeAll(); availableAssets.removeAll()
        finishReady(ScrivError.unavailable("Peer transport disconnected."))
        status = "Peer transfer stopped"
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let currentView = view, message.webView === currentView, message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready": ready = true; finishReady()
        case "signal":
            guard let peer = body["toDeviceId"] as? String, let type = body["type"] as? String, let payload = body["payload"], let bytes = try? JSONSerialization.data(withJSONObject: payload), let json = try? ScrivJSON.decoder.decode(JSONValue.self, from: bytes) else { return }
            onSignal?(PeerSignal(toDeviceId: peer, type: type, payload: json))
        case "request":
            guard let peer = body["fromDeviceId"] as? String, let hash = body["hash"] as? String else { return }
            let localURL = availableAssets[hash]
            let current = generation
            Task { [weak self] in
                guard let self, self.generation == current, self.view === currentView else { return }
                var encoded: Any = NSNull()
                if self.knownHashes.contains(hash), let localURL {
                    let limit = self.limit
                    let data = await Task.detached(priority: .utility) { () -> Data? in
                        guard let size = try? localURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), size.isRegularFile == true, let count = size.fileSize, count > 0, count <= limit,
                              let data = try? Data(contentsOf: localURL), ScrivDigest.sha256(data) == hash else { return nil }
                        return data
                    }.value
                    if let data { encoded = data.base64EncodedString() }
                }
                guard self.generation == current, self.view === currentView else { return }
                if !self.knownHashes.contains(hash) || self.availableAssets[hash] != localURL { encoded = NSNull() }
                do { _ = try await currentView.callAsyncJavaScript("return await ScrivPeer.provideAsset(peer, hash, base64);", arguments: ["peer": peer, "hash": hash, "base64": encoded], in: nil, contentWorld: .page) }
                catch { if self.generation == current, self.view === currentView { self.onError?(error) } }
            }
        case "asset":
            guard let hash = body["hash"] as? String, let peer = body["fromDeviceId"] as? String else { return }
            let request = Request(peer: peer, hash: hash)
            // A different source may still be fulfilling the same image. Its
            // authorization cannot be consumed by this source's result/error.
            guard requests.contains(request), knownHashes.contains(hash) else { return }
            requests.remove(request)
            guard let encoded = body["base64"] as? String, encoded.utf8.count <= ((limit + 2) / 3) * 4,
                  let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= limit, ScrivDigest.sha256(data) == hash else {
                let error = ScrivError.invalid("The peer image failed its integrity check.")
                onTransferError?(peer, hash, error); onError?(error); return
            }
            status = "Image received and verified"; onAsset?(hash, data)
        case "connected": status = "Encrypted peer connection"
        case "disconnected": status = "Peer disconnected — ready to reconnect"
        case "error":
            let text = body["message"] as? String ?? "Peer image transfer failed."
            let error = ScrivError.unavailable(text)
            if let hash = body["hash"] as? String, let peer = body["fromDeviceId"] as? String,
               requests.remove(Request(peer: peer, hash: hash)) != nil { onTransferError?(peer, hash, error) }
            status = text; onError?(error)
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { guard view === webView else { return }; finishReady(error); onError?(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { guard view === webView else { return }; finishReady(error); onError?(error) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}
