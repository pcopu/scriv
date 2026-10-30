import UIKit
import ScrivCore

@MainActor
final class ScrivAccountController: ScrivScreenController {
    private let content = AccountUI.stack(spacing: 18)
    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false); preferredContentSize = CGSize(width: 450, height: 620) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Scriv account"; view.backgroundColor = AccountUI.panel
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        _ = AccountUI.installScroll(in: self, content: content); storeDidChange()
    }
    override func storeDidChange() {
        guard isViewLoaded else { return }; AccountUI.clear(content)
        if let account = store.account {
            content.addArrangedSubview(AccountUI.stack([AccountUI.avatar(account.name, size: 50), AccountUI.stack([AccountUI.label(account.name, size: 17, weight: .semibold), AccountUI.label(account.email ?? "Signed in", size: 13, color: .secondaryLabel)], spacing: 4)], horizontal: true))
            content.addArrangedSubview(AccountUI.divider())
            content.addArrangedSubview(AccountUI.stack([AccountUI.label("Current project", size: 12, color: .secondaryLabel), AccountUI.label(store.project.title, size: 16, weight: .medium), AccountUI.label(store.syncStatus, size: 14), AccountUI.label(store.peerTransferStatus, size: 13, color: .secondaryLabel)]))
            if store.hasConflicts {
                let recovery = AccountUI.stack([AccountUI.label("Sync needs attention", size: 16, weight: .semibold, color: .systemOrange), AccountUI.label("Keep your local recovery draft. Export a safety copy before opening a different cloud revision.", size: 13), AccountUI.button("Export safety copy…", primary: true) { [weak self] in self?.store.exportProject() }, AccountUI.button("Retry saved cloud commands") { [weak self] in self?.store.retryCloudSync() }, AccountUI.label("Review before switching revisions.", size: 12, color: .secondaryLabel)])
                content.addArrangedSubview(AccountUI.card(recovery, tint: UIColor.systemOrange.withAlphaComponent(0.08)))
            } else {
                let sync = AccountUI.button("Sync this script", primary: true) { [weak self] in self?.store.syncProject() }; sync.isEnabled = !store.isSyncing; content.addArrangedSubview(sync)
            }
            content.addArrangedSubview(AccountUI.divider())
            content.addArrangedSubview(AccountUI.link("Refresh account", symbol: "arrow.clockwise") { [weak self] in self?.store.refreshAccount() })
            content.addArrangedSubview(AccountUI.link("Sign out", symbol: "rectangle.portrait.and.arrow.right") { [weak self] in self?.store.signOut(); self?.dismiss(animated: true) })
        } else {
            content.addArrangedSubview(AccountUI.label("Local editing is free. Sign in for script storage and team access.", size: 14, color: .secondaryLabel))
            content.addArrangedSubview(AccountUI.button("Sign in to Scriv", primary: true) { [weak self] in self?.show(.signIn) })
        }
        content.addArrangedSubview(AccountUI.link("Settings…", symbol: "gearshape") { [weak self] in self?.show(.settings) })
        content.addArrangedSubview(AccountUI.divider())
        content.addArrangedSubview(AccountUI.label("ChatGPT sign-in is separate, under Codex on this Mac.", size: 12, color: .secondaryLabel))
    }
}
