import XCTest
@testable import ScrivCore

private actor UploadGate {
    private var continuation: CheckedContinuation<Void,Never>?
    private var entered = false
    private var observers: [CheckedContinuation<Void,Never>] = []
    func upload() async {
        entered = true; for observer in observers { observer.resume() }; observers = []
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForUpload() async { if entered { return }; await withCheckedContinuation { observers.append($0) } }
    func finish() { continuation?.resume(); continuation = nil }
}

final class CloudCommitBarrierTests: XCTestCase {
    @MainActor func testEditsDuringScriptPauseAndUploadReachOutboxAndFlush() async {
        let barrier = CloudCommitBarrier(), media = UploadGate()
        barrier.setPaused(true)
        var dirty = ["line":1], outbox: [Int] = [], uploaded = false
        let duringScript = Task { @MainActor in await barrier.waitUntilReady(); outbox.append(1) }
        await Task.yield()
        XCTAssertTrue(outbox.isEmpty)
        // Script revision 0 has been accepted. A later local edit must survive it.
        dirty = CloudCommitBarrier.remainingDirtyItems(dirty,through:0)
        XCTAssertEqual(dirty,["line":1])
        barrier.setPaused(false)
        let upload = Task { @MainActor in await media.upload(); uploaded = true }
        await media.waitForUpload()
        dirty["line"] = 2
        let duringUpload = Task { @MainActor in await barrier.waitUntilReady(); outbox.append(2) }
        await duringScript.value; await duringUpload.value
        XCTAssertFalse(uploaded) // Outbox delivery is not blocked by R2 completion.
        XCTAssertEqual(Set(outbox),[1,2])
        dirty = CloudCommitBarrier.remainingDirtyItems(dirty,through:1)
        XCTAssertEqual(dirty,["line":2])
        await media.finish(); await upload.value
        dirty = CloudCommitBarrier.remainingDirtyItems(dirty,through:2)
        XCTAssertTrue(dirty.isEmpty)
    }
    @MainActor func testResumeReleasesAllWaitersAndIsIdempotent() async {
        let barrier = CloudCommitBarrier(); barrier.setPaused(true)
        var completed = 0
        let tasks = (0..<4).map { _ in Task { @MainActor in await barrier.waitUntilReady(); completed += 1 } }
        await Task.yield()
        barrier.setPaused(false); barrier.setPaused(false)
        for task in tasks { await task.value }
        XCTAssertEqual(completed,4)
        barrier.setPaused(true); barrier.setPaused(false)
        await barrier.waitUntilReady()
    }
}
