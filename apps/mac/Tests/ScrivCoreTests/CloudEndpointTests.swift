import XCTest
@testable import ScrivCore

final class CloudEndpointTests: XCTestCase {
    func testProductionHTTPSAndLoopbackOnlyDevelopment() {
        for value in ["https://scriv.example", "https://scriv.example:8443/", "http://127.0.0.1:8787", "http://localhost:8787", "http://[::1]:8787"] { XCTAssertTrue(CloudEndpoint.isValid(URL(string: value)!)) }
        for value in ["http://scriv.example", "https://user:pass@scriv.example", "https://scriv.example/api", "https://scriv.example?token=x", "https://scriv.example/#fragment", "file:///tmp"] { XCTAssertFalse(CloudEndpoint.isValid(URL(string: value)!)) }
    }
    func testAPIResolutionRejectsCrossOriginAndTraversal() throws {
        let base = URL(string: "https://scriv.example:8443/")!
        XCTAssertEqual(try CloudEndpoint.apiURL(path: "/v1/projects/p/events?after=1&limit=100", base: base).absoluteString, "https://scriv.example:8443/v1/projects/p/events?after=1&limit=100")
        for path in ["https://evil.example/steal", "//evil.example/steal", "///evil.example", "v1/me", "/\\evil.example/steal", "/v1/../auth/logout", "/v1/%2e%2e/auth/logout", "/%2f%2fevil.example", "/v1/me#fragment", "/v1/\nme"] { XCTAssertThrowsError(try CloudEndpoint.apiURL(path: path, base: base), path) }
    }
    func testQueryValuesCannotInjectAnotherParameter() throws {
        let escaped = CloudEndpoint.queryValue("message &after=9000/雪")
        let url = try CloudEndpoint.apiURL(path: "/v1/messages?afterId=\(escaped)", base: URL(string: "https://scriv.example")!)
        let values = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(values.count, 1); XCTAssertEqual(values[0].value, "message &after=9000/雪")
    }
}
