import UIKit
import XCTest
import ScrivCore
@testable import ScrivUIKit

/// Drives the real workspace through its own controls (transport buttons, the
/// tab control, a script line's tap-to-edit path and native text input), then
/// checks the results through to the saved package. Isolated verification
/// storage only; never a user's project.
@MainActor
final class WorkspaceEndToEndTests: XCTestCase {
    private func views<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        var result: [T] = [], pending = [root]
        while let view = pending.popLast() { if let match = view as? T { result.append(match) }; pending.append(contentsOf: view.subviews) }
        return result
    }
    private func button(labelled label: String, in root: UIView) throws -> UIButton {
        try XCTUnwrap(views(UIButton.self, in: root).first { $0.accessibilityLabel == label && $0.window != nil }, "No visible button \(label)")
    }
    private func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    func testPlaybackTabsAndEditingThroughRealControls() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification storage.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent().deletingLastPathComponent()) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1448, height: 900); window.overrideUserInterfaceStyle = .light
        let workspace = ScrivWorkspaceController(store: store)
        window.rootViewController = workspace; window.makeKeyAndVisible()
        defer { if store.isPlaying { store.togglePlayback() }; window.isHidden = true }
        let ok1 = await until { workspace.view.window != nil && !self.views(ScriptEntryRow.self, in: workspace.view).isEmpty }
        XCTAssertTrue(ok1)

        // Play with the transport button: time advances, the active line and
        // its current word are highlighted, and Pause stops the clock.
        try button(labelled: "Play scene", in: workspace.view).sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(store.isPlaying)
        let ok2 = await until { store.playheadMs > 600 }
        XCTAssertTrue(ok2)
        let activeID = try XCTUnwrap(store.project.activeEntry(at: Int(store.playheadMs), sceneId: store.selectedSceneID)?.id)
        let ok3 = await until { store.selectedEntryID == activeID || store.project.activeEntry(at: Int(store.playheadMs), sceneId: store.selectedSceneID)?.id != activeID }
        XCTAssertTrue(ok3)
        if let word = store.currentWordID, let row = views(ScriptEntryRow.self, in: workspace.view).first(where: { $0.entryID == store.project.entries.first { $0.words.contains { $0.id == word } }?.id }) {
            let ok4 = await until {
                let text = row.display.attributedText ?? NSAttributedString()
                var white = false
                text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, _, stop in if (value as? UIColor) == .white { white = true; stop.pointee = true } }
                return white
            }
            XCTAssertTrue(ok4, "The playing word is highlighted")
        }
        try button(labelled: "Pause scene", in: workspace.view).sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(store.isPlaying)
        let paused = store.playheadMs
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.playheadMs, paused, "Pause stops the clock")

        // Switch tabs with the segmented control.
        let tabs = try XCTUnwrap(views(UISegmentedControl.self, in: workspace.view).first { $0.accessibilityIdentifier == "workspace-tabs" })
        for (index, tab) in WorkspaceTab.allCases.enumerated().reversed() {
            tabs.selectedSegmentIndex = index; tabs.sendActions(for: .valueChanged)
            XCTAssertEqual(store.tab, tab)
            let ok5 = await until { workspace.view.window != nil }
            XCTAssertTrue(ok5); workspace.view.layoutIfNeeded()
        }
        XCTAssertEqual(store.tab, .script)

        // Tap a dialogue line to edit it, type through native text input, finish.
        let entry = try XCTUnwrap(store.sceneEntries.first { $0.kind == .dialogue })
        let row = try XCTUnwrap(views(ScriptEntryRow.self, in: workspace.view).first { $0.entryID == entry.id })
        row.onEdit?(entry.text.utf16.count)
        let ok6 = await until { !row.editor.isHidden && row.editor.isFirstResponder }
        XCTAssertTrue(ok6, "Tapping a line opens its native editor")
        row.editor.selectedRange = NSRange(location: (row.editor.text as NSString).length, length: 0)
        row.editor.insertText(" Indeed")
        XCTAssertTrue(row.editor.text.hasSuffix(" Indeed"))
        row.editor.finishEditing?()
        let ok7 = await until { store.project.entries.first { $0.id == entry.id }?.text == entry.text + " Indeed" }
        XCTAssertTrue(ok7, "Finishing applies the typed text")
        let ok8 = await until { row.editor.isHidden }
        XCTAssertTrue(ok8, "The line returns to display mode")
        XCTAssertTrue(row.display.attributedText.string.hasSuffix(" Indeed"))

        // The edit reaches the saved package and leaves no pending recovery.
        await store.flushPendingSaves()
        let repository = try ProjectRepository(root: package.deletingLastPathComponent())
        let saved = try await repository.load(at: package)
        XCTAssertEqual(saved.entries.first { $0.id == entry.id }?.text, entry.text + " Indeed")
        let journal = try PendingProjectSaveJournal(root: package.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PendingProjectSaves"))
        XCTAssertTrue(try journal.load(package: package).isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testAddUndoRedoCharactersAndStoryboardThroughRealControls() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification storage.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent().deletingLastPathComponent()) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1448, height: 900); window.overrideUserInterfaceStyle = .light
        let workspace = ScrivWorkspaceController(store: store)
        window.rootViewController = workspace; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let ready = await until { !self.views(ScriptEntryRow.self, in: workspace.view).isEmpty }
        XCTAssertTrue(ready)

        // Add a dialogue line from the add bar; it opens ready for typing.
        let before = store.sceneEntries.count
        try button(labelled: "Dialogue", in: workspace.view).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(store.sceneEntries.count, before + 1)
        let addedID = try XCTUnwrap(store.selectedEntryID)
        let opened = await until { self.views(ScriptEntryRow.self, in: workspace.view).first { $0.entryID == addedID }.map { !$0.editor.isHidden && $0.editor.isFirstResponder } ?? false }
        XCTAssertTrue(opened, "A new line opens in its editor")
        let row = try XCTUnwrap(views(ScriptEntryRow.self, in: workspace.view).first { $0.entryID == addedID })
        row.editor.selectedRange = NSRange(location: 0, length: (row.editor.text as NSString).length)
        row.editor.insertText("Hello there")
        row.editor.finishEditing?()
        let typed = await until { store.project.entries.first { $0.id == addedID }?.text == "Hello there" }
        XCTAssertTrue(typed)

        // Undo/redo through the workspace's own key commands (Cmd-Z / Shift-Cmd-Z).
        let commands = try XCTUnwrap(workspace.keyCommands)
        let undo = try XCTUnwrap(commands.first { $0.input == "z" && $0.modifierFlags == .command }?.action)
        let redo = try XCTUnwrap(commands.first { $0.input == "z" && $0.modifierFlags == [.command, .shift] }?.action)
        let idle = await until { !ScrivKeyboardTextContext.state(for: ScrivKeyboardTextContext.firstResponder()).editingText }
        XCTAssertTrue(idle)
        XCTAssertTrue(workspace.canPerformAction(undo, withSender: nil))
        _ = workspace.perform(undo)
        XCTAssertNotEqual(store.project.entries.first { $0.id == addedID }?.text, "Hello there", "Undo reverts the typed text")
        _ = workspace.perform(redo)
        XCTAssertEqual(store.project.entries.first { $0.id == addedID }?.text, "Hello there", "Redo restores it")

        // Characters tab: choosing a character in the ribbon selects it.
        let tabs = try XCTUnwrap(views(UISegmentedControl.self, in: workspace.view).first { $0.accessibilityIdentifier == "workspace-tabs" })
        tabs.selectedSegmentIndex = try XCTUnwrap(WorkspaceTab.allCases.firstIndex(of: .characters)); tabs.sendActions(for: .valueChanged)
        let target = try XCTUnwrap(store.project.characters.last)
        let ribbonReady = await until { self.views(UIButton.self, in: workspace.view).contains { $0.accessibilityLabel == target.name && $0.window != nil } }
        XCTAssertTrue(ribbonReady)
        try button(labelled: target.name, in: workspace.view).sendActions(for: .touchUpInside)
        XCTAssertEqual(store.selectedCharacterID, target.id)

        // Storyboard: clicking a picture card selects that placement.
        tabs.selectedSegmentIndex = try XCTUnwrap(WorkspaceTab.allCases.firstIndex(of: .storyboard)); tabs.sendActions(for: .valueChanged)
        let cue = try XCTUnwrap(store.sceneCues.dropFirst().first)
        let label = cue.label.isEmpty ? "Picture at " + ScrivFormat.time(cue.startMs) : cue.label
        let cardReady = await until { self.views(UIView.self, in: workspace.view).contains { $0.accessibilityLabel == label && $0.window != nil } }
        XCTAssertTrue(cardReady)
        let picture = try XCTUnwrap(views(UIView.self, in: workspace.view).first { $0.accessibilityLabel == label && $0.window != nil })
        let tap = try XCTUnwrap(picture.gestureRecognizers?.first { $0 is UITapGestureRecognizer })
        let card = try XCTUnwrap(sequence(first: picture as UIView, next: { $0.superview }).first { $0.responds(to: Selector(("selectPicture"))) })
        XCTAssertTrue(tap.isEnabled)
        _ = card.perform(Selector(("selectPicture")))
        XCTAssertEqual(store.selectedCueID, cue.id)

        await store.flushPendingSaves()
        XCTAssertNil(store.errorMessage)
    }
}
