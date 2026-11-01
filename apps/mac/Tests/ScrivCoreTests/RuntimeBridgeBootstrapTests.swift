import XCTest
@testable import ScrivCore

final class RuntimeBridgeBootstrapTests: XCTestCase {
    private let now: Int64 = 1_000_000
    func testExplicitConsentIsRequired() throws {
        let request = RuntimeBridgeBootstrapRequest(userApproved: false, timestamp: now)
        XCTAssertThrowsError(try request.validate(now: now))
        XCTAssertNoThrow(try RuntimeBridgeBootstrapRequest(userApproved: true, timestamp: now).validate(now: now))
    }
    func testExpiredAndFutureConsentIsRejected() {
        for stamp in [now - 60_001, now + 5_001] {
            XCTAssertThrowsError(try RuntimeBridgeBootstrapRequest(userApproved: true, timestamp: stamp).validate(now: now))
        }
    }
    func testConsentCannotBeReplayed() throws {
        let request = RuntimeBridgeBootstrapRequest(userApproved: true, timestamp: now)
        var replay = RuntimeBridgeBootstrapReplayWindow()
        try replay.accept(request, now: now)
        XCTAssertThrowsError(try replay.accept(request, now: now))
        XCTAssertNoThrow(try replay.accept(RuntimeBridgeBootstrapRequest(userApproved: true, timestamp: now), now: now))
    }
    func testResponseMustMatchRequestAndCurrentUser() throws {
        let request = RuntimeBridgeBootstrapRequest(userApproved: true, timestamp: now)
        let pair = RuntimeBridgePairing(ownerUID: 501, port: 12345, secret: Data(repeating: 7, count: 32))
        let response = RuntimeBridgeBootstrapResponse(requestID: request.requestID, pairing: pair)
        XCTAssertNoThrow(try response.validate(requestID: request.requestID, ownerUID: 501))
        XCTAssertThrowsError(try response.validate(requestID: UUID(), ownerUID: 501))
        XCTAssertThrowsError(try response.validate(requestID: request.requestID, ownerUID: 502))
    }
    func testSigningRequirementPinsDeveloperTeamAndBundleIdentifier() throws {
        let r = try RuntimeBridgeBootstrapSigning.requirement(teamIdentifier: "ABCD123456", bundleIdentifier: "app.scriv.uikit")
        XCTAssertEqual(r, "anchor apple generic and certificate leaf[subject.OU] = \"ABCD123456\" and identifier \"app.scriv.uikit\"")
        for team in ["", "ad-hoc", "ABCD12345\""] {
            XCTAssertThrowsError(try RuntimeBridgeBootstrapSigning.requirement(teamIdentifier: team, bundleIdentifier: "app.scriv.uikit"))
        }
        XCTAssertThrowsError(try RuntimeBridgeBootstrapSigning.requirement(teamIdentifier: "ABCD123456", bundleIdentifier: "app\" or true"))
    }
    func testMalformedConsentVersionFailsClosed() throws {
        let bytes = Data("{\"version\":2,\"requestID\":\"00000000-0000-0000-0000-000000000001\",\"timestamp\":1000000,\"userApproved\":true}".utf8)
        let request = try JSONDecoder().decode(RuntimeBridgeBootstrapRequest.self, from: bytes)
        XCTAssertThrowsError(try request.validate(now: now))
    }
    func testGuidedImportCannotReplaceAnExistingDifferentPairing() throws {
        let original = RuntimeBridgePairing(ownerUID: 501, port: 12345, secret: Data(repeating: 7, count: 32))
        let replacement = RuntimeBridgePairing(ownerUID: 501, port: 12346, secret: Data(repeating: 8, count: 32))
        XCTAssertNoThrow(try RuntimeBridgeBootstrapSigning.validateImport(existing: nil, incoming: original, ownerUID: 501))
        XCTAssertNoThrow(try RuntimeBridgeBootstrapSigning.validateImport(existing: original, incoming: original, ownerUID: 501))
        XCTAssertThrowsError(try RuntimeBridgeBootstrapSigning.validateImport(existing: original, incoming: replacement, ownerUID: 501))
    }
}
