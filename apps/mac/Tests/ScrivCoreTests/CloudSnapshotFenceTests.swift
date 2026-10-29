import XCTest
@testable import ScrivCore

final class CloudSnapshotFenceTests: XCTestCase {
    func testOlderResponseCannotReplaceNewerReplayEvenInSameLifecycle() {
        XCTAssertTrue(CloudSnapshotFence.canInstall(snapshotHead:12,snapshotEpoch:1,currentHead:10,currentEpoch:1,acceptedReceiptSeq:0))
        XCTAssertFalse(CloudSnapshotFence.canInstall(snapshotHead:11,snapshotEpoch:1,currentHead:12,currentEpoch:1,acceptedReceiptSeq:0))
        XCTAssertTrue(CloudSnapshotFence.isCaughtUp(headSeq:12,pageHead:11,acceptedReceiptSeq:0))
    }

    func testReceiptProtectsItemsBeforeItsEventAdvancesTheCursor() {
        // A seq-12 command receipt arrived while a seq-11 snapshot was in flight.
        XCTAssertFalse(CloudSnapshotFence.canInstall(snapshotHead:11,snapshotEpoch:1,currentHead:10,currentEpoch:1,acceptedReceiptSeq:12))
        XCTAssertFalse(CloudSnapshotFence.isCaughtUp(headSeq:10,pageHead:11,acceptedReceiptSeq:12))
        XCTAssertFalse(CloudSnapshotFence.isCaughtUp(headSeq:11,pageHead:11,acceptedReceiptSeq:12))
        XCTAssertTrue(CloudSnapshotFence.canInstall(snapshotHead:12,snapshotEpoch:1,currentHead:10,currentEpoch:1,acceptedReceiptSeq:12))
        XCTAssertTrue(CloudSnapshotFence.isCaughtUp(headSeq:12,pageHead:12,acceptedReceiptSeq:12))
    }

    func testRestoreAdvancesEpochWithoutAllowingAnOldEpochResponseBackIn() {
        XCTAssertTrue(CloudSnapshotFence.canInstall(snapshotHead:13,snapshotEpoch:2,currentHead:12,currentEpoch:1,acceptedReceiptSeq:12))
        XCTAssertFalse(CloudSnapshotFence.canInstall(snapshotHead:12,snapshotEpoch:1,currentHead:13,currentEpoch:2,acceptedReceiptSeq:12))
        XCTAssertFalse(CloudSnapshotFence.canInstall(snapshotHead:14,snapshotEpoch:1,currentHead:13,currentEpoch:2,acceptedReceiptSeq:12))
        XCTAssertTrue(CloudSnapshotFence.canInstall(snapshotHead:13,snapshotEpoch:2,currentHead:13,currentEpoch:2,acceptedReceiptSeq:12))
    }

    func testFinalEmptyPageCannotAcknowledgeAnUnreplayedReceipt() {
        XCTAssertFalse(CloudSnapshotFence.isCaughtUp(headSeq:7,pageHead:7,acceptedReceiptSeq:8))
        XCTAssertTrue(CloudSnapshotFence.isCaughtUp(headSeq:8,pageHead:8,acceptedReceiptSeq:8))
    }

    func testSkippedSnapshotKeepsTheCursorForAFreshReplayPage() {
        var head = 10
        let receipt = 12
        // Event 11 requires a snapshot, but this response predates receipt 12.
        if CloudSnapshotFence.canInstall(snapshotHead:11,snapshotEpoch:1,currentHead:head,currentEpoch:1,acceptedReceiptSeq:receipt) { head = 11 }
        XCTAssertEqual(head,10)
        XCTAssertFalse(CloudSnapshotFence.isCaughtUp(headSeq:head,pageHead:12,acceptedReceiptSeq:receipt))
        // Restart at 10, not at the next event (12) in the stale response page.
        XCTAssertEqual(head + 1,11)
        if CloudSnapshotFence.canInstall(snapshotHead:12,snapshotEpoch:1,currentHead:head,currentEpoch:1,acceptedReceiptSeq:receipt) { head = 12 }
        XCTAssertEqual(head,12)
        XCTAssertTrue(CloudSnapshotFence.isCaughtUp(headSeq:head,pageHead:12,acceptedReceiptSeq:receipt))
    }
}
