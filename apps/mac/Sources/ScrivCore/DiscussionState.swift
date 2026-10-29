import Foundation

/// HTTP catch-up and live replay may deliver the same message in either order.
public enum DiscussionState {
    public enum RefreshAction: Equatable, Sendable { case none, loadThread, reloadMessages }
    public static func refreshAction(isVisible: Bool, isAttached: Bool, hasThread: Bool, isLoading: Bool) -> RefreshAction {
        guard isVisible, isAttached else { return .none }
        if hasThread { return .reloadMessages }
        return isLoading ? .none : .loadThread
    }
    public static func validatedMentionIDs(_ ids: [String], members: [DiscussionMember]) throws -> [String] {
        guard ids.count <= 20, Set(ids).count == ids.count else { throw ScrivError.invalid("Choose up to 20 different project members.") }
        let allowed = Set(members.map(\.id))
        guard ids.allSatisfy({ allowed.contains($0) }) else { throw ScrivError.invalid("A mentioned person is no longer a project member. Remove that mention and try again.") }
        return ids.sorted()
    }
    public static func mentions(_ messages: [DiscussionMessage], userID: String?) -> [DiscussionMessage] {
        guard let userID else { return [] }
        var unique: [String:DiscussionMessage] = [:]
        for message in messages where message.mentionedUserIds.contains(userID) { unique[message.id] = message }
        return unique.values.sorted { ($0.createdAt ?? $0.at ?? 0,$0.id) > ($1.createdAt ?? $1.at ?? 0,$1.id) }
    }
    public static func merged(_ existing: [DiscussionMessage], with incoming: [DiscussionMessage], threadId: String) -> [DiscussionMessage] {
        var byID: [String: DiscussionMessage] = [:]
        for message in existing + incoming where message.threadId == threadId { byID[message.id] = message }
        return byID.values.sorted { ($0.createdAt ?? $0.at ?? 0, $0.id) < ($1.createdAt ?? $1.at ?? 0, $1.id) }
    }
    public static func draftKey(server: String, account: String?, project: String, item: String?) -> String {
        // JSON framing distinguishes missing IDs and delimiter-containing identities.
        let scope: JSONValue = .array([.string(server), account.map(JSONValue.string) ?? .null, .string(project), item.map(JSONValue.string) ?? .null])
        return ScrivDigest.sha256((try? ScrivJSON.encoder.encode(scope)) ?? Data())
    }
}
