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
}
