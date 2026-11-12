#if SCRIV_CLI_AUTOMATION
import UIKit

/// A bounded public dispatch of an existing attachment action on its original
/// owning button. This does not open or physically interact with a native menu.
@MainActor
enum ScrivCLIAudioAnchorMenu {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Audio attachment menu action is outside the supported isolated scope" }
    }

    /// Shared read-only presentation/identity check. Observation intentionally
    /// uses false so a changed clip value is observable, not hidden by a guard.
    static func editor(in workspace: ScrivWorkspaceController,
                       requiresUnchangedClip: Bool) -> AudioClipEditorController? {
        let store = workspace.store
        guard store.errorMessage == nil, !store.isPlaying,
              store.account == nil, store.cloud.account == nil,
              store.project.cloudProjectId == nil, store.cloud.projectId == nil,
              workspace.viewIfLoaded?.window != nil,
              !workspace.isBeingPresented, !workspace.isBeingDismissed,
              workspace.transitionCoordinator == nil,
              let library = workspace.presentedViewController as? AudioLibraryController,
              library.presentingViewController === workspace,
              library.store === store, library.modalPresentationStyle == .formSheet,
              library.parent == nil, library.navigationController == nil, library.children.isEmpty,
              library.viewIfLoaded?.window != nil,
              !library.isBeingPresented, !library.isBeingDismissed, library.transitionCoordinator == nil,
              let editor = library.presentedViewController as? AudioClipEditorController,
              editor.modalPresentationStyle == .formSheet,
              editor.parent == nil, editor.navigationController == nil, editor.children.isEmpty,
              editor.viewIfLoaded?.window != nil, editor.presentedViewController == nil,
              !editor.isBeingPresented, !editor.isBeingDismissed, editor.transitionCoordinator == nil,
              library.cliOwnsTrimEditor(editor, requiresUnchangedClip: requiresUnchangedClip) else { return nil }
        return editor
    }

    static func dispatch(view: UIView, window: UIWindow, request: [String: Any]) throws -> [String: Any] {
        guard Set(request.keys).isSubset(of: ["id", "command", "target", "action"]),
              request["target"] as? String == "audio-anchor",
              let title = request["action"] as? String,
              let button = view as? UIButton, button.accessibilityIdentifier == "audio-anchor",
              let workspace = window.rootViewController as? ScrivWorkspaceController,
              let editor = editor(in: workspace, requiresUnchangedClip: true),
              let content = editor.viewIfLoaded, button.isDescendant(of: content),
              button.window === content.window, editor.cliOwnsAttachmentMenu(button),
              let menu = button.menu,
              let action = menu.children.compactMap({ $0 as? UIAction }).first(where: { $0.title == title })
        else { throw Failure() }
        // ScrivCLI already proved unique/active/interactable/enabled/hittable.
        // The existing observer additionally proves run/package isolation.
        _ = try ScrivCLILoadedProject.observe(workspace: workspace)
        // Same stored action and original control, once. No handler extraction,
        // relay registration, selector, provider, model mutation or retry.
        button.sendAction(action)
        return ["dispatched": true, "coverage": "semantic-menu-action"]
    }
}
#endif
