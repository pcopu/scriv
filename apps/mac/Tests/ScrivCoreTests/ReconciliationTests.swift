import XCTest
@testable import ScrivCore

final class ReconciliationTests: XCTestCase {
    private func fixture() -> ScrivProject {
        ScrivProject(id:"project",scenes:[ScriptScene(id:"scene",title:"INT. ROOM — DAY")],entries:[
            ScriptEntry(id:"a",sceneId:"scene",order:0,text:"Hello there",ownedDurationMs:2000),
            ScriptEntry(id:"b",sceneId:"scene",order:1,text:"Good morning",ownedDurationMs:2000)
        ],characters:[ScriptCharacter(id:"one",name:"One"),ScriptCharacter(id:"two",name:"Two")],cues:[ImageCue(id:"cue",sceneId:"scene",startMs:0,endMs:4000)])
    }
    private func merge(_ base: ScrivProject, _ local: ScrivProject, _ remote: ScrivProject) throws -> ScrivProject {
        try CloudCodec.applying(CloudReconciliation.merge(base:CloudCodec.items(from:base),local:CloudCodec.items(from:local),remote:CloudCodec.items(from:remote)),to:local)
    }
    func testIndependentCharacterEditsMerge() throws {
        let base = fixture(); var local = base, remote = base
        local.characters[0].biography = "Local biography"; remote.characters[1].appearance = "Remote appearance"
        let result = try merge(base,local,remote)
        XCTAssertEqual(result.characters.first { $0.id == "one" }?.biography,"Local biography")
        XCTAssertEqual(result.characters.first { $0.id == "two" }?.appearance,"Remote appearance")
    }
    func testDisjointSpokenLinesCanMergeWithoutMovingSceneClock() throws {
        let base = fixture(); var local = base, remote = base
        try TimingEngine.updateText(&local,entryId:"a",text:"Welcome back")
        try TimingEngine.updateText(&remote,entryId:"b",text:"Good evening")
        let result = try merge(base,local,remote)
        XCTAssertEqual(result.entries.first { $0.id == "a" }?.text,"Welcome back")
        XCTAssertEqual(result.entries.first { $0.id == "b" }?.text,"Good evening")
        XCTAssertEqual(result.durationMs(of:"scene"),4000)
    }
    func testDurationChangeConflictsWithRemoteTextTiming() throws {
        let base = fixture(); var local = base, remote = base
        try TimingEngine.setOwnedDuration(&local,entryId:"a",durationMs:3000)
        try TimingEngine.updateText(&remote,entryId:"b",text:"Good evening")
        XCTAssertThrowsError(try merge(base,local,remote))
    }
    func testDeletionConflictsWithConcurrentEdit() throws {
        let base = fixture(); var local = base, remote = base
        local.characters.removeFirst(); remote.characters[0].biography = "New details"
        XCTAssertThrowsError(try merge(base,local,remote))
    }
    func testRemoteOnlyChangeAndTombstoneAreApplied() throws {
        let base = fixture(); let local = try CloudCodec.items(from:base)
        var remote = local
        let index = try XCTUnwrap(remote.firstIndex { $0.id == "one" })
        remote[index].deleted = true; remote[index].version = 12
        let merged = try CloudReconciliation.merge(base:local,local:local,remote:remote)
        XCTAssertFalse(merged.contains { $0.id == "one" })
        try TimingEngine.validate(CloudCodec.applying(merged,to:base))
    }
    func testCheckpointRoundTripRetainsAccountServerAndTimingFence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = try ProjectRepository(root:root)
        let checkpoint = CloudCheckpoint(projectId:"project",serverURL:"https://scriv.example",accountId:"user",epoch:3,headSeq:22,timingVersion:17,items:try CloudCodec.items(from:fixture()))
        try await repo.saveCheckpoint(checkpoint,at:root)
        let loaded = try await repo.checkpoint(at:root)
        XCTAssertEqual(loaded?.accountId,"user"); XCTAssertEqual(loaded?.serverURL,"https://scriv.example")
        XCTAssertEqual(loaded?.timingVersion,17); XCTAssertEqual(loaded?.items,checkpoint.items)
    }
    func testPremiumFollowsServerComputedPlan() throws {
        let expired = try ScrivJSON.decoder.decode(CloudTeam.self,from:Data("{\"id\":\"team\",\"name\":\"Team\",\"status\":\"active\",\"plan\":\"free\"}".utf8))
        XCTAssertFalse(expired.isPaid)
        let paid = try ScrivJSON.decoder.decode(CloudTeam.self,from:Data("{\"id\":\"team\",\"name\":\"Team\",\"status\":\"active\",\"plan\":\"team\"}".utf8))
        XCTAssertTrue(paid.isPaid)
    }
    func testSnapshotKeepsDeletionVersionsForReconnectedUndo() throws {
        let source = fixture()
        let active = try CloudCodec.items(from:source).filter { $0.id != "one" }
        let tombstone = CloudItem(id:"one",kind:"character",version:7,data:.object([:]),deleted:true)
        let payload: JSONValue = .object(["projectId":.string("remote"),"epoch":.number(2),"headSeq":.number(15),"timingVersion":.number(9),"items":try .encoded(active),"deletedItems":try .encoded([tombstone]),"canImport":.bool(false)])
        let snapshot = try payload.decoded(CloudSnapshot.self)
        let items = try snapshot.validatedItems(for:"remote")
        XCTAssertEqual(items.first { $0.id == "one" }?.version,7)
        XCTAssertEqual(items.count,active.count+1)
        let restored = try CloudCodec.applying(items,to:source)
        XCTAssertFalse(restored.characters.contains { $0.id == "one" })
        var resurrected = restored; resurrected.characters.append(source.characters[0])
        let merged = try CloudReconciliation.merge(base:items,local:CloudCodec.items(from:resurrected),remote:items)
        // The merge retains canonical tombstone version even though the desired item is active.
        XCTAssertEqual(merged.first { $0.id == "one" }?.version,7)
        XCTAssertEqual(items.first { $0.id == "one" }?.version,7) // CloudClient's expectedVersion source.
        XCTAssertThrowsError(try snapshot.validatedItems(for:"wrong-project"))
    }
    func testSnapshotRejectsDuplicateTombstoneAndImpossibleImportFlag() throws {
        let item = CloudItem(id:"a",kind:"character",version:2,data:.object([:]))
        var tombstone = item; tombstone.deleted = true
        let duplicate: JSONValue = .object(["projectId":.string("p"),"epoch":.number(1),"headSeq":.number(1),"items":try .encoded([item]),"deletedItems":try .encoded([tombstone])])
        XCTAssertThrowsError(try duplicate.decoded(CloudSnapshot.self).validatedItems(for:"p"))
        let impossible: JSONValue = .object(["projectId":.string("p"),"epoch":.number(1),"headSeq":.number(1),"items":.array([]),"deletedItems":try .encoded([tombstone]),"canImport":.bool(true)])
        XCTAssertThrowsError(try impossible.decoded(CloudSnapshot.self).validatedItems(for:"p"))
        let discussionOnly: JSONValue = .object(["projectId":.string("p"),"epoch":.number(1),"headSeq":.number(4),"items":.array([]),"deletedItems":.array([]),"canImport":.bool(true)])
        XCTAssertTrue(try discussionOnly.decoded(CloudSnapshot.self).validatedItems(for:"p").isEmpty)
    }

}
