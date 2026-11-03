import UIKit
import AVFoundation
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

    /// Presents real sheets from the workspace the way the app does and operates
    /// their controls, then checks the store and saved package.
    func testSheetsAreOperableThroughTheirControls() async throws {
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
        defer { if workspace.presentedViewController != nil { workspace.dismiss(animated: false) }; window.isHidden = true }
        let attached = await until { workspace.view.window != nil }
        XCTAssertTrue(attached)
        func present(_ route: ScrivUIKitRoute) async throws -> UIViewController {
            ScrivUIKitRouter.shared.present(route, from: workspace, store: store)
            let shown = await until { workspace.presentedViewController?.viewIfLoaded?.window != nil && workspace.presentedViewController?.isBeingPresented == false }
            XCTAssertTrue(shown, "\(route) sheet appears")
            return try XCTUnwrap(workspace.presentedViewController)
        }
        func dismiss() async {
            workspace.dismiss(animated: false)
            _ = await until { workspace.presentedViewController == nil }
        }

        // Settings: the follow-playback switch drives the store.
        let settings = try await present(.settings)
        let follow = try XCTUnwrap(views(UISwitch.self, in: settings.view).first { $0.window != nil })
        let wasFollowing = store.followPlayback
        follow.setOn(!wasFollowing, animated: false); follow.sendActions(for: .valueChanged)
        XCTAssertEqual(store.followPlayback, !wasFollowing)
        await dismiss()

        // Character editor: type a name and save a new character.
        let editor = try await present(.characterEditor(characterID: nil))
        let field = try XCTUnwrap(views(UITextField.self, in: editor.view).first { $0.placeholder == "Name" })
        field.text = "Zelda Quinn"; field.sendActions(for: .editingChanged)
        // Picking colours never moves the swatches under the pointer.
        func swatches() -> [String] { editor.view.layoutIfNeeded(); return views(UIButton.self, in: editor.view).filter { $0.window != nil && ($0.accessibilityLabel ?? "").hasSuffix("character colour") }.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }.compactMap(\.accessibilityLabel) }
        let opening = swatches()
        XCTAssertGreaterThanOrEqual(opening.count, 8)
        try button(labelled: "Purple character colour", in: editor.view).sendActions(for: .touchUpInside)
        XCTAssertEqual(swatches(), opening, "The swatches stay in place after a pick")
        try button(labelled: "Pink character colour", in: editor.view).sendActions(for: .touchUpInside)
        XCTAssertEqual(swatches(), opening)
        let save = try button(labelled: "Save character", in: editor.view)
        let enabled = await until { save.isEnabled }
        XCTAssertTrue(enabled, "Save enables once a name is typed")
        save.sendActions(for: .primaryActionTriggered)
        let created = await until { store.project.characters.contains { $0.name == "Zelda Quinn" } }
        XCTAssertTrue(created, "Saving adds the character")
        XCTAssertEqual(store.project.characters.first { $0.name == "Zelda Quinn" }?.color, "F272AC", "The last picked colour is saved")
        _ = await until { workspace.presentedViewController == nil }
        if workspace.presentedViewController != nil { await dismiss() }

        // Word timing: edit the selected word's end time and save.
        let entry = try XCTUnwrap(store.sceneEntries.first { $0.kind == .dialogue && $0.words.count > 1 })
        let first = entry.words[0]
        let timing = try await present(.wordTiming(entryID: entry.id, wordIDs: [first.id]))
        let saveTiming = try XCTUnwrap(views(UIButton.self, in: timing.view).first { $0.accessibilityIdentifier == "word-timing-save" })
        let fields = views(UITextField.self, in: timing.view).filter { $0.window != nil }.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        XCTAssertEqual(fields.count, 2, "Start and end fields")
        let newEnd = max(first.startMs + 50, first.endMs - 100)
        fields[1].text = String(format: "%.3f", Double(newEnd) / 1000); fields[1].sendActions(for: .editingChanged)
        let ready = await until { saveTiming.isEnabled }
        XCTAssertTrue(ready, "Save timing enables after an edit once the line is leased")
        saveTiming.sendActions(for: .primaryActionTriggered)
        let retimed = await until { store.project.entries.first { $0.id == entry.id }?.words.first?.endMs == newEnd }
        XCTAssertTrue(retimed, "Saving applies the new word end time")
        if workspace.presentedViewController != nil { await dismiss() }

        await store.flushPendingSaves()
        let repository = try ProjectRepository(root: package.deletingLastPathComponent())
        let saved = try await repository.load(at: package)
        XCTAssertTrue(saved.characters.contains { $0.name == "Zelda Quinn" })
        XCTAssertEqual(saved.entries.first { $0.id == entry.id }?.words.first?.endMs, newEnd)
        XCTAssertNil(store.errorMessage)
    }

    /// History restore, the projects browser and teams, through their controls.
    func testHistoryRestoreProjectsAndTeamsThroughTheirControls() async throws {
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
        defer { if workspace.presentedViewController != nil { workspace.dismiss(animated: false) }; window.isHidden = true }
        let attached = await until { workspace.view.window != nil }
        XCTAssertTrue(attached)
        func topmost() -> UIViewController? { var top = workspace.presentedViewController; while let next = top?.presentedViewController { top = next }; return top }
        func present(_ route: ScrivUIKitRoute) async throws -> UIViewController {
            ScrivUIKitRouter.shared.present(route, from: workspace, store: store)
            let shown = await until { workspace.presentedViewController?.viewIfLoaded?.window != nil && workspace.presentedViewController?.isBeingPresented == false }
            XCTAssertTrue(shown, "\(route) sheet appears")
            return try XCTUnwrap(workspace.presentedViewController)
        }
        func dismissAll() async { workspace.dismiss(animated: false); _ = await until { workspace.presentedViewController == nil } }
        func controller<T: UIViewController>(_ type: T.Type, in root: UIViewController) -> T? {
            var pending = [root]
            while let next = pending.popLast() { if let match = next as? T { return match }; pending.append(contentsOf: next.children) }
            return nil
        }

        // History: two titled revisions, restore the first through the sheet.
        store.setProjectTitle("Revision A"); store.setProjectTitle("Revision B")
        await store.flushPendingSaves()
        let sheet = try await present(.history)
        let history = try XCTUnwrap(controller(HistoryController.self, in: sheet))
        let table = try XCTUnwrap(views(UITableView.self, in: history.view).first)
        let rows = table.numberOfRows(inSection: 0)
        XCTAssertGreaterThanOrEqual(rows, 3, "Working copy plus saved revisions")
        let targetRow = try XCTUnwrap((0..<rows).first { row in
            (table.cellForRow(at: IndexPath(row: row, section: 0)) ?? table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: row, section: 0))).map { cell in
                views(UILabel.self, in: cell.contentView).contains { $0.text?.contains("Revision \(store.project.revision - 1)") == true }
            } ?? false
        }, "Row for the previous revision")
        table.selectRow(at: IndexPath(row: targetRow, section: 0), animated: false, scrollPosition: .none)
        history.tableView(table, didSelectRowAt: IndexPath(row: targetRow, section: 0))
        let restore = try button(labelled: "Restore revision…", in: history.view)
        let previewed = await until { restore.isEnabled }
        XCTAssertTrue(previewed, "Restore enables once the revision preview loads")
        restore.sendActions(for: .primaryActionTriggered)
        let asked = await until { topmost() is UIAlertController }
        XCTAssertTrue(asked, "Restoring asks for confirmation")
        let alert = try XCTUnwrap(topmost() as? UIAlertController)
        let confirm = try XCTUnwrap(alert.actions.first { $0.title == "Restore as a new revision" })
        typealias AlertHandler = @convention(block) (UIAlertAction) -> Void
        let handler = unsafeBitCast(try XCTUnwrap(confirm.value(forKey: "handler") as AnyObject?), to: AlertHandler.self)
        let revisionBefore = store.project.revision
        alert.dismiss(animated: false); handler(confirm)
        let restored = await until { store.project.title == "Revision A" }
        XCTAssertTrue(restored, "The previous revision's content is restored")
        XCTAssertEqual(store.project.revision, revisionBefore + 1, "Restoring creates a new revision")
        await dismissAll()

        // Projects browser: New project replaces the open project.
        let oldID = store.project.id
        let projects = try await present(.projects)
        try button(labelled: "New project", in: projects.view).sendActions(for: .primaryActionTriggered)
        let created = await until { store.project.id != oldID }
        XCTAssertTrue(created, "New project opens a fresh project")
        await dismissAll()

        // Teams (signed out): Sign in leads to the sign-in sheet.
        let teams = try await present(.teams)
        try button(labelled: "Sign in to Scriv", in: teams.view).sendActions(for: .primaryActionTriggered)
        let signIn = await until { topmost().flatMap { controller(ScrivSignInController.self, in: $0) } != nil }
        XCTAssertTrue(signIn, "Signing in from Teams opens the sign-in sheet")
        await dismissAll()
        await store.flushPendingSaves()
        XCTAssertNil(store.errorMessage)
    }

    /// Rows shift when an editor above a direction opens and closes; the
    /// direction's rail must follow its line without any later refresh.
    func testDirectionRailFollowsItsLineWhenRowsAboveResize() async throws {
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
        let entries = store.sceneEntries
        let directionIndex = try XCTUnwrap(entries.indices.first { $0 > 0 && entries[$0].kind == .direction })
        let direction = entries[directionIndex]
        let above = try XCTUnwrap(entries[..<directionIndex].last { $0.kind == .dialogue })
        let rails = try XCTUnwrap(views(ScriptDirectionRails.self, in: workspace.view).first)
        func offset() throws -> CGFloat {
            let row = try XCTUnwrap(views(ScriptEntryRow.self, in: workspace.view).first { $0.entryID == direction.id })
            let handle = try XCTUnwrap(rails.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "Select direction: " + direction.text })
            return handle.convert(handle.bounds, to: rails).midY - row.convert(row.bounds, to: rails).minY
        }
        try await Task.sleep(for: .milliseconds(300)); workspace.view.layoutIfNeeded()
        let baseline = try offset()
        XCTAssertLessThan(abs(baseline), 60, "The rail starts at its own line")
        let row = try XCTUnwrap(views(ScriptEntryRow.self, in: workspace.view).first { $0.entryID == above.id })
        row.onEdit?(0)
        let opened = await until { !row.editor.isHidden }
        XCTAssertTrue(opened)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try offset(), baseline, accuracy: 0.5, "Rail follows its line while the editor above is open")
        row.editor.finishEditing?()
        let closed = await until { row.editor.isHidden }
        XCTAssertTrue(closed)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try offset(), baseline, accuracy: 0.5, "Rail follows its line after the editor above closes")
    }

    /// Storyboard: select a word through its button, then move the cut with the
    /// word's own menu action; and import real audio through the picker's path.
    func testStoryboardWordCutMoveAndAudioImport() async throws {
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
        defer { if workspace.presentedViewController != nil { workspace.dismiss(animated: false) }; window.isHidden = true }
        store.tab = .storyboard
        let shown = await until { self.views(UIView.self, in: workspace.view).contains { $0.accessibilityIdentifier == "storyboard-shared-script" && $0.window != nil } }
        XCTAssertTrue(shown)
        let words = TimingEngine.absoluteWords(store.project, sceneId: store.selectedSceneID)
        var wordButton: [String: UIButton] = [:]
        for button in views(UIButton.self, in: workspace.view) {
            if let id = button.accessibilityIdentifier, id.hasPrefix("storyboard-word-") { XCTAssertNil(wordButton[id], "One control per word"); wordButton[id] = button }
        }
        XCTAssertEqual(Set(wordButton.keys), Set(words.map { "storyboard-word-" + $0.id }), "Every timed word has its control under its picture row")

        // Pick the first word of a picture that directly follows another one.
        let cues = store.sceneCues
        let pair = try XCTUnwrap(cues.indices.dropFirst().first { index in
            cues[index - 1].endMs == cues[index].startMs && words.contains { $0.startMs >= cues[index].startMs && $0.startMs < cues[index].endMs }
        })
        let previous = cues[pair - 1], current = cues[pair]
        let wordIndex = try XCTUnwrap(words.firstIndex { $0.startMs >= current.startMs && $0.startMs < current.endMs })
        let button = try XCTUnwrap(wordButton["storyboard-word-" + words[wordIndex].id])
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(store.selectedWordIDs, [words[wordIndex].id], "Clicking a word selects it")
        XCTAssertEqual(store.selectedCueID, current.id, "and its picture")
        XCTAssertNil(button.menu, "Word pills are dragged; their menu opens on right-click only")
        let menuReady = await until { ScrivSecondaryMenu.menu(of: button)?.children.contains { ($0 as? UIAction)?.title == "Move to previous image" } == true }
        XCTAssertTrue(menuReady, "The word offers moving the cut to the previous image")
        let move = try XCTUnwrap(ScrivSecondaryMenu.menu(of: button)?.children.compactMap { $0 as? UIAction }.first { $0.title == "Move to previous image" })
        typealias ActionHandler = @convention(block) (UIAction) -> Void
        unsafeBitCast(try XCTUnwrap(move.value(forKey: "handler") as AnyObject?), to: ActionHandler.self)(move)
        let moved = await until { store.sceneCues.first { $0.id == previous.id }?.endMs ?? 0 > previous.endMs }
        XCTAssertTrue(moved, "The cut moves so the word belongs to the previous picture")
        XCTAssertEqual(store.sceneCues.first { $0.id == previous.id }?.endMs, store.sceneCues.first { $0.id == current.id }?.startMs, "Pictures stay contiguous")

        // Deselect is only offered while words are selected.
        let deselect = try XCTUnwrap(views(UIButton.self, in: workspace.view).first { $0.accessibilityIdentifier == "storyboard-deselect" })
        button.sendActions(for: .touchUpInside)
        let enabled = await until { deselect.isEnabled }
        XCTAssertTrue(enabled, "Deselect is offered once a word is selected")
        deselect.sendActions(for: .touchUpInside)
        XCTAssertTrue(store.selectedWordIDs.isEmpty)
        let disabled = await until { !deselect.isEnabled }
        XCTAssertTrue(disabled, "Deselect does nothing with no words selected, so it is disabled")

        // Current moment focuses the picture under the playhead even when it is on screen.
        let first = try XCTUnwrap(store.sceneCues.first)
        XCTAssertNotEqual(store.selectedCueID, first.id)
        store.seek(toMs: Double(first.startMs) + 1)
        let currentMoment = try XCTUnwrap(views(UIButton.self, in: workspace.view).first { $0.configuration?.title == "Current moment" })
        currentMoment.sendActions(for: .touchUpInside)
        XCTAssertEqual(store.selectedCueID, first.id, "Current moment selects the picture under the playhead")

        // Audio: a real file through the same entry point the file picker uses.
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("scriv-e2e-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / 44_100) }
        try AVAudioFile(forWriting: audioURL, settings: format.settings).write(from: buffer)
        let dialogue = try XCTUnwrap(store.sceneEntries.first { $0.kind == .dialogue })
        let clipsBefore = store.project.audioClips.count
        let imported = await store.importAudio(from: audioURL, entryId: dialogue.id)
        XCTAssertTrue(imported, store.errorMessage ?? store.audioStatus)
        XCTAssertEqual(store.project.audioClips.count, clipsBefore + 1)
        let clip = try XCTUnwrap(store.project.audioClips.last)
        XCTAssertEqual(clip.entryId, dialogue.id)
        let asset = try XCTUnwrap(store.project.audioAssets.first { $0.id == clip.assetId })
        XCTAssertNotNil(store.audioURL(asset), "The audio is copied into the project package")
        XCTAssertEqual(Double(asset.durationMs), 1000, accuracy: 50)
        ScrivUIKitRouter.shared.present(.audio, from: workspace, store: store)
        let library = await until { workspace.presentedViewController?.viewIfLoaded?.window != nil }
        XCTAssertTrue(library)
        await store.flushPendingSaves()
        let repository = try ProjectRepository(root: package.deletingLastPathComponent())
        let saved = try await repository.load(at: package)
        XCTAssertEqual(saved.audioClips.count, clipsBefore + 1)
        XCTAssertEqual(saved.cues.first { $0.id == previous.id }?.endMs, store.sceneCues.first { $0.id == previous.id }?.endMs)
        XCTAssertNil(store.errorMessage)
    }

    /// Extending a direction's coverage while its text is open for editing, then
    /// finishing without typing, is not a draft conflict.
    func testOwnCoverageDragWhileEditingDoesNotConflict() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification storage.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent().deletingLastPathComponent()) }
        let direction = try XCTUnwrap(store.sceneEntries.first { $0.kind == .direction })
        let session = ScriptDraftSession(store: store)
        session.begin(direction.id)
        let opened = await until { session.entryID == direction.id }
        XCTAssertTrue(opened, "The direction opens for editing")
        let end = store.project.startMs(of: direction.id) + direction.coverageDurationMs + 2_000
        store.setCoverage(direction.id, endMs: end)
        let extended = await until { store.project.entries.first { $0.id == direction.id }?.coverageDurationMs == direction.coverageDurationMs + 2_000 }
        XCTAssertTrue(extended, "Coverage extends")
        XCTAssertTrue(session.finish(), "Finishing an untouched draft succeeds")
        XCTAssertNil(session.issue, "No 'Draft not applied' notice")
        XCTAssertEqual(store.project.entries.first { $0.id == direction.id }?.coverageDurationMs, direction.coverageDurationMs + 2_000, "The coverage change is kept")
    }

    /// Find marks the match Next/Previous landed on, even when it was already
    /// on screen, and the query field stays readable on the smallest window.
    func testFindMarksTheCurrentMatch() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification storage.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent().deletingLastPathComponent()) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 1080, height: 720)
        let workspace = ScrivWorkspaceController(store: store)
        window.rootViewController = workspace; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        store.tab = .script
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(30)); window.layoutIfNeeded() }
        try button(labelled: "Find in script", in: window).sendActions(for: .primaryActionTriggered)
        let field = try XCTUnwrap(views(UISearchTextField.self, in: window).first { $0.window != nil })
        field.text = "Miyazaki"; field.sendActions(for: .editingChanged)
        window.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(field.bounds.width, 160, "The query stays readable at 1080 pt")
        let strong = UIColor.systemYellow.withAlphaComponent(0.34)
        func current() -> [ScriptEntryRow] { views(ScriptEntryRow.self, in: window).filter { $0.window != nil && $0.backgroundColor == strong } }
        XCTAssertEqual(current().count, 1, "Exactly one current match")
        let first = try XCTUnwrap(current().first)
        try button(labelled: "Next match", in: window).sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(current().count, 1)
        XCTAssertFalse(current().first === first, "Next moves the mark to another line")
        try button(labelled: "Previous match", in: window).sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(current().first === first, "Previous moves it back")
        // Escape in the field closes Find and clears every match highlight.
        func controllers(_ root: UIViewController) -> [UIViewController] { [root] + root.children.flatMap(controllers) }
        let script = try XCTUnwrap(controllers(workspace).compactMap { $0 as? ScriptScreenController }.first)
        let escape = try XCTUnwrap(script.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
        XCTAssertTrue(escape.wantsPriorityOverSystemBehavior, "The field must not swallow Escape")
        field.becomeFirstResponder()
        let action = try XCTUnwrap(escape.action)
        XCTAssertTrue(script.canPerformAction(action, withSender: escape))
        script.perform(action, with: escape)
        window.layoutIfNeeded()
        XCTAssertEqual(field.text ?? "", "")
        XCTAssertNil(field.window.flatMap { _ in field.superview?.isHidden == false ? field : nil }, "The find bar is hidden")
        XCTAssertTrue(views(ScriptEntryRow.self, in: window).allSatisfy { $0.backgroundColor != strong && $0.backgroundColor != UIColor.systemYellow.withAlphaComponent(0.12) }, "No line stays highlighted")
        XCTAssertFalse(script.canPerformAction(action, withSender: escape), "With Find closed, Escape keeps its other meanings")
    }

    /// Escape in the Characters search clears the filter, not just the field.
    func testCharacterSearchEscapeClearsTheFilter() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification storage.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent().deletingLastPathComponent()) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 1080, height: 720)
        let workspace = ScrivWorkspaceController(store: store)
        window.rootViewController = workspace; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        store.tab = .characters
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(30)); window.layoutIfNeeded() }
        func controllers(_ root: UIViewController) -> [UIViewController] { [root] + root.children.flatMap(controllers) }
        let characters = try XCTUnwrap(controllers(workspace).compactMap { $0 as? CharactersController }.first)
        let bar = try XCTUnwrap(views(UISearchBar.self, in: window).first { $0.window != nil })
        func shown(_ name: String) -> Bool { views(UILabel.self, in: window).contains { $0.window != nil && !$0.isHidden && $0.text == name } }
        XCTAssertTrue(shown("Randy"))
        bar.text = "Miya"; characters.searchBar(bar, textDidChange: "Miya"); window.layoutIfNeeded()
        XCTAssertFalse(shown("Randy"), "The filter hides non-matching characters")
        bar.searchTextField.becomeFirstResponder()
        let escape = try XCTUnwrap(characters.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
        XCTAssertTrue(escape.wantsPriorityOverSystemBehavior, "The field must not swallow Escape")
        let action = try XCTUnwrap(escape.action)
        XCTAssertTrue(characters.canPerformAction(action, withSender: escape))
        characters.perform(action, with: escape); window.layoutIfNeeded()
        XCTAssertEqual(bar.text ?? "", "")
        XCTAssertTrue(shown("Randy"), "Every character is listed again")
        XCTAssertFalse(characters.canPerformAction(action, withSender: escape), "Outside the field, Escape keeps its other meanings")
    }

    /// The first and last lines of a scene offer no move past its ends,
    /// instead of an error after choosing it.
    func testLineMenuDisablesMovesPastTheSceneEnds() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification storage.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent().deletingLastPathComponent()) }
        let script = ScriptScreenController(store: store)
        let ids = store.sceneEntries.map(\.id)
        let first = try XCTUnwrap(ids.first), last = try XCTUnwrap(ids.last)
        func item(_ title: String, _ id: String) -> UIAction? {
            func flat(_ menu: UIMenu) -> [UIAction] { menu.children.flatMap { ($0 as? UIMenu).map(flat) ?? [$0 as? UIAction].compactMap { $0 } } }
            return flat(script.entryMenu(id)).first { $0.title == title }
        }
        XCTAssertTrue(try XCTUnwrap(item("Move up", first)).attributes.contains(.disabled))
        XCTAssertFalse(try XCTUnwrap(item("Move down", first)).attributes.contains(.disabled))
        XCTAssertFalse(try XCTUnwrap(item("Move up", last)).attributes.contains(.disabled))
        XCTAssertTrue(try XCTUnwrap(item("Move down", last)).attributes.contains(.disabled))
    }

    /// The Characters tab shows the same script as the Script tab: same text
    /// size and the same place in the script.
    func testScriptLooksTheSameInScriptAndCharactersTabs() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots") else { throw XCTSkip("Requires isolated verification storage.") }
        let store = WorkspaceStore()
        while store.isBootstrapping { await Task.yield() }
        let package = try XCTUnwrap(store.projectURL)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent().deletingLastPathComponent()) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let workspace = ScrivWorkspaceController(store: store)
        window.rootViewController = workspace; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func settle() async throws { for _ in 0..<5 { try await Task.sleep(for: .milliseconds(30)); window.layoutIfNeeded() } }
        store.tab = .script; try await settle()
        func controllers(_ root: UIViewController) -> [UIViewController] { [root] + root.children.flatMap(controllers) }
        let script = try XCTUnwrap(controllers(workspace).compactMap { $0 as? ScriptScreenController }.first)
        let scroll = try XCTUnwrap(views(UIScrollView.self, in: script.view).first { $0.contentSize.height > $0.bounds.height && !($0 is UITextView) })
        scroll.contentOffset.y = 300; window.layoutIfNeeded()
        func fontSize() -> CGFloat? { views(ScriptEntryRow.self, in: window).first { $0.window != nil }?.display.font?.pointSize }
        let scriptSize = try XCTUnwrap(fontSize()), scriptOffset = scroll.contentOffset.y, scriptWidth = script.view.bounds.width
        store.tab = .characters; try await settle()
        XCTAssertEqual(script.view.bounds.width, scriptWidth, accuracy: 1, "Both tabs give the script the same width")
        XCTAssertEqual(try XCTUnwrap(fontSize()), scriptSize, accuracy: 0.01, "Same text size in both tabs")
        XCTAssertEqual(scroll.contentOffset.y, scriptOffset, accuracy: 1, "Same place in the script")
    }
}
