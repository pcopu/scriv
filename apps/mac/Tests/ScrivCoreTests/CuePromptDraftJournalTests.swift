import XCTest
@testable import ScrivCore

final class CuePromptDraftJournalTests: XCTestCase {
    private func fixture() -> (ScrivProject, LocalCuePromptDraft) {
        let project = ScrivProject.example(), cue = project.cues[0]
        let scope = CuePromptDraftScope(packagePath: "/private/scripts/original.scriv", projectID: project.id,
            cloudProjectID: project.cloudProjectId, server: "https://scriv.example", accountID: "private-owner", sceneID: cue.sceneId, cueID: cue.id)
        return (project, LocalCuePromptDraft(scope: scope, sourcePrompt: cue.prompt, sourceEpoch: 2))
    }
    private func withJournal(_ body: (CuePromptDraftJournal, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivCueDraft-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(CuePromptDraftJournal(root: root), root)
    }
    private func encodedSize(_ cue: ImageCue) throws -> Int {
        let encoder = ScrivJSON.encoder; encoder.outputFormatting.insert(.withoutEscapingSlashes)
        return try encoder.encode(cue).count
    }

    func testRestartPreservesExactUnicodeAndWhitespaceWithPrivatePermissions() throws {
        try withJournal { journal, root in
            var (_, draft) = fixture()
            let text = "  🎬 cafe\u{301}\n台詞\tfinish  "
            draft.replaceText(text)
            try journal.save(draft, replacing: nil)
            let recovered = try XCTUnwrap(CuePromptDraftJournal(root: root).load(draft.scope))
            XCTAssertEqual(recovered, draft)
            XCTAssertTrue(recovered.text.utf16.elementsEqual(text.utf16))
            let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(draft.scope.key + ".json").path)
            let directory = try FileManager.default.attributesOfItem(atPath: root.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }
    func testAllContextDimensionsAreIsolatedAndCannotApplyAcrossScopes() throws {
        try withJournal { journal, _ in
            var (project, draft) = fixture(); draft.replaceText("Local manual direction")
            try journal.save(draft, replacing: nil)
            var variants: [CuePromptDraftScope] = []
            var scope = draft.scope; scope.packagePath += "-copy"; variants.append(scope)
            scope = draft.scope; scope.projectID += "-copy"; variants.append(scope)
            scope = draft.scope; scope.cloudProjectID = "other-cloud"; variants.append(scope)
            scope = draft.scope; scope.server = "https://other.example"; variants.append(scope)
            scope = draft.scope; scope.accountID = nil; variants.append(scope)
            scope = draft.scope; scope.accountID = "other"; variants.append(scope)
            scope = draft.scope; scope.sceneID = "other-scene"; variants.append(scope)
            scope = draft.scope; scope.cueID = "other-cue"; variants.append(scope)
            for variant in variants {
                XCTAssertNotEqual(variant.key, draft.scope.key)
                XCTAssertNil(try journal.load(variant))
                XCTAssertThrowsError(try draft.applying(to: project, scope: variant, epoch: 2))
            }
            project.id = "different-project"
            XCTAssertThrowsError(try draft.applying(to: project, scope: draft.scope, epoch: 2))
            XCTAssertEqual(try journal.load(draft.scope), draft)
        }
    }
    func testOnlyManualPromptChangesAndUnrelatedCueEditsArePreserved() throws {
        var (project, draft) = fixture(); draft.replaceText("A private manual creative direction.")
        project.revision += 1
        project.cues[0].label = "Changed by another editor"
        project.characters[0].biography = "Unrelated current biography"
        var expected = project; expected.cues[0].prompt = draft.text
        let next = try draft.applying(to: project, scope: draft.scope, epoch: 2)
        XCTAssertEqual(next, expected)
        XCTAssertNotEqual(project.cues[0].prompt, draft.text)
    }
    func testPromptOrEpochDriftRequiresExplicitRebaseAndDoesNotDiscardText() throws {
        var (project, draft) = fixture(); draft.replaceText("Keep this pending direction")
        project.cues[0].prompt = "Collaborator's newer direction"
        XCTAssertTrue(draft.needsRebase(sourcePrompt: project.cues[0].prompt, epoch: 2))
        XCTAssertThrowsError(try draft.applying(to: project, scope: draft.scope, epoch: 2))
        let revision = draft.revisionID
        draft.rebase(sourcePrompt: project.cues[0].prompt, epoch: 3)
        XCTAssertEqual(draft.text, "Keep this pending direction")
        XCTAssertNotEqual(draft.revisionID, revision)
        XCTAssertThrowsError(try draft.applying(to: project, scope: draft.scope, epoch: 2))
        XCTAssertEqual(try draft.applying(to: project, scope: draft.scope, epoch: 3).cues[0].prompt, draft.text)
    }
    func testCanonicallyEquivalentButDifferentSourceCodeUnitsStillConflict() throws {
        var (project, draft) = fixture()
        project.cues[0].prompt = "café"
        draft.sourcePrompt = "cafe\u{301}"
        XCTAssertEqual(draft.sourcePrompt, project.cues[0].prompt)
        XCTAssertThrowsError(try draft.applying(to: project, scope: draft.scope, epoch: 2))
    }
    func testDeletionAndMovingCueNeverRecreatesOrRetargetsItsDraft() throws {
        var (project, draft) = fixture(); draft.replaceText("Preserve pending text")
        var deleted = project; deleted.cues.removeFirst()
        XCTAssertThrowsError(try draft.applying(to: deleted, scope: draft.scope, epoch: 2))
        project.cues[0].sceneId = "another-scene"
        XCTAssertThrowsError(try draft.applying(to: project, scope: draft.scope, epoch: 2))
    }
    func testInvalidOversizedPromptRemainsRecoverableWithoutCanonicalMutation() throws {
        try withJournal { journal, _ in
            var (project, draft) = fixture()
            draft.replaceText(String(repeating: "🙂", count: 15_001))
            try journal.save(draft, replacing: nil)
            let before = project
            XCTAssertThrowsError(try draft.applying(to: project, scope: draft.scope, epoch: 2))
            XCTAssertEqual(project, before)
            XCTAssertEqual(try journal.load(draft.scope), draft)
            let previous = draft.revisionID
            draft.replaceText(String(repeating: "x", count: 30_000))
            try journal.save(draft, replacing: previous)
            project = try draft.applying(to: project, scope: draft.scope, epoch: 2)
            XCTAssertEqual(project.cues[0].prompt, draft.text)
            XCTAssertEqual(try journal.load(draft.scope), draft, "In-memory apply never deletes recovery")
        }
    }
    func testEncodedMetadataFailureAndCanonicalDiskFailureKeepRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivCueDraftSave-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try CuePromptDraftJournal(root: root.appendingPathComponent("Drafts"))
        let repository = try ProjectRepository(root: root.appendingPathComponent("Projects"))
        var (project, draft) = fixture()
        draft.replaceText(String(repeating: "\u{0001}", count: 11_000))
        try journal.save(draft, replacing: nil)
        XCTAssertThrowsError(try draft.applying(to: project, scope: draft.scope, epoch: 2))
        XCTAssertEqual(try journal.load(draft.scope), draft)
        let oldRevision = draft.revisionID
        draft.replaceText("Recovered manual direction")
        try journal.save(draft, replacing: oldRevision)
        project = try draft.applying(to: project, scope: draft.scope, epoch: 2)
        let blocked = root.appendingPathComponent("not-a-directory.scriv")
        try Data("occupied".utf8).write(to: blocked)
        do { try await repository.save(project, at: blocked, label: "Test"); XCTFail("Expected canonical save failure") } catch { }
        XCTAssertEqual(try journal.load(draft.scope), draft)
        try await repository.save(project, at: root.appendingPathComponent("saved.scriv"), label: "Test")
        XCTAssertTrue(try journal.clear(draft))
        XCTAssertNil(try journal.load(draft.scope))
    }
    func testFullEncodedCueMetadataHasExact64KiBBoundary() throws {
        var (project, draft) = fixture()
        project.cues[0].prompt = ""; draft.sourcePrompt = ""
        let available = 65_536 - (try encodedSize(project.cues[0]))
        draft.replaceText(String(repeating: "\u{0001}", count: available / 6) + String(repeating: "x", count: available % 6))
        XCTAssertLessThan(draft.text.utf16.count, 30_000)
        let next = try draft.applying(to: project, scope: draft.scope, epoch: 2)
        XCTAssertEqual(try encodedSize(next.cues[0]), 65_536)
        draft.replaceText(draft.text + "x")
        XCTAssertThrowsError(try draft.applying(to: project, scope: draft.scope, epoch: 2))
    }
    func testLateClearAndStaleCASCannotRemoveNewerTypingOrResurrectDiscardedDraft() throws {
        try withJournal { journal, _ in
            var (_, first) = fixture(); first.replaceText("First")
            XCTAssertThrowsError(try journal.save(first, replacing: UUID().uuidString))
            try journal.save(first, replacing: nil)
            XCTAssertThrowsError(try journal.save(first, replacing: nil))
            var second = first; second.replaceText("Second")
            try journal.save(second, replacing: first.revisionID)
            XCTAssertFalse(try journal.clear(first))
            XCTAssertThrowsError(try journal.save(first, replacing: first.revisionID))
            XCTAssertEqual(try journal.load(second.scope), second)
            XCTAssertTrue(try journal.clear(second))
            XCTAssertThrowsError(try journal.save(second, replacing: second.revisionID))
            XCTAssertNil(try journal.load(second.scope))
        }
    }
    func testSameRevisionCannotHideChangedDraftTextFromClearFence() throws {
        try withJournal { journal, _ in
            var (_, first) = fixture(); first.replaceText("café"); try journal.save(first, replacing: nil)
            var changed = first; changed.text = "Changed without advancing revision"
            XCTAssertThrowsError(try journal.save(changed, replacing: first.revisionID))
            changed.text = "cafe\u{301}"
            XCTAssertEqual(changed.text, first.text)
            XCTAssertThrowsError(try journal.save(changed, replacing: first.revisionID))
            XCTAssertEqual(try journal.load(first.scope), first)
        }
    }
    func testStorageBoundsRefuseWithoutEvictingOrOverwritingExistingDrafts() throws {
        try withJournal { journal, root in
            var (_, first) = fixture(); first.replaceText("Keep this")
            try journal.save(first, replacing: nil)
            let bounded = try CuePromptDraftJournal(root: root, maximumRecords: 1)
            var second = first; second.scope.cueID = "new-cue"
            XCTAssertThrowsError(try bounded.save(second, replacing: nil))
            XCTAssertEqual(try journal.load(first.scope), first)
            var oversized = first; oversized.replaceText(String(repeating: "x", count: 2 * 1024 * 1024 + 1))
            XCTAssertThrowsError(try journal.save(oversized, replacing: first.revisionID))
            XCTAssertEqual(try journal.load(first.scope), first)
            let totalBounded = try CuePromptDraftJournal(root: root, maximumTotalBytes: 10)
            XCTAssertThrowsError(try totalBounded.save(first, replacing: first.revisionID))
            XCTAssertEqual(try journal.load(first.scope), first)
        }
    }
    func testCorruptAndSymlinkRecordsAreRetainedWithoutFollowingThem() throws {
        try withJournal { journal, root in
            let (_, draft) = fixture(), target = root.appendingPathComponent(draft.scope.key + ".json")
            try Data("broken".utf8).write(to: target)
            XCTAssertThrowsError(try journal.save(draft, replacing: nil))
            XCTAssertEqual(try Data(contentsOf: target), Data("broken".utf8))
            try FileManager.default.removeItem(at: target)
            let outside = root.appendingPathComponent("protected.txt"); try Data("untouched".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            XCTAssertThrowsError(try journal.load(draft.scope))
            XCTAssertThrowsError(try journal.save(draft, replacing: nil))
            XCTAssertThrowsError(try journal.clear(draft))
            XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("missing"))
            XCTAssertThrowsError(try journal.save(draft, replacing: nil), "Dangling links are unsafe too")
        }
    }
    func testRootAndLockSymlinksAreRejected() throws {
        try withJournal { journal, root in
            let link = root.appendingPathComponent("directory-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            XCTAssertThrowsError(try CuePromptDraftJournal(root: link))
            let lock = root.appendingPathComponent(".journal-lock")
            try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: root.appendingPathComponent("missing"))
            XCTAssertThrowsError(try journal.load(fixture().1.scope))
        }
    }
    func testPrivateRecoveryLocationMustBeOutsideProjectAndNeverEntersCloudItems() throws {
        try withJournal { journal, root in
            var (project, draft) = fixture(); draft.replaceText("Only authored direction")
            let insidePackage = try CuePromptDraftJournal(root: root.appendingPathComponent("drafts"))
            var privateScope = draft.scope; privateScope.packagePath = root.path
            var privateDraft = draft; privateDraft.scope = privateScope
            XCTAssertThrowsError(try insidePackage.save(privateDraft, replacing: nil))
            try journal.save(draft, replacing: nil)
            project = try draft.applying(to: project, scope: draft.scope, epoch: 2)
            let items = try CloudCodec.items(from: project)
            let data = try ScrivJSON.encoder.encode(items)
            let text = String(decoding: data, as: UTF8.self)
            for field in ["packagePath", "sourceEpoch", "sourcePrompt", "revisionID", "accountID"] { XCTAssertFalse(text.contains("\"" + field + "\"")) }
            XCTAssertFalse(text.contains("private-owner"))
            XCTAssertEqual(items.first { $0.id == draft.scope.cueID }?.data["prompt"]?.string, draft.text)
        }
    }
    func testConcurrentJournalInstancesAllowOnlyOneCASWinner() throws {
        try withJournal { journal, root in
            let (_, first) = fixture(); try journal.save(first, replacing: nil)
            let lock = NSLock()
            var winners = [LocalCuePromptDraft](), failures = 0
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                do {
                    var next = first; next.replaceText("Writer \(index)")
                    try CuePromptDraftJournal(root: root).save(next, replacing: first.revisionID)
                    lock.lock(); winners.append(next); lock.unlock()
                } catch { lock.lock(); failures += 1; lock.unlock() }
            }
            XCTAssertEqual(winners.count, 1)
            XCTAssertEqual(failures, 1)
            XCTAssertEqual(try journal.load(first.scope), winners.first)
        }
    }
}
