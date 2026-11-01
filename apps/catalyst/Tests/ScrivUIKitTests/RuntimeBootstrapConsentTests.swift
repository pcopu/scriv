import XCTest
import UIKit
@testable import ScrivUIKit

@MainActor
private final class SyntheticBootstrapAdapter: NSObject, ScrivRuntimeBootstrapAdapter {
    var calls = 0
    var disconnected = 0
    var reply: ((Data?, Error?) -> Void)?
    var immediate: Data?
    func connectAfterUserConsent(_ approved: Bool, completion: @escaping (Data?, Error?) -> Void) {
        XCTAssertTrue(approved); calls += 1
        if let immediate { completion(immediate, nil) } else { reply = completion }
    }
    func disconnect() { disconnected += 1 }
}

@MainActor
final class RuntimeBootstrapConsentTests: XCTestCase {
    func testDeclineCreatesNoAdapterAndSavesNothing() async {
        var loads = 0, saves = 0
        let coordinator = ScrivRuntimeBootstrapCoordinator(hasSavedGrant: { false }, makeAdapter: {
            loads += 1; return SyntheticBootstrapAdapter()
        }, savePairing: { _ in saves += 1 }, confirm: { _ in false })
        do { try await coordinator.prepare(from: UIViewController()); XCTFail("Decline must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(loads, 0); XCTAssertEqual(saves, 0)
    }
    func testExistingGrantReconnectsWithoutNewConsent() async throws {
        let adapter = SyntheticBootstrapAdapter(); adapter.immediate = Data([1, 2, 3])
        var confirmations = 0, saved: Data?
        let coordinator = ScrivRuntimeBootstrapCoordinator(hasSavedGrant: { true }, makeAdapter: { adapter }, savePairing: { saved = $0 }, confirm: { _ in confirmations += 1; return false })
        try await coordinator.prepare(from: UIViewController())
        XCTAssertEqual(confirmations, 0); XCTAssertEqual(adapter.calls, 1)
        XCTAssertEqual(saved, Data([1, 2, 3])); XCTAssertEqual(adapter.disconnected, 0)
        coordinator.cancel(); XCTAssertEqual(adapter.disconnected, 1)
    }
    func testCancellationBeforeLateReplyCannotSaveGrant() async {
        let adapter = SyntheticBootstrapAdapter(); var saves = 0
        let called = expectation(description: "Adapter requested")
        let coordinator = ScrivRuntimeBootstrapCoordinator(hasSavedGrant: { false }, makeAdapter: { called.fulfill(); return adapter }, savePairing: { _ in saves += 1 }, confirm: { _ in true })
        let task = Task { try await coordinator.prepare(from: UIViewController()) }
        await fulfillment(of: [called], timeout: 2)
        coordinator.cancel()
        adapter.reply?(Data([7]), nil)
        do { try await task.value; XCTFail("Cancelled request must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(saves, 0); XCTAssertEqual(adapter.disconnected, 1)
    }
    func testUnreadableGrantFailsBeforeConsentOrAdapter() async {
        enum FixtureError: Error { case locked }
        var confirmations = 0, loads = 0
        let coordinator = ScrivRuntimeBootstrapCoordinator(hasSavedGrant: { throw FixtureError.locked }, makeAdapter: { loads += 1; return SyntheticBootstrapAdapter() }, savePairing: { _ in XCTFail("No write") }, confirm: { _ in confirmations += 1; return true })
        do { try await coordinator.prepare(from: UIViewController()); XCTFail("Must preserve unreadable grant") }
        catch { XCTAssertTrue(error is FixtureError) }
        XCTAssertEqual(confirmations, 0); XCTAssertEqual(loads, 0)
    }
}
