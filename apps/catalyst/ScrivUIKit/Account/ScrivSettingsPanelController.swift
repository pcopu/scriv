import UIKit

enum ScrivSettingsPane: Int, CaseIterable {
    case general, account, codex
    var title: String {
        switch self { case .general: return "General"; case .account: return "Account"; case .codex: return "Codex" }
    }
    var symbol: String {
        switch self { case .general: return "gearshape"; case .account: return "person.crop.circle"; case .codex: return "sparkles" }
    }
}

@MainActor
final class ScrivSettingsPanelController: UISplitViewController {
    let store: WorkspaceStore
    private let detail = UINavigationController()
    private let makePane: @MainActor (WorkspaceStore, ScrivSettingsPane) -> ScrivSettingsController
    private var panes: [ScrivSettingsPane: ScrivSettingsController] = [:]
    private(set) var selectedPane = ScrivSettingsPane.general

    init(store: WorkspaceStore, makePane: @escaping @MainActor (WorkspaceStore, ScrivSettingsPane) -> ScrivSettingsController = { ScrivSettingsController(store: $0, pane: $1) }) {
        self.store = store; self.makePane = makePane
        super.init(style: .doubleColumn)
        title = "Settings"
        preferredContentSize = CGSize(width: 880, height: 660)
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        primaryBackgroundStyle = .sidebar
        minimumPrimaryColumnWidth = 190; maximumPrimaryColumnWidth = 240
        preferredPrimaryColumnWidth = 210
        presentsWithGesture = false
        let sidebar = ScrivSettingsSidebarController()
        sidebar.onSelect = { [weak self] in self?.selectPane($0) }
        setViewController(sidebar, for: .primary)
        setViewController(detail, for: .secondary)
        selectPane(.general)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }

    func selectPane(_ pane: ScrivSettingsPane) {
        (viewController(for: .primary) as? ScrivSettingsSidebarController)?.select(pane)
        guard selectedPane != pane || panes[pane] == nil else { return }
        panes[selectedPane]?.cancelPendingConnectionCheck()
        viewIfLoaded?.endEditing(true)
        selectedPane = pane
        let controller = panes[pane] ?? makePane(store, pane)
        panes[pane] = controller
        detail.setViewControllers([controller], animated: false)
    }

    func cancelPendingConnectionCheck() { panes[.codex]?.cancelPendingConnectionCheck() }

}

@MainActor
private final class ScrivSettingsSidebarController: UICollectionViewController {
    var onSelect: ((ScrivSettingsPane) -> Void)?
    private var selectedPane = ScrivSettingsPane.general
    private let cell = UICollectionView.CellRegistration<UICollectionViewListCell, ScrivSettingsPane> { cell, _, pane in
        var content = cell.defaultContentConfiguration()
        content.text = pane.title; content.image = UIImage(systemName: pane.symbol)
        content.textProperties.font = .systemFont(ofSize: 14)
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "scriv.settings.\(pane.title.lowercased())"
    }
    init() {
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: .init(appearance: .sidebar)))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init()") }
    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .clear
        select(selectedPane)
    }
    func select(_ pane: ScrivSettingsPane) {
        selectedPane = pane
        guard isViewLoaded else { return }
        collectionView.selectItem(at: IndexPath(item: pane.rawValue, section: 0), animated: false, scrollPosition: [])
    }
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { ScrivSettingsPane.allCases.count }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: ScrivSettingsPane.allCases[indexPath.item])
    }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect?(ScrivSettingsPane.allCases[indexPath.item])
    }
}
