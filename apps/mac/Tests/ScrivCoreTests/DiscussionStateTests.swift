import XCTest
@testable import ScrivCore

final class DiscussionStateTests: XCTestCase {
    private func message(_ id: String, thread: String = "t", at: Int) throws -> DiscussionMessage {
        try JSONValue.object(["id":.string(id), "threadId":.string(thread), "body":.string(id), "createdAt":.number(Double(at))]).decoded(DiscussionMessage.self)
    }
    func testReplayAndHTTPMergeAreDeduplicatedSortedAndThreadScoped() throws {
        let a = try message("a", at: 1), b = try message("b", at: 1), c = try message("c", at: 2), unrelated = try message("other", thread: "other", at: 0)
        let result = DiscussionState.merged([c, b], with: [a, b, unrelated], threadId: "t")
        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(DiscussionState.merged(result, with: [c, a, b], threadId: "t"), result)
    }
    func testDraftScopesSeparateAccountsProjectsAndItemSelections() {
        let base = DiscussionState.draftKey(server: "https://scriv.example", account: "a", project: "p", item: nil)
        let others = [
            DiscussionState.draftKey(server: "https://other.example", account: "a", project: "p", item: nil),
            DiscussionState.draftKey(server: "https://scriv.example", account: "b", project: "p", item: nil),
            DiscussionState.draftKey(server: "https://scriv.example", account: "a", project: "q", item: nil),
            DiscussionState.draftKey(server: "https://scriv.example", account: "a", project: "p", item: ""),
            DiscussionState.draftKey(server: "https://scriv.example", account: "a", project: "p", item: "line")]
        XCTAssertEqual(Set([base] + others).count, 6)
    }
    func testOfflinePanelLoadsItsPendingContextAfterAttachWithoutDuplicateRequests() {
        XCTAssertEqual(DiscussionState.refreshAction(isVisible:true,isAttached:false,hasThread:false,isLoading:false),.none)
        XCTAssertEqual(DiscussionState.refreshAction(isVisible:true,isAttached:true,hasThread:false,isLoading:false),.loadThread)
        XCTAssertEqual(DiscussionState.refreshAction(isVisible:true,isAttached:true,hasThread:false,isLoading:true),.none)
        XCTAssertEqual(DiscussionState.refreshAction(isVisible:true,isAttached:true,hasThread:true,isLoading:false),.reloadMessages)
        XCTAssertEqual(DiscussionState.refreshAction(isVisible:false,isAttached:true,hasThread:true,isLoading:false),.none)
        XCTAssertEqual(DiscussionState.refreshAction(isVisible:true,isAttached:false,hasThread:true,isLoading:false),.none)
    }

    func testMentionMetadataIsBackwardCompatibleAndSurvivesReplayEncoding() throws {
        let legacy = try message("old",at:1)
        XCTAssertEqual(legacy.mentionedUserIds,[])
        let tagged = try JSONValue.object(["id":.string("tagged"),"threadId":.string("t"),"body":.string("Please review"),"mentionedUserIds":.array([.string("u1"),.string("u2")])]).decoded(DiscussionMessage.self)
        XCTAssertEqual(try ScrivJSON.decoder.decode(DiscussionMessage.self,from:ScrivJSON.encoder.encode(tagged)),tagged)
        XCTAssertEqual(tagged.body,"Please review")
    }
    func testMentionSelectionRejectsAmbiguousDuplicatesRemovedMembersAndOverflow() throws {
        let members = (0..<21).map { DiscussionMember(id:"u\($0)",name:"Person",role:"member") }
        XCTAssertEqual(try DiscussionState.validatedMentionIDs(["u2","u1"],members:members),["u1","u2"])
        XCTAssertThrowsError(try DiscussionState.validatedMentionIDs(["u1","u1"],members:members))
        XCTAssertThrowsError(try DiscussionState.validatedMentionIDs(["removed"],members:members))
        XCTAssertThrowsError(try DiscussionState.validatedMentionIDs(members.map(\.id),members:members))
    }
    func testMentionInboxDeduplicatesAcrossThreadsAndNeverLeaksAnotherAccount() throws {
        var first = try message("a",at:2); first.mentionedUserIds = ["me"]
        var second = try message("b",thread:"archived",at:3); second.mentionedUserIds = ["me","other"]
        let ordinary = try message("c",at:4)
        XCTAssertEqual(DiscussionState.mentions([first,second,first,ordinary],userID:"me").map(\.id),["b","a"])
        XCTAssertEqual(DiscussionState.mentions([first,second],userID:"other").map(\.id),["b"])
        XCTAssertTrue(DiscussionState.mentions([first,second],userID:nil).isEmpty)
    }

}
