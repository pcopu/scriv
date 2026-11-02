import XCTest
@testable import ScrivCore

private final class StartupTraceEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [StartupTrace.Event] = []
    func append(_ event: StartupTrace.Event) { lock.lock(); values.append(event); lock.unlock() }
    var events: [StartupTrace.Event] { lock.lock(); defer { lock.unlock() }; return values.sorted { $0.sequence < $1.sequence } }
}

final class StartupTraceTests: XCTestCase {
    func testDisabledTraceDoesNotCallSinkOrScheduleHeartbeats() async throws {
        let captured = StartupTraceEvents()
        let trace = StartupTrace(enabled: false) { captured.append($0) }
        trace.record(.bootstrapBegin, error: NSError(domain: "PRIVATE", code: 7))
        trace.scheduleHeartbeats()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(captured.events.isEmpty)
    }
    func testSchemaRetainsOnlyFixedStagesTimingAndAllowlistedErrorFamiliesAndCodes() throws {
        let captured = StartupTraceEvents()
        let trace = StartupTrace(enabled: true) { captured.append($0) }
        let cause = NSError(domain: NSPOSIXErrorDomain, code: 1, userInfo: ["token": "PRIVATE_TOKEN"])
        trace.record(.metadataReadFailed, error: NSError(domain: "PRIVATE_ACCOUNT_DOMAIN", code: 257,
            userInfo: [NSLocalizedDescriptionKey: "PRIVATE_PROJECT_TEXT", NSFilePathErrorKey: "/PRIVATE_PATH", NSUnderlyingErrorKey: cause]))
        let event = try XCTUnwrap(captured.events.first)
        XCTAssertEqual(event.stage, .metadataReadFailed); XCTAssertEqual(event.sequence, 1)
        XCTAssertEqual(event.errorFamily, .other); XCTAssertEqual(event.errorCode, 257)
        XCTAssertEqual(event.underlyingFamily, .posix); XCTAssertEqual(event.underlyingCode, 1)
        XCTAssertGreaterThanOrEqual(event.elapsedMilliseconds, 0)
        let encoded = try JSONEncoder().encode(event)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("PRIVATE")); XCTAssertFalse(text.contains("localizedDescription"))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(["sequence", "stage", "elapsedMilliseconds", "errorFamily", "errorCode", "underlyingFamily", "underlyingCode"]))
        trace.record(.bootstrapFailed, error: NSError(domain: NSCocoaErrorDomain, code: 257))
        trace.record(.accountRestoreEnd, error: NSError(domain: NSURLErrorDomain, code: -1001))
        XCTAssertEqual(captured.events.map(\.errorFamily), [.other, .cocoa, .url])
    }
    func testEventBudgetHasAHardCapAndConcurrentSequenceIsUnique() {
        let captured = StartupTraceEvents()
        let trace = StartupTrace(enabled: true, maximumEvents: Int.max) { captured.append($0) }
        DispatchQueue.concurrentPerform(iterations: 600) { _ in trace.record(.bootstrapBegin) }
        XCTAssertEqual(captured.events.count, 256)
        XCTAssertEqual(captured.events.map(\.sequence), Array(1...256))
        let zero = StartupTrace(enabled: true, maximumEvents: -1) { captured.append($0) }
        zero.record(.bootstrapEnd)
        XCTAssertEqual(captured.events.count, 256)
    }
    @MainActor
    func testHeartbeatIsTwoMainQueueObservationsNotARepeatingTimer() async throws {
        let captured = StartupTraceEvents()
        let trace = StartupTrace(enabled: true) { captured.append($0) }
        for _ in 0..<20 { trace.scheduleHeartbeats() }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while captured.events.count < 3 && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(captured.events.map(\.stage), [.heartbeatScheduled, .heartbeatFirst, .heartbeatSecond])
    }
}
