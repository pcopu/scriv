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
}
