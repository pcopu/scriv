import XCTest
@testable import ScrivCore

final class FountainTests: XCTestCase {
    func testExportImportPreservesAuthoredTextAndDurations() throws {
        let source = ScrivProject.example()
        let imported = Fountain.parse(Fountain.export(source))
        XCTAssertEqual(imported.title, source.title)
        XCTAssertEqual(imported.entries.map(\.text), source.entries.map(\.text))
        XCTAssertEqual(imported.entries.map(\.ownedDurationMs), source.entries.map(\.ownedDurationMs))
        XCTAssertEqual(imported.entries.filter { $0.kind == .direction }.map(\.coverageDurationMs), source.entries.filter { $0.kind == .direction }.map(\.coverageDurationMs))
        try TimingEngine.validate(imported)
    }
    func testParentheticalIsUnspokenForwardDirection() throws {
        let source = "Title: A Scene\n\nINT. ROOM - DAY\n\nJASON\n(angrily)\nYou stupid guy!\n\nJason turns toward Bonny.\n"
        let project = Fountain.parse(source)
        XCTAssertEqual(project.entries.count, 3)
        XCTAssertEqual(project.entries[0].kind, .direction)
        XCTAssertEqual(project.entries[0].ownedDurationMs, 0)
        XCTAssertTrue(project.entries[0].words.isEmpty)
        XCTAssertEqual(project.entries[1].kind, .dialogue)
        XCTAssertEqual(project.entries[1].text, "You stupid guy!")
        try TimingEngine.validate(project)
    }
    func testCRLFAndSceneOrder() throws {
        let source = "EXT. FARM - DAY\r\n\r\nThe farmer waits.\r\n\r\nINT. BARN - NIGHT\r\n\r\nA lamp flickers.\r\n"
        let project = Fountain.parse(source)
        XCTAssertEqual(project.scenes.count, 2)
        XCTAssertEqual(project.entries.count, 2)
        XCTAssertEqual(project.cues.count, 2)
        try TimingEngine.validate(project)
    }
    func testForcedActionsAndCustomHeadingsRoundTripWithoutBecomingSpeakers() throws {
        let scene = ScriptScene(id:"s",title:"A custom scene name")
        let source = ScrivProject(title:"Forced",scenes:[scene],entries:[
            ScriptEntry(sceneId:"s",order:0,kind:.direction,text:"RUN\nDo not look back.",ownedDurationMs:2000,coverageDurationMs:86_400_000),
            ScriptEntry(sceneId:"s",order:1,kind:.direction,text:"INT. is a direction here, not a scene.",ownedDurationMs:1000),
            ScriptEntry(sceneId:"s",order:2,kind:.direction,text:"@camera stays still",ownedDurationMs:0,coverageDurationMs:3000)
        ])
        let imported = Fountain.parse(Fountain.export(source))
        XCTAssertEqual(imported.scenes.map(\.title),source.scenes.map(\.title))
        XCTAssertEqual(imported.entries.map(\.text),source.entries.map(\.text))
        XCTAssertEqual(imported.entries.map(\.kind),source.entries.map(\.kind))
        XCTAssertEqual(imported.entries.map(\.coverageDurationMs),source.entries.map(\.coverageDurationMs))
        try TimingEngine.validate(imported)
    }
    func testMetadataImmediatelyAfterTextAppliesToThatEntry() throws {
        let p = Fountain.parse("INT. ROOM\n\n@RANDY\nHello there\n[[scriv duration=2000 coverage=0]]")
        XCTAssertEqual(p.entries.count,1)
        XCTAssertEqual(p.entries[0].ownedDurationMs,2000)
        XCTAssertEqual(p.entries[0].coverageDurationMs,0)
        XCTAssertEqual(p.entries[0].words.last?.endMs,2000)
        try TimingEngine.validate(p)
    }
    func testMidDialogueParentheticalKeepsSpeakerAndIsNeverSpoken() throws {
        let p = Fountain.parse("INT. ROOM\n\nRANDY\nBefore.\n(whispering)\nAfter.\n\nRANDY (CONT'D)\nStill me.\n")
        XCTAssertEqual(p.entries.map(\.text),["Before.","(whispering)","After.","Still me."])
        XCTAssertEqual(p.characters.count,1)
        XCTAssertEqual(p.entries[0].characterId,p.entries[2].characterId)
        XCTAssertEqual(p.entries[2].characterId,p.entries[3].characterId)
        XCTAssertTrue(p.entries[1].words.isEmpty)
        XCTAssertEqual(p.entries[1].ownedDurationMs,0)
        try TimingEngine.validate(p)
    }
    func testEmptyScenesAndMalformedTimingAnnotationsRemainSafe() throws {
        let p = Fountain.parse(".First empty scene\n\n.Second scene\n\n!Wait.\n[[scriv duration=-1 coverage=99999999999999999999]]")
        XCTAssertEqual(p.scenes.map(\.title),["First empty scene","Second scene"])
        XCTAssertEqual(p.entries.count,1)
        XCTAssertEqual(p.entries[0].ownedDurationMs,1000)
        try TimingEngine.validate(p)
    }

}
