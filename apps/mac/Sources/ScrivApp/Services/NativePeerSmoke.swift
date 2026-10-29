import AppKit
import Foundation
import ScrivCore

/// Runs the shipped WKWebView transport twice, with a real data channel between
/// them. Only signaling is relayed in memory; image bytes cross WebRTC.
@MainActor
enum NativePeerSmoke {
    private static var started = false

    static func runIfRequested() async -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--peer-smoke") else { return false }
        guard !started else { return true }
        started = true
        guard arguments.indices.contains(index + 1) else {
            fputs("Scriv --peer-smoke requires an output directory.\n", stderr)
            exit(1)
        }
        let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivPeerSmoke-" + UUID().uuidString, isDirectory: true)
        let session = NativePeerSmokeSession()
        var watchdog: Task<Void, Never>?
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            watchdog = Task {
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                let message = "WKWebView peer transfer exceeded the 45-second deadline. Sender: \(session.sender.status). Receiver: \(session.receiver.status)."
                session.stop()
                try? Data((message + "\n").utf8).write(to: output.appendingPathComponent("error.txt"), options: .atomic)
                fputs("Scriv native peer smoke failed: \(message)\n", stderr)
                exit(1)
            }
            guard let bundled = Bundle.scrivResources.url(forResource: "farm-wide", withExtension: "png", subdirectory: "SampleImages") ?? Bundle.scrivResources.url(forResource: "farm-wide", withExtension: "png") else {
                throw ScrivError.unavailable("Bundled sample PNG is missing.")
            }
            let source = temporary.appendingPathComponent("source.png")
            try FileManager.default.copyItem(at: bundled, to: source)
            let expected = try Data(contentsOf: source)
            guard expected.count > 16 * 1024 else { throw ScrivError.invalid("The native peer fixture must span multiple data-channel chunks.") }
            let hash = ScrivDigest.sha256(expected)
            let began = Date()
            let received = try await session.transfer(source: source, expected: expected, hash: hash)
            watchdog?.cancel()
            session.stop()
            try received.write(to: output.appendingPathComponent("received.png"), options: .atomic)
            let result: [String: Any] = [
                "transport": "WKWebView RTCPeerConnection",
                "bytes": received.count,
                "sha256": hash,
                "signals": session.signalCount,
                "connectRequests": session.connectRequestCount,
                "offererOffers": session.offerCount,
                "offererDeviceId": session.senderID,
                "requesterDeviceId": session.receiverID,
                "higherIDRequester": session.receiverID > session.senderID,
                "elapsedSeconds": Date().timeIntervalSince(began),
                "iceServers": 0,
                "byteEquality": received == expected
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"), options: .atomic)
            try Data("PASS: the higher-ID requester sent an explicit connection request through the native transport router; the lower-ID sender offered the connection. Two native WKWebView bridges transferred \(received.count) bytes over a real WebRTC data channel. SHA-256 and byte equality verified. No cloud account or external ICE service was used.\n".utf8).write(to: output.appendingPathComponent("result.txt"), options: .atomic)
            try? FileManager.default.removeItem(at: temporary)
            NSApp.terminate(nil)
            return true
        } catch {
            watchdog?.cancel()
            session.stop()
            try? FileManager.default.removeItem(at: temporary)
            let message = "Native WKWebView peer smoke failed: " + error.localizedDescription + "\n"
            try? Data(message.utf8).write(to: output.appendingPathComponent("error.txt"), options: .atomic)
            fputs(message, stderr)
            exit(1)
        }
    }
}

@MainActor
private final class NativePeerSmokeSession {
    let sender = PeerMediaBridge()
    let receiver = PeerMediaBridge()
    private(set) var signalCount = 0
    private(set) var connectRequestCount = 0
    private(set) var offerCount = 0
    private var received: Data?
    private var failure: Error?
    let senderID = "a-native-peer-smoke-sender"
    let receiverID = "z-native-peer-smoke-receiver"

    func transfer(source: URL, expected: Data, hash: String) async throws -> Data {
        guard senderID < receiverID else { throw ScrivError.invalid("The native smoke requester must have the higher device ID.") }
        sender.onError = { [weak self] error in self?.failure = error }
        receiver.onError = { [weak self] error in self?.failure = error }
        sender.onSignal = { [weak self] signal in
            guard let self else { return }
            relay(signal, from: senderID, to: receiverID, bridge: receiver)
        }
        receiver.onSignal = { [weak self] signal in
            guard let self else { return }
            relay(signal, from: receiverID, to: senderID, bridge: sender)
        }
        receiver.onAsset = { [weak self] receivedHash, bytes in
            guard let self else { return }
            guard receivedHash == hash, bytes == expected, ScrivDigest.sha256(bytes) == hash else {
                failure = ScrivError.invalid("The received native data-channel image differs from the bundled source.")
                return
            }
            received = bytes
        }
        try await sender.start(deviceId: senderID, iceServers: .array([]))
        try await receiver.start(deviceId: receiverID, iceServers: .array([]))
        sender.authorize(knownHashes: [hash], localAssets: [hash: source])
        receiver.authorize(knownHashes: [hash], localAssets: [:])
        try await receiver.requestAsset(hash: hash, fromDeviceId: senderID)
        while received == nil {
            if let failure { throw failure }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let failure { throw failure }
        guard let received, signalCount > 0, connectRequestCount > 0, offerCount > 0 else { throw ScrivError.invalid("The native transfer completed without the required connection-request and sole-offerer evidence.") }
        return received
    }

    private func relay(_ signal: PeerSignal, from: String, to: String, bridge: PeerMediaBridge) {
        guard signal.toDeviceId == to else {
            failure = ScrivError.invalid("Native peer smoke signaled an unexpected device.")
            return
        }
        let routed = PeerSignal(fromDeviceId: from, toDeviceId: to, type: signal.type, payload: signal.payload)
        // Exercise the same classifier used by WorkspaceStore before forwarding
        // the explicit connect action into the actual WKWebView bridge.
        guard PeerMediaBridge.isTransportSignal(routed) else {
            failure = ScrivError.invalid("Native peer smoke emitted a signal outside the transport route.")
            return
        }
        if routed.type == "asset-request" {
            guard from == receiverID, to == senderID else { failure = ScrivError.invalid("The connection request did not originate at the higher-ID requester."); return }
            connectRequestCount += 1
        } else if routed.type == "offer" {
            guard from == senderID else { failure = ScrivError.invalid("The higher-ID requester attempted to create an offer."); return }
            offerCount += 1
        }
        signalCount += 1
        Task { [weak self] in
            do { try await bridge.handleSignal(routed) }
            catch { self?.failure = error }
        }
    }

    func stop() {
        sender.onSignal = nil; sender.onAsset = nil; sender.onError = nil
        receiver.onSignal = nil; receiver.onAsset = nil; receiver.onError = nil
        sender.disconnect(); receiver.disconnect()
    }
}
