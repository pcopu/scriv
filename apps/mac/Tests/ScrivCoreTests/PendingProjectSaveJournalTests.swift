import XCTest
@testable import ScrivCore

final class PendingProjectSaveJournalTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scriv-pending-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func fixture() -> ScrivProject {
        ScrivProject(id: "project", title: "Draft", scenes: [ScriptScene(id: "scene")], entries: [ScriptEntry(id: "line", sceneId: "scene", order: 0, text: "A line", ownedDurationMs: 2000)])
    }
    private func next(_ source: ScrivProject, title: String = "Changed") -> ScrivProject {
        var result = source; result.title = title; result.revision += 1; return result
    }
    private func scope(_ package: URL, project: ScrivProject) -> PendingProjectSaveScope {
        PendingProjectSaveScope(packagePath: package.path, projectID: project.id, cloudProjectID: project.cloudProjectId)
    }
    private func journal(_ root: URL) throws -> PendingProjectSaveJournal {
        try PendingProjectSaveJournal(root: root.appendingPathComponent("Pending"))
    }
    func testInitialProjectIsDurableBeforePackageExistsAndReplayDoesNotMutateAnything() throws {
        let root = try workspace(), package = root.appendingPathComponent("new.scriv"), project = fixture(), journal = try journal(root)
        let record = try journal.persist(scope: scope(package, project: project), before: nil, after: project, label: "New project")
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        XCTAssertEqual(try journal.allPackages(), [package])
        XCTAssertEqual(try journal.load(package: package), [record])
        let reopened = try PendingProjectSaveJournal(root: journal.root)
        let plan = try reopened.planRecovery(scope: record.scope, canonical: nil)
        XCTAssertEqual(plan.replay, [record]); XCTAssertTrue(plan.alreadySaved.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        XCTAssertEqual(try journal.load(package: package), [record])
    }
    func testContiguousReplayAndAcknowledgementOnlyAfterCanonicalSave() async throws {
        let root = try workspace(), package = root.appendingPathComponent("story.scriv"), base = fixture(), journal = try journal(root)
        let one = next(base, title: "One"), two = next(next(base, title: "One"), title: "Two")
        let a = try journal.persist(scope: scope(package, project: base), before: base, after: one, label: "First edit")
        let b = try journal.persist(scope: a.scope, before: one, after: two, label: "Second edit")
        let plan = try journal.planRecovery(scope: a.scope, canonical: base, acceptedHistory: [base])
        XCTAssertEqual(plan.replay, [a, b]); XCTAssertTrue(plan.alreadySaved.isEmpty)
        let repo = try ProjectRepository(root: root.appendingPathComponent("Projects"))
        try await repo.save(base, at: package, label: "Base")
        for record in plan.replay {
            let current = try await repo.load(at: package)
            XCTAssertEqual(current, record.before)
            try await repo.save(record.after, at: package, label: record.label)
            XCTAssertTrue(try journal.acknowledge(record))
        }
        let saved = try await repo.load(at: package)
        XCTAssertEqual(saved, two); XCTAssertTrue(try journal.load(package: package).isEmpty)
        XCTAssertTrue(try journal.acknowledge(a))
    }
    func testAlreadySavedRecordsNeedExactAcceptedHistoryAndNeverRewindNewerCanonical() throws {
        let root = try workspace(), package = root.appendingPathComponent("story.scriv"), zero = fixture(), journal = try journal(root)
        let one = next(zero, title: "One"), two = next(next(zero, title: "One"), title: "Two"), three = next(next(next(zero, title: "One"), title: "Two"), title: "Three")
        let a = try journal.persist(scope: scope(package, project: zero), before: nil, after: zero, label: "New")
        let b = try journal.persist(scope: a.scope, before: zero, after: one, label: "One")
        let c = try journal.persist(scope: a.scope, before: one, after: two, label: "Two")
        let plan = try journal.planRecovery(scope: a.scope, canonical: three, acceptedHistory: [zero, one, two])
        XCTAssertTrue(plan.replay.isEmpty); XCTAssertEqual(plan.alreadySaved, [a, b, c])
        XCTAssertThrowsError(try journal.planRecovery(scope: a.scope, canonical: three, acceptedHistory: [zero, two]))
        var fork = two; fork.title = "Unrelated accepted branch"
        XCTAssertThrowsError(try journal.planRecovery(scope: a.scope, canonical: three, acceptedHistory: [zero, one, fork]))
        XCTAssertEqual(try journal.load(package: package), [a, b, c])
    }
    func testDivergedCanonicalGapFutureHistoryAndUnrelatedProjectFailClosed() throws {
        let root = try workspace(), package = root.appendingPathComponent("story.scriv"), zero = fixture(), journal = try journal(root)
        let one = next(zero), two = next(next(zero)), three = next(next(next(zero)))
        let record = try journal.persist(scope: scope(package, project: zero), before: two, after: three, label: "Gap")
        XCTAssertThrowsError(try journal.planRecovery(scope: record.scope, canonical: zero, acceptedHistory: [zero]))
        var fork = two; fork.title = "Different source"
        XCTAssertThrowsError(try journal.planRecovery(scope: record.scope, canonical: fork, acceptedHistory: [zero, one]))
        XCTAssertThrowsError(try journal.planRecovery(scope: record.scope, canonical: two, acceptedHistory: [three]))
        var other = two; other.id = "another-project"
        XCTAssertThrowsError(try journal.planRecovery(scope: record.scope, canonical: other))
        XCTAssertThrowsError(try journal.planRecovery(scope: record.scope, canonical: nil, acceptedHistory: [zero]))
        XCTAssertEqual(try journal.load(package: package), [record])
    }
    func testImmutableRevisionRejectsForkAndRetryIsIdempotent() throws {
        let root = try workspace(), package = root.appendingPathComponent("story.scriv"), before = fixture(), journal = try journal(root), after = next(before)
        let record = try journal.persist(scope: scope(package, project: before), before: before, after: after, label: "Edit")
        XCTAssertEqual(try journal.persist(scope: record.scope, before: before, after: after, label: "Edit"), record)
        var fork = after; fork.title = "Fork"
        XCTAssertThrowsError(try journal.persist(scope: record.scope, before: before, after: fork, label: "Edit"))
        XCTAssertThrowsError(try journal.persist(scope: record.scope, before: before, after: after, label: "Different accepted label"))
        XCTAssertEqual(try journal.load(package: package), [record])
    }
    func testAccountScopeMismatchRetainsAndBlocksAutomaticReplayAndFurtherWrites() throws {
        let root = try workspace(), package = root.appendingPathComponent("cloud.scriv"), journal = try journal(root)
        var before = fixture(); before.cloudProjectId = "cloud-project"
        let after = next(before), later = next(next(before))
        let owner = PendingProjectSaveScope(packagePath: package.path, projectID: before.id, cloudProjectID: before.cloudProjectId, server: "https://api.example.test", accountID: "owner")
        let other = PendingProjectSaveScope(packagePath: package.path, projectID: before.id, cloudProjectID: before.cloudProjectId, server: "https://api.example.test", accountID: "different")
        let record = try journal.persist(scope: owner, before: before, after: after, label: "Edit")
        XCTAssertThrowsError(try journal.planRecovery(scope: other, canonical: before))
        XCTAssertThrowsError(try journal.persist(scope: other, before: after, after: later, label: "Another account"))
        XCTAssertEqual(try journal.load(package: package), [record])
        XCTAssertEqual(try journal.planRecovery(scope: owner, canonical: before).replay, [record])
    }
    func testDistinctPackagesDoNotConflictAndExactAcknowledgementCannotClearDifferentContent() throws {
        let root = try workspace(), aPackage = root.appendingPathComponent("a.scriv"), bPackage = root.appendingPathComponent("b.scriv"), base = fixture(), journal = try journal(root)
        let recordA = try journal.persist(scope: scope(aPackage, project: base), before: base, after: next(base), label: "A")
        let recordB = try journal.persist(scope: scope(bPackage, project: base), before: base, after: next(base), label: "B")
        let alternativeJournal = try PendingProjectSaveJournal(root: root.appendingPathComponent("AlternativePending"))
        let fork = try alternativeJournal.persist(scope: recordA.scope, before: base, after: next(base, title: "Different"), label: "A")
        XCTAssertFalse(try journal.acknowledge(fork))
        XCTAssertEqual(try journal.allPackages(), [aPackage, bPackage])
        XCTAssertEqual(try journal.load(package: aPackage), [recordA]); XCTAssertEqual(try journal.load(package: bPackage), [recordB])
    }
    func testSizeAndCountLimitsNeverEvictExistingRecoveryData() throws {
        let root = try workspace(), package = root.appendingPathComponent("story.scriv"), base = fixture(), journal = try journal(root), after = next(base)
        let record = try journal.persist(scope: scope(package, project: base), before: base, after: after, label: "One")
        let countLimited = try PendingProjectSaveJournal(root: journal.root, maximumRecords: 1)
        XCTAssertThrowsError(try countLimited.persist(scope: record.scope, before: after, after: next(after), label: "Two"))
        let totalLimited = try PendingProjectSaveJournal(root: journal.root, maximumTotalBytes: 1)
        XCTAssertThrowsError(try totalLimited.persist(scope: record.scope, before: after, after: next(after), label: "Two"))
        let recordLimited = try PendingProjectSaveJournal(root: journal.root, maximumRecordBytes: 100)
        XCTAssertThrowsError(try recordLimited.persist(scope: record.scope, before: after, after: next(after), label: "Two"))
        XCTAssertEqual(try journal.load(package: package), [record])
    }
    func testReadBoundsRejectAnOversizedInventoryWithoutEviction() throws {
        let root = try workspace(), package = root.appendingPathComponent("story.scriv"), base = fixture(), journal = try journal(root)
        let one = next(base), two = next(next(base))
        let a = try journal.persist(scope: scope(package, project: base), before: base, after: one, label: "One")
        let b = try journal.persist(scope: a.scope, before: one, after: two, label: "Two")
        let limited = try PendingProjectSaveJournal(root: journal.root, maximumRecords: 1)
        XCTAssertThrowsError(try limited.load(package: package))
        XCTAssertThrowsError(try limited.allPackages())
        let byteLimited = try PendingProjectSaveJournal(root: journal.root, maximumTotalBytes: 1)
        XCTAssertThrowsError(try byteLimited.load(package: package))
        XCTAssertEqual(try journal.load(package: package), [a, b])
    }
    func testAbandonedPartialWriteIsNotReplayedOrEvictedAndStillCountsTowardBounds() throws {
        let root = try workspace(), package = root.appendingPathComponent("story.scriv"), project = fixture(), journal = try journal(root)
        let partial = journal.root.appendingPathComponent(".pending-interrupted.tmp")
        let bytes = Data("unfinished record".utf8); try bytes.write(to: partial)
        XCTAssertTrue(try journal.allPackages().isEmpty)
        XCTAssertTrue(try journal.load(package: package).isEmpty)
        let limited = try PendingProjectSaveJournal(root: journal.root, maximumTotalBytes: bytes.count)
        XCTAssertThrowsError(try limited.persist(scope: scope(package, project: project), before: nil, after: project, label: "New"))
        XCTAssertEqual(try Data(contentsOf: partial), bytes)
    }
    func testUnwritableJournalRefusesNewMutationWithoutRemovingExistingRecord() throws {
        let root = try workspace(), package = root.appendingPathComponent("story.scriv"), base = fixture(), journal = try journal(root)
        let one = next(base)
        let record = try journal.persist(scope: scope(package, project: base), before: base, after: one, label: "One")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: journal.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journal.root.path) }
        XCTAssertThrowsError(try journal.persist(scope: record.scope, before: one, after: next(one), label: "Two"))
        XCTAssertEqual(try journal.load(package: package), [record])
    }
    func testJournalPermissionsArePrivateAndSymlinkRecordsCannotBeFollowed() throws {
        let root = try workspace(), package = root.appendingPathComponent("story.scriv"), base = fixture(), journal = try journal(root)
        let record = try journal.persist(scope: scope(package, project: base), before: nil, after: base, label: "New")
        let file = journal.root.appendingPathComponent(record.id + ".json")
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: journal.root.path)[.posixPermissions] as? NSNumber
        let filePermissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700); XCTAssertEqual(filePermissions?.intValue, 0o600)
        let external = root.appendingPathComponent("unrelated.json"), bytes = try Data(contentsOf: file)
        try bytes.write(to: external); try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        XCTAssertThrowsError(try journal.load(package: package)); XCTAssertThrowsError(try journal.acknowledge(record))
        XCTAssertEqual(try Data(contentsOf: external), bytes)
    }
    func testSymlinkRootLockAndPackageInternalJournalAreRejected() throws {
        let root = try workspace(), external = root.appendingPathComponent("External"), linked = root.appendingPathComponent("Linked")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)
        XCTAssertThrowsError(try PendingProjectSaveJournal(root: linked))
        let journal = try journal(root), lock = journal.root.appendingPathComponent(".journal-lock"), unrelated = root.appendingPathComponent("unrelated-lock")
        try Data("do not change".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: unrelated)
        XCTAssertThrowsError(try journal.allPackages()); XCTAssertEqual(try String(contentsOf: unrelated), "do not change")
        let package = root.appendingPathComponent("inside.scriv"), project = fixture()
        let internalJournal = try PendingProjectSaveJournal(root: package.appendingPathComponent("Pending"))
        XCTAssertThrowsError(try internalJournal.persist(scope: scope(package, project: project), before: nil, after: project, label: "New"))
    }
    func testCorruptedSnapshotsAndChangedRecordBytesAreRetained() throws {
        let root = try workspace(), package = root.appendingPathComponent("story.scriv"), base = fixture(), journal = try journal(root)
        let record = try journal.persist(scope: scope(package, project: base), before: nil, after: base, label: "New")
        let file = journal.root.appendingPathComponent(record.id + ".json"), originalBytes = try Data(contentsOf: file)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: originalBytes) as? [String: Any])
        var after = try XCTUnwrap(object["after"] as? [String: Any]); after["title"] = "Tampered"; object["after"] = after
        let corrupt = try JSONSerialization.data(withJSONObject: object); try corrupt.write(to: file)
        XCTAssertThrowsError(try journal.load(package: package)); XCTAssertEqual(try Data(contentsOf: file), corrupt)
        var reformatted = originalBytes; reformatted.append(Data("\n ".utf8)); try reformatted.write(to: file)
        XCTAssertEqual(try journal.load(package: package), [record])
        XCTAssertFalse(try journal.acknowledge(record)); XCTAssertEqual(try Data(contentsOf: file), reformatted)
    }
    func testMalformedRevisionAndCredentialBearingScopeAreRejectedBeforeWriting() throws {
        let root = try workspace(), package = root.appendingPathComponent("story.scriv"), base = fixture(), journal = try journal(root)
        let regularScope = scope(package, project: base)
        XCTAssertThrowsError(try journal.persist(scope: regularScope, before: nil, after: next(base), label: "Bad initial"))
        XCTAssertThrowsError(try journal.persist(scope: regularScope, before: base, after: next(next(base)), label: "Gap"))
        let secretScope = PendingProjectSaveScope(packagePath: package.path, projectID: base.id, server: "https://user:password@example.test")
        XCTAssertThrowsError(try journal.persist(scope: secretScope, before: nil, after: base, label: "No credentials"))
        let tokenScope = PendingProjectSaveScope(packagePath: package.path, projectID: base.id, server: "https://example.test/?token=secret")
        XCTAssertThrowsError(try journal.persist(scope: tokenScope, before: nil, after: base, label: "No tokens"))
        XCTAssertTrue(try journal.allPackages().isEmpty)
    }
    func testConcurrentInstancesAcceptExactlyOneForkWithoutReplacement() throws {
        let root = try workspace(), package = root.appendingPathComponent("story.scriv"), base = fixture(), first = try journal(root)
        let second = try PendingProjectSaveJournal(root: first.root), scope = scope(package, project: base)
        let lock = NSLock(); var successes: [PendingProjectSaveRecord] = [], failures = 0
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                let record = try (index == 0 ? first : second).persist(scope: scope, before: base, after: next(base, title: "Writer \(index)"), label: "Concurrent")
                lock.lock(); successes.append(record); lock.unlock()
            } catch { lock.lock(); failures += 1; lock.unlock() }
        }
        XCTAssertEqual(successes.count, 1); XCTAssertEqual(failures, 1)
        XCTAssertEqual(try first.load(package: package), successes)
    }
}
