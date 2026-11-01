import Foundation
import XCTest
#if os(Linux)
import Glibc
#else
import Darwin
#endif
@testable import ScrivCore

private final class PromptCoreTestLockLease: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32
    init(root: URL) throws {
        descriptor = open(root.appendingPathComponent(".journal-lock").path,O_RDWR | O_CREAT,mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        guard flock(descriptor,LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(descriptor); descriptor = -1
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))
        }
    }
    var isReleased: Bool { mutex.lock(); defer { mutex.unlock() }; return descriptor < 0 }
    func release() {
        mutex.lock(); defer { mutex.unlock() }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor,LOCK_UN); close(descriptor); descriptor = -1
    }
    deinit { release() }
}

final class CuePromptDraftNonblockingTests: XCTestCase {
    private func scope() -> CuePromptDraftScope {
        CuePromptDraftScope(packagePath:"/private/test/nonblocking.scriv",projectID:"p",cloudProjectID:nil,
                            server:"https://example.invalid",accountID:nil,sceneID:"s",cueID:"c")
    }
    func testBusyReadIsDistinctFromMissingAndReturnsWithoutTakingTheHeldLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = try CuePromptDraftJournal(root:root), scope = scope()
        let lease = try PromptCoreTestLockLease(root:root); defer { lease.release() }
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now() + 0.8) { lease.release() }
        XCTAssertEqual(try journal.loadIfAvailable(scope),.busy)
        XCTAssertFalse(lease.isReleased,"The operation must return before the failsafe releases the held lock")
        lease.release()
        XCTAssertEqual(try journal.loadIfAvailable(scope),.ready(nil))
        var draft = LocalCuePromptDraft(scope:scope,sourcePrompt:"Saved",sourceEpoch:nil)
        draft.replaceText("  🎬 cafe\u{301}\n日本語\t  ")
        try journal.save(draft,replacing:nil)
        XCTAssertEqual(try journal.loadIfAvailable(scope),.ready(draft))
    }
    func testNonblockingClearKeepsExactRevisionFenceAndNeverDeletesNewerTyping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = try CuePromptDraftJournal(root:root)
        var old = LocalCuePromptDraft(scope:scope(),sourcePrompt:"Saved",sourceEpoch:nil)
        old.replaceText("Earlier accepted edit")
        try journal.save(old,replacing:nil)
        var newer = old; newer.replaceText("Newer accepted edit 😀")
        try journal.save(newer,replacing:old.revisionID)
        XCTAssertEqual(try journal.clearIfAvailable(old),.finished(false))
        XCTAssertEqual(try journal.loadIfAvailable(old.scope),.ready(newer))
        XCTAssertEqual(try journal.clearIfAvailable(newer),.finished(true))
        XCTAssertEqual(try journal.loadIfAvailable(old.scope),.ready(nil))
    }
    func testBusyClearDoesNotMeanSuccessAndDoesNotChangeTheRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = try CuePromptDraftJournal(root:root)
        var draft = LocalCuePromptDraft(scope:scope(),sourcePrompt:"Saved",sourceEpoch:nil)
        draft.replaceText("Retain this")
        try journal.save(draft,replacing:nil)
        let lease = try PromptCoreTestLockLease(root:root); defer { lease.release() }
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now() + 0.8) { lease.release() }
        XCTAssertEqual(try journal.clearIfAvailable(draft),.busy)
        XCTAssertFalse(lease.isReleased,"The operation must return before the failsafe releases the held lock")
        lease.release()
        XCTAssertEqual(try journal.load(draft.scope),draft)
    }
}
