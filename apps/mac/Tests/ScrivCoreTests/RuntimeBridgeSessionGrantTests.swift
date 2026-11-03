import XCTest
@testable import ScrivCore

final class RuntimeBridgeSessionGrantTests: XCTestCase {
    private func pairing(secret: String = String(repeating: "a", count: 64), owner: UInt32 = 501) -> RuntimeBridgePairing {
        RuntimeBridgePairing(ownerUID: owner, port: 4501, secret: secret)
    }
    func testApprovedSessionGrantConnectsWithoutPersistentStorageAndDoesNotSurviveRestart() throws {
        var session = RuntimeBridgeSessionGrant()
        let approved = pairing()
        XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
        try session.retain(approved, ownerUID: 501)
        XCTAssertEqual(try session.resolve(persistent: nil, ownerUID: 501), approved)
        XCTAssertNil(try RuntimeBridgeSessionGrant().resolve(persistent: nil, ownerUID: 501))
        session.reset()
        XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
    }
    func testSessionGrantCannotReplaceAnotherApprovedCapability() throws {
        var session = RuntimeBridgeSessionGrant()
        let approved = pairing()
        try session.retain(approved, ownerUID: 501)
        XCTAssertThrowsError(try session.retain(pairing(secret: String(repeating: "b", count: 64)), ownerUID: 501))
        XCTAssertEqual(try session.resolve(persistent: nil, ownerUID: 501), approved)
    }
    func testPersistentGrantRemainsAuthoritativeAndConflictsFailClosed() throws {
        var session = RuntimeBridgeSessionGrant()
        let approved = pairing()
        XCTAssertEqual(try session.resolve(persistent: approved, ownerUID: 501), approved)
        try session.retain(approved, ownerUID: 501)
        XCTAssertEqual(try session.resolve(persistent: approved, ownerUID: 501), approved)
        XCTAssertThrowsError(try session.resolve(persistent: pairing(secret: String(repeating: "b", count: 64)), ownerUID: 501))
        XCTAssertEqual(try session.resolve(persistent: nil, ownerUID: 501), approved)
    }
    func testSessionGrantRejectsWrongOwnerAndInvalidCapabilities() {
        var session = RuntimeBridgeSessionGrant()
        XCTAssertThrowsError(try session.retain(pairing(owner: 502), ownerUID: 501))
        XCTAssertThrowsError(try session.retain(pairing(secret: "invalid"), ownerUID: 501))
        XCTAssertThrowsError(try session.resolve(persistent: pairing(owner: 502), ownerUID: 501))
        XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
    }
}
