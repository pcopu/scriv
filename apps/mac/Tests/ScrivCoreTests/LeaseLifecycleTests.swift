import XCTest
@testable import ScrivCore

private actor ReleaseGate {
    var entered = false
    var waiting: CheckedContinuation<Void,Never>?
    var observers: [CheckedContinuation<Void,Never>] = []
    func hold() async {
        entered = true; for observer in observers { observer.resume() }; observers = []
        await withCheckedContinuation { waiting = $0 }
    }
    func waitUntilEntered() async { if entered { return }; await withCheckedContinuation { observers.append($0) } }
    func open() { waiting?.resume(); waiting = nil }
}

final class LeaseLifecycleTests: XCTestCase {
    private func lease(fence: Int = 1, token: String = "fixture-token", epoch: Int = 1) throws -> EditLease {
        try JSONValue.object(["itemId":.string("line"),"sessionId":.string("editor"),"token":.string(token),"fence":.number(Double(fence)),"epoch":.number(Double(epoch)),"expiresAt":.number(10000),"userId":.string("user")]).decoded(EditLease.self)
    }
    func testRenewalCannotResurrectClosedOrSupersededLease() throws {
        let original = try lease()
        XCTAssertTrue(LeaseLifecycle.matches(original,expected:original,epoch:1))
        XCTAssertFalse(LeaseLifecycle.matches(nil,expected:original,epoch:1))
        XCTAssertFalse(LeaseLifecycle.matches(try lease(fence:2),expected:original,epoch:1))
        XCTAssertFalse(LeaseLifecycle.matches(try lease(token:"new-token"),expected:original,epoch:1))
        XCTAssertFalse(LeaseLifecycle.matches(original,expected:original,epoch:2))
    }
    @MainActor func testReacquisitionWaitsForDeleteWithoutBlockingOtherItemsOrGenerations() async {
        let queue = LeaseReleaseBarrier(), gate = ReleaseGate()
        var events: [String] = []
        let release = queue.enqueue(key:"1:line") { events.append("delete-start"); await gate.hold(); events.append("delete-finished") }
        await gate.waitUntilEntered()
        XCTAssertNotNil(queue.task(for:"1:line"))
        XCTAssertNil(queue.task(for:"1:other-line"))
        XCTAssertNil(queue.task(for:"2:line"))
        let duplicate = queue.enqueue(key:"1:line") { events.append("duplicate-delete") }
        let reacquire = Task { @MainActor in await queue.task(for:"1:line")?.value; events.append("acquire") }
        await gate.open()
        await release.value; await duplicate.value; await reacquire.value
        XCTAssertEqual(events,["delete-start","delete-finished","acquire"])
        XCTAssertNil(queue.task(for:"1:line"))
    }
}
