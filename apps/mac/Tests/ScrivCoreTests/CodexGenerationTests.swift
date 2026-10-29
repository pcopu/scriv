import XCTest
@testable import ScrivCore

final class CodexGenerationTests: XCTestCase {
    private func completed(_ id: String) -> JSONValue { .object(["id": .string(id), "status": .string("completed")]) }

    func testCancellationBeforeTurnResponseInterruptsTheLateTurnOnce() {
        var job = CodexGenerationState()
        job.startThread("thread")
        XCTAssertNil(job.requestCancellation())
        let interrupt = job.startTurn("late-turn")
        XCTAssertEqual(interrupt?.threadID, "thread")
        XCTAssertEqual(interrupt?.turnID, "late-turn")
        XCTAssertTrue(job.cancellationRequested)
        XCTAssertNil(job.requestCancellation(), "A cancellation handler and Cancel button must not duplicate an interrupt")
    }
    func testCancellationAfterStartAndFreshJobsAreIndependent() {
        var job = CodexGenerationState()
        job.startThread("thread"); XCTAssertNil(job.startTurn("turn"))
        XCTAssertEqual(job.requestCancellation()?.turnID, "turn")
        job = CodexGenerationState()
        job.startThread("new-thread"); XCTAssertNil(job.startTurn("new-turn"))
        XCTAssertFalse(job.cancellationRequested)
    }
    func testCompletionBeforeStartResponseIsRetainedAndCorrelated() {
        var job = CodexGenerationState()
        job.startThread("thread")
        job.recordCompletion(threadID: "unrelated", turn: completed("turn"))
        job.recordCompletion(threadID: "thread", turn: completed("turn"))
        XCTAssertNil(job.completion)
        XCTAssertNil(job.startTurn("turn"))
        XCTAssertEqual(job.completion, completed("turn"))
        job.recordCompletion(threadID: "thread", turn: completed("another-turn"))
        XCTAssertEqual(job.completion, completed("turn"))
    }
    func testForeignAndUncorrelatedCompletionsCannotFinishAJob() {
        var job = CodexGenerationState()
        job.recordCompletion(threadID: nil, turn: completed("turn"))
        job.startThread("thread"); XCTAssertNil(job.startTurn("turn"))
        job.recordCompletion(threadID: "other", turn: completed("turn"))
        job.recordCompletion(threadID: "thread", turn: completed("other"))
        XCTAssertNil(job.completion)
        job.recordCompletion(threadID: "thread", turn: completed("turn"))
        XCTAssertEqual(job.completion, completed("turn"))
    }
    func testArtifactSelectionRejectsReferencesSymlinksEmptyAndOversizedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivCodexTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("generation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func put(_ name: String, _ bytes: Data = Data([1])) throws -> URL {
            let file = directory.appendingPathComponent(name); try bytes.write(to: file); return file
        }
        let valid = try put("tool-image.png"), preferred = try put("storyboard.jpg")
        let reference = try put("Reference-0.png"), empty = try put("empty.png", Data())
        let oversized = try put("large.png", Data(count: CodexImageArtifacts.maximumBytes + 1))
        let outside = root.appendingPathComponent("outside.png"); try Data([1]).write(to: outside)
        let link = directory.appendingPathComponent("link.png"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
        let candidates = try CodexImageArtifacts.candidates(in: directory, reported: [reference, empty, outside, oversized, link, valid])
        XCTAssertEqual(candidates, [preferred, valid])
        for file in [reference, empty, outside, oversized, link] { XCTAssertFalse(CodexImageArtifacts.isEligible(file, in: directory)) }
    }
    func testInvalidPreferredArtifactDoesNotHideValidReportedOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivCodexTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("storyboard.png"))
        let nested = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let valid = nested.appendingPathComponent("image.png"); try Data([1]).write(to: valid)
        XCTAssertEqual(try CodexImageArtifacts.candidates(in: root, reported: [valid, valid]), [valid])
    }
}
