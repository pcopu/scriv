import UIKit
import Combine
import ScrivCore

/// Stable UIKit controller identity; refresh visible state without rebuilding an
/// active text responder or replacing its pending edit/selection on each publish.
@MainActor
class ScrivScreenController: UIViewController {
    let store: WorkspaceStore
    let initialNavigationContext: Int
    let scopeToProject: Bool
    var subscriptions = Set<AnyCancellable>()
    private var refreshQueued = false

    init(store: WorkspaceStore, scopeToProject: Bool = true) {
        self.store = store; self.scopeToProject = scopeToProject
        initialNavigationContext = store.navigationContext
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(store:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ScrivUIKitTheme.panel
        store.objectWillChange.sink { [weak self] _ in self?.queueRefresh() }.store(in: &subscriptions)
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); storeDidChange()
    }
    /// Override for idempotent rendering. Never silently replace a local form's
    /// draft with remote state; keep its original identity/version and review it.
    func storeDidChange() {}
    var contextIsCurrent: Bool { !scopeToProject || initialNavigationContext == store.navigationContext }
    @discardableResult
    func requireCurrentContext() -> Bool {
        guard contextIsCurrent else {
            store.errorMessage = "The project changed while this screen was open. Reopen it before applying changes."
            return false
        }
        return true
    }
    func show(_ route: ScrivUIKitRoute) {
        guard requireCurrentContext() else { return }
        ScrivUIKitRouter.shared.present(route, from: self, store: store)
    }
    private func queueRefresh() {
        guard !refreshQueued else { return }; refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.refreshQueued = false
            if self.isViewLoaded { self.storeDidChange() }
        }
    }
}
