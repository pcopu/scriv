import Foundation
import XCTest
@testable import ScrivCore

final class RuntimeBridgeSessionGrantTests: XCTestCase {
    private let installation = UUID(uuidString: "C773A73A-C62F-4A12-A72C-500F13A4DB88")!
    private func pairing(secret: Data = Data(repeating: 0xa1, count: 32), owner: UInt32 = 501,
                         port: UInt16 = 4501, installationID: UUID? = nil) -> RuntimeBridgePairing {
        RuntimeBridgePairing(ownerUID: owner, port: port, secret: secret, installationID: installationID ?? installation)
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

    func testRetainingTheSameApprovedCapabilityIsIdempotent() throws {
        var session = RuntimeBridgeSessionGrant()
        let approved = pairing()
        try session.retain(approved, ownerUID: 501)
        try session.retain(approved, ownerUID: 501)
        XCTAssertEqual(try session.resolve(persistent: nil, ownerUID: 501), approved)
    }

    func testSessionGrantCannotReplaceAnotherApprovedCapability() throws {
        var session = RuntimeBridgeSessionGrant()
        let approved = pairing()
        try session.retain(approved, ownerUID: 501)
        for replacement in [pairing(secret: Data(repeating: 0xb2, count: 32)), pairing(port: 4502), pairing(installationID: UUID())] {
            XCTAssertThrowsError(try session.retain(replacement, ownerUID: 501))
            XCTAssertEqual(try session.resolve(persistent: nil, ownerUID: 501), approved)
        }
    }

    func testPersistentGrantRemainsAuthoritativeAndConflictsFailClosed() throws {
        var session = RuntimeBridgeSessionGrant()
        let approved = pairing()
        XCTAssertEqual(try session.resolve(persistent: approved, ownerUID: 501), approved)
        try session.retain(approved, ownerUID: 501)
        XCTAssertEqual(try session.resolve(persistent: approved, ownerUID: 501), approved)
        for conflicting in [pairing(secret: Data(repeating: 0xb2, count: 32)), pairing(port: 4502), pairing(installationID: UUID())] {
            XCTAssertThrowsError(try session.resolve(persistent: conflicting, ownerUID: 501))
        }
        XCTAssertEqual(try session.resolve(persistent: nil, ownerUID: 501), approved)
    }

    func testReadingPersistentGrantDoesNotRetainItForLaterAbsence() throws {
        let session = RuntimeBridgeSessionGrant()
        XCTAssertEqual(try session.resolve(persistent: pairing(), ownerUID: 501), pairing())
        XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
    }

    func testSessionGrantRejectsWrongOwnerAndInvalidCapabilitiesWithoutMutatingState() throws {
        var session = RuntimeBridgeSessionGrant()
        for invalid in [pairing(owner: 502), pairing(secret: Data()), pairing(secret: Data(repeating: 0xa1, count: 31)), pairing(port: 1023)] {
            XCTAssertThrowsError(try session.retain(invalid, ownerUID: 501))
            XCTAssertThrowsError(try session.resolve(persistent: invalid, ownerUID: 501))
            XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
        }
        let approved = pairing()
        try session.retain(approved, ownerUID: 501)
        XCTAssertThrowsError(try session.retain(pairing(secret: Data()), ownerUID: 501))
        XCTAssertEqual(try session.resolve(persistent: nil, ownerUID: 501), approved)
    }

    func testStoredSessionCannotBeResolvedByAnotherOwner() throws {
        var session = RuntimeBridgeSessionGrant()
        try session.retain(pairing(), ownerUID: 501)
        XCTAssertThrowsError(try session.resolve(persistent: nil, ownerUID: 502))
        XCTAssertThrowsError(try session.resolve(persistent: pairing(owner: 502), ownerUID: 502))
        XCTAssertEqual(try session.resolve(persistent: nil, ownerUID: 501), pairing())
    }

    func testInvalidPersistentGrantCannotBeHiddenByValidSessionGrant() throws {
        var session = RuntimeBridgeSessionGrant()
        try session.retain(pairing(), ownerUID: 501)
        for invalid in [pairing(owner: 502), pairing(secret: Data()), pairing(port: 1023)] {
            XCTAssertThrowsError(try session.resolve(persistent: invalid, ownerUID: 501))
        }
        XCTAssertEqual(try session.resolve(persistent: nil, ownerUID: 501), pairing())
    }

    func testUnsupportedVersionIsNotAcceptedAsSessionOrPersistentGrant() throws {
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pairing())) as? [String: Any])
        encoded["version"] = 2
        let invalid = try JSONDecoder().decode(RuntimeBridgePairing.self, from: JSONSerialization.data(withJSONObject: encoded))
        var session = RuntimeBridgeSessionGrant()
        XCTAssertThrowsError(try session.retain(invalid, ownerUID: 501))
        XCTAssertThrowsError(try session.resolve(persistent: invalid, ownerUID: 501))
        XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
    }

    func testExplicitResetAllowsANewGrantButDoesNotErasePersistentAuthority() throws {
        var session = RuntimeBridgeSessionGrant()
        try session.retain(pairing(), ownerUID: 501)
        session.reset()
        session.reset()
        let replacement = pairing(secret: Data(repeating: 0xb2, count: 32))
        XCTAssertEqual(try session.resolve(persistent: replacement, ownerUID: 501), replacement)
        XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
        try session.retain(replacement, ownerUID: 501)
        XCTAssertEqual(try session.resolve(persistent: nil, ownerUID: 501), replacement)
    }
}

/// Storage failures are synthetic; these tests never read or mutate Keychain.
final class RuntimeBridgeBootstrapStorageTests: XCTestCase {
    private final class Store {
        enum Failure: Error, Equatable { case locked, missingReadEntitlement, writeDenied, unexpectedRead }
        var reads: [Result<RuntimeBridgePairing?, Failure>]
        var createResult: Result<RuntimeBridgeSessionGrant.CreateResult, Failure>
        var readCount = 0
        var created: [RuntimeBridgePairing] = []
        init(reads: [Result<RuntimeBridgePairing?, Failure>], create: Result<RuntimeBridgeSessionGrant.CreateResult, Failure>) {
            self.reads = reads; self.createResult = create
        }
        func read() throws -> RuntimeBridgePairing? {
            readCount += 1
            guard !reads.isEmpty else { throw Failure.unexpectedRead }
            return try reads.removeFirst().get()
        }
        func create(_ pairing: RuntimeBridgePairing) throws -> RuntimeBridgeSessionGrant.CreateResult {
            created.append(pairing)
            return try createResult.get()
        }
    }
    private func pairing(owner: UInt32 = 501) -> RuntimeBridgePairing {
        RuntimeBridgePairing(ownerUID: owner, port: 4501, secret: Data(repeating: 0xa1, count: 32))
    }

    func testSuccessfulPersistentCreateDoesNotRetainAMemoryFallback() throws {
        let incoming = pairing(), store = Store(reads: [.success(nil)], create: .success(.saved))
        var session = RuntimeBridgeSessionGrant()
        try session.importBootstrapped(incoming, ownerUID: 501, readPersistent: store.read, createPersistent: store.create)
        XCTAssertEqual(store.created, [incoming]); XCTAssertEqual(store.readCount, 1)
        XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
        XCTAssertEqual(try session.resolve(persistent: incoming, ownerUID: 501), incoming)
    }

    func testMissingWriteEntitlementWithTwoAbsentReadsRetainsOnlyForThisProcess() throws {
        let incoming = pairing(), store = Store(reads: [.success(nil), .success(nil), .success(nil)], create: .success(.missingEntitlement))
        var session = RuntimeBridgeSessionGrant()
        try session.importBootstrapped(incoming, ownerUID: 501, readPersistent: store.read, createPersistent: store.create)
        XCTAssertEqual(store.created, [incoming]); XCTAssertEqual(store.readCount, 2)
        XCTAssertEqual(try session.resolve(persistent: nil, ownerUID: 501), incoming)
        // An already approved session still reads storage, but never retries a
        // persistent write or requests a different capability implicitly.
        try session.importBootstrapped(incoming, ownerUID: 501, readPersistent: store.read, createPersistent: store.create)
        XCTAssertEqual(store.created, [incoming]); XCTAssertEqual(store.readCount, 3)
        XCTAssertNil(try RuntimeBridgeSessionGrant().resolve(persistent: nil, ownerUID: 501))
    }

    func testInitialReadFailuresCannotCreateOrRetainAGrant() throws {
        for failure in [Store.Failure.locked, .missingReadEntitlement] {
            let store = Store(reads: [.failure(failure)], create: .success(.missingEntitlement))
            var session = RuntimeBridgeSessionGrant()
            XCTAssertThrowsError(try session.importBootstrapped(pairing(), ownerUID: 501, readPersistent: store.read, createPersistent: store.create)) {
                XCTAssertEqual($0 as? Store.Failure, failure)
            }
            XCTAssertTrue(store.created.isEmpty); XCTAssertEqual(store.readCount, 1)
            XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
        }
    }

    func testOtherWriteFailuresCannotRetainAGrant() throws {
        let store = Store(reads: [.success(nil)], create: .failure(.writeDenied))
        var session = RuntimeBridgeSessionGrant()
        XCTAssertThrowsError(try session.importBootstrapped(pairing(), ownerUID: 501, readPersistent: store.read, createPersistent: store.create)) {
            XCTAssertEqual($0 as? Store.Failure, .writeDenied)
        }
        XCTAssertEqual(store.created.count, 1); XCTAssertEqual(store.readCount, 1)
        XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
    }

    func testRereadFailureAfterDuplicateOrMissingEntitlementFailsClosed() throws {
        for result in [RuntimeBridgeSessionGrant.CreateResult.duplicate, .missingEntitlement] {
            for failure in [Store.Failure.locked, .missingReadEntitlement] {
                let store = Store(reads: [.success(nil), .failure(failure)], create: .success(result))
                var session = RuntimeBridgeSessionGrant()
                XCTAssertThrowsError(try session.importBootstrapped(pairing(), ownerUID: 501, readPersistent: store.read, createPersistent: store.create)) {
                    XCTAssertEqual($0 as? Store.Failure, failure)
                }
                XCTAssertEqual(store.created.count, 1); XCTAssertEqual(store.readCount, 2)
                XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
            }
        }
    }

    func testMatchingPersistentRaceIsAuthoritativeAndIsNotRetainedInMemory() throws {
        for result in [RuntimeBridgeSessionGrant.CreateResult.duplicate, .missingEntitlement] {
            let incoming = pairing(), store = Store(reads: [.success(nil), .success(incoming)], create: .success(result))
            var session = RuntimeBridgeSessionGrant()
            try session.importBootstrapped(incoming, ownerUID: 501, readPersistent: store.read, createPersistent: store.create)
            XCTAssertEqual(store.created, [incoming]); XCTAssertEqual(store.readCount, 2)
            XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
            XCTAssertEqual(try session.resolve(persistent: incoming, ownerUID: 501), incoming)
        }
    }

    func testConflictingOrInvalidPersistentRaceCannotBeReplaced() throws {
        for result in [RuntimeBridgeSessionGrant.CreateResult.duplicate, .missingEntitlement] {
            let incoming = pairing()
            for raced in [pairing(), pairing(owner: 502)] {
                let store = Store(reads: [.success(nil), .success(raced)], create: .success(result))
                var session = RuntimeBridgeSessionGrant()
                XCTAssertThrowsError(try session.importBootstrapped(incoming, ownerUID: 501, readPersistent: store.read, createPersistent: store.create))
                XCTAssertEqual(store.created, [incoming]); XCTAssertEqual(store.readCount, 2)
                XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
            }
        }
    }

    func testDuplicateFollowedByAbsentReadDoesNotPermitFallback() throws {
        let store = Store(reads: [.success(nil), .success(nil)], create: .success(.duplicate))
        var session = RuntimeBridgeSessionGrant()
        XCTAssertThrowsError(try session.importBootstrapped(pairing(), ownerUID: 501, readPersistent: store.read, createPersistent: store.create))
        XCTAssertEqual(store.created.count, 1); XCTAssertEqual(store.readCount, 2)
        XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
    }

    func testExistingPersistentGrantIsReusedWithoutAWriteOrMemoryCopy() throws {
        let incoming = pairing(), store = Store(reads: [.success(incoming)], create: .failure(.writeDenied))
        var session = RuntimeBridgeSessionGrant()
        try session.importBootstrapped(incoming, ownerUID: 501, readPersistent: store.read, createPersistent: store.create)
        XCTAssertTrue(store.created.isEmpty); XCTAssertEqual(store.readCount, 1)
        XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
    }

    func testExistingConflictingOrUnreadableGrantCannotBeHiddenByAnApprovedSession() throws {
        let incoming = pairing()
        for read in [Result<RuntimeBridgePairing?, Store.Failure>.success(pairing()), .failure(.locked), .failure(.missingReadEntitlement)] {
            let store = Store(reads: [read], create: .success(.missingEntitlement))
            var session = RuntimeBridgeSessionGrant()
            try session.retain(incoming, ownerUID: 501)
            XCTAssertThrowsError(try session.importBootstrapped(incoming, ownerUID: 501, readPersistent: store.read, createPersistent: store.create))
            XCTAssertTrue(store.created.isEmpty); XCTAssertEqual(store.readCount, 1)
            XCTAssertEqual(try session.resolve(persistent: nil, ownerUID: 501), incoming)
        }
    }

    func testInvalidIncomingCapabilityCannotReachStorage() throws {
        let store = Store(reads: [], create: .success(.missingEntitlement))
        var session = RuntimeBridgeSessionGrant()
        XCTAssertThrowsError(try session.importBootstrapped(pairing(owner: 502), ownerUID: 501, readPersistent: store.read, createPersistent: store.create))
        XCTAssertTrue(store.created.isEmpty); XCTAssertEqual(store.readCount, 0)
        XCTAssertNil(try session.resolve(persistent: nil, ownerUID: 501))
    }
}
