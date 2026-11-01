import XCTest
@testable import ScrivCore

final class RuntimeBridgeEnvelopeTests: XCTestCase {
    let secret = Data(repeating: 0x2a, count: 32)
    func testHMACPublishedVector() {
        let result = RuntimeBridgeEnvelope.hmac(Data("Hi There".utf8), key: Data(repeating: 0x0b, count: 20))
        XCTAssertEqual(result.map { String(format: "%02x", $0) }.joined(), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }
    func testMutualProofAndNonce() throws {
        let request = try RuntimeBridgeEnvelope(payload: Data("status".utf8), secret: secret, timestamp: 100_000)
        try request.verify(secret: secret, response: false, now: 100_000)
        XCTAssertThrowsError(try request.verify(secret: secret, response: true, now: 100_000))
        let reply = try RuntimeBridgeEnvelope(payload: Data("ready".utf8), secret: secret, nonce: request.nonce, timestamp: 100_000, response: true)
        try reply.verify(secret: secret, response: true, expectedNonce: request.nonce, now: 100_000)
        XCTAssertThrowsError(try reply.verify(secret: secret, response: true, expectedNonce: UUID(), now: 100_000))
        XCTAssertThrowsError(try reply.verify(secret: Data(repeating: 0, count: 32), response: true, now: 100_000))
    }
    func testTamperReplayAndClockWindow() throws {
        let request = try RuntimeBridgeEnvelope(payload: Data("start".utf8), secret: secret, timestamp: 100_000)
        var window = RuntimeBridgeReplayWindow(); try window.accept(request, secret: secret, now: 100_000)
        XCTAssertThrowsError(try window.accept(request, secret: secret, now: 100_001))
        XCTAssertThrowsError(try request.verify(secret: secret, response: false, now: 160_001))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]); json["payload"] = Data("stop".utf8).base64EncodedString()
        let changed = try JSONDecoder().decode(RuntimeBridgeEnvelope.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try changed.verify(secret: secret, response: false, now: 100_000))
    }
    func testPairingRejectsDifferentUserAndInvalidKey() throws {
        try RuntimeBridgePairing(ownerUID: 501, port: 19461, secret: secret).validate(ownerUID: 501)
        XCTAssertThrowsError(try RuntimeBridgePairing(ownerUID: 502, port: 19461, secret: secret).validate(ownerUID: 501))
        XCTAssertThrowsError(try RuntimeBridgePairing(ownerUID: 501, port: 80, secret: secret).validate(ownerUID: 501))
        XCTAssertThrowsError(try RuntimeBridgePairing(ownerUID: 501, port: 19461, secret: Data()).validate(ownerUID: 501))
    }
    func testRequestsNeverContainTheSecret() throws {
        let value = try RuntimeBridgeEnvelope(payload: Data("request".utf8), secret: secret)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains(secret.base64EncodedString()))
    }
    func testInstanceFenceSurvivesReplayWindowReset() throws {
        let previous = UUID(), current = UUID(), session = UUID()
        try RuntimeBridgePolicy.requireInstance(.init(.status, sessionID: session), current: current)
        XCTAssertThrowsError(try RuntimeBridgePolicy.requireInstance(.init(.start, sessionID: session, instanceID: previous), current: current))
        XCTAssertThrowsError(try RuntimeBridgePolicy.requireInstance(.init(.send, sessionID: session), current: current))
        try RuntimeBridgePolicy.requireInstance(.init(.start, sessionID: session, instanceID: current), current: current)
    }
    func testNoArbitraryCommandsOrApprovalEscalation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Generation")
        func data(_ value: JSONValue) throws -> Data { try ScrivJSON.encoder.encode(value) }
        XCTAssertThrowsError(try RuntimeBridgePolicy.validateCodexMessage(data(.object(["method": .string("command/exec"), "params": .object([:])])), generationRoot: root))
        XCTAssertThrowsError(try RuntimeBridgePolicy.validateCodexMessage(data(.object(["id": .number(5), "result": .object(["decision": .string("accept")])])), generationRoot: root))
        try RuntimeBridgePolicy.validateCodexMessage(data(.object(["id": .number(5), "result": .object(["decision": .string("decline")])])), generationRoot: root)
        XCTAssertThrowsError(try RuntimeBridgePolicy.validateCodexMessage(data(.object(["method": .string("turn/start"), "params": .object(["threadId": .string("t"), "input": .array([.object(["type": .string("text"), "text": .string("image")])]), "sandboxPolicy": .string("danger-full-access")])])), generationRoot: root))
    }
    func testRestrictedTurnPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Generation")
        let params: JSONValue = .object(["threadId": .string("existing-thread"), "input": .array([.object(["type": .string("text"), "text": .string("Exact captured prompt")])])])
        try RuntimeBridgePolicy.validateCodexMessage(ScrivJSON.encoder.encode(JSONValue.object(["method": .string("turn/start"), "params": params])), generationRoot: root)
        XCTAssertThrowsError(try RuntimeBridgePolicy.validateCodexMessage(ScrivJSON.encoder.encode(JSONValue.object(["method": .string("turn/start"), "params": .object(["threadId": .string("existing-thread"), "input": .array([.object(["type": .string("localImage"), "path": .string("/etc/passwd")])])])])), generationRoot: root))
    }

    func testCharacterAnalysisThreadAndInlineTurnAreNarrowlyWhitelisted() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivBridgePolicy-" + UUID().uuidString, isDirectory: true)
        let generation = fixture.appendingPathComponent("Generation", isDirectory: true)
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        // The adapter creates both directories before sending the thread. Real
        // directory URLs also preserve Foundation's trailing-slash identity.
        let root = generation.resolvingSymlinksInPath().standardizedFileURL
        let directory = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        func validate(_ method: String, _ params: [String: JSONValue]) throws {
            try RuntimeBridgePolicy.validateCodexMessage(ScrivJSON.encoder.encode(JSONValue.object(["method": .string(method), "params": .object(params)])), generationRoot: root)
        }
        let thread: [String: JSONValue] = ["cwd": .string(directory.path), "model": .string("vision"), "approvalPolicy": .string("never"), "sandbox": .string("read-only"), "ephemeral": .bool(true), "developerInstructions": .string(CodexCharacterAnalysisProtocol.developerInstructions)]
        try validate("thread/start", thread)
        for (key, value) in ["ephemeral": JSONValue.bool(false), "sandbox": .string("danger-full-access"), "config": .object([:]), "developerInstructions": .string("different"), "cwd": .string("/")] {
            var changed = thread; changed[key] = value; XCTAssertThrowsError(try validate("thread/start", changed), key)
        }
        let prompt: JSONValue = .object(["type": .string("text"), "text": .string("Explicit captured character context")])
        let image: JSONValue = .object(["type": .string("image"), "url": .string("data:image/jpeg;base64," + Data([0xff, 0xd8, 0xff]).base64EncodedString())])
        let turn: [String: JSONValue] = ["threadId": .string("owned"), "input": .array([prompt, image]), "cwd": .string(directory.path), "approvalPolicy": .string("never"), "sandboxPolicy": .object(["type": .string("readOnly"), "networkAccess": .bool(false)]), "outputSchema": CodexCharacterAnalysisProtocol.outputSchema]
        try validate("turn/start", turn)
        for (key, value) in ["sandboxPolicy": JSONValue.object(["type": .string("readOnly"), "networkAccess": .bool(true)]), "approvalPolicy": .string("on-request"), "cwd": .string("/"), "outputSchema": .object([:]), "tools": .array([])] {
            var changed = turn; changed[key] = value; XCTAssertThrowsError(try validate("turn/start", changed), key)
        }
        let invalidImages: [JSONValue] = [
            .object(["type": .string("image"), "url": .string("https://example.invalid/image.png")]),
            .object(["type": .string("localImage"), "path": .string("/etc/passwd")]),
            .object(["type": .string("image"), "url": .string("data:image/jpeg;base64,invalid!")])
        ]
        for invalidImage in invalidImages {
            var changed = turn; changed["input"] = .array([prompt, invalidImage]); XCTAssertThrowsError(try validate("turn/start", changed))
        }
        let outside = fixture.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let escapingLink = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escapingLink, withDestinationURL: outside)
        for invalidDirectory in [outside, escapingLink] {
            var changedThread = thread; changedThread["cwd"] = .string(invalidDirectory.path)
            XCTAssertThrowsError(try validate("thread/start", changedThread))
            var changedTurn = turn; changedTurn["cwd"] = .string(invalidDirectory.path)
            XCTAssertThrowsError(try validate("turn/start", changedTurn))
        }
        for method in ["config/value/write", "mcpServer/reload", "command/exec", "fs/readFile"] { XCTAssertThrowsError(try validate(method, [:])) }
    }

}
