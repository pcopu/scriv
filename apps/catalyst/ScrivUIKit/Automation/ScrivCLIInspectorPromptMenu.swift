#if SCRIV_CLI_AUTOMATION
import UIKit
import ScrivCore

/// Explicit semantic disclosure only, never native-menu presentation or a
/// fallback for accessibility activation. Clipboard and share actions are inert.
@MainActor
enum ScrivCLIInspectorPromptMenu {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Inspector prompt menu action is outside the supported isolated scope" }
    }
    private static let disclosureTitles = ["Show captured generation prompt", "Hide captured generation prompt"]

    static func dispatch(view: UIView, window: UIWindow, windows: [UIWindow], request: [String: Any]) throws -> [String: Any] {
        guard Set(request.keys) == Set(["id", "command", "target", "action"]),
              request["command"] as? String == "menu-action", request["target"] is String,
              let title = request["action"] as? String, disclosureTitles.contains(title),
              let button = view as? UIButton,
              let workspace = window.rootViewController as? ScrivWorkspaceController else { throw Failure() }
        // Find the actual nearest controller through a bounded responder chain;
        // matching a label elsewhere cannot authorize this action.
        var responder: UIResponder? = button
        var inspector: ImageDetailViewController?
        for _ in 0..<64 {
            guard let current = responder else { break }
            if let controller = current as? UIViewController {
                inspector = controller as? ImageDetailViewController
                break
            }
            responder = current.next
        }
        guard let inspector,
              let navigation = inspector.parent as? UINavigationController,
              let asset = workspace.store.project.asset(inspector.imageID),
              let originalMenu = button.menu else { throw Failure() }
        func validate() throws -> [UIAction] {
            let store = workspace.store
            guard workspace.viewIfLoaded?.window === window,
                  windows.contains(where: { $0 === window }),
                  window.rootViewController === workspace,
                  !workspace.isBeingPresented, !workspace.isBeingDismissed,
                  workspace.transitionCoordinator == nil,
                  workspace.presentedViewController === navigation,
                  navigation.presentingViewController === workspace,
                  navigation.parent == nil, !navigation.isBeingDismissed,
                  navigation.transitionCoordinator == nil,
                  navigation.viewControllers.count == 1, navigation.viewControllers.first === inspector,
                  navigation.topViewController === inspector, navigation.visibleViewController === inspector,
                  navigation.children.count == 1, navigation.children.first === inspector,
                  inspector.parent === navigation, inspector.navigationController === navigation,
                  navigation.presentedViewController == nil, inspector.presentedViewController == nil,
                  !inspector.isBeingPresented, !inspector.isBeingDismissed,
                  inspector.transitionCoordinator == nil,
                  inspector.store === store, inspector.scopeToProject, inspector.contextIsCurrent,
                  inspector.initialNavigationContext == store.navigationContext,
                  store.project.asset(inspector.imageID) == asset, store.assetURL(asset) != nil,
                  !store.isBootstrapping, !store.isSyncing, !store.hasConflicts,
                  let content = inspector.viewIfLoaded, let surfaceWindow = content.window,
                  navigation.viewIfLoaded?.window === surfaceWindow,
                  button.window === surfaceWindow,
                  windows.contains(where: { $0 === surfaceWindow }),
                  button.isDescendant(of: content), button.isEnabled,
                  button.accessibilityLabel == "Image version actions",
                  button.showsMenuAsPrimaryAction, ScrivSecondaryMenu.menu(of: button) == nil,
                  button.menu === originalMenu, originalMenu.title.isEmpty,
                  originalMenu.options.isEmpty else { throw Failure() }
            // Exact genuine production shape, in order. No providers, nested
            // menus, commands, duplicates, extra actions or selectable sharing.
            var expected = [title, "Copy image direction"]
            if asset.generationPrompt != nil { expected.append("Copy captured generation prompt") }
            expected.append("Share original image")
            let actions = originalMenu.children.compactMap { $0 as? UIAction }
            guard actions.count == expected.count, originalMenu.children.count == expected.count,
                  actions.map({ $0.title }) == expected,
                  actions.enumerated().allSatisfy({ index, action in
                      action.state == .off && action.attributes ==
                        (index == 1 && asset.prompt.isEmpty ? [.disabled] : [])
                  }) else { throw Failure() }
            return actions
        }
        let originalActions = try validate()
        guard let originalAction = originalActions.first else { throw Failure() }
        // Full existing synthetic package/fixture byte evidence, not just a
        // prepared capability. No loaded-project observer widening is needed.
        _ = try ScrivCLILocalImageEvidence.observe(workspace: workspace, windows: windows)
        let currentActions = try validate()
        guard zip(originalActions, currentActions).allSatisfy({ pair in pair.0 === pair.1 }) else { throw Failure() }
        // Public dispatch on the original owning control, exactly once. Never
        // extract a handler, register a relay, call a selector or retry.
        button.sendAction(originalAction)
        return ["dispatched": true, "coverage": "semantic-menu-action"]
    }
}
#endif
