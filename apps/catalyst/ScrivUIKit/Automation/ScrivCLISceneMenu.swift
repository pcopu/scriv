#if SCRIV_CLI_AUTOMATION
import UIKit
import ScrivCore

/// Dispatches stored structure actions from the mounted Script menus.
@MainActor
enum ScrivCLISceneMenu {
    private struct Failure: LocalizedError {
        let subject: String
        var errorDescription: String? { "\(subject) menu action is outside the supported isolated scope" }
    }
    static func canHandle(_ request: [String: Any]) -> Bool {
        let scope = request["scope"] as? String
        return scope == "script-scenes" || scope == "script-entries"
    }
    static func dispatch(view: UIView, window: UIWindow, request: [String: Any]) throws -> [String: Any] {
        let isEntry = request["scope"] as? String == "script-entries"
        let failure = Failure(subject: isEntry ? "Entry" : "Scene")
        guard request["command"] as? String == "menu-action", canHandle(request),
              request["target"] is String, let title = request["action"] as? String,
              let button = view as? UIButton, button.isEnabled, button.showsMenuAsPrimaryAction,
              let workspace = window.rootViewController as? ScrivWorkspaceController,
              workspace.presentedViewController == nil, workspace.store.tab == .script,
              !workspace.isBeingPresented, !workspace.isBeingDismissed,
              workspace.transitionCoordinator == nil else { throw failure }
        let store = workspace.store
        guard store.account == nil, store.cloud.account == nil,
              store.project.cloudProjectId == nil, store.cloud.projectId == nil,
              store.errorMessage == nil, !store.isPlaying, !store.isBootstrapping,
              !store.isSyncing, !store.hasConflicts, !store.codex.isGenerating,
              store.requestedEntryEditingID == nil else { throw failure }
        var responder: UIResponder? = button
        var script: ScriptScreenController?
        for _ in 0..<64 {
            guard let current = responder else { break }
            if let candidate = current as? ScriptScreenController { script = candidate; break }
            responder = current.next
        }
        guard let script, script.parent === workspace, script.store === store,
              script.contextIsCurrent, script.presentedViewController == nil,
              script.presentingViewController == nil, !script.isBeingPresented,
              !script.isBeingDismissed, script.transitionCoordinator == nil,
              let scriptView = script.viewIfLoaded, button.isDescendant(of: scriptView),
              button.window === window, scriptView.window === window,
              workspace.viewIfLoaded?.window === window else { throw failure }
        // Do not dispatch while an inline source editor owns uncommitted text.
        func hasFirstResponder(_ view: UIView) -> Bool {
            view.isFirstResponder || view.subviews.contains(where: hasFirstResponder)
        }
        guard !scriptView.subviews.contains(where: hasFirstResponder),
              let menu = button.menu, menu.title.isEmpty, menu.options.isEmpty else { throw failure }
        let keys = Set(request.keys)
        var required: Set<String> = ["id", "command", "target", "action", "scope"]
        let action: UIAction?
        if isEntry {
            required.insert("entryID")
            guard keys == required, let entryID = request["entryID"] as? String,
                  script.cliOwnsEntryMenu(button, entryID: entryID) else { throw failure }
            action = entryAction(title, menu: menu)
        } else {
            let deleting = title == "Delete scene…"
            if deleting { required.insert("sceneID") }
            guard keys == required, script.cliOwnsSceneMenu(button),
                  !deleting || request["sceneID"] as? String == store.selectedSceneID else { throw failure }
            action = sceneAction(title, menu: menu, button: button, store: store)
        }
        guard let action else { throw failure }
        // Proves the prepared private run root and its currently loaded package.
        _ = try ScrivCLILoadedProject.observe(workspace: workspace)
        button.sendAction(action)
        return ["dispatched": true, "coverage": "semantic-menu-action"]
    }
    private static func entryAction(_ title: String, menu: UIMenu) -> UIAction? {
        let expected = ["Move up", "Move down", "Delete entry"]
        let actions = menu.children.compactMap { $0 as? UIAction }
        guard menu.children.count == expected.count, actions.map(\.title) == expected,
              let action = actions.first(where: { $0.title == title }), action.state == .off,
              action.attributes == (title == "Delete entry" ? [.destructive] : []) else { return nil }
        return action
    }
    private static func sceneAction(_ title: String, menu: UIMenu, button: UIButton, store: WorkspaceStore) -> UIAction? {
        let scenes = store.project.orderedScenes
        guard !scenes.isEmpty, let selected = scenes.first(where: { $0.id == store.selectedSceneID }),
              button.currentTitle == selected.title + " ⌄" else { return nil }
        let expected = scenes.map(\.title) + ["New scene", "Rename scene…", "Delete scene…"]
        let actions = menu.children.compactMap { $0 as? UIAction }
        guard actions.count == expected.count, menu.children.count == expected.count,
              actions.map(\.title) == expected,
              Set(expected).count == expected.count else { return nil }
        for (index, action) in actions.enumerated() {
            let destructive = index == expected.count - 1
            guard action.attributes == (destructive ? [.destructive] : []),
                  action.state == (index < scenes.count && scenes[index].id == selected.id ? .on : .off)
            else { return nil }
        }
        guard title != "Rename scene…" else { return nil }
        return actions.first(where: { $0.title == title })
    }
}
#endif
