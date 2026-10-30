import XCTest
@testable import ScrivCore

final class PendingSaveRepositoryTests: XCTestCase {
    private func setup() throws -> (URL, URL, ProjectRepository, PendingProjectSaveJournal, ScrivProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivPendingRepository-" + UUID().uuidString)
        let repo = try ProjectRepository(root:root.appendingPathComponent("Projects"))
        let value = ScrivProject.example(), package = root.appendingPathComponent("Project.scriv")
        let journal = try PendingProjectSaveJournal(root:root.appendingPathComponent("Pending"))
        return (root,package,repo,journal,value)
    }
    func testInitialAndContiguousRecoveryAreIdempotent() async throws {
        let (root,package,repo,journal,initial) = try setup(); defer { try? FileManager.default.removeItem(at:root) }
        let scope = PendingProjectSaveScope(packagePath:package.path,projectID:initial.id)
        let first = try journal.persist(scope:scope,before:nil,after:initial,label:"Create")
        try await repo.saveRecovering(first,at:package)
        try await repo.saveRecovering(first,at:package)
        var next = initial; next.revision += 1; next.title = "Accepted after process death"
        let change = try journal.persist(scope:scope,before:initial,after:next,label:"Rename")
        try await repo.saveRecovering(change,at:package)
        try await repo.saveRecovering(change,at:package)
        let loaded = try await repo.load(at:package)
        XCTAssertEqual(loaded,next)
        XCTAssertTrue(try journal.acknowledge(first)); XCTAssertTrue(try journal.acknowledge(change))
    }
    func testDivergedSourceAfterPlanningCannotBeOverwritten() async throws {
        let (root,package,repo,journal,initial) = try setup(); defer { try? FileManager.default.removeItem(at:root) }
        try await repo.save(initial,at:package,label:"Initial")
        let scope = PendingProjectSaveScope(packagePath:package.path,projectID:initial.id)
        var planned = initial; planned.revision = 1; planned.title = "Pending"
        let record = try journal.persist(scope:scope,before:initial,after:planned,label:"Pending")
        _ = try journal.planRecovery(scope:scope,canonical:initial,acceptedHistory:[initial])
        var concurrent = initial; concurrent.revision = 1; concurrent.title = "Other accepted writer"
        let other = try ProjectRepository(root:root)
        try await other.save(concurrent,at:package,label:"Other")
        let bytes = try Data(contentsOf:package.appendingPathComponent("project.json"))
        do { try await repo.saveRecovering(record,at:package); XCTFail("Recovery overwrote a concurrent writer") } catch {}
        XCTAssertEqual(try Data(contentsOf:package.appendingPathComponent("project.json")),bytes)
        XCTAssertEqual(try journal.load(package:package),[record])
    }
    func testIdempotentRetryRequiresExactHistory() async throws {
        let (root,package,repo,journal,initial) = try setup(); defer { try? FileManager.default.removeItem(at:root) }
        try await repo.save(initial,at:package,label:"Initial")
        var next = initial; next.revision = 1; next.title = "Next"
        let record = try journal.persist(scope:.init(packagePath:package.path,projectID:initial.id),before:initial,after:next,label:"Next")
        try await repo.saveRecovering(record,at:package)
        try FileManager.default.removeItem(at:package.appendingPathComponent("history/000000000000.json"))
        do { try await repo.saveRecovering(record,at:package); XCTFail("Missing source history was accepted") } catch {}
        XCTAssertEqual(try journal.load(package:package),[record])
    }
    func testSymlinkLockCannotRedirectWrites() async throws {
        let (root,package,repo,_,initial) = try setup(); defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
        let target = root.appendingPathComponent("private.txt"); try Data("untouched".utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:package.appendingPathComponent(".scriv-write.lock"),withDestinationURL:target)
        do { try await repo.save(initial,at:package,label:"Bad lock"); XCTFail("Symlink lock was accepted") } catch {}
        XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath:package.appendingPathComponent("project.json").path))
    }
    func testOlderAcceptedRecordRequiresDurableHistoryWithoutRegressingHead() async throws {
        let (root,package,repo,journal,initial) = try setup(); defer { try? FileManager.default.removeItem(at:root) }
        try await repo.save(initial,at:package,label:"Initial")
        var one = initial; one.revision = 1; one.title = "One"
        let record = try journal.persist(scope:.init(packagePath:package.path,projectID:initial.id),before:initial,after:one,label:"One")
        try await repo.saveRecovering(record,at:package)
        var two = one; two.revision = 2; two.title = "Two"
        try await repo.save(two,at:package,label:"Two")
        try await repo.saveRecovering(record,at:package)
        let current = try await repo.load(at:package); XCTAssertEqual(current,two)
        try FileManager.default.removeItem(at:package.appendingPathComponent("history/000000000001.json"))
        do { try await repo.saveRecovering(record,at:package); XCTFail("An older unproven history was accepted") } catch {}
        XCTAssertEqual(try journal.load(package:package),[record])
    }

}
