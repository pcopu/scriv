#if SCRIV_CLI_AUTOMATION
import UIKit
import ScrivCore

/// Only New scene and selection from the mounted Script scene button's stored
/// UIActions. Never rebuilds a menu, extracts a closure, or relays an action.
@MainActor
enum ScrivCLISceneMenu {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Scene menu action is outside the supported isolated scope" }
    }
    static func canHandle(_ request: [String: Any]) -> Bool {
        request["scope"] as? String == "script-scenes"
    }
    static func dispatch(view: UIView, window: UIWindow, request: [String: Any]) throws -> [String: Any] {
        guard Set(request.keys) == Set(["id", "command", "target", "action", "scope"]),
              request["command"] as? String == "menu-action", canHandle(request),
              request["target"] is String, let title = request["action"] as? String,
              let button = view as? UIButton, button.isEnabled, button.showsMenuAsPrimaryAction,
              let workspace = window.rootViewController as? ScrivWorkspaceController,
              workspace.presentedViewController == nil, workspace.store.tab == .script,
              !workspace.isBeingPresented, !workspace.isBeingDismissed,
              workspace.transitionCoordinator == nil else { throw Failure() }
        let store = workspace.store
        guard store.account == nil, store.cloud.account == nil,
              store.project.cloudProjectId == nil, store.cloud.projectId == nil,
              store.errorMessage == nil, !store.isPlaying, !store.isBootstrapping,
              !store.isSyncing, !store.hasConflicts, !store.codex.isGenerating,
              store.requestedEntryEditingID == nil else { throw Failure() }
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
              workspace.viewIfLoaded?.window === window else { throw Failure() }
        // Do not dispatch while an inline source editor owns uncommitted text.
        func hasFirstResponder(_ view: UIView) -> Bool {
            view.isFirstResponder || view.subviews.contains(where: hasFirstResponder)
        }
        guard !scriptView.subviews.contains(where: hasFirstResponder) else { throw Failure() }
        let scenes = store.project.orderedScenes
        guard !scenes.isEmpty, let selected = scenes.first(where: { $0.id == store.selectedSceneID }),
              button.currentTitle == selected.title + " ⌄",
              let menu = button.menu, menu.title.isEmpty, menu.options.isEmpty else { throw Failure() }
        let expected = scenes.map(\.title) + ["New scene", "Rename scene…", "Delete scene…"]
        let actions = menu.children.compactMap { $0 as? UIAction }
        guard actions.count == expected.count, menu.children.count == expected.count,
              actions.map(\.title) == expected,
              Set(expected).count == expected.count else { throw Failure() }
        for (index, action) in actions.enumerated() {
            let destructive = index == expected.count - 1
            guard action.attributes == (destructive ? [.destructive] : []),
                  action.state == (index < scenes.count && scenes[index].id == selected.id ? .on : .off)
            else { throw Failure() }
        }
        guard title == "New scene" || scenes.contains(where: { $0.title == title }),
              let action = actions.first(where: { $0.title == title }),
              action.attributes.isEmpty else { throw Failure() }
        // Also proves the prepared private run root/package identity. The shared
        // dispatcher must first enforce unique target, presentation and hittability.
        _ = try ScrivCLILoadedProject.observe(workspace: workspace)
        button.sendAction(action)
        return ["dispatched": true, "coverage": "semantic-menu-action"]
    }
}
#endif
