import XCTest
@testable import ScrivCore

final class PresentationGeometryTests: XCTestCase {
    private let rows = [
        ScriptRailRow(startMs: 0, durationMs: 3000, anchorY: 20, bottomY: 90),
        ScriptRailRow(startMs: 3000, durationMs: 0, anchorY: 120, bottomY: 165),
        ScriptRailRow(startMs: 3000, durationMs: 0, anchorY: 180, bottomY: 225),
        ScriptRailRow(startMs: 3000, durationMs: 5000, anchorY: 250, bottomY: 370),
        ScriptRailRow(startMs: 8000, durationMs: 2400, anchorY: 400, bottomY: 490)
    ]
    func testRailIncludesVariableRowsAndGaps() {
        XCTAssertEqual(PresentationGeometry.railPosition(at: 1500, rows: rows), 70)
        XCTAssertEqual(PresentationGeometry.railPosition(at: 5500, rows: rows), 325)
        XCTAssertEqual(PresentationGeometry.railTime(at: 325, rows: rows), 5500)
        XCTAssertEqual(PresentationGeometry.railTime(at: 100, rows: rows), 2400)
    }
    func testZeroOwnedNotesConsumeNoTimeAndBoundaryUsesFirstAuthoredAnchor() {
        XCTAssertEqual(PresentationGeometry.railPosition(at: 3000, rows: rows), 120)
        for y in [120.0, 150, 179, 180, 225, 250] {
            XCTAssertEqual(PresentationGeometry.railTime(at: y, rows: rows), 3000)
        }
        XCTAssertEqual(PresentationGeometry.railPosition(at: 8000, rows: rows), 400)
    }
    func testRailRoundTripsAndClamps() {
        for ms in stride(from: 0, through: 10400, by: 100) {
            XCTAssertEqual(PresentationGeometry.railTime(at: PresentationGeometry.railPosition(at: ms, rows: rows), rows: rows), ms)
        }
        XCTAssertEqual(PresentationGeometry.railTime(at: -100, rows: rows), 0)
        XCTAssertEqual(PresentationGeometry.railTime(at: 900, rows: rows), 10400)
        XCTAssertEqual(PresentationGeometry.railTime(at: .nan, rows: rows), 0)
        XCTAssertEqual(PresentationGeometry.railPosition(at: 100, rows: []), 0)
        XCTAssertEqual(PresentationGeometry.railTime(at: 100, rows: []), 0)
    }
    func testPartialCoverageDoesNotClaimWholeImageOrTouchingCut() {
        XCTAssertEqual(PresentationGeometry.coverageFractions(startMs: 1100, endMs: 1900, cueStartMs: 1000, cueEndMs: 2000), 0.1...0.9)
        XCTAssertEqual(PresentationGeometry.coverageFractions(startMs: 0, endMs: 1900, cueStartMs: 1000, cueEndMs: 2000), 0...0.9)
        XCTAssertEqual(PresentationGeometry.coverageFractions(startMs: 1100, endMs: 3000, cueStartMs: 1000, cueEndMs: 2000), 0.1...1)
        XCTAssertNil(PresentationGeometry.coverageFractions(startMs: 0, endMs: 1000, cueStartMs: 1000, cueEndMs: 2000))
        XCTAssertNil(PresentationGeometry.coverageFractions(startMs: 1000, endMs: 1000, cueStartMs: 1000, cueEndMs: 2000))
        XCTAssertNil(PresentationGeometry.coverageFractions(startMs: 0, endMs: 1000, cueStartMs: 1000, cueEndMs: 1000))
    }
    func testCoincidentRailEndsHaveStableSelectableIdentities() {
        let positions = ["purple": 250.0, "teal": 250, "coral": 260, "far": 300]
        XCTAssertEqual(PresentationGeometry.coincidentHandles(selectedID: "purple", positions: positions), ["coral", "purple", "teal"])
        XCTAssertEqual(PresentationGeometry.coincidentHandles(selectedID: "missing", positions: positions), [])
    }
    func testStoryboardRowsKeepFullShotGroupTogetherWithoutLosingCues() {
        let cuts = [0, 1000, 2000, 3000, 4000, 5000, 6000]
        let cues = (0..<6).map { ImageCue(id: "cue-\($0)", sceneId: "s", startMs: cuts[$0], endMs: cuts[$0 + 1]) }
        let rows = PresentationGeometry.storyboardRows(cues: cues, entryStarts: [0, 1000, 4000], columns: 3)
        XCTAssertEqual(rows.map(\.count), [1, 3, 2])
        XCTAssertEqual(rows.flatMap { $0 }, cues)
        XCTAssertEqual(PresentationGeometry.storyboardRows(cues: cues, entryStarts: [], columns: 2).map(\.count), [2, 2, 2])
        XCTAssertEqual(PresentationGeometry.storyboardRows(cues: [], entryStarts: [], columns: 3), [])
        XCTAssertEqual(PresentationGeometry.storyboardRows(cues: cues, entryStarts: [], columns: 0).count, 6)
    }

    func testCutDragClampsWithoutChangingPairDurationOrDisabledLabel() {
        XCTAssertEqual(PresentationGeometry.clampedCueDuration(proposed: -500, current: 1400, neighbor: 2400), 1)
        XCTAssertEqual(PresentationGeometry.clampedCueDuration(proposed: 5000, current: 1400, neighbor: 2400), 3799)
        XCTAssertEqual(PresentationGeometry.clampedCueDuration(proposed: 1400, current: 1400, neighbor: nil), 1400)
        XCTAssertEqual(PresentationGeometry.clampedCueDuration(proposed: 2000, current: 1400, neighbor: 2400), 2000)
        XCTAssertEqual(PresentationGeometry.clampedCueDuration(proposed: Int.max, current: Int.max, neighbor: 1), Int.max)
    }

}
