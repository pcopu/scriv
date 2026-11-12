#if SCRIV_CLI_AUTOMATION
import UIKit
import ScrivCore

/// Existing Layers action dispatch only; not native-menu or hardware input.
@MainActor
enum ScrivCLIWordTimingMenu {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Word timing menu action is outside the supported isolated scope" }
    }
    private static func localIdle(_ workspace: ScrivWorkspaceController) -> Bool {
        let store = workspace.store
        return store.account == nil && store.cloud.account == nil &&
            store.project.cloudProjectId == nil && store.cloud.projectId == nil &&
            store.errorMessage == nil && !store.isPlaying && !store.isBootstrapping &&
            !store.isSyncing && !store.hasConflicts && !store.codex.isGenerating &&
            workspace.viewIfLoaded?.window != nil && !workspace.isBeingPresented &&
            !workspace.isBeingDismissed && workspace.transitionCoordinator == nil
    }
    /// Read-only identity scope for pending draft observations. Never compares
    /// project values to the draft: accidental mutations must remain observable.
    static func editor(in workspace: ScrivWorkspaceController) -> WordTimingEditorController? {
        guard localIdle(workspace),
              let editor = workspace.presentedViewController as? WordTimingEditorController,
              editor.presentingViewController === workspace,
              editor.modalPresentationStyle == .formSheet,
              editor.parent == nil, editor.navigationController == nil, editor.children.isEmpty,
              editor.store === workspace.store, editor.scopeToProject,
              editor.initialNavigationContext == workspace.store.navigationContext,
              editor.cliOwnsCurrentScene,
              let workspaceWindow = workspace.viewIfLoaded?.window,
              workspaceWindow.rootViewController === workspace,
              let editorView = editor.viewIfLoaded, !editorView.isHidden, editorView.alpha > 0.01,
              let editorWindow = editorView.window, !editorWindow.isHidden, editorWindow.alpha > 0.01,
              // Catalyst may bridge this exact direct sheet into another scene.
              // Follow only its attached view window, never search other scenes.
              let workspaceScene = workspaceWindow.windowScene,
              let editorScene = editorWindow.windowScene,
              workspaceScene.windows.contains(where: { $0 === workspaceWindow }),
              editorScene.windows.contains(where: { $0 === editorWindow }),
              editor.presentedViewController == nil,
              !editor.isBeingPresented, !editor.isBeingDismissed,
              editor.transitionCoordinator == nil else { return nil }
        return editor
    }
    static func dispatch(view: UIView, window: UIWindow, request: [String: Any]) throws -> [String: Any] {
        guard Set(request.keys) == Set(["id", "command", "target", "action"]),
              request["command"] as? String == "menu-action",
              request["target"] is String,
              request["action"] as? String == "Edit word timing…",
              let button = view as? UIButton, button.isEnabled,
              let workspace = window.rootViewController as? ScrivWorkspaceController,
              localIdle(workspace), workspace.presentedViewController == nil,
              button.menu == nil, !button.showsMenuAsPrimaryAction,
              let menu = ScrivSecondaryMenu.menu(of: button),
              menu.title.isEmpty, menu.options.isEmpty, menu.children.count == 1,
              let action = menu.children.first as? UIAction,
              action.title == "Edit word timing…", action.attributes.isEmpty,
              action.state == .off else { throw Failure() }
        var responder: UIResponder? = button
        var layers: LayerTimelineViewController?
        for _ in 0..<64 {
            guard let current = responder else { break }
            if let candidate = current as? LayerTimelineViewController { layers = candidate; break }
            responder = current.next
        }
        guard let layers, let preview = layers.parent as? PreviewViewController,
              preview.parent === workspace, preview.layersExpanded,
              layers.store === workspace.store, preview.store === workspace.store,
              layers.contextIsCurrent, preview.contextIsCurrent,
              layers.presentedViewController == nil, preview.presentedViewController == nil,
              layers.presentingViewController == nil, preview.presentingViewController == nil,
              let layerView = layers.viewIfLoaded, button.isDescendant(of: layerView),
              button.window === window, layerView.window === window,
              preview.viewIfLoaded?.window === window, workspace.viewIfLoaded?.window === window,
              let label = button.accessibilityLabel, button.currentTitle == label,
              workspace.store.sceneEntries.filter({ $0.kind == .dialogue })
                .flatMap({ $0.words }).filter({ $0.text == label }).count == 1 else { throw Failure() }
        // ScrivCLI proves uniqueness, active presentation, all interactive
        // ancestors and actual hittability before this dispatch. This observer
        // additionally proves the private synthetic root and package identity.
        _ = try ScrivCLILoadedProject.observe(workspace: workspace)
        button.sendAction(action)
        return ["dispatched": true, "coverage": "semantic-menu-action"]
    }
}
#endif
