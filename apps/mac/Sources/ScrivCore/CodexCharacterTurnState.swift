import Foundation

/// A separate, bounded observer for one owned analysis thread. Observing and
/// interrupting tool activity is not a replacement for the runtime's permissions.
public struct CodexCharacterTurnState {
    public private(set) var lifecycle = CodexGenerationState()
    public private(set) var failure: String?
    private var messages: [String: String] = [:]
    private var messageOrder: [String] = []
    private var earlyItems: [String: [JSONValue]] = [:]
    public init() {}
    public mutating func startThread(_ id: String) { lifecycle.startThread(id) }
    public mutating func startTurn(_ id: String) -> CodexGenerationState.Turn? {
        let interruption = lifecycle.startTurn(id)
        for item in earlyItems[id] ?? [] { record(item) }
        earlyItems = [:]
        if let completion = lifecycle.completion { for item in completion["items"]?.array ?? [] { record(item) } }
        return interruption
    }
    public mutating func cancel() -> CodexGenerationState.Turn? { lifecycle.requestCancellation() }
    public mutating func reject(_ reason: String) { if failure == nil { failure = reason } }
    public mutating func receive(method: String, params: JSONValue) {
        guard let thread = lifecycle.threadID, params["threadId"]?.string == thread else { return }
        if let turn = params["turnId"]?.string, let current = lifecycle.turnID, turn != current { return }
        let safeDeltas: Set<String> = ["item/agentMessage/delta", "item/reasoning/textDelta", "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded"]
        if (method.hasPrefix("item/") && !["item/started", "item/completed"].contains(method) && !safeDeltas.contains(method)) || method == "turn/diff/updated" {
            reject("Codex reported unexpected tool activity during character analysis. The scan was stopped; review the original turn before retrying.")
            return
        }
        if method == "turn/completed", let turn = params["turn"] {
            lifecycle.recordCompletion(threadID: thread, turn: turn)
            if let current = lifecycle.turnID, turn["id"]?.string == current {
                for item in turn["items"]?.array ?? [] { record(item) }
            }
            return
        }
        guard ["item/started", "item/completed"].contains(method), let item = params["item"], let turn = params["turnId"]?.string else { return }
        if let current = lifecycle.turnID, current != turn { return }
        let type = item["type"]?.string ?? "unknown"
        guard ["agentMessage", "reasoning", "userMessage"].contains(type) else {
            reject("Codex attempted \(type) during character analysis. The scan was stopped; review the turn in Codex before retrying.")
            return
        }
        guard method == "item/completed" else { return }
        if lifecycle.turnID == nil {
            guard earlyItems.count < 8, (earlyItems[turn]?.count ?? 0) < 100 else { reject("The analysis returned too many early items."); return }
            earlyItems[turn, default: []].append(item)
        } else { record(item) }
    }
    private mutating func record(_ item: JSONValue) {
        let type = item["type"]?.string ?? "unknown"
        guard ["agentMessage", "reasoning", "userMessage"].contains(type) else { reject("Codex used an unexpected tool during character analysis. The scan was stopped; review it before retrying."); return }
        guard type == "agentMessage", item["phase"]?.string != "commentary", let text = item["text"]?.string else { return }
        let id = item["id"]?.string ?? "final"
        if messages[id] == nil { messageOrder.append(id) }
        messages[id] = text
        if messages.count > 100 || messages.values.reduce(0, { $0 + $1.utf8.count }) > 65_536 { reject("The character analysis response exceeded its limit.") }
    }
    public var finalText: String? {
        guard failure == nil, !lifecycle.cancellationRequested, lifecycle.completion?["status"] == .string("completed") else { return nil }
        return messageOrder.last.flatMap { messages[$0] }
    }
}
