import XCTest
@testable import ScrivCore

final class EmailSignInFlowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970:1_800_000_000)
    private func challenge(_ flow: inout EmailSignInFlow, operation: UUID, at date: Date) throws {
        XCTAssertTrue(try flow.receivedChallenge(id:String(repeating:"a",count:43),expiresAtMilliseconds:Int64(date.addingTimeInterval(600).timeIntervalSince1970*1000),resendAtMilliseconds:Int64(date.addingTimeInterval(60).timeIntervalSince1970*1000),operation:operation,now:date))
    }
    func testEmailAndCodeAreBoundedAndNormalized() throws {
        XCTAssertEqual(try EmailSignInFlow.normalizedEmail("  Writer+Mac@Example.com\n"),"writer+mac@example.com")
        for email in ["", "a", "a@b", "a@@example.com", "a\n@example.com", "a@.example.com", "a@example.com.", "a..b@example.com", ".a@example.com", "a.@example.com", "<a>@example.com", "a@éxample.com", "a@bad_domain.com", "a@-bad.com", "a@bad-.com", String(repeating:"a",count:65)+"@example.com"] { XCTAssertThrowsError(try EmailSignInFlow.normalizedEmail(email),email) }
        XCTAssertEqual(try EmailSignInFlow.normalizedCode(" 012345\n"),"012345")
        for code in ["12345", "1234567", "１２３４５６", "١٢٣٤٥٦", "12 345", "12345a"] { XCTAssertThrowsError(try EmailSignInFlow.normalizedCode(code),code) }
    }
    func testRequestVerificationAndResendDeadline() throws {
        var flow = EmailSignInFlow()
        let operation = try flow.beginRequest(email:"writer@example.com",now:now)
        XCTAssertTrue(flow.isBusy); XCTAssertThrowsError(try flow.beginRequest(email:"writer@example.com",now:now))
        try challenge(&flow,operation:operation,at:now)
        XCTAssertEqual(flow.phase,.awaitingCode); XCTAssertEqual(flow.resendSeconds(at:now),60)
        XCTAssertThrowsError(try flow.beginRequest(email:"writer@example.com",now:now.addingTimeInterval(59)))
        let verify = try flow.beginVerification(code:"012345",now:now)
        XCTAssertEqual(flow.phase,.verifying)
        flow.fail(operation:verify,message:"That code was not accepted.")
        XCTAssertEqual(flow.phase,.awaitingCode); XCTAssertNotNil(flow.challengeID)
        XCTAssertTrue(flow.canResend(at:now.addingTimeInterval(60)))
        _ = try flow.beginRequest(email:"writer@example.com",now:now.addingTimeInterval(60))
        XCTAssertNil(flow.challengeID)
    }
    func testCancelRejectsLateResponseAndCannotReplaceNewFlow() throws {
        var flow = EmailSignInFlow()
        let stale = try flow.beginRequest(email:"first@example.com",now:now)
        flow.cancel()
        let fresh = try flow.beginRequest(email:"next@example.com",now:now)
        XCTAssertFalse(try flow.receivedChallenge(id:"old",expiresAtMilliseconds:0,resendAtMilliseconds:0,operation:stale,now:now))
        flow.fail(operation:stale,message:"Stale failure")
        XCTAssertEqual(flow.operationID,fresh); XCTAssertEqual(flow.email,"next@example.com"); XCTAssertNil(flow.errorMessage)
        try challenge(&flow,operation:fresh,at:now)
        let verify = try flow.beginVerification(code:"123456",now:now)
        flow.cancel(); flow.fail(operation:verify,message:"Late verification")
        XCTAssertEqual(flow,EmailSignInFlow())
    }
    func testExpiryAndMalformedServerDeadlinesFailClosed() throws {
        var flow = EmailSignInFlow()
        let operation = try flow.beginRequest(email:"writer@example.com",now:now)
        XCTAssertThrowsError(try flow.receivedChallenge(id:"bad/id",expiresAtMilliseconds:Int64(now.addingTimeInterval(600).timeIntervalSince1970*1000),resendAtMilliseconds:Int64(now.timeIntervalSince1970*1000),operation:operation,now:now))
        XCTAssertThrowsError(try flow.receivedChallenge(id:String(repeating:"a",count:43),expiresAtMilliseconds:Int64.max,resendAtMilliseconds:0,operation:operation,now:now))
        try challenge(&flow,operation:operation,at:now)
        XCTAssertTrue(flow.isExpired(at:now.addingTimeInterval(600)))
        XCTAssertThrowsError(try flow.beginVerification(code:"123456",now:now.addingTimeInterval(600)))
        XCTAssertTrue(flow.canResend(at:now.addingTimeInterval(600)))
    }
    func testFailureRetryIsBoundedAndAddressCannotChangeMidFlow() throws {
        var flow = EmailSignInFlow()
        let operation = try flow.beginRequest(email:"writer@example.com",now:now)
        flow.fail(operation:operation,message:String(repeating:"x",count:1000),retryAfter:10_000,now:now)
        XCTAssertEqual(flow.errorMessage?.count,500); XCTAssertEqual(flow.resendSeconds(at:now),120)
        XCTAssertThrowsError(try flow.beginRequest(email:"other@example.com",now:now.addingTimeInterval(120)))
        flow.cancel(); XCTAssertEqual(flow.email,""); XCTAssertNil(flow.resendAt)
        _ = try flow.beginRequest(email:"other@example.com",now:now)
    }
}
