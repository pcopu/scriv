import Foundation

/// Cloud reconnect/restore pauses acceptance briefly; edits made during that pause
/// wait rather than disappearing. Media upload runs after the barrier is released.
@MainActor public final class CloudCommitBarrier {
    private var paused = false
    private var waiters: [CheckedContinuation<Void,Never>] = []
    public init() {}
    public func setPaused(_ value: Bool) {
        paused = value
        if !value { let waiting = waiters; waiters = []; for waiter in waiting { waiter.resume() } }
    }
    public func waitUntilReady() async {
        guard paused else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    /// An acknowledgement must never clear a newer edit to the same item.
    public static func remainingDirtyItems(_ dirty: [String:Int], through revision: Int) -> [String:Int] {
        dirty.filter { $0.value > revision }
    }
}
