import XCTest
@testable import ScrivCore

final class GenerationJournalTests: XCTestCase {
    private func withJournal(_ body: (GenerationJournal, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivGenerationJournal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(GenerationJournal(root: directory.appendingPathComponent("Journal")), directory)
    }
    private func job() -> LocalGenerationJob {
        LocalGenerationJob(ownerInstallationID: UUID().uuidString,
                           context: .init(projectID: "project", projectTitle: "Script", packagePath: "/private/local/script.scriv",
                                          targetCue: .init(id: "OriginalCue", sceneId: "scene", startMs: 0, endMs: 1000), sourceRevision: 9),
                           prompt: "Private image direction", model: "model", runtimeIdentity: "managed:/local/codex")
    }
    func testAtomicJournalRoundTripPreservesRecoveryIdentityAndContext() throws {
        try withJournal { journal, _ in
            var value = job(); value.status = .running; value.threadID = "thread"; value.turnID = "turn"
            value.references = [.init(fileName: "reference-0.png", sha256: String(repeating: "a", count: 64))]
            try journal.save(value)
            let loaded = try journal.load()
            XCTAssertEqual(loaded.jobs, [value]); XCTAssertEqual(loaded.unreadable, 0)
            XCTAssertEqual(loaded.jobs[0].context?.targetCue.id, "OriginalCue", "Existing item IDs are case-sensitive, unlike new job UUID formatting")
            value.status = .completed; value.artifactRelativePath = "output/final.png"; value.artifactSha256 = String(repeating: "b", count: 64)
            value.outputImageID = "ImageVersion"
            try journal.save(value)
            XCTAssertEqual(try journal.load().jobs, [value])
            let attrs = try FileManager.default.attributesOfItem(atPath: journal.root.appendingPathComponent(value.id + ".json").path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
    func testRestartChangesOnlyUnfinishedRequestsToWaitingWithoutResubmission() {
        for status in [LocalGenerationJob.Status.queued, .running, .waiting, .completed, .cancelled, .failed] {
            var value = job(); value.status = status; value.threadID = "thread"; value.turnID = "turn"
            let id = value.id, prompt = value.prompt
            value.recoverAfterRestart()
            XCTAssertEqual(value.status, status == .queued || status == .running ? .waiting : status)
            XCTAssertEqual(value.id, id); XCTAssertEqual(value.prompt, prompt)
            XCTAssertEqual(value.threadID, "thread"); XCTAssertEqual(value.turnID, "turn")
        }
    }
    func testCorruptAndIdentityMismatchedRecordsDoNotHideOtherJobs() throws {
        try withJournal { journal, _ in
            let value = job(); try journal.save(value)
            let corrupt = journal.root.appendingPathComponent(UUID().uuidString + ".json")
            try Data("incomplete".utf8).write(to: corrupt)
            let mismatch = journal.root.appendingPathComponent(UUID().uuidString + ".json")
            try ScrivJSON.encoder.encode(value).write(to: mismatch)
            let loaded = try journal.load()
            XCTAssertEqual(loaded.jobs, [value]); XCTAssertEqual(loaded.unreadable, 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: mismatch.path))
        }
    }
    func testInvalidReferencesAndArtifactTraversalCannotEnterJournal() throws {
        try withJournal { journal, _ in
            var value = job(); value.artifactRelativePath = "../another-job/image.png"
            XCTAssertThrowsError(try journal.save(value))
            value.artifactRelativePath = "/absolute.png"
            XCTAssertThrowsError(try journal.save(value))
            value.artifactRelativePath = nil
            value.references = [.init(fileName: "../reference-0.png", sha256: String(repeating: "a", count: 64))]
            XCTAssertThrowsError(try journal.save(value))
            value.references = [.init(fileName: "reference-0.png", sha256: "not a checksum")]
            XCTAssertThrowsError(try journal.save(value))
            XCTAssertTrue(try journal.load().jobs.isEmpty)
        }
    }
    func testJournalSymlinkCannotOverwriteAnotherFile() throws {
        try withJournal { journal, root in
            let value = job(), outside = root.appendingPathComponent("preserved.txt"), bytes = Data("preserve".utf8)
            try bytes.write(to: outside)
            try FileManager.default.createSymbolicLink(at: journal.root.appendingPathComponent(value.id + ".json"), withDestinationURL: outside)
            XCTAssertThrowsError(try journal.save(value))
            XCTAssertEqual(try Data(contentsOf: outside), bytes)
            XCTAssertEqual(try journal.load().unreadable, 1)
            let alias = root.appendingPathComponent("Alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: journal.root)
            XCTAssertThrowsError(try GenerationJournal(root: alias))
        }
    }
    func testCloudJobDecodingDoesNotRequirePrivateLocalRecoveryFields() throws {
        let json = """
        {"schemaVersion":1,"id":"job","projectId":"project","targetItemId":"OriginalCue","sourceRevision":9,"status":"waiting","progressText":"Waiting for this Mac","createdAt":1,"updatedAt":2,"outputImageId":null,"errorCode":null,"createdBy":"user","ownerDeviceId":"device","ownerDeviceName":"Mac","version":3,"leaseExpiresAt":0}
        """
        let job = try ScrivJSON.decoder.decode(CloudGenerationJob.self, from: Data(json.utf8))
        XCTAssertEqual(job.status.label, "Waiting for this Mac")
        let payload = try JSONSerialization.jsonObject(with: ScrivJSON.encoder.encode(job)) as! [String: Any]
        for privateField in ["prompt", "context", "packagePath", "runtimeIdentity", "references", "threadID", "turnID", "artifactRelativePath"] { XCTAssertNil(payload[privateField]) }
    }
}
