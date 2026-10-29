import Foundation

/// Snapshot HTTP responses can finish out of order relative to other replays
/// and command receipts. Receipt progress and replay progress are distinct:
/// only events/snapshots may advance the replay cursor.
public enum CloudSnapshotFence {
    public static func canInstall(snapshotHead: Int, snapshotEpoch: Int, currentHead: Int, currentEpoch: Int, acceptedReceiptSeq: Int) -> Bool {
        snapshotHead >= max(currentHead, acceptedReceiptSeq) && snapshotEpoch >= currentEpoch
    }

    public static func isCaughtUp(headSeq: Int, pageHead: Int, acceptedReceiptSeq: Int) -> Bool {
        headSeq >= max(pageHead, acceptedReceiptSeq)
    }
}
