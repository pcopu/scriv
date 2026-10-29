import Foundation

/// The last canonical cloud state accepted by this local package. This is not an authentication token.
public struct CloudCheckpoint: Codable, Sendable {
    public var projectId: String
    public var serverURL: String
    public var accountId: String
    public var epoch: Int
    public var headSeq: Int
    public var timingVersion: Int
    public var items: [CloudItem]
    public init(projectId: String, serverURL: String, accountId: String, epoch: Int, headSeq: Int, timingVersion: Int, items: [CloudItem]) {
        self.projectId = projectId; self.serverURL = serverURL; self.accountId = accountId; self.epoch = epoch
        self.headSeq = headSeq; self.timingVersion = timingVersion; self.items = items
    }
}

public enum CloudReconciliation {
    private static func active(_ items: [CloudItem]) throws -> [String:CloudItem] {
        guard Set(items.map(\.id)).count == items.count else { throw ScrivError.invalid("Cloud state contains duplicate identities.") }
        return Dictionary(uniqueKeysWithValues: items.filter { $0.deleted != true }.map { ($0.id,$0) })
    }
    private static func content(_ item: CloudItem?) -> JSONValue? {
        item.map { .object(["kind":.string($0.kind),"data":$0.data]) }
    }
    private static func timing(_ items: [String:CloudItem], geometryOnly: Bool = false) -> JSONValue {
        var values: [String:JSONValue] = [:]
        for (id,item) in items {
            let keys: [String]
            switch item.kind {
            case "entry": keys = ["sceneId","order","kind","ownedDurationMs","coverageDurationMs"] + (geometryOnly ? [] : ["text","words"])
            case "cue": keys = ["sceneId","startMs","endMs"]
            default: continue
            }
            values[id] = .object(Dictionary(uniqueKeysWithValues: keys.map { ($0,item.data[$0] ?? .null) }))
        }
        return .object(values)
    }
    /// Merge independent item edits. Scene clock changes form one concurrency domain,
    /// so two offline duration/text/cut edits never silently compose into a new timing.
    public static func merge(base: [CloudItem], local: [CloudItem], remote: [CloudItem]) throws -> [CloudItem] {
        let baseline = try active(base), draft = try active(local), canonical = try active(remote)
        let originalTiming = timing(baseline), localTiming = timing(draft), remoteTiming = timing(canonical)
        let localGeometryChanged = timing(draft,geometryOnly:true) != timing(baseline,geometryOnly:true)
        let remoteGeometryChanged = timing(canonical,geometryOnly:true) != timing(baseline,geometryOnly:true)
        if (localGeometryChanged && remoteTiming != originalTiming || remoteGeometryChanged && localTiming != originalTiming) && localTiming != remoteTiming {
            throw ScrivError.conflict("The script timing changed on another Mac while this draft was offline. Both versions are retained; review the cloud version before applying this timing edit.")
        }
        let canonicalVersions = Dictionary(uniqueKeysWithValues:remote.map { ($0.id,$0.version) })
        var merged: [CloudItem] = []
        for id in Set(baseline.keys).union(draft.keys).union(canonical.keys).sorted() {
            let before = content(baseline[id]), here = content(draft[id]), there = content(canonical[id])
            let selected: CloudItem?
            if here == before { selected = canonical[id] }
            else if there == before || here == there { selected = draft[id] }
            else { throw ScrivError.conflict("An item was edited on both Macs (\(id)). Your local draft and the complete cloud history are retained.") }
            if var selected { selected.version = canonicalVersions[id] ?? 0; merged.append(selected) }
        }
        return merged
    }
}
