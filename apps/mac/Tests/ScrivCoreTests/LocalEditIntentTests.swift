import XCTest
@testable import ScrivCore

final class LocalEditIntentTests: XCTestCase {
    func testNewEditorIntentPreventsOldQueuedSaveFromReleasingLease() {
        var intents = LocalEditIntents()
        intents.begin("line")
        intents.end("line") // Old editor closes, release is waiting on its save.
        intents.begin("line") // New sheet registers BEFORE acquiring its lease.
        XCTAssertTrue(intents.contains("line")) // Old delayed release must skip.
        intents.end("line")
        XCTAssertFalse(intents.contains("line"))
    }
    func testOverlappingAcquisitionsAndCancellationKeepOtherOwner() {
        var intents = LocalEditIntents()
        intents.begin("line"); intents.begin("line"); intents.begin("other")
        intents.end("line") // One scope cancels while the other is still acquiring.
        XCTAssertTrue(intents.contains("line")); XCTAssertTrue(intents.contains("other"))
        intents.end("line"); intents.end("line")
        XCTAssertFalse(intents.contains("line")); XCTAssertTrue(intents.contains("other"))
    }
    func testProjectReplacementStartsWithNoStaleIntents() {
        var intents = LocalEditIntents(); intents.begin("line")
        intents = LocalEditIntents()
        XCTAssertFalse(intents.contains("line"))
    }
}
