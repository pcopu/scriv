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

    func testTitlePageAuthorDoesNotCreateATimedEntryOrExtraScene() throws {
        let project = Fountain.parse("Title: Audit fixture\nAuthor: Test Writer\n\nINT. ROOM - DAY\n\n@JASON\nHello there.\n")
        XCTAssertEqual(project.title, "Audit fixture")
        XCTAssertEqual(project.scenes.map(\.title), ["INT. ROOM - DAY"])
        XCTAssertEqual(project.entries.map(\.text), ["Hello there."])
        XCTAssertEqual(project.characters.map(\.name), ["Jason"])
        XCTAssertEqual(project.cues.count, 1)
        try TimingEngine.validate(project)
    }

    func testTitlePageSupportsAllKeysAndIndentedValues() throws {
        let source = """
        title:
            First line
            Second line
        Credit: Written by
        Authors:
            One Writer
            Another Writer
        Source: An original story
        Draft date: 2026-10-30
        Contact:
            Production office
            Address line
        Copyright: 2026
        Custom metadata: Preserved in the source, not a timed script element

        EXT. ROAD - DAY

        !The car arrives.
        """
        let project = Fountain.parse(source)
        XCTAssertEqual(project.title, "First line\nSecond line")
        XCTAssertEqual(project.scenes.count, 1)
        XCTAssertEqual(project.entries.map(\.text), ["The car arrives."])
        XCTAssertTrue(project.characters.isEmpty)
        let roundTrip = Fountain.parse(Fountain.export(project))
        XCTAssertEqual(roundTrip.title, project.title)
        XCTAssertEqual(roundTrip.entries.map(\.text), project.entries.map(\.text))
        try TimingEngine.validate(project)
        try TimingEngine.validate(roundTrip)
    }

    func testTitlePageMayOmitTitleAndEndsBeforeTheBody() throws {
        let project = Fountain.parse("Draft date: 2026-10-30\nAuthor: A Writer\n\nINT. OFFICE - DAY\n\nAuthor: This is an action in the screenplay.\n\n@WRITER\nTitle: These are spoken words.\n", title: "Filename fallback")
        XCTAssertEqual(project.title, "Filename fallback")
        XCTAssertEqual(project.scenes.count, 1)
        XCTAssertEqual(project.entries.map(\.text), ["Author: This is an action in the screenplay.", "Title: These are spoken words."])
        XCTAssertEqual(project.entries.map(\.kind), [.direction, .dialogue])
        try TimingEngine.validate(project)
    }

    func testTitlePageToleratesUTF8BOMCRLFAndTabIndentedValues() throws {
        let project = Fountain.parse("\u{FEFF}Title:\r\n\tBOM title\r\nAuthor:\r\n\tTest Writer\r\n\r\nINT. ROOM - DAY\r\n\r\n!Wait.\r\n")
        XCTAssertEqual(project.title, "BOM title")
        XCTAssertEqual(project.scenes.count, 1)
        XCTAssertEqual(project.entries.map(\.text), ["Wait."])
        try TimingEngine.validate(project)
    }

    func testTitlePageStopsAtNonMetadataEvenWithoutBlankSeparator() throws {
        let project = Fountain.parse("Title: No separator\nAuthor: Test Writer\nINT. ROOM - DAY\n\n!Wait.")
        XCTAssertEqual(project.title, "No separator")
        XCTAssertEqual(project.scenes.map(\.title), ["INT. ROOM - DAY"])
        XCTAssertEqual(project.entries.map(\.text), ["Wait."])
        try TimingEngine.validate(project)
    }

    func testTitleLikeBodyAfterBlankAndForcedActionsAreNotMetadata() throws {
        let project = Fountain.parse("Title: Actual title\n\nTitle: A card in the screenplay.\n\nINT. ROOM - DAY\n\n!Author: Not metadata.")
        XCTAssertEqual(project.title, "Actual title")
        XCTAssertEqual(project.entries.map(\.text), ["Title: A card in the screenplay.", "Author: Not metadata."])
        let forced = Fountain.parse("!Author: A literal opening action.\n\nINT. ROOM - DAY")
        XCTAssertEqual(forced.entries.map(\.text), ["Author: A literal opening action."])
        let transition = Fountain.parse("CUT TO:\n\nINT. ROOM - DAY")
        XCTAssertEqual(transition.entries.map(\.text), ["CUT TO:"])
        try TimingEngine.validate(project)
        try TimingEngine.validate(forced)
        try TimingEngine.validate(transition)
    }

    func testPlainTextOpeningColonIsNotMistakenForTitleMetadata() throws {
        for opening in ["JASON: Hello there.", "Warning: Do not enter.", "12:30 on the clock.", "https://example.test/script"] {
            let project = Fountain.parse(opening + "\n\nThe door opens.", title: "Plain text")
            XCTAssertEqual(project.title, "Plain text")
            XCTAssertEqual(project.entries.map(\.text), [opening, "The door opens."])
            try TimingEngine.validate(project)
        }
    }

    func testEmptyAndMetadataOnlyInputsRemainValid() throws {
        for source in ["", "\n\n", "Title: Metadata only\nAuthor: Writer", "Author:\n\tOne Writer"] {
            let project = Fountain.parse(source)
            XCTAssertEqual(project.scenes.count, 1)
            XCTAssertTrue(project.entries.isEmpty)
            XCTAssertTrue(project.cues.isEmpty)
            try TimingEngine.validate(project)
        }
    }

    func testTitleMayContainAColonOrTransitionText() throws {
        let project = Fountain.parse("Title: CUT TO:\nAuthor: A Writer\nCUT TO:\n\nINT. ROOM - DAY\n\n!Wait.")
        XCTAssertEqual(project.title, "CUT TO:")
        XCTAssertEqual(project.entries.map(\.text), ["CUT TO:", "Wait."])
        try TimingEngine.validate(project)
    }

    func testExportedMultilineTitleWithBlankLineDoesNotLeakIntoScript() throws {
        var source = ScrivProject.example()
        source.title = "First line\n\nThird line"
        let project = Fountain.parse(Fountain.export(source))
        XCTAssertEqual(project.title, source.title)
        XCTAssertEqual(project.entries.map(\.text), source.entries.map(\.text))
        XCTAssertEqual(project.scenes.map(\.title), source.scenes.map(\.title))
        try TimingEngine.validate(project)
    }

}
