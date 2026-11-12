#if SCRIV_CLI_AUTOMATION
import UIKit
import ScrivCore

/// Narrow semantic dispatch of the original mounted ellipsis menu UIAction.
/// No menu rebuilding, provider evaluation, handler relay or model operation.
@MainActor
enum ScrivCLIStoryboardMerge {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Storyboard merge is outside the supported isolated scope" }
    }
    static func canHandle(_ request: [String: Any]) -> Bool {
        request["scope"] as? String == "storyboard-merge"
    }
    static func dispatch(view: UIView, window: UIWindow, request: [String: Any]) throws -> [String: Any] {
        guard Set(request.keys) == Set(["id", "command", "target", "action", "scope"]),
              request["command"] as? String == "menu-action", canHandle(request),
              request["target"] is String,
              request["action"] as? String == "Merge with next placement",
              let button = view as? UIButton,
              let workspace = window.rootViewController as? ScrivWorkspaceController,
              let originalMenu = button.menu else { throw Failure() }
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
                  let cue = storyboard.cliValidatedMergeCue(for: button) else { throw Failure() }
            var expected: [String] = []
            if cue.imageId != nil { expected.append("Inspect image…") }
            expected += ["Picture source…", "Choose existing image…"]
            if let image = store.project.asset(cue.imageId), store.assetURL(image) == nil {
                expected.append("Fetch image")
            }
            expected += ["Import image…", "Generate image", "Preview picture split…", "Discuss image",
                "Merge with next placement", "Remove placement…"]
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
              let action = originalActions.first(where: { $0.title == "Merge with next placement" })
        else { throw Failure() }
        button.sendAction(action)
        return ["dispatched": true, "coverage": "semantic-menu-action"]
    }
}
#endif
