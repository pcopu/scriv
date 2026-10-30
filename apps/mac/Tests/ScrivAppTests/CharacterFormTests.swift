import AppKit
import SwiftUI
import XCTest
import ScrivCore
@testable import ScrivApp

/// These compile the actual SwiftUI form presentation helpers on macOS.
/// Portable core tests separately exercise identity persistence and validation.
final class CharacterFormTests: XCTestCase {
    func testPresentationSnapshotKeepsCharacterAndContextTogether() {
        var character = ScriptCharacter(id: "character", name: "Before")
        let selection = CharacterEditSelection(character: character, navigationContext: 42)
        character.name = "After"
        XCTAssertEqual(selection.id, "character")
        XCTAssertEqual(selection.character.name, "Before")
        XCTAssertEqual(selection.navigationContext, 42)
        XCTAssertFalse(selection.isNew)
    }

    func testNewCharacterPresentationIsAnUnsavedBlankDraft() {
        let project = ScrivProject(characters: [ScriptCharacter(id: "existing", name: "Existing")])
        let selection = CharacterEditSelection(character: ScriptCharacter(name: ""), navigationContext: 7, isNew: true)
        XCTAssertTrue(selection.isNew)
        XCTAssertTrue(selection.character.name.isEmpty)
        XCTAssertFalse(project.characters.contains { $0.id == selection.id })
        XCTAssertEqual(project.characters.map(\.name), ["Existing"])
    }

    func testAliasChipsTrimNewAliasWithoutSplittingOrReorderingExistingNames() {
        let aliases = ["The Farmer", "Franklin"]
        XCTAssertEqual(CharacterFormValues.addingAlias("  Papa, Jr.\n", to: aliases), aliases + ["Papa, Jr."])
        XCTAssertEqual(CharacterFormValues.addingAlias(" frankLIN ", to: aliases), aliases)
        XCTAssertEqual(CharacterFormValues.addingAlias(" \n", to: aliases), aliases)
    }

    func testManualOccurrencesUseExactUTF16OffsetsAndDisambiguateRepeatedWords() {
        let text = "🙂 Franklin and Franklin."
        XCTAssertEqual(CharacterLinkReviewPresentation.occurrences(of: "Franklin", in: text), [
            NSRange(location: 3, length: 8), NSRange(location: 16, length: 8)
        ])
        XCTAssertEqual(CharacterLinkReviewPresentation.occurrences(of: "franklin", in: text), [])
        XCTAssertEqual(CharacterLinkReviewPresentation.occurrences(of: "", in: text), [])
    }

    func testOccurrencePreviewHighlightsOnlyChosenOccurrenceAndPreservesWords() {
        let text = "🙂 Franklin and Franklin."
        let value = CharacterLinkReviewPresentation.highlightedSource(text, focusedRange: NSRange(location: 16, length: 8))
        XCTAssertEqual(String(value.characters), text)
        XCTAssertEqual(highlightedWords(value), ["Franklin"])
        let highlighted = value.runs.first { $0.backgroundColor != nil }!
        XCTAssertEqual(String(value[..<highlighted.range.lowerBound].characters), "🙂 Franklin and ")
    }

    func testReviewHighlightDoesNotInventUnknownOrLegacyLinks() {
        let character = ScriptCharacter(id: "franklin", name: "Farmer Franklin", aliases: ["Franklin"])
        let text = "Franklin waits."
        XCTAssertEqual(highlightedWords(CharacterLinkReviewPresentation.highlightedSource(text, characters: [character])), [])
        let missing = CharacterTextLink(characterId: "missing", location: 0, length: 8, text: "Franklin")
        XCTAssertEqual(highlightedWords(CharacterLinkReviewPresentation.highlightedSource(text, links: [missing], characters: [character])), [])
        let unlinked = CharacterTextLink(characterId: nil, location: 0, length: 8, text: "Franklin")
        XCTAssertEqual(highlightedWords(CharacterLinkReviewPresentation.highlightedSource(text, links: [unlinked], characters: [character])), [])
    }

    func testSuggestionsRemainUnconfirmedAndStaleRangesAreNotHighlighted() {
        let character = ScriptCharacter(id: "franklin", name: "Franklin")
        let text = "🙂 Franklin waits."
        let links = CharacterMentions.suggestions(in: text, characters: [character])
        let value = CharacterLinkReviewPresentation.highlightedSource(text, links: links, characters: [character])
        XCTAssertEqual(highlightedWords(value), ["Franklin"])
        XCTAssertTrue(links.allSatisfy { !$0.isConfirmed })
        XCTAssertTrue(CharacterMentions.resolved(in: text, links: links).isEmpty)
        XCTAssertEqual(highlightedWords(CharacterLinkReviewPresentation.highlightedSource("🙂 Someone waits.", links: links, characters: [character])), [])
    }

    private func highlightedWords(_ value: AttributedString) -> [String] {
        value.runs.filter { $0.backgroundColor != nil }.map { String(value[$0.range].characters) }
    }
}
