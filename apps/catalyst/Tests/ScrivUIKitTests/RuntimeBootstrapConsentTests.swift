import XCTest
import UIKit
import ScrivCore
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
    func testAutomaticConnectionPreparesLocalRuntimeWithoutAnAddress() async {
        enum FixtureError: Error { case notInstalled }
        let previous = UserDefaults.standard.object(forKey: "codexEndpoint")
        defer { UserDefaults.standard.set(previous, forKey: "codexEndpoint") }
        let controller = CodexController()
        for address in ["", "not an address", "ws://example.test:4500"] {
            controller.endpoint = address
            var preparations = 0
            await controller.checkAndConnect(prepareLocalRuntime: {
                preparations += 1
                throw FixtureError.notInstalled
            })
            XCTAssertEqual(preparations, 1, "Automatic connection must reach the local helper without parsing a saved address")
            XCTAssertEqual(controller.endpoint, address, "Keep manual settings for the explicit Advanced action")
            XCTAssertFalse(controller.isConnected)
            XCTAssertFalse(controller.accountChecked)
            XCTAssertEqual(controller.connectionCheck.phase, .notFound)
        }
    }

    func testCancelledAutomaticConnectionNeverPreparesRuntime() async {
        let controller = CodexController()
        var preparations = 0
        let task = Task {
            await controller.checkAndConnect(prepareLocalRuntime: { preparations += 1 })
        }
        task.cancel()
        await task.value
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(controller.connectionCheck.phase, .cancelled)
    }

    func testCancelAndDuplicateCheckCannotStartRuntimeAfterLatePreparation() async {
        let previous = UserDefaults.standard.object(forKey: "codexEndpoint")
        defer { UserDefaults.standard.set(previous, forKey: "codexEndpoint") }
        let controller = CodexController(); controller.endpoint = ""
        let prepared = expectation(description: "Local preparation started")
        var release: CheckedContinuation<Void, Never>?
        let task = Task {
            await controller.checkAndConnect(prepareLocalRuntime: {
                await withCheckedContinuation { continuation in
                    release = continuation; prepared.fulfill()
                }
            })
        }
        await fulfillment(of: [prepared], timeout: 2)
        await controller.checkAndConnect(prepareLocalRuntime: { XCTFail("Duplicate check must be ignored") })
        controller.cancelConnectionCheck()
        release?.resume()
        await task.value
        XCTAssertEqual(controller.connectionCheck.phase, .cancelled)
        XCTAssertFalse(controller.isConnecting)
        XCTAssertFalse(controller.isConnected)
        XCTAssertFalse(controller.bridgePaired, "A cancelled preparation must not read or import a pairing")
    }

    func testDeclineCreatesNoAdapterAndSavesNothing() async {
        var loads = 0, saves = 0
        let coordinator = ScrivRuntimeBootstrapCoordinator(hasSavedGrant: { false }, makeAdapter: {
            loads += 1; return SyntheticBootstrapAdapter()
        }, savePairing: { _ in saves += 1 })
        do { try await coordinator.prepare(userApproved: false); XCTFail("Missing user action must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(loads, 0); XCTAssertEqual(saves, 0)
    }
    func testExistingGrantReconnectsWithoutNewConsent() async throws {
        let adapter = SyntheticBootstrapAdapter(); adapter.immediate = Data([1, 2, 3])
        var saved: Data?
        let coordinator = ScrivRuntimeBootstrapCoordinator(hasSavedGrant: { false }, makeAdapter: { adapter }, savePairing: { saved = $0 })
        try await coordinator.prepare(userApproved: true)
        XCTAssertEqual(adapter.calls, 1, "The Connect button authorizes the first connection without another prompt")
        XCTAssertEqual(saved, Data([1, 2, 3])); XCTAssertEqual(adapter.disconnected, 0)
        coordinator.cancel(); XCTAssertEqual(adapter.disconnected, 1)
    }
    func testCancellationBeforeLateReplyCannotSaveGrant() async {
        let adapter = SyntheticBootstrapAdapter(); var saves = 0
        let called = expectation(description: "Adapter requested")
        let coordinator = ScrivRuntimeBootstrapCoordinator(hasSavedGrant: { false }, makeAdapter: { called.fulfill(); return adapter }, savePairing: { _ in saves += 1 })
        let task = Task { try await coordinator.prepare(userApproved: true) }
        await fulfillment(of: [called], timeout: 2)
        coordinator.cancel()
        adapter.reply?(Data([7]), nil)
        do { try await task.value; XCTFail("Cancelled request must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(saves, 0); XCTAssertEqual(adapter.disconnected, 1)
    }
    func testUnreadableGrantFailsBeforeConsentOrAdapter() async {
        enum FixtureError: Error { case locked }
        var loads = 0
        let coordinator = ScrivRuntimeBootstrapCoordinator(hasSavedGrant: { throw FixtureError.locked }, makeAdapter: { loads += 1; return SyntheticBootstrapAdapter() }, savePairing: { _ in XCTFail("No write") })
        do { try await coordinator.prepare(userApproved: true); XCTFail("Must preserve unreadable grant") }
        catch { XCTAssertTrue(error is FixtureError) }
        XCTAssertEqual(loads, 0)
    }
}
