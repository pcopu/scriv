import Foundation
import XCTest
@testable import ScrivCore

final class TeamInvitationTests: XCTestCase {
    private let token = String(repeating: "aB0_-", count: 9)
    private let server = URL(string: "https://scriv.example")!

    func testAcceptsRawTokensAndExactNativeAndServerInvitations() throws {
        for input in [token, " \n\(token)\n", "scriv://join/\(token)", "https://scriv.example/join/\(token)", "https://scriv.example:443/join/\(token)"] {
            XCTAssertEqual(try TeamInvitation.token(from: input, serverURL: server), token)
        }
    }
    func testRejectsWrongOriginAndLookalikeRoutes() {
        for input in ["https://evil.example/join/\(token)", "https://scriv.example.evil.test/join/\(token)", "https://scriv.example@evil.test/join/\(token)", "https://user@scriv.example/join/\(token)", "https://scriv.example:444/join/\(token)", "https://scriv.example/other/\(token)", "scriv://billing/\(token)", "scriv://join:443/\(token)", "scriv://join/\(token)/extra"] {
            XCTAssertThrowsError(try TeamInvitation.token(from: input, serverURL: server), input)
        }
    }
    func testRejectsMalformedAndAmbiguousInvitations() {
        for input in ["", "short", String(repeating: "a", count: 129), String(repeating: "+", count: 43), "scriv://join/\(token)?redirect=elsewhere", "https://scriv.example/join/\(token)#ignored", "https://scriv.example/join/\(token)/", "javascript:alert(1)", "http://scriv.example/join/\(token)"] {
            XCTAssertThrowsError(try TeamInvitation.token(from: input, serverURL: server), input)
        }
    }
    func testAllowsOnlyExplicitLocalDevelopmentHTTPOrigin() throws {
        let local = URL(string: "http://127.0.0.1:8787")!
        XCTAssertEqual(try TeamInvitation.token(from: "http://127.0.0.1:8787/join/\(token)", serverURL: local), token)
        XCTAssertThrowsError(try TeamInvitation.token(from: "http://127.0.0.1:8788/join/\(token)", serverURL: local))
        XCTAssertThrowsError(try TeamInvitation.token(from: "http://scriv.example/join/\(token)"))
    }
}
