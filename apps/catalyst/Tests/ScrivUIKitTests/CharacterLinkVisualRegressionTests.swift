import UIKit
import XCTest
import ScrivCore
@testable import ScrivUIKit

/// Native UIKit assertions, not screenshot evidence. Run in the isolated
/// Catalyst test host; no user store, files, accounts or network are accessed.
@MainActor
final class CharacterLinkVisualRegressionTests: XCTestCase {
    func testCompactMissingPortraitHasNoClippedTextAndKeepsAccessibleStatus() {
        let view = CharacterTeamUI.compactMissingPortrait()
        view.frame = CGRect(x: 0, y: 0, width: 56, height: 58)
        view.layoutIfNeeded()
        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertTrue(view.accessibilityTraits.contains(.image))
        XCTAssertEqual(view.accessibilityValue, "No portrait on this device")
        XCTAssertTrue(view.interactions.contains { $0 is UIToolTipInteraction })
        XCTAssertFalse(view.subviews.contains { $0 is UILabel })
        XCTAssertEqual(view.subviews.count, 1)
        guard let icon = view.subviews.first as? UIImageView else { return XCTFail("Expected a portrait icon") }
        XCTAssertEqual(icon.frame.size, CGSize(width: 26, height: 26))
        XCTAssertTrue(view.bounds.contains(icon.frame))
        XCTAssertEqual(icon.center.x, view.bounds.midX, accuracy: 0.01)
        XCTAssertEqual(icon.center.y, view.bounds.midY, accuracy: 0.01)
    }

    func testPlaybackWordRetainsWhiteForegroundAndBothCharacterIdentities() throws {
        let (entry, project) = fixture()
        let row = ScriptEntryRow(entryID: entry.id)
        for active in [String?.none, entry.words[1].id, entry.words[3].id, nil] {
            configure(row, entry: entry, project: project, word: active)
            XCTAssertNil(row.display.linkTextAttributes[.foregroundColor], "Link-wide colors must not hide the active word")
            XCTAssertNil(row.display.linkTextAttributes[.backgroundColor])
            XCTAssertTrue(row.display.isSelectable)
            XCTAssertFalse(row.display.isEditable)
            XCTAssertTrue(row.display.attributedText.string.utf16.elementsEqual(entry.text.utf16))
            for (offset, id, word) in [(3, "farmer-a", entry.words[1].id), (16, "farmer-b", entry.words[3].id)] {
                let value = row.display.attributedText!
                XCTAssertEqual((value.attribute(.link, at: offset, effectiveRange: nil) as? URL)?.lastPathComponent, id)
                let foreground = try XCTUnwrap(value.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor)
                XCTAssertEqual(foreground, word == active ? UIColor.white : ScrivUIKitTheme.accent)
                if word == active {
                    XCTAssertEqual(value.attribute(.backgroundColor, at: offset, effectiveRange: nil) as? UIColor, ScrivUIKitTheme.accent)
                }
            }
        }
        XCTAssertEqual(entry.characterLinks?.map(\.characterId), ["farmer-a", "farmer-b"])
    }

    func testPlaybackRefreshDoesNotReplaceLiveEditorOrSelection() {
        let (entry, project) = fixture()
        let row = ScriptEntryRow(entryID: entry.id)
        configure(row, entry: entry, project: project, word: nil)
        row.setEditing(true, text: entry.text, focus: false)
        let editor = row.editor
        let selection = NSRange(location: 3, length: 8)
        row.editor.selectedRange = selection
        for active in [String?.none, entry.words[1].id, entry.words[3].id, nil] {
            configure(row, entry: entry, project: project, word: active)
            row.setEditing(true, text: entry.text, focus: false)
            XCTAssertTrue(row.editor === editor)
            XCTAssertEqual(row.editor.selectedRange, selection)
            XCTAssertTrue(row.editor.text.utf16.elementsEqual(entry.text.utf16))
        }
    }

    func testReviewHighlightKeepsExactSourceAndReadableText() throws {
        let (entry, project) = fixture()
        let value = UIKitCharacterLinkPresentation.highlighted(entry.text, links: entry.characterLinks ?? [], characters: project.characters)
        XCTAssertTrue(value.string.utf16.elementsEqual(entry.text.utf16))
        for offset in [3, 16] {
            let foreground = try XCTUnwrap(value.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor)
            XCTAssertEqual(foreground, ScrivUIKitTheme.ink)
            var alpha: CGFloat = 0
            let background = try XCTUnwrap(value.attribute(.backgroundColor, at: offset, effectiveRange: nil) as? UIColor)
            background.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            XCTAssertLessThan(alpha, 0.3)
        }
    }

    private func configure(_ row: ScriptEntryRow, entry: ScriptEntry, project: ScrivProject, word: String?) {
        row.configure(entry: entry, project: project, selected: true, active: word != nil, search: "", currentWordID: word, peers: [], locked: false, speakerMenu: UIMenu(children: []), fontSize: 22)
    }
    private func fixture() -> (ScriptEntry, ScrivProject) {
        let text = "🙂 Franklin and Franklin."
        let words = ["🙂", "Franklin", "and", "Franklin."].enumerated().map {
            TimedWord(text: $0.element, startMs: $0.offset * 500, endMs: ($0.offset + 1) * 500)
        }
        let people = [ScriptCharacter(id: "farmer-a", name: "Renamed character", color: "blue"), ScriptCharacter(id: "farmer-b", name: "Other character", color: "orange")]
        let links = [CharacterTextLink(characterId: "farmer-a", location: 3, length: 8, text: "Franklin"), CharacterTextLink(characterId: "farmer-b", location: 16, length: 8, text: "Franklin")]
        let entry = ScriptEntry(id: "line", sceneId: "scene", order: 0, text: text, ownedDurationMs: 2000, words: words, characterLinks: links)
        return (entry, ScrivProject(scenes: [ScriptScene(id: "scene")], entries: [entry], characters: people))
    }
}
