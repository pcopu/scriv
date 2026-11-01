import XCTest
@testable import BootstrapClient
final class ConsentTests: XCTestCase {
    func testDeclinedConsentReturnsErrorWithoutStartingConnection() {
        let client = ScrivRuntimeBootstrapClient()
        var replies = 0
        client.connectAfterUserConsent(false) { data, error in
            replies += 1; XCTAssertNil(data); XCTAssertNotNil(error)
        }
        XCTAssertEqual(replies, 1)
        client.disconnect()
    }
}
