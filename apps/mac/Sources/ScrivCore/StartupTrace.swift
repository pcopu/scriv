import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Opt-in, local-only startup evidence. The schema cannot carry paths, account
/// identifiers, project text, bookmarks, tokens, or arbitrary error messages.
public final class StartupTrace: @unchecked Sendable {
    public enum Stage: String, Codable, Sendable {
        case sceneEntered, storeConstructionBegin, storeConstructionEnd
        case codexInitializationBegin, codexInitializationEnd, pairingReadBegin, pairingReadEnd
        case generationBookmarkBegin, generationBookmarkEnd, generationBookmarkFailed
        case generationJournalBegin, generationJournalEnd, generationJournalFailed
        case cloudInitializationBegin, cloudInitializationEnd, cloudTokenReadBegin, cloudTokenReadEnd
        case projectStorageBegin, projectStorageEnd, projectStorageFailed
        case windowCreated, windowVisibilityRequested, windowBecameKey, rootViewAppeared, sceneBecameActive
        case bootstrapBegin, verificationBootstrapSkipped, accountRestoreBegin, accountRestoreEnd
        case pendingInventoryBegin, pendingInventoryEnd, projectOpenBegin, projectOpenEnd
        case accessRestoreBegin, accessRestoreEnd, accessRestoreFailed
        case pendingRecoveryBegin, pendingRecoveryEnd, pendingRecoveryFailed
        case metadataReadBegin, metadataReadEnd, metadataReadFailed
        case checkpointReadBegin, checkpointReadEnd, checkpointReadFailed
        case historyReadBegin, historyReadEnd, historyReadFailed
        case bootstrapFailed, bootstrapEnd, errorQueued, errorPresented, errorDismissed
        case heartbeatScheduled, heartbeatFirst, heartbeatSecond
    }
    public enum ErrorFamily: String, Codable, Sendable { case cocoa, posix, url, other }
    public struct Event: Codable, Equatable, Sendable {
        public let sequence: Int
        public let stage: Stage
        public let elapsedMilliseconds: Int
        public let errorFamily: ErrorFamily?
        public let errorCode: Int?
        public let underlyingFamily: ErrorFamily?
        public let underlyingCode: Int?
    }
    public static let process = StartupTrace(
        enabled: ProcessInfo.processInfo.arguments.contains("--scriv-startup-trace"),
        sink: { localLog($0) })
    public let enabled: Bool
    private let limit: Int
    private let started: TimeInterval
    private let sink: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var sequence = 0
    private var heartbeatsScheduled = false

    public init(enabled: Bool, maximumEvents: Int = 128, sink: @escaping @Sendable (Event) -> Void) {
        self.enabled = enabled; limit = min(256, max(0, maximumEvents))
        started = ProcessInfo.processInfo.systemUptime; self.sink = sink
    }
    public func record(_ stage: Stage, error: Error? = nil) {
        guard enabled else { return }
        lock.lock()
        guard sequence < limit else { lock.unlock(); return }
        sequence += 1
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started) * 1000
        let source = error.map { $0 as NSError }
        let cause = source?.userInfo[NSUnderlyingErrorKey] as? NSError
        let event = Event(sequence: sequence, stage: stage,
                          elapsedMilliseconds: Int(min(Double(Int.max - 1), elapsed)),
                          errorFamily: source.map { Self.family($0.domain) }, errorCode: source?.code,
                          underlyingFamily: cause.map { Self.family($0.domain) }, underlyingCode: cause?.code)
        lock.unlock()
        sink(event)
    }
    /// Two observations, never an unbounded timer or a startup timeout policy.
    public func scheduleHeartbeats() {
        guard enabled else { return }
        lock.lock()
        guard !heartbeatsScheduled else { lock.unlock(); return }
        heartbeatsScheduled = true; lock.unlock()
        record(.heartbeatScheduled)
        DispatchQueue.main.async { [self] in record(.heartbeatFirst) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in record(.heartbeatSecond) }
    }
    private static func family(_ domain: String) -> ErrorFamily {
        switch domain {
        case NSCocoaErrorDomain: return .cocoa
        case NSPOSIXErrorDomain: return .posix
        case NSURLErrorDomain: return .url
        default: return .other
        }
    }
    private static func localLog(_ event: Event) {
        #if canImport(OSLog)
        // Only fixed enums and integers are public. No dynamic error domain,
        // localizedDescription, userInfo, URL or arbitrary String is accepted.
        let logger = Logger(subsystem: "app.scriv.startup", category: "local-startup")
        logger.notice("stage=\(event.stage.rawValue, privacy: .public) sequence=\(event.sequence) elapsed_ms=\(event.elapsedMilliseconds) error_family=\(event.errorFamily?.rawValue ?? "none", privacy: .public) error_code=\(event.errorCode ?? 0) underlying_family=\(event.underlyingFamily?.rawValue ?? "none", privacy: .public) underlying_code=\(event.underlyingCode ?? 0)")
        #endif
    }
}
