import Foundation

/// Per-image discovery state. Only solicited, authorized sources can be tried;
/// duplicate callbacks never consume a different source or another image's slot.
public struct PeerAssetDiscovery: Sendable {
    public let requestId: String
    private let allowedPeers: Set<String>
    private var available: [String] = []
    private var attempted: Set<String> = []
    public private(set) var activePeer: String?
    public init(requestId: String, allowedPeers: Set<String>) { self.requestId = requestId; self.allowedPeers = allowedPeers }
    @discardableResult public mutating func offer(peer: String, requestId: String) -> Bool {
        guard requestId == self.requestId, allowedPeers.contains(peer), !attempted.contains(peer), !available.contains(peer) else { return false }
        available.append(peer); return true
    }
    public mutating func nextSource() -> String? {
        guard activePeer == nil, !available.isEmpty else { return nil }
        let peer = available.removeFirst(); attempted.insert(peer); activePeer = peer; return peer
    }
    @discardableResult public mutating func failed(peer: String) -> Bool {
        guard activePeer == peer else { return false }
        activePeer = nil; return true
    }
}
