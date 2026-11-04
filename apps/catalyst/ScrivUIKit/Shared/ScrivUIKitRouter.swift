import UIKit

/// Route payloads carry stable item IDs, not separately toggled booleans/data.
/// Feature owners register factories; no SwiftUI or NSHostingView is involved.
enum ScrivUIKitRoute: Hashable {
    case script, projects, history, audio, characters, teams, storyboard, preview
    case signIn, account, settings, codexSettings, generationJobs, codex
    case wordTiming(entryID: String, wordIDs: [String])
    case characterEditor(characterID: String?)
    case characterLinks(entryID: String)
    case imageDetail(imageID: String, cueID: String?)
    case cueAnchor(cueID: String)

    enum Kind: Hashable {
        case script, projects, history, audio, characters, teams, storyboard, preview
        case signIn, account, settings, codexSettings, generationJobs, codex, wordTiming
        case characterEditor, characterLinks, imageDetail, cueAnchor
    }
    var kind: Kind {
        switch self {
        case .script: return .script; case .projects: return .projects; case .history: return .history
        case .audio: return .audio; case .characters: return .characters; case .teams: return .teams
        case .storyboard: return .storyboard; case .preview: return .preview; case .signIn: return .signIn
        case .account: return .account; case .settings: return .settings; case .codexSettings: return .codexSettings; case .generationJobs: return .generationJobs
        case .codex: return .codex; case .wordTiming: return .wordTiming; case .characterEditor: return .characterEditor
        case .characterLinks: return .characterLinks; case .imageDetail: return .imageDetail; case .cueAnchor: return .cueAnchor
        }
    }
}

@MainActor
final class ScrivUIKitRouter {
    static let shared = ScrivUIKitRouter()
    typealias Factory = @MainActor (ScrivUIKitRoute, WorkspaceStore) -> UIViewController?
    private var factories: [ScrivUIKitRoute.Kind:Factory] = [:]
    func register(_ kind: ScrivUIKitRoute.Kind, factory: @escaping Factory) { factories[kind] = factory }
    func controller(for route: ScrivUIKitRoute, store: WorkspaceStore) -> UIViewController? {
        factories[route.kind]?(route, store)
    }
    func present(_ route: ScrivUIKitRoute, from presenter: UIViewController, store: WorkspaceStore, sourceView: UIView? = nil) {
        #if targetEnvironment(macCatalyst)
        if case .settings = route { ScrivSettingsWindowCoordinator.shared.show(store: store); return }
        if case .codexSettings = route { ScrivSettingsWindowCoordinator.shared.show(store: store, pane: .codex); return }
        #endif
        var front = presenter
        while let presented = front.presentedViewController {
            guard !presented.isBeingDismissed else { return }
            // Reopening the menu must reuse the visible popup, not stack one.
            if case .codex = route, (presented as? UINavigationController)?.topViewController is ScrivCodexController { return }
            front = presented
        }
        if case .codex = route, front is ScrivCodexController { return }
        guard front.viewIfLoaded?.window != nil, !front.isBeingDismissed, !front.isBeingPresented else {
            store.errorMessage = "Wait for the current screen to finish opening, then try again."
            return
        }
        guard let controller = controller(for: route, store: store) else {
            store.errorMessage = "This screen is unavailable in this build. No project data was changed."
            return
        }
        if case .codex = route {
            controller.modalPresentationStyle = .popover
            if let popup = controller.popoverPresentationController {
                let anchor = sourceView?.window === front.view.window ? sourceView : nil
                popup.sourceView = anchor ?? front.view
                popup.sourceRect = anchor?.bounds ?? CGRect(x: front.view.bounds.midX, y: 24, width: 1, height: 1)
                popup.permittedArrowDirections = anchor == nil ? [] : [.up, .down]
                popup.delegate = (controller as? UINavigationController)?.topViewController as? ScrivCodexController
            }
        } else {
            controller.modalPresentationStyle = .formSheet
            ScrivSheetFitting.fit(controller, presentedFrom: front)
        }
        front.present(controller, animated: true)
    }
}

/// Separate extensions in feature-owned files register only their route kinds.
/// Final App registration must invoke every feature before opening a workspace.
@MainActor
enum ScrivUIKitFeatures {}
