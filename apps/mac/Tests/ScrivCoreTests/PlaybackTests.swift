import XCTest
@testable import ScrivCore

final class PlaybackTests: XCTestCase {
    func testSeekDuringPlaybackRebasesNextTick() {
        var clock = PlaybackPositionClock()
        clock.start(fromMs:1000,nowMs:500)
        XCTAssertEqual(clock.position(nowMs:1000,durationMs:10000),1500)
        clock.seek(toMs:6000,nowMs:1000)
        XCTAssertEqual(clock.position(nowMs:1016,durationMs:10000),6016)
        clock.seek(toMs:200,nowMs:1500)
        XCTAssertEqual(clock.position(nowMs:1600,durationMs:10000),300)
    }
    func testPauseResumeClampAndInvalidTimes() {
        var clock = PlaybackPositionClock()
        clock.start(fromMs:50,nowMs:100)
        XCTAssertEqual(clock.pause(nowMs:300,durationMs:500),250)
        XCTAssertEqual(clock.position(nowMs:900,durationMs:500),250)
        clock.seek(toMs:.nan,nowMs:900)
        XCTAssertEqual(clock.position(nowMs:900,durationMs:500),250)
        clock.start(fromMs:250,nowMs:900)
        XCTAssertEqual(clock.position(nowMs:10000,durationMs:500),500)
        XCTAssertEqual(clock.position(nowMs:10000,durationMs:0),0)
    }
}
