#if SCRIV_CLI_AUTOMATION
import UIKit
import ScrivCore

/// Narrow semantic dispatch of the original mounted Storyboard UIActions.
/// No menu rebuilding, provider evaluation, handler relay or model operation.
@MainActor
enum ScrivCLIStoryboardMerge {
    private static let wordMoveScope = "storyboard-word-move"
    static let scopes = ["storyboard-merge", "storyboard-picture-source", "picture-source-entry", "storyboard-remove-placement", wordMoveScope]

    private struct Failure: LocalizedError {
        var errorDescription: String? { "Storyboard merge is outside the supported isolated scope" }
    }
    static func canHandle(_ request: [String: Any]) -> Bool {
        guard let scope = request["scope"] as? String else { return false }
        return scopes.contains(scope)
    }
    static func dispatch(view: UIView, window: UIWindow, request: [String: Any]) throws -> [String: Any] {
        guard let scope = request["scope"] as? String else { throw Failure() }
        if scope == wordMoveScope { return try dispatchWordMove(view: view, window: window, request: request) }
        let removing = scope == "storyboard-remove-placement"
        let keys: Set<String> = ["id", "command", "target", "action", "scope"]
        guard Set(request.keys) == (removing ? keys.union(["cueID"]) : keys),
              request["command"] as? String == "menu-action", canHandle(request),
              request["target"] is String,
              let title = request["action"] as? String,
              let button = view as? UIButton,
              let workspace = window.rootViewController as? ScrivWorkspaceController,
              let originalMenu = button.menu else { throw Failure() }
        if scope == "picture-source-entry" {
            return try dispatchSourceEntry(button: button, workspace: workspace, title: title)
        }
        let merge = scope == "storyboard-merge"
        let expectedTitle = removing ? "Remove placement…" : merge ? "Merge with next placement" : "Picture source…"
        guard title == expectedTitle else { throw Failure() }
        var responder: UIResponder? = button
        var storyboard: StoryboardViewController?
        for _ in 0..<64 {
            guard let current = responder else { break }
            if let controller = current as? UIViewController {
                storyboard = controller as? StoryboardViewController; break
            }
            responder = current.next
        }
        guard let storyboard else { throw Failure() }
        func hasFirstResponder(_ view: UIView) -> Bool {
            view.isFirstResponder || view.subviews.contains(where: hasFirstResponder)
        }
        func validate() throws -> [UIAction] {
            let store = workspace.store
            guard window.rootViewController === workspace,
                  workspace.viewIfLoaded?.window === window,
                  workspace.presentedViewController == nil,
                  !workspace.isBeingPresented, !workspace.isBeingDismissed,
                  workspace.transitionCoordinator == nil,
                  store.tab == .storyboard, !store.showDiscussion,
                  store.account == nil, store.cloud.account == nil,
                  store.project.cloudProjectId == nil, store.cloud.projectId == nil,
                  store.errorMessage == nil, !store.isPlaying, !store.isBootstrapping,
                  !store.isSyncing, !store.hasConflicts, !store.codex.isGenerating,
                  store.codex.jobs.isEmpty, store.codex.sharedJobs.isEmpty,
                  !store.characterAnalysis.isScanning,
                  store.characterAnalysis.availability == "Image analysis is disabled in verification mode.",
                  store.requestedEntryEditingID == nil,
                  storyboard.parent === workspace, storyboard.store === store,
                  storyboard.contextIsCurrent, storyboard.presentedViewController == nil,
                  storyboard.presentingViewController == nil,
                  !storyboard.isBeingPresented, !storyboard.isBeingDismissed,
                  storyboard.transitionCoordinator == nil,
                  let content = storyboard.viewIfLoaded, content.window === window,
                  button.window === window, button.isEnabled,
                  !hasFirstResponder(window), button.showsMenuAsPrimaryAction,
                  ScrivSecondaryMenu.menu(of: button) == nil,
                  button.menu === originalMenu, originalMenu.title.isEmpty,
                  originalMenu.options.isEmpty,
                  let card = storyboard.cliValidatedPictureCue(for: button), !merge || card.canMerge else { throw Failure() }
            let cue = card.cue
            if removing, request["cueID"] as? String != cue.id { throw Failure() }
            var expected: [String] = []
            if cue.imageId != nil { expected.append("Inspect image…") }
            expected += ["Picture source…", "Choose existing image…"]
            if let image = store.project.asset(cue.imageId), store.assetURL(image) == nil {
                expected.append("Fetch image")
            }
            expected += ["Import image…", "Generate image", "Preview picture split…", "Discuss image"]
            if card.canMerge { expected.append("Merge with next placement") }
            expected.append("Remove placement…")
            let actions = originalMenu.children.compactMap { $0 as? UIAction }
            guard originalMenu.children.count == expected.count, actions.count == expected.count,
                  actions.map(\.title) == expected,
                  actions.enumerated().allSatisfy({ index, action in
                      action.state == .off && action.attributes ==
                        (index == expected.count - 1 ? [.destructive] : [])
                  }) else { throw Failure() }
            return actions
        }
        let run = try ScrivCLIRunCapability.requirePrepared()
        guard run.approvedOrigin == nil else { throw Failure() }
        let originalActions = try validate()
        _ = try ScrivCLILoadedProject.observe(workspace: workspace)
        try run.validate()
        let currentActions = try validate()
        guard originalActions.count == currentActions.count,
              zip(originalActions, currentActions).allSatisfy({ $0 === $1 }),
              let action = originalActions.first(where: { $0.title == title })
        else { throw Failure() }
        button.sendAction(action)
        return ["dispatched": true, "coverage": "semantic-menu-action"]
    }

    private static func dispatchWordMove(view: UIView, window: UIWindow, request: [String: Any]) throws -> [String: Any] {
        let run = try ScrivCLIRunCapability.requirePrepared()
        guard Set(request.keys) == ["id", "command", "target", "action", "scope", "wordID"],
              request["command"] as? String == "menu-action", request["target"] is String,
              let title = request["action"] as? String, let wordID = request["wordID"] as? String,
              run.approvedOrigin == nil, let workspace = window.rootViewController as? ScrivWorkspaceController,
              workspace.presentedViewController == nil, workspace.transitionCoordinator == nil,
              !workspace.isBeingPresented, !workspace.isBeingDismissed,
              let button = view as? UIButton, button.window === window, button.isEnabled,
              button.menu == nil, !button.showsMenuAsPrimaryAction,
              let storyboard = workspace.children.compactMap({ $0 as? StoryboardViewController }).first,
              storyboard.parent === workspace, storyboard.store === workspace.store else { throw Failure() }
        let store = workspace.store
        guard store.tab == .storyboard, !store.showDiscussion,
              store.account == nil, store.cloud.account == nil,
              store.project.cloudProjectId == nil, store.cloud.projectId == nil,
              store.errorMessage == nil, !store.isPlaying, !store.isBootstrapping, !store.isSyncing, !store.hasConflicts,
              let action = storyboard.cliWordMoveAction(for: button, wordID: wordID, title: title) else { throw Failure() }
        _ = try ScrivCLILoadedProject.observe(workspace: workspace)
        try run.validate()
        guard storyboard.cliWordMoveAction(for: button, wordID: wordID, title: title) === action else { throw Failure() }
        button.sendAction(action)
        return ["dispatched": true, "coverage": "semantic-menu-action"]
    }

    private static func dispatchSourceEntry(button: UIButton, workspace: ScrivWorkspaceController,
                                            title: String) throws -> [String: Any] {
        let run = try ScrivCLIRunCapability.requirePrepared()
        let store = workspace.store
        guard run.approvedOrigin == nil, store.tab == .storyboard,
              store.account == nil, store.cloud.account == nil,
              store.project.cloudProjectId == nil, store.cloud.projectId == nil,
              !store.isPlaying, !store.isBootstrapping, !store.isSyncing, !store.hasConflicts,
              store.errorMessage == nil,
              let navigation = workspace.presentedViewController as? UINavigationController,
              navigation.presentingViewController === workspace, navigation.modalPresentationStyle == .formSheet,
              navigation.viewControllers.count == 1, navigation.presentedViewController == nil,
              !navigation.isBeingDismissed, navigation.transitionCoordinator == nil,
              let editor = navigation.visibleViewController as? CueAnchorViewController,
              editor.parent === navigation, editor.store === store,
              editor.presentedViewController == nil, !editor.isBeingDismissed,
              let action = editor.cliSourceEntryAction(for: button, title: title) else { throw Failure() }
        // Only the original picker action updates the sheet's local draft.
        button.sendAction(action)
        return ["dispatched": true, "coverage": "semantic-menu-action"]
    }
}
#endif
