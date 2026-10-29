import Foundation

/// Local editor scopes may briefly overlap while a sheet opens and an old editor
/// finishes its queued save. Register before awaiting the network, not afterward.
public struct LocalEditIntents: Sendable {
    private var counts: [String:Int] = [:]
    public init() {}
    public mutating func begin(_ itemID: String) { counts[itemID, default: 0] += 1 }
    public mutating func end(_ itemID: String) {
        guard let count = counts[itemID] else { return }
        if count > 1 { counts[itemID] = count - 1 } else { counts.removeValue(forKey: itemID) }
    }
    public func contains(_ itemID: String) -> Bool { counts[itemID, default: 0] > 0 }
}
