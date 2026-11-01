import UIKit
import XCTest
import ScrivCore
@testable import ScrivUIKit

/// These exercise real UIKit responders/layout. Syntax-only Linux checks must
/// never be reported as a pass of this Catalyst test target.
@MainActor
final class ScriptUIKitTests: XCTestCase {
    func testNativeEditorUsesConstrainedWidthAndKeepsExactSelection() {
        let editor = ScriptTextView(frame: CGRect(x: 0, y: 0, width: 260, height: 40))
        editor.setScriptStyle(size: 20, direction: false)
        let text = String(repeating: "Long authored dialogue with 😀 and café. ", count: 20)
        editor.text = text; editor.selectedRange = NSRange(location: 8, length: 12)
        let selection = editor.selectedRange
        editor.layoutIfNeeded(); let narrow = editor.intrinsicContentSize.height
        editor.frame.size.width = 700; editor.layoutIfNeeded(); let wide = editor.intrinsicContentSize.height
        XCTAssertGreaterThan(narrow, wide)
        XCTAssertEqual(editor.selectedRange, selection)
        XCTAssertTrue(editor.text.utf16.elementsEqual(text.utf16))
        XCTAssertFalse(editor.isScrollEnabled)
        XCTAssertEqual(editor.textContainer.maximumNumberOfLines, 0)
    }

    func testDelegateJournalsExactUTF16OperationBeforeAllowingUIKitMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try EditorDraftJournal(root: root)
        let scene = ScriptScene(id: "scene", title: "Scene")
        let a = ScriptCharacter(id: "a", name: "Alex"), b = ScriptCharacter(id: "b", name: "Other")
        let entry = ScriptEntry(id: "line", sceneId: scene.id, order: 0, text: "😀 Alex Alex", ownedDurationMs: 3_000, characterLinks: [CharacterTextLink(characterId: a.id, location: 3, length: 4, text: "Alex"), CharacterTextLink(characterId: b.id, location: 8, length: 4, text: "Alex")])
        let project = ScrivProject(id: "project", scenes: [scene], entries: [entry], characters: [a, b])
        let scope = EditorDraftScope(packagePath: "/private/test.scriv", projectID: project.id, cloudProjectID: nil, server: "https://example.invalid", accountID: nil, entryID: entry.id)
        var record = LocalEditorDraft(scope: scope, sourceRevision: 0, sourceEpoch: nil, sourceEntry: entry)
        let row = ScriptEntryRow(entryID: entry.id)
        row.editor.text = entry.text
        row.onTextEdit = { edit in
            guard let range = Range(edit.range, in: record.text) else { return false }
            var next = record; next.replaceText(record.text.replacingCharacters(in: range, with: edit.replacement), edit: edit)
            do { try journal.save(next, replacing: record.revisionID); record = next; return true } catch { return false }
        }
        // No journal exists yet; the first edit still has to reach disk before
        // UITextView receives permission to alter its own string.
        XCTAssertTrue(row.textView(row.editor, shouldChangeTextIn: NSRange(location: 3, length: 5), replacementText: ""))
        XCTAssertEqual(row.editor.text, entry.text)
        XCTAssertEqual(try journal.load(scope)?.text, "😀 Alex")
        XCTAssertEqual(record.edits.last?.native.range, NSRange(location: 3, length: 5))
        let applied = try record.applying(to: project, scope: scope, epoch: nil)
        XCTAssertEqual(applied.entries.first?.characterLinks?.first?.characterId, "b")
        XCTAssertEqual(applied.entries.first?.characterLinks?.first?.location, 3)
    }

    func testRejectedNativeEditCannotMutateTextOrJournal() {
        let row = ScriptEntryRow(entryID: "line"); row.editor.text = "Saved line"
        var observed: CharacterTextEdit?
        row.onTextEdit = { observed = $0; return false }
        XCTAssertFalse(row.textView(row.editor, shouldChangeTextIn: NSRange(location: 0, length: 5), replacementText: "Rejected"))
        XCTAssertEqual(row.editor.text, "Saved line")
        XCTAssertEqual(observed?.range, NSRange(location: 0, length: 5))
        XCTAssertEqual(observed?.replacement, "Rejected")
    }

    func testRowRefreshPreservesNativeEditorIdentityAndCaret() {
        let row = ScriptEntryRow(entryID: "line")
        row.setEditing(true, text: "A longer local draft", focus: false)
        row.editor.selectedRange = NSRange(location: 3, length: 6)
        let identity = ObjectIdentifier(row.editor), selection = row.editor.selectedRange
        row.setEditing(true, text: "A longer local draft", focus: false)
        XCTAssertEqual(ObjectIdentifier(row.editor), identity)
        XCTAssertEqual(row.editor.selectedRange, selection)
    }

    func testConfirmedCharacterLinksUseStableIdentityNotMatchingDisplayName() throws {
        let a = ScriptCharacter(id: "a", name: "Renamed"), b = ScriptCharacter(id: "b", name: "Alex")
        let scene = ScriptScene(id: "scene", title: "Scene")
        let entry = ScriptEntry(id: "e", sceneId: scene.id, order: 0, text: "Alex Alex", characterLinks: [CharacterTextLink(characterId: "a", location: 0, length: 4, text: "Alex"), CharacterTextLink(characterId: "b", location: 5, length: 4, text: "Alex")])
        let project = ScrivProject(id: "p", scenes: [scene], entries: [entry], characters: [a, b])
        let text = ScriptAttributedText.make(entry: entry, project: project, font: .systemFont(ofSize: 20), color: .label, currentWordID: nil, peers: [])
        XCTAssertEqual((text.attribute(.link, at: 1, effectiveRange: nil) as? URL)?.lastPathComponent, "a")
        XCTAssertEqual((text.attribute(.link, at: 6, effectiveRange: nil) as? URL)?.lastPathComponent, "b")
    }

    func testRecoveredComparisonHighlightsWholeEmojiAndLeavesIdenticalCopyUnmarked() throws {
        let current = "Miyazaki 👩🏽‍🚀 says café.", draft = "Miyazaki 👨🏾‍🚀 says café."
        let range = try XCTUnwrap(RecoveredDraftComparison.changedRange(in: draft, comparedTo: current))
        XCTAssertEqual((draft as NSString).substring(with: range), "👨🏾‍🚀")
        XCTAssertNotNil(Range(range, in: draft))
        XCTAssertNil(RecoveredDraftComparison.changedRange(in: draft, comparedTo: draft))
    }

    func testHistoryComparisonShowsActualOwnedDurationRatherThanRawJSON() throws {
        let scene = ScriptScene(id: "s", title: "Scene")
        let entry = ScriptEntry(id: "direction", sceneId: scene.id, order: 0, kind: .direction, text: "Looks between them.", ownedDurationMs: 2_000, coverageDurationMs: 4_000)
        let before = ScrivProject(id: "p", scenes: [scene], entries: [entry])
        var after = before; after.entries[0].ownedDurationMs = 2_400
        let change = try XCTUnwrap(HistoryPresentation.localChanges(before: before, after: after).first { $0.id == entry.id })
        let fields = HistoryPresentation.fields(for: change, beforeProject: before, afterProject: after)
        XCTAssertEqual(fields.first { $0.label == "Owned time" }?.before, "2.0 s")
        XCTAssertEqual(fields.first { $0.label == "Owned time" }?.after, "2.4 s")
    }
    func testReturnInvokesBoundaryOperationWithoutInsertingOrDeletingSelectedText() {
        let row = ScriptEntryRow(entryID: "line"); row.editor.text = "One two"
        var split: Int?, textEdits = 0
        row.onSplit = { split = $0 }; row.onTextEdit = { _ in textEdits += 1; return true }
        XCTAssertFalse(row.textView(row.editor, shouldChangeTextIn: NSRange(location: 4, length: 3), replacementText: "\n"))
        XCTAssertEqual(split, 4); XCTAssertEqual(textEdits, 0); XCTAssertEqual(row.editor.text, "One two")
    }
    func testBackspaceAtZeroRequestsMergeButSelectionAndCompositionRemainNative() {
        let editor = ScriptTextView()
        // Exercise the real script configuration, not UIKit's default smart
        // deletion (which is allowed to remove an adjacent space as well).
        editor.setScriptStyle(size: 20, direction: false)
        editor.text = "One two"; editor.isEditable = true
        XCTAssertEqual(editor.smartInsertDeleteType, .no)
        var merged = 0; editor.mergeAtStart = { merged += 1 }
        editor.selectedRange = NSRange(location: 0, length: 0); editor.deleteBackward()
        XCTAssertEqual(merged, 1); XCTAssertEqual(editor.text, "One two")
        editor.selectedRange = NSRange(location: 0, length: 3)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 3))
        editor.deleteBackward()
        XCTAssertEqual(merged, 1); XCTAssertEqual(editor.text, " two")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))
    }
    func testConfiguredScriptDeletionPreservesExactUnicodeAndAdjacentSpaces() {
        let editor = ScriptTextView(); editor.setScriptStyle(size: 20, direction: false)
        editor.text = "😀 One two"; editor.isEditable = true
        var merged = 0; editor.mergeAtStart = { merged += 1 }
        editor.selectedRange = NSRange(location: 3, length: 3)
        editor.deleteBackward()
        XCTAssertEqual(merged, 0)
        XCTAssertTrue(editor.text.utf16.elementsEqual("😀  two".utf16))
        XCTAssertEqual(editor.selectedRange, NSRange(location: 3, length: 0))
    }
    func testSharedFontAppliesToDisplayAndNativeEditorWithoutReplacingEither() {
        let entry = ScriptEntry(id: "e", sceneId: "s", order: 0, text: "One two")
        let project = ScrivProject(scenes: [ScriptScene(id: "s")], entries: [entry]), row = ScriptEntryRow(entryID: "e")
        let identity = ObjectIdentifier(row.editor)
        for size: CGFloat in [14, 21] {
            row.configure(entry: entry, project: project, selected: true, active: false, search: "", currentWordID: nil, peers: [], locked: false, speakerMenu: UIMenu(children: []), fontSize: size)
            XCTAssertEqual(row.display.font?.pointSize, size); XCTAssertEqual(row.editor.font?.pointSize, size)
            XCTAssertEqual(ObjectIdentifier(row.editor), identity)
        }
    }
    func testDurationScrubPreviewsAndCommitsOnlyOnceWithExactContext() {
        let entry = ScriptEntry(id: "e", sceneId: "s", order: 0, text: "One two", ownedDurationMs: 2200)
        var draft = ScriptDurationScrubDraft(entry: entry, navigation: 7)
        draft.update(translationY: -15); XCTAssertEqual(draft.proposedMilliseconds, 2500); XCTAssertEqual(entry.ownedDurationMs, 2200)
        XCTAssertEqual(draft.finish(entry: entry, navigation: 7, sceneID: "s"), 2500)
        XCTAssertNil(draft.finish(entry: entry, navigation: 7, sceneID: "s"))
        var stale = ScriptDurationScrubDraft(entry: entry, navigation: 7); stale.update(translationY: 20)
        XCTAssertNil(stale.finish(entry: entry, navigation: 8, sceneID: "s"))
        var cancelled = ScriptDurationScrubDraft(entry: entry, navigation: 7); cancelled.update(translationY: -10); cancelled.cancel()
        XCTAssertNil(cancelled.finish(entry: entry, navigation: 7, sceneID: "s"))
    }
    func testOwnedDurationPillKeepsNumericClickAndExactTextSelection() {
        let entry = ScriptEntry(id: "e", sceneId: "s", order: 0, text: "🙂 One two", ownedDurationMs: 2200)
        let project = ScrivProject(scenes: [ScriptScene(id: "s")], entries: [entry])
        let row = ScriptEntryRow(entryID: entry.id)
        row.configure(entry: entry, project: project, selected: true, active: false, search: "", currentWordID: nil, peers: [], locked: false, speakerMenu: UIMenu(children: []), fontSize: 22)
        row.setEditing(true, text: entry.text, focus: false)
        row.editor.selectedRange = NSRange(location: 3, length: 3)
        row.display.selectedRange = NSRange(location: 7, length: 3)
        let editor = ObjectIdentifier(row.editor), display = ObjectIdentifier(row.display)
        var numericEdits = 0, textEdits = 0
        row.onDuration = { numericEdits += 1 }; row.onEdit = { _ in textEdits += 1 }
        XCTAssertEqual(row.durationButton.buttonType, .custom, "The scrubber must retain UIKit event tracking, including when Catalyst adopts Mac control behavior")
        XCTAssertEqual(row.durationButton.accessibilityLabel, "Edit owned duration")
        for _ in 0..<2 { row.durationButton.sendActions(for: .touchUpInside) }
        XCTAssertEqual(numericEdits, 2); XCTAssertEqual(textEdits, 0)
        XCTAssertEqual(ObjectIdentifier(row.editor), editor); XCTAssertEqual(ObjectIdentifier(row.display), display)
        XCTAssertEqual(row.editor.selectedRange, NSRange(location: 3, length: 3))
        XCTAssertEqual(row.display.selectedRange, NSRange(location: 7, length: 3))
        XCTAssertTrue(row.editor.text.utf16.elementsEqual(entry.text.utf16))
        XCTAssertEqual(row.durationButton.title(for: .normal), ScrivFormat.duration(2200))
        row.configure(entry: entry, project: project, selected: true, active: false, search: "", currentWordID: nil, peers: [], locked: true, speakerMenu: UIMenu(children: []), fontSize: 22)
        XCTAssertFalse(row.durationButton.isEnabled, "A remote editing lease must still disable the pill")
    }
    func testInstalledOwnedDurationGestureIsLocalToPillAndAcceptsTouchAndPointer() throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else {
            XCTFail("Run with the isolated ScrivUIKit --screenshots verification argument."); return
        }
        // Inspect the installed controller, not a hand-wired recognizer.
        let controller = ScriptScreenController(store: WorkspaceStore())
        controller.loadViewIfNeeded()
        var pending = [controller.view!], rows: [ScriptEntryRow] = []
        while let view = pending.popLast() {
            if let row = view as? ScriptEntryRow { rows.append(row) }
            pending.append(contentsOf: view.subviews)
        }
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let holds = (row.durationButton.gestureRecognizers ?? []).compactMap { $0 as? UILongPressGestureRecognizer }
            XCTAssertEqual(holds.count, 1)
            let hold = try XCTUnwrap(holds.first)
            XCTAssertTrue(hold.view === row.durationButton); XCTAssertTrue(hold.isEnabled)
            XCTAssertEqual(row.durationButton.buttonType, .custom)
            XCTAssertEqual(hold.minimumPressDuration, 0.18, accuracy: 0.001)
            XCTAssertEqual(hold.allowableMovement, 20, accuracy: 0.001)
            XCTAssertEqual(hold.numberOfTouchesRequired, 1)
            XCTAssertTrue(hold.cancelsTouchesInView, "A recognized drag must not also dispatch the precise-editor click")
            for type in [UITouch.TouchType.direct, .indirectPointer] {
                XCTAssertTrue(hold.allowedTouchTypes.contains(NSNumber(value: type.rawValue)), "Both touch and pointer presses must reach the same scrubber")
            }
            XCTAssertFalse((row.editor.gestureRecognizers ?? []).contains { $0 === hold })
            XCTAssertFalse((row.display.gestureRecognizers ?? []).contains { $0 === hold })
            XCTAssertTrue(row.durationButton.accessibilityHint?.contains("Hold and drag up") == true)
        }
        // This records the real runtime idiom without assuming Mac-style
        // controls from the target's device-family setting. It is not synthetic
        // mouse-event proof; actual press/drag/release remains an acceptance gate.
        if let row = rows.first {
            #if targetEnvironment(macCatalyst)
            print("Duration input diagnostics: idiom=\(row.traitCollection.userInterfaceIdiom.rawValue), customBehavior=\(row.durationButton.behavioralStyle.rawValue), systemBehavior=\(UIButton(type: .system).behavioralStyle.rawValue)")
            #endif
        }
    }
    func testDurationScrubProtectsZeroBoundsAndRejectsChangedSourceOrScene() {
        let direction = ScriptEntry(id: "d", sceneId: "s", order: 0, kind: .direction, text: "Wait", ownedDurationMs: 0)
        var zero = ScriptDurationScrubDraft(entry: direction, navigation: 1)
        zero.update(translationY: 50); XCTAssertEqual(zero.proposedMilliseconds, 0)
        zero.update(translationY: -50); XCTAssertEqual(zero.proposedMilliseconds, 1000)
        XCTAssertEqual(zero.finish(entry: direction, navigation: 1, sceneID: "s"), 1000)
        let words = [TimedWord(text: "One", startMs: 0, endMs: 500), TimedWord(text: "two", startMs: 500, endMs: 1000)]
        let dialogue = ScriptEntry(id: "e", sceneId: "s", order: 1, text: "One two", ownedDurationMs: 1000, words: words)
        var bounded = ScriptDurationScrubDraft(entry: dialogue, navigation: 1)
        bounded.update(translationY: -0.125); XCTAssertEqual(bounded.proposedMilliseconds, 1003, "Preserve integer-millisecond rounding, not the displayed tenth-second quantum")
        bounded.update(translationY: 1_000_000); XCTAssertEqual(bounded.proposedMilliseconds, words.count)
        bounded.update(translationY: -1_000_000); XCTAssertEqual(bounded.proposedMilliseconds, 3_600_000)
        bounded.update(translationY: .nan); XCTAssertEqual(bounded.proposedMilliseconds, 3_600_000)
        var changed = dialogue; changed.ownedDurationMs = 1200
        XCTAssertNil(bounded.finish(entry: changed, navigation: 1, sceneID: "s"))
        var moved = ScriptDurationScrubDraft(entry: dialogue, navigation: 1); moved.update(translationY: -50)
        XCTAssertNil(moved.finish(entry: dialogue, navigation: 1, sceneID: "other"))
        var removed = ScriptDurationScrubDraft(entry: dialogue, navigation: 1); removed.update(translationY: -50)
        XCTAssertNil(removed.finish(entry: nil, navigation: 1, sceneID: "s"))
        var unicodeSource = dialogue; unicodeSource.text = "caf\u{00E9}"
        var canonicalEqual = unicodeSource; canonicalEqual.text = "cafe\u{0301}"
        XCTAssertEqual(unicodeSource.text, canonicalEqual.text)
        XCTAssertFalse(unicodeSource.text.utf16.elementsEqual(canonicalEqual.text.utf16))
        var unicodeDraft = ScriptDurationScrubDraft(entry: unicodeSource, navigation: 1); unicodeDraft.update(translationY: -50)
        XCTAssertNil(unicodeDraft.finish(entry: canonicalEqual, navigation: 1, sceneID: "s"), "Canonically equal text still cannot bypass the exact-source fence")
        XCTAssertEqual(direction.ownedDurationMs, 0); XCTAssertEqual(dialogue.ownedDurationMs, 1000)
    }
    func testDiscussionAttachmentNeverSubstitutesDifferentImageVersion() {
        let a = ImageAsset(id: "a", fileName: "a.png", sha256: String(repeating: "a", count: 64), byteCount: 10)
        let b = ImageAsset(id: "b", version: 2, fileName: "b.png", sha256: String(repeating: "b", count: 64), byteCount: 10, previousVersionId: "a")
        let project = ScrivProject(images: [a, b])
        XCTAssertEqual(UIKitDiscussionPresentation.attachmentImage(.object(["itemId": .string("a"), "imageVersionId": .string("b")]), project: project)?.id, "b")
        XCTAssertNil(UIKitDiscussionPresentation.attachmentImage(.object(["itemId": .string("a"), "imageVersionId": .string("missing")]), project: project))
    }

}
