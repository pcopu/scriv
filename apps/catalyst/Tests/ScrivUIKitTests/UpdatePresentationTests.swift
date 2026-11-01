import XCTest
@testable import ScrivUIKit

final class UpdatePresentationTests: XCTestCase {
    func testExplicitChoicesAndHonestDevelopmentBlock() {
        let available = ScrivUpdatePresentation(phase: "available", version: "1.2")
        XCTAssertEqual(available.primary, "Download & Update")
        XCTAssertTrue(available.detail.contains("install on quit"))
        XCTAssertEqual(ScrivUpdatePresentation(phase: "ready").primary, "Update & Relaunch")
        XCTAssertEqual(ScrivUpdatePresentation(phase: "ready").secondary, "Later")
        XCTAssertEqual(ScrivUpdatePresentation(phase: "blocked").primary, "Done")
    }
    func testTerminationStatesNeverInventAProgressPercentageOrPromiseCancellation() {
        let waiting = ScrivUpdatePresentation(phase: "retryQuit")
        XCTAssertEqual(waiting.primary, "Try Quit & Relaunch")
        XCTAssertEqual(waiting.secondary, "Keep Working")
        XCTAssertTrue(waiting.detail.contains("may install when you quit"))
        XCTAssertFalse(waiting.showsProgress)
        let blocked = ScrivUpdatePresentation(phase: "retryBlocked")
        XCTAssertEqual(blocked.primary, "Close")
        XCTAssertNil(blocked.secondary)
        XCTAssertTrue(blocked.detail.contains("still prepared"))
        XCTAssertFalse(blocked.showsProgress)
        XCTAssertTrue(ScrivUpdatePresentation(phase: "downloading").showsProgress)
        XCTAssertTrue(ScrivUpdatePresentation(phase: "verifying").showsProgress)
    }
    func testEveryBusyAndTerminalStateHasSafeActions() {
        for phase in ["saving", "installing"] {
            let model = ScrivUpdatePresentation(phase: phase)
            XCTAssertNil(model.primary); XCTAssertNil(model.secondary); XCTAssertFalse(model.showsProgress)
        }
        for phase in ["error", "current", "complete", "blocked"] {
            let model = ScrivUpdatePresentation(phase: phase)
            XCTAssertNotNil(model.primary); XCTAssertFalse(model.showsProgress)
        }
        XCTAssertEqual(ScrivUpdatePresentation(phase: "downloading").secondary, "Cancel")
    }
}
