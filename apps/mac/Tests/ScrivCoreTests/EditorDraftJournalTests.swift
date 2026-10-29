import XCTest
@testable import ScrivCore

final class EditorDraftJournalTests: XCTestCase {
    private func fixture() -> (ScrivProject, LocalEditorDraft) {
        let project = ScrivProject.example()
        let entry = project.entries.first { $0.kind == .dialogue }!
        let scope = EditorDraftScope(packagePath:"/private/scripts/original.scriv",projectID:project.id,cloudProjectID:project.cloudProjectId,
                                     server:"https://scriv.example",accountID:"owner",entryID:entry.id)
        return (project,LocalEditorDraft(scope:scope,sourceRevision:project.revision,sourceEpoch:nil,sourceEntry:entry))
    }
    private func withJournal(_ body: (EditorDraftJournal, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivEditorDraft-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try body(EditorDraftJournal(root:root),root)
    }
    func testRestartPreservesExactSourceScopeTextAndEditEvents() throws {
        try withJournal { journal, root in
            var (_, draft) = fixture()
            let edit = CharacterTextEdit(range:NSRange(location:0,length:0),replacement:"😀 New ")
            draft.replaceText("😀 New " + draft.text,edit:edit)
            try journal.save(draft,replacing:nil)
            let reopened = try EditorDraftJournal(root:root)
            XCTAssertEqual(try reopened.load(draft.scope),draft)
            XCTAssertEqual(draft.edits[0].native,edit)
            let attrs = try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent(draft.scope.key + ".json").path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue,0o600)
        }
    }
    func testPackageProjectEntryOriginAccountAndCloudProjectAreIsolated() throws {
        try withJournal { journal, _ in
            var (_, draft) = fixture(); draft.replaceText("Local text")
            try journal.save(draft,replacing:nil)
            var variants: [EditorDraftScope] = []
            var scope = draft.scope; scope.packagePath += "-copy"; variants.append(scope)
            scope = draft.scope; scope.projectID += "-copy"; variants.append(scope)
            scope = draft.scope; scope.entryID += "-copy"; variants.append(scope)
            scope = draft.scope; scope.server = "https://other.example"; variants.append(scope)
            scope = draft.scope; scope.accountID = nil; variants.append(scope)
            scope = draft.scope; scope.accountID = "other"; variants.append(scope)
            scope = draft.scope; scope.cloudProjectID = "other-cloud"; variants.append(scope)
            for variant in variants {
                XCTAssertNil(try journal.load(variant)); XCTAssertNotEqual(variant.key,draft.scope.key)
                XCTAssertThrowsError(try draft.applying(to:fixture().0,scope:variant,epoch:nil))
            }
            XCTAssertEqual(try journal.load(draft.scope),draft)
        }
    }
    func testInvalidAuthoredTimingIsRetainedWithoutCanonicalMutation() throws {
        try withJournal { journal, _ in
            var (project, draft) = fixture()
            let index = project.entries.firstIndex { $0.id == draft.scope.entryID }!
            project.entries[index].words[0].timingSource = .authored
            project.entries[index].words[0].startMs = 0
            draft.sourceEntry = project.entries[index]
            // There is no space before the pinned first word for a new word.
            draft.replaceText("NewWord " + draft.text,edit:.init(range:NSRange(location:0,length:0),replacement:"NewWord "))
            try journal.save(draft,replacing:nil)
            let before = project
            XCTAssertThrowsError(try draft.applying(to:project,scope:draft.scope,epoch:nil))
            XCTAssertEqual(project,before)
            XCTAssertEqual(try journal.load(draft.scope),draft)
        }
    }
    func testSourceAndEpochDriftRequireExplicitRebaseButUnrelatedRevisionDoesNot() throws {
        var (project, draft) = fixture(); draft.replaceText(draft.text + " More.")
        project.revision += 1
        XCTAssertNoThrow(try draft.applying(to:project,scope:draft.scope,epoch:nil))
        XCTAssertThrowsError(try draft.applying(to:project,scope:draft.scope,epoch:3))
        let index = project.entries.firstIndex { $0.id == draft.scope.entryID }!
        project.entries[index].color = "red"
        XCTAssertThrowsError(try draft.applying(to:project,scope:draft.scope,epoch:nil))
        draft.rebase(on:project.entries[index],revision:project.revision,epoch:3)
        XCTAssertNoThrow(try draft.applying(to:project,scope:draft.scope,epoch:3))
    }
    func testExactRepeatedNameEditKeepsCorrectIdentityAndRebaseRevokesGuessing() throws {
        var (project, draft) = fixture()
        let a = ScriptCharacter(id:"a",name:"Alex"), b = ScriptCharacter(id:"b",name:"Other")
        project.characters += [a,b]
        let index = project.entries.firstIndex { $0.id == draft.scope.entryID }!
        project.entries[index].text = "Alex Alex"
        project.entries[index].words = TimingEngine.retimeWords(text:"Alex Alex",durationMs:project.entries[index].ownedDurationMs)
        project.entries[index].characterLinks = [.init(characterId:"a",location:0,length:4,text:"Alex"),.init(characterId:"b",location:5,length:4,text:"Alex")]
        draft.sourceEntry = project.entries[index]; draft.text = "Alex Alex"
        draft.replaceText("Alex",edit:.init(range:NSRange(location:0,length:5),replacement:""))
        let exact = try draft.applying(to:project,scope:draft.scope,epoch:nil)
        XCTAssertEqual(exact.entries[index].characterLinks?.first?.characterId,"b")
        XCTAssertEqual(exact.entries[index].characterLinks?.first?.isConfirmed,true)
        draft.rebase(on:project.entries[index],revision:project.revision,epoch:nil)
        let reviewed = try draft.applying(to:project,scope:draft.scope,epoch:nil)
        XCTAssertFalse(reviewed.entries[index].characterLinks?.contains(where: { $0.isConfirmed && $0.characterId != nil }) ?? false)
    }
    func testLateSaveCannotClearOrOverwriteNewerTyping() throws {
        try withJournal { journal, _ in
            var (_, first) = fixture(); first.replaceText("First")
            try journal.save(first,replacing:nil)
            var second = first; second.replaceText("Second")
            try journal.save(second,replacing:first.revisionID)
            XCTAssertFalse(try journal.clear(first))
            XCTAssertThrowsError(try journal.save(first,replacing:first.revisionID))
            XCTAssertEqual(try journal.load(second.scope),second)
            XCTAssertTrue(try journal.clear(second))
            XCTAssertNil(try journal.load(second.scope))
        }
    }
    func testCanonicalDiskFailureRetainsDraftUntilSuccessfulSaveAndExplicitClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivDraftSave-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let journal = try EditorDraftJournal(root:root.appendingPathComponent("Drafts"))
        let repository = try ProjectRepository(root:root.appendingPathComponent("Projects"))
        var (project,draft) = fixture(); draft.replaceText(draft.text + " Additional words.")
        try journal.save(draft,replacing:nil)
        project = try draft.applying(to:project,scope:draft.scope,epoch:nil)
        XCTAssertEqual(try journal.load(draft.scope),draft,"Applying valid text in memory must not clear recovery.")
        let blocked = root.appendingPathComponent("not-a-directory.scriv")
        try Data("occupied".utf8).write(to:blocked)
        do { try await repository.save(project,at:blocked,label:"Test"); XCTFail("Expected disk save to fail") } catch { }
        XCTAssertEqual(try journal.load(draft.scope),draft)
        try await repository.save(project,at:root.appendingPathComponent("saved.scriv"),label:"Test")
        XCTAssertTrue(try journal.clear(draft))
        XCTAssertNil(try journal.load(draft.scope))
    }
    func testDeletedSourceIsNeverRecreatedOrAppliedToAnotherLine() throws {
        var (project,draft) = fixture(); draft.replaceText("Unsaved words")
        project.entries.removeAll { $0.id == draft.scope.entryID }
        let before = project
        XCTAssertThrowsError(try draft.applying(to:project,scope:draft.scope,epoch:nil))
        XCTAssertEqual(project,before)
    }
    func testStorageLimitsRefuseNewRecordsWithoutEvictingExistingDrafts() throws {
        try withJournal { journal, root in
            var (_, first) = fixture(); first.replaceText("Keep this")
            try journal.save(first,replacing:nil)
            let bounded = try EditorDraftJournal(root:root,maximumRecordBytes:2*1024*1024,maximumTotalBytes:64*1024*1024,maximumRecords:1)
            var second = first; second.scope.entryID = "new-entry"; second.sourceEntry.id = "new-entry"
            XCTAssertThrowsError(try bounded.save(second,replacing:nil))
            XCTAssertEqual(try journal.load(first.scope),first)
            var oversized = first; oversized.replaceText(String(repeating:"x",count:2*1024*1024+1))
            XCTAssertThrowsError(try journal.save(oversized,replacing:first.revisionID))
            XCTAssertEqual(try journal.load(first.scope),first)
        }
    }
    func testCorruptAndSymlinkFilesAreRetainedAndNeverOverwritten() throws {
        try withJournal { journal, root in
            let (_, draft) = fixture()
            let target = root.appendingPathComponent(draft.scope.key + ".json")
            try Data("broken".utf8).write(to:target)
            XCTAssertThrowsError(try journal.save(draft,replacing:nil))
            XCTAssertEqual(try Data(contentsOf:target),Data("broken".utf8))
            try FileManager.default.removeItem(at:target)
            let outside = root.appendingPathComponent("protected.txt"); try Data("untouched".utf8).write(to:outside)
            try FileManager.default.createSymbolicLink(at:target,withDestinationURL:outside)
            XCTAssertThrowsError(try journal.load(draft.scope))
            XCTAssertThrowsError(try journal.save(draft,replacing:nil))
            XCTAssertEqual(try Data(contentsOf:outside),Data("untouched".utf8))
        }
    }
    func testBoundedEditCompactionIsConservativeAndStillRoundTrips() throws {
        try withJournal { journal, _ in
            var (_, draft) = fixture()
            for _ in 0..<1025 { let offset = draft.text.utf16.count; draft.replaceText(draft.text + "x",edit:.init(range:NSRange(location:offset,length:0),replacement:"x")) }
            XCTAssertLessThanOrEqual(draft.edits.count,1024)
            try journal.save(draft,replacing:nil)
            XCTAssertEqual(try journal.load(draft.scope),draft)
        }
    }
}
