import XCTest
@testable import ScrivCore

final class CodexConnectionCheckTests: XCTestCase {
    func testOneClickCannotStartDuplicateChecks() throws {
        var check = CodexConnectionCheck(); let attempt = try XCTUnwrap(check.begin())
        XCTAssertEqual(check.phase, .checking); XCTAssertNil(check.begin())
        check.finish(.ready, attempt: attempt); XCTAssertEqual(check.phase, .ready); XCTAssertNil(check.attempt)
    }
    func testAbsentIncompatibleAndSignedOutAreDistinctAndRetriable() throws {
        var check = CodexConnectionCheck()
        for phase in [CodexConnectionCheck.Phase.notFound, .incompatible, .signInRequired, .ready] {
            let attempt = try XCTUnwrap(check.begin()); check.finish(phase, attempt: attempt)
            XCTAssertEqual(check.phase, phase); XCTAssertNil(check.attempt)
        }
    }
    func testCancelAndNewerCheckRejectStaleSuccessAndFailure() throws {
        var check = CodexConnectionCheck(); let old = try XCTUnwrap(check.begin()); check.cancel()
        check.finish(.ready, attempt: old); XCTAssertEqual(check.phase, .cancelled)
        let current = try XCTUnwrap(check.begin()); check.finish(.notFound, attempt: old)
        XCTAssertEqual(check.phase, .checking); XCTAssertTrue(check.accepts(current))
        check.finish(.ready, attempt: current); XCTAssertEqual(check.phase, .ready)
    }
    func testEndpointIsNumericLoopbackAndRejectsUnsafeInput() throws {
        XCTAssertEqual(try CodexLocalSetup.endpointURL("ws://localhost:4500").host, "127.0.0.1")
        XCTAssertEqual(try CodexLocalSetup.endpointURL(CodexLocalSetup.defaultEndpoint).port, 4500)
        for value in ["ws://example.com:4500", "ws://0.0.0.0:4500", "ws://127.0.0.1:80", "https://127.0.0.1:4500", "ws://a:b@127.0.0.1:4500", "ws://127.0.0.1:4500?token=secret", "ws://127.0.0.1:4500#fragment", "ws://127.0.0.1:65536"] {
            XCTAssertThrowsError(try CodexLocalSetup.endpointURL(value), value)
        }
    }
    func testCapabilityIsNotInferredFromConnectionOrModelName() {
        XCTAssertFalse(CodexModelCapabilities(model: "image-model", inputModalities: nil).supportsImageInput)
        XCTAssertFalse(CodexModelCapabilities(model: "text-model", inputModalities: ["text"]).supportsImageInput)
        XCTAssertTrue(CodexModelCapabilities(model: "reported-model", inputModalities: ["text", "image"]).supportsImageInput)
    }
    func testSetupCommandsAreLiteralOfficialLocalInstructions() {
        XCTAssertEqual(CodexLocalSetup.installCommand, "curl -fsSL https://chatgpt.com/codex/install.sh | sh")
        XCTAssertEqual(CodexLocalSetup.signInCommand, "codex")
        XCTAssertEqual(CodexLocalSetup.serverCommand, "codex app-server --listen ws://127.0.0.1:4500")
    }
    func testReadyAccountAndSignInRequiredUseActualProtocolEvidence() throws {
        let signedOut = try CodexAccountReadiness(response: .object(["account": .null, "requiresOpenaiAuth": .bool(true)]))
        XCTAssertFalse(signedOut.isReady); XCTAssertNil(signedOut.label)
        let signedIn = try CodexAccountReadiness(response: .object(["account": .object(["type": .string("chatgpt"), "email": .string("synthetic@example.test")]), "requiresOpenaiAuth": .bool(true)]))
        XCTAssertTrue(signedIn.isReady); XCTAssertEqual(signedIn.label, "synthetic@example.test")
        let noAccountNeeded = try CodexAccountReadiness(response: .object(["account": .null, "requiresOpenaiAuth": .bool(false)]))
        XCTAssertTrue(noAccountNeeded.isReady); XCTAssertNil(noAccountNeeded.label)
    }
    func testMissingAndMalformedAccountRepliesNeverBecomeSignedOutOrReady() {
        for response in [JSONValue.null, .object([:]), .object(["account": .string("signed in")]), .object(["account": .object(["type": .string("")])])] {
            XCTAssertThrowsError(try CodexAccountReadiness(response: response))
        }
    }
    func testIncompatibleInitializeReplyCannotClaimAConnection() throws {
        for response in [JSONValue.null, .object([:]), .object(["userAgent": .number(1)]), .object(["userAgent": .string("")])] {
            XCTAssertThrowsError(try CodexAccountReadiness.validateInitialize(response))
        }
        XCTAssertNoThrow(try CodexAccountReadiness.validateInitialize(.object(["userAgent": .string("synthetic-app-server/1")])) )
    }
    func testAutomaticDiscoveryFindsInstalledChatGPTBundledCLI() {
        let path = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        XCTAssertEqual(CodexLocalSetup.resolveExecutable(preferredPath: CodexLocalSetup.automaticExecutable, homeDirectory: URL(fileURLWithPath: "/synthetic"), isExecutable: { $0 == path }), path)
    }
    func testSavedExecutableIsPreservedAndMissingExplicitChoiceDoesNotFallBack() {
        let custom = "/synthetic/custom/codex"
        XCTAssertEqual(CodexLocalSetup.resolveExecutable(preferredPath: custom, isExecutable: { _ in true }), custom)
        XCTAssertNil(CodexLocalSetup.resolveExecutable(preferredPath: custom, isExecutable: { $0 != custom }))
    }
    func testAutomaticDiscoveryUsesKnownCLILocationsAndReturnsNilWhenAbsent() {
        let home = URL(fileURLWithPath: "/synthetic")
        XCTAssertEqual(CodexLocalSetup.resolveExecutable(homeDirectory: home, isExecutable: { $0 == "/synthetic/.npm-global/bin/codex" }), "/synthetic/.npm-global/bin/codex")
        XCTAssertEqual(CodexLocalSetup.resolveExecutable(homeDirectory: home, isExecutable: { _ in true }), "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        XCTAssertNil(CodexLocalSetup.resolveExecutable(homeDirectory: home, isExecutable: { _ in false }))
    }
    func testRelativeExplicitExecutableIsRejected() {
        XCTAssertNil(CodexLocalSetup.resolveExecutable(preferredPath: "codex", isExecutable: { _ in true }))
    }
}
