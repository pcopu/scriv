import XCTest
@testable import ScrivCore

final class CodexCharacterTurnStateTests: XCTestCase {
    private func message(_ text: String = "{\"detections\":[]}", id: String = "answer", phase: String = "final_answer") -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string(phase)])
    }
    private func item(_ value: JSONValue, thread: String = "owned", turn: String = "turn") -> JSONValue {
        .object(["threadId": .string(thread), "turnId": .string(turn), "item": value])
    }
    private func completion(_ items: [JSONValue] = [], thread: String = "owned", turn: String = "turn", status: String = "completed") -> JSONValue {
        .object(["threadId": .string(thread), "turn": .object(["id": .string(turn), "status": .string(status), "items": .array(items)])])
    }
    func testCompletedStructuredMessageIsAcceptedOnlyForOwnedTurn() {
        var state = CodexCharacterTurnState(); state.startThread("owned"); XCTAssertNil(state.startTurn("turn"))
        state.receive(method: "item/completed", params: item(message("foreign"), thread: "other"))
        state.receive(method: "item/completed", params: item(message("old"), turn: "old"))
        XCTAssertNil(state.finalText)
        state.receive(method: "item/completed", params: item(message()))
        XCTAssertNil(state.finalText, "An item alone is not a completed turn")
        state.receive(method: "turn/completed", params: completion())
        XCTAssertEqual(state.finalText, "{\"detections\":[]}")
    }
    func testEarlyItemsAndCompletionSurviveStartReplyRace() {
        var state = CodexCharacterTurnState(); state.startThread("owned")
        state.receive(method: "item/completed", params: item(message()))
        state.receive(method: "turn/completed", params: completion())
        XCTAssertNil(state.finalText); XCTAssertNil(state.startTurn("turn"))
        XCTAssertEqual(state.finalText, "{\"detections\":[]}")
    }
    func testCompletionCanCarryTheFinalMessageWithoutItemEvents() {
        var state = CodexCharacterTurnState(); state.startThread("owned"); _ = state.startTurn("turn")
        state.receive(method: "turn/completed", params: completion([message()]))
        XCTAssertEqual(state.finalText, "{\"detections\":[]}")
    }
    func testToolActivityStopsAnalysisEvenBeforeStartReplyAndNeverYieldsJSON() {
        for type in ["commandExecution", "mcpToolCall", "dynamicToolCall", "fileChange", "webSearch", "imageGeneration", "unknownFutureTool"] {
            var state = CodexCharacterTurnState(); state.startThread("owned")
            state.receive(method: "item/started", params: item(.object(["type": .string(type)])))
            XCTAssertNotNil(state.failure, type)
            _ = state.startTurn("turn")
            state.receive(method: "turn/completed", params: completion([message()]))
            XCTAssertNil(state.finalText, type)
        }
    }
    func testToolInCompletionCannotBypassActivityMonitor() {
        var state = CodexCharacterTurnState(); state.startThread("owned"); _ = state.startTurn("turn")
        state.receive(method: "turn/completed", params: completion([message(), .object(["type": .string("mcpToolCall")])]))
        XCTAssertNotNil(state.failure); XCTAssertNil(state.finalText)
    }
    func testToolOutputNotificationStopsAnalysisWithoutStartedItem() {
        var state = CodexCharacterTurnState(); state.startThread("owned"); _ = state.startTurn("turn")
        state.receive(method: "item/commandExecution/outputDelta", params: .object(["threadId": .string("owned"), "turnId": .string("turn"), "delta": .string("unexpected")]))
        XCTAssertNotNil(state.failure)
    }
    func testForeignToolActivityDoesNotCancelOwnedAnalysis() {
        var state = CodexCharacterTurnState(); state.startThread("owned"); _ = state.startTurn("turn")
        let tool: JSONValue = .object(["type": .string("commandExecution")])
        state.receive(method: "item/started", params: item(tool, thread: "other"))
        state.receive(method: "item/started", params: item(tool, turn: "other"))
        XCTAssertNil(state.failure)
    }
    func testCancellationBeforeTurnIDInterruptsLateTurnExactlyOnce() {
        var state = CodexCharacterTurnState(); state.startThread("owned")
        XCTAssertNil(state.cancel()); XCTAssertEqual(state.startTurn("turn")?.turnID, "turn"); XCTAssertNil(state.cancel())
        state.receive(method: "turn/completed", params: completion([message()]))
        XCTAssertNil(state.finalText)
    }
    func testCommentaryAndIncompleteTurnsAreNeverAccepted() {
        for status in ["failed", "interrupted", "inProgress"] {
            var state = CodexCharacterTurnState(); state.startThread("owned"); _ = state.startTurn("turn")
            state.receive(method: "turn/completed", params: completion([message()], status: status))
            XCTAssertNil(state.finalText)
        }
        var state = CodexCharacterTurnState(); state.startThread("owned"); _ = state.startTurn("turn")
        state.receive(method: "turn/completed", params: completion([message("working", phase: "commentary")]))
        XCTAssertNil(state.finalText)
    }
    func testResponseLimitAndStickyFailure() {
        var state = CodexCharacterTurnState(); state.startThread("owned"); _ = state.startTurn("turn")
        state.receive(method: "item/completed", params: item(message(String(repeating: "a", count: 65_537))))
        let first = state.failure; XCTAssertNotNil(first); state.reject("later"); XCTAssertEqual(state.failure, first)
        state.receive(method: "turn/completed", params: completion([message()]))
        XCTAssertNil(state.finalText)
    }
}
