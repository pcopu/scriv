import XCTest
@testable import ScrivCore
final class CodexConnectionReadinessTests: XCTestCase {
    func testDisconnectedNeverClaimsMissingLogin() {
        for checked in [true, false] {
            for label in [nil, "existing-account"] as [String?] {
                let state = CodexConnectionReadiness(isConnected: false, accountChecked: checked, accountLabel: label)
                XCTAssertEqual(state, .disconnected); XCTAssertFalse(state.requiresSignIn)
                XCTAssertTrue(state.generationBlocker!.contains("existing CLI or desktop sign-in may already be valid"))
            }
        }
    }
    func testConnectedUnknownIsNotSignedOut() {
        let state = CodexConnectionReadiness(isConnected: true, accountChecked: false, accountLabel: nil)
        XCTAssertEqual(state, .checkingAccount); XCTAssertFalse(state.requiresSignIn)
    }
    func testOnlyVerifiedMissingAccountRequiresSignIn() {
        let state = CodexConnectionReadiness(isConnected: true, accountChecked: true, accountLabel: nil)
        XCTAssertEqual(state, .signedOut); XCTAssertTrue(state.requiresSignIn)
        XCTAssertEqual(CodexConnectionReadiness(isConnected: true, accountChecked: true, accountLabel: "existing-account"), .ready)
        XCTAssertNil(CodexConnectionReadiness.ready.generationBlocker)
    }
}
