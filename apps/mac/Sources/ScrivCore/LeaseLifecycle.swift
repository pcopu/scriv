import Foundation

public enum LeaseLifecycle {
    /// A late renewal belongs only to the exact still-held lease. Closing an editor,
    /// restoring history or reacquiring a newer fence makes its response obsolete.
    public static func matches(_ current: EditLease?, expected: EditLease, epoch: Int) -> Bool {
        guard let current else { return false }
        return current.itemId == expected.itemId && current.sessionId == expected.sessionId && current.userId == expected.userId && current.token == expected.token && current.fence == expected.fence && (current.epoch ?? epoch) == epoch && (expected.epoch ?? epoch) == epoch
    }
}

/// Registration is synchronous on the UI actor, before either release or reacquire
/// can suspend. This prevents an old DELETE from crossing a new lease acquisition.
@MainActor public final class LeaseReleaseBarrier {
    private var pending: [String:(id:UUID,task:Task<Void,Never>)] = [:]
    public init() {}
    public func task(for key: String) -> Task<Void,Never>? { pending[key]?.task }
    @discardableResult public func enqueue(key: String, operation: @escaping @MainActor () async -> Void) -> Task<Void,Never> {
        if let existing = pending[key] { return existing.task }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            if self?.pending[key]?.id == id { self?.pending.removeValue(forKey:key) }
        }
        pending[key] = (id,task)
        return task
    }
}
