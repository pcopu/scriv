import XCTest
@testable import ScrivCore

final class PeerAssetDiscoveryTests: XCTestCase {
    func testOffersAreScopedAndSourcesFailOverExactlyOnce() {
        var discovery = PeerAssetDiscovery(requestId:"request",allowedPeers:["a","b"])
        XCTAssertFalse(discovery.offer(peer:"intruder",requestId:"request"))
        XCTAssertFalse(discovery.offer(peer:"a",requestId:"old-request"))
        XCTAssertTrue(discovery.offer(peer:"a",requestId:"request"))
        XCTAssertEqual(discovery.nextSource(),"a")
        XCTAssertTrue(discovery.offer(peer:"b",requestId:"request"))
        XCTAssertNil(discovery.nextSource())
        XCTAssertFalse(discovery.failed(peer:"b"))
        XCTAssertTrue(discovery.failed(peer:"a"))
        XCTAssertEqual(discovery.nextSource(),"b")
        XCTAssertFalse(discovery.failed(peer:"a"))
        XCTAssertEqual(discovery.activePeer,"b")
        XCTAssertFalse(discovery.offer(peer:"a",requestId:"request"))
        XCTAssertTrue(discovery.failed(peer:"b"))
        XCTAssertNil(discovery.nextSource())
    }
    func testLateAvailabilityCanRecoverAfterFirstFailure() {
        var first = PeerAssetDiscovery(requestId:"one",allowedPeers:["a","b"])
        var second = PeerAssetDiscovery(requestId:"two",allowedPeers:["a","b"])
        first.offer(peer:"a",requestId:"one"); second.offer(peer:"a",requestId:"two")
        XCTAssertEqual(first.nextSource(),"a"); XCTAssertEqual(second.nextSource(),"a")
        first.failed(peer:"a")
        XCTAssertNil(first.nextSource()); XCTAssertEqual(second.activePeer,"a")
        first.offer(peer:"b",requestId:"one")
        XCTAssertEqual(first.nextSource(),"b"); XCTAssertEqual(second.activePeer,"a")
    }
}
