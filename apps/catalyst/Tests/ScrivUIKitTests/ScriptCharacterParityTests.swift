import UIKit
import XCTest
import ScrivCore
@testable import ScrivUIKit

/// Native layout verification belongs to the Catalyst test target on a Mac.
/// These are not screenshot substitutes and do not change authored fixture data.
@MainActor
final class ScriptCharacterParityTests: XCTestCase {
    func testCharactersRibbonFirstLoadAndRebuildShareAConstraintHierarchy() {
        // The hosted test scheme must use isolated verification storage and skip
        // session restoration. Never instantiate a real-user store for this test.
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else {
            XCTFail("Run with the ScrivUIKit scheme's --screenshots verification argument.")
            return
        }
        let store = WorkspaceStore()
        let controller = CharactersController(store: store)
        controller.loadViewIfNeeded() // Previously raised NSException on the first ribbon card.
        func cardIDs() -> Set<String> {
            var pending: [UIView] = [controller.view], result = Set<String>()
            while let view = pending.popLast() {
                if let id = view.accessibilityIdentifier, id.hasPrefix("character-ribbon-") { result.insert(id) }
                pending.append(contentsOf: view.subviews)
            }
            return result
        }
        let expected = Set(store.project.characters.map { "character-ribbon-" + $0.id })
        XCTAssertFalse(expected.isEmpty)
        for width in [CGFloat(480), 930, 620] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            XCTAssertEqual(cardIDs(), expected)
        }
        controller.searchBar(UISearchBar(), textDidChange: "no matching synthetic character")
        XCTAssertTrue(cardIDs().isEmpty)
        controller.searchBar(UISearchBar(), textDidChange: "")
        store.selectedCharacterID = store.project.characters.last?.id
        controller.storeDidChange(); controller.view.layoutIfNeeded()
        XCTAssertEqual(cardIDs(), expected)
    }

    func testApprovedDensitiesUseOneSharedZoomFactor() {
        for zoom in [0.7, 1.0, 1.3, 2.0] {
            XCTAssertEqual(ScriptPresentationMetrics.expanded.fontSize(zoom: zoom), CGFloat(22 * zoom), accuracy: 0.001)
            XCTAssertEqual(ScriptPresentationMetrics.compact.fontSize(zoom: zoom), CGFloat(16 * zoom), accuracy: 0.001)
        }
        XCTAssertEqual(ScriptPresentationMetrics.expanded.textInset + 20, 222)
        XCTAssertEqual(ScriptPresentationMetrics.expanded.railX + 20, 136)
        let reference = ScriptPresentationMetrics(isCompact: false, paneWidth: 930)
        XCTAssertEqual(reference.fontSize(zoom: 1), 28.6, accuracy: 0.001)
        XCTAssertEqual(ScriptPresentationMetrics(isCompact: true, paneWidth: 930).fontSize(zoom: 1), 20.8, accuracy: 0.001)
        XCTAssertEqual(ScriptPresentationMetrics(isCompact: false, paneWidth: 2_000).opticalScale, 1.3)
        XCTAssertEqual(ScriptPresentationMetrics(isCompact: false, paneWidth: 480).opticalScale, 1)
        XCTAssertLessThan(ScriptPresentationMetrics.compact.rowSpacing, ScriptPresentationMetrics.expanded.rowSpacing)
    }

    func testChangingDensityPreservesLiveEditorAndExactCaret() {
        let scene = ScriptScene(id: "s", title: "Scene")
        let entry = ScriptEntry(id: "e", sceneId: "s", order: 0, text: "🙂 The exact authored words remain.")
        let project = ScrivProject(scenes: [scene], entries: [entry])
        let row = ScriptEntryRow(entryID: entry.id)
        row.setEditing(true, text: entry.text, focus: false)
        let identity = ObjectIdentifier(row.editor)
        row.editor.selectedRange = NSRange(location: 3, length: 3)
        for metrics in [ScriptPresentationMetrics.expanded, .compact, .expanded] {
            row.configure(entry: entry, project: project, selected: true, active: false, search: "", currentWordID: nil, peers: [], locked: false, speakerMenu: UIMenu(children: []), fontSize: metrics.fontSize(zoom: 1.3), presentation: metrics)
            row.setEditing(true, text: entry.text, focus: false)
            XCTAssertEqual(ObjectIdentifier(row.editor), identity)
            XCTAssertEqual(row.editor.selectedRange, NSRange(location: 3, length: 3))
            XCTAssertTrue(row.editor.text.utf16.elementsEqual(entry.text.utf16))
            XCTAssertEqual(row.editor.font?.pointSize, metrics.fontSize(zoom: 1.3))
            XCTAssertEqual(row.display.font?.pointSize, row.editor.font?.pointSize)
        }
    }

    func testContinuationIsSeparateFromCharacterIdentityChip() {
        let person = ScriptCharacter(id: "randy", name: "Randy", color: "blue")
        let a = ScriptEntry(id: "a", sceneId: "s", order: 0, kind: .dialogue, text: "One.", characterId: person.id, ownedDurationMs: 1_000)
        let b = ScriptEntry(id: "b", sceneId: "s", order: 1, kind: .dialogue, text: "Two.", characterId: person.id, ownedDurationMs: 1_000)
        let project = ScrivProject(scenes: [ScriptScene(id: "s")], entries: [a, b], characters: [person])
        let row = ScriptEntryRow(entryID: b.id)
        row.configure(entry: b, project: project, selected: false, active: false, search: "", currentWordID: nil, peers: [], locked: false, speakerMenu: UIMenu(children: []), fontSize: 22)
        XCTAssertEqual(row.speakerButton.title(for: .normal), "RANDY")
        XCTAssertFalse(row.continuationLabel.isHidden)
        XCTAssertEqual(row.display.attributedText.string, "Two.")
    }

    func testLongScriptStillWrapsAtNarrowWidthsAndLargeZoom() {
        let entry = ScriptEntry(id: "e", sceneId: "s", order: 0, text: String(repeating: "Authored words 🙂 ", count: 24))
        let project = ScrivProject(scenes: [ScriptScene(id: "s")], entries: [entry])
        let row = ScriptEntryRow(entryID: entry.id)
        row.configure(entry: entry, project: project, selected: false, active: false, search: "", currentWordID: nil, peers: [], locked: false, speakerMenu: UIMenu(children: []), fontSize: 44)
        func measuredHeight(width: CGFloat) -> CGFloat {
            row.frame = CGRect(x: 0, y: 0, width: width, height: 2_000)
            row.setNeedsLayout(); row.layoutIfNeeded(); row.display.layoutIfNeeded()
            return row.display.intrinsicContentSize.height
        }
        let narrow = measuredHeight(width: 480), wide = measuredHeight(width: 760)
        XCTAssertGreaterThan(narrow, wide)
        XCTAssertFalse(row.display.isScrollEnabled)
        XCTAssertEqual(row.display.attributedText.string, entry.text)
    }

    func testCompactTagControlsKeepAllNamesAndWrapInsteadOfTruncating() {
        let tags = CharacterChipWrapView(frame: CGRect(x: 0, y: 0, width: 170, height: 200))
        tags.minimumChipHeight = 26
        tags.chips = ["Farmer Franklin", "Miyazaki", "Randy"].map { CharacterTeamUI.button($0, size: 11) {} }
        tags.layoutIfNeeded()
        XCTAssertEqual(tags.chips.count, 3)
        XCTAssertGreaterThan(tags.intrinsicContentSize.height, 26)
        for chip in tags.chips {
            XCTAssertGreaterThanOrEqual(chip.frame.height, 26)
            XCTAssertLessThanOrEqual(chip.frame.maxX, 170)
        }
    }
}
