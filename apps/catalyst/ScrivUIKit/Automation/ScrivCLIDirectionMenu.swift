#if SCRIV_CLI_AUTOMATION
import UIKit
import ScrivCore

/// Dispatches only the stored, existing direction-duration secondary action.
/// This is semantic public UIControl dispatch, not physical menu interaction.
@MainActor
enum ScrivCLIDirectionMenu {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Direction menu action is outside the supported isolated scope" }
    }

    static func dispatch(view: UIView, window: UIWindow, request: [String: Any]) throws -> [String: Any] {
        guard Set(request.keys).isSubset(of: ["id", "command", "target", "action"]),
              request["action"] as? String == "Owned duration…",
              let button = view as? UIButton,
              let workspace = window.rootViewController as? ScrivWorkspaceController,
              workspace.presentedViewController == nil, workspace.store.errorMessage == nil,
              workspace.store.account == nil, workspace.store.cloud.account == nil,
              workspace.store.project.cloudProjectId == nil, workspace.store.cloud.projectId == nil,
              button.menu == nil, !button.showsMenuAsPrimaryAction,
              let menu = ScrivSecondaryMenu.menu(of: button),
              menu.title.isEmpty, menu.options.isEmpty, menu.children.count == 1,
              let action = menu.children.first as? UIAction,
              action.title == "Owned duration…", action.attributes.isEmpty else { throw Failure() }
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
              layers.presentedViewController == nil, preview.presentedViewController == nil,
              let layerView = layers.viewIfLoaded, button.isDescendant(of: layerView),
              button.window === workspace.viewIfLoaded?.window,
              let label = button.accessibilityLabel, button.currentTitle == label else { throw Failure() }
        let sources = workspace.store.sceneEntries.filter {
            $0.kind == .direction &&
            $0.text + "\n" + ScrivFormat.duration($0.ownedDurationMs) + " owned" == label
        }
        guard sources.count == 1 else { throw Failure() }
        // Opening the real editor may acquire a lease for cloud projects. The
        // explicit account/project guards above keep this local synthetic-only.
        _ = try ScrivCLILoadedProject.observe(workspace: workspace)
        button.sendAction(action)
        return ["dispatched": true, "coverage": "semantic-menu-action"]
    }
}
#endif
