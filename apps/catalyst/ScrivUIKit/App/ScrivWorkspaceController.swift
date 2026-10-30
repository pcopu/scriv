import UIKit
import ScrivCore

@MainActor
final class ScrivWorkspaceController: ScrivScreenController {
    private let chrome = UIStackView()
    private let content = UIStackView()
    private let contentContainer = UIView()
    private let workspaceBody = UIStackView()
    private var discussionDock: UIView?
    private var discussionHeight: NSLayoutConstraint?
    private let tabs = UISegmentedControl(items: WorkspaceTab.allCases.map(\.rawValue))
    private var titleButton: UIButton!
    private var accountButton: UIButton!
    private var discussionButton: UIButton!
    private var statusLabel = ScrivUIKitTheme.label("", size: 11, color: .secondaryLabel)
    private var cached: [ScrivUIKitRoute.Kind:UIViewController] = [:]
    private var installedTab: WorkspaceTab?
    private var discussion: ScrivDiscussionController?

    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = ScrivUIKitTheme.canvas
        configureChrome()
        content.axis = .horizontal; content.spacing = 12; content.alignment = .fill
        content.scrivPinEdges(to: contentContainer)
        let transport = AudioTransportView(store: store, compact: false)
        let footer = ScrivUIKitTheme.stack([transport, statusLabel], spacing: 5)
        workspaceBody.axis = .horizontal; workspaceBody.spacing = 12; workspaceBody.alignment = .fill
        workspaceBody.addArrangedSubview(contentContainer)
        let column = ScrivUIKitTheme.stack([chrome, workspaceBody, footer], spacing: 12)
        column.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            chrome.heightAnchor.constraint(equalToConstant: 48),
            transport.heightAnchor.constraint(greaterThanOrEqualToConstant: 42)
        ])
        footer.setContentHuggingPriority(.required, for: .vertical)
        storeDidChange()
    }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        titleButton.configuration?.title = store.project.title
        accountButton.configuration?.title = store.account?.name ?? "Sign in"
        chrome.isUserInteractionEnabled = !store.isBootstrapping
        workspaceBody.isUserInteractionEnabled = !store.isBootstrapping
        tabs.selectedSegmentIndex = WorkspaceTab.allCases.firstIndex(of: store.tab) ?? 0
        statusLabel.text = store.statusMessage + " · " + store.syncStatus
        discussionButton.accessibilityValue = "\(store.unreadDiscussionMentionCount) unread mentions"
        if installedTab != store.tab { installContent() }
        updateDiscussion()
        if store.showAccountSignIn, !(presentedViewController is ScrivSignInController) {
            store.showAccountSignIn = false
            show(.signIn)
        }
    }
    private func configureChrome() {
        chrome.axis = .horizontal; chrome.spacing = 10; chrome.alignment = .center
        titleButton = ScrivUIKitTheme.button(store.project.title, symbol: "doc.text.fill") { [weak self] in self?.show(.projects) }
        titleButton.titleLabel?.lineBreakMode = .byTruncatingTail
        titleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        titleButton.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true
        let more = icon("chevron.down", label: "Project actions") {}
        more.menu = projectMenu(); more.showsMenuAsPrimaryAction = true
        chrome.addArrangedSubview(titleButton); chrome.addArrangedSubview(more)
        let leftSpace = UIView(); leftSpace.setContentHuggingPriority(.defaultLow, for: .horizontal); chrome.addArrangedSubview(leftSpace)
        tabs.addTarget(self, action: #selector(changeTab), for: .valueChanged)
        tabs.widthAnchor.constraint(greaterThanOrEqualToConstant: 270).isActive = true; chrome.addArrangedSubview(tabs)
        let rightSpace = UIView(); rightSpace.setContentHuggingPriority(.defaultLow, for: .horizontal); chrome.addArrangedSubview(rightSpace)
        chrome.addArrangedSubview(icon("waveform", label: "Audio library") { [weak self] in self?.show(.audio) })
        discussionButton = icon("bubble.left.and.bubble.right", label: "Discussion") { [weak self] in
            guard let self else { return }
            if self.store.showDiscussion { self.store.showDiscussion = false }
            else { self.store.loadDiscussion(itemId: self.store.discussionItemID) }
        }
        chrome.addArrangedSubview(discussionButton)
        chrome.addArrangedSubview(icon("clock.arrow.circlepath", label: "History") { [weak self] in self?.show(.history) })
        chrome.addArrangedSubview(icon("square.and.arrow.up", label: "Teams and sharing") { [weak self] in self?.show(.teams) })
        accountButton = ScrivUIKitTheme.button("Sign in", symbol: "person.crop.circle") { [weak self] in
            guard let self else { return }; self.show(self.store.account == nil ? .signIn : .account)
        }
        chrome.addArrangedSubview(accountButton)
        chrome.addArrangedSubview(ScrivUIKitTheme.button("Codex", symbol: "sparkles") { [weak self] in self?.show(.codex) })
    }
    private func icon(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        let button = ScrivUIKitTheme.button("", symbol: symbol, action: action)
        button.accessibilityLabel = label; button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 7, bottom: 8, trailing: 7)
        return button
    }
    private func projectMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Projects…", image: UIImage(systemName: "folder")) { [weak self] _ in self?.show(.projects) },
            UIAction(title: "New project", image: UIImage(systemName: "plus")) { [weak self] _ in self?.store.newProject() },
            UIAction(title: "Open…", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in self?.store.openProject() },
            UIAction(title: "Rename…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.renameProject() },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Import script…") { [weak self] _ in self?.store.importScript() },
                UIAction(title: "Export script…") { [weak self] _ in self?.store.exportScript() },
                UIAction(title: "Export project…") { [weak self] _ in self?.store.exportProject() }
            ])
        ])
    }
    private func renameProject() {
        let context = store.navigationContext
        let alert = UIAlertController(title: "Rename project", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = self.store.project.title }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            guard let self, self.store.navigationContext == context else { return }
            self.store.setProjectTitle(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }
    @objc private func changeTab() {
        guard WorkspaceTab.allCases.indices.contains(tabs.selectedSegmentIndex) else { return }
        UIKitPresentation.finishEditing(); store.tab = WorkspaceTab.allCases[tabs.selectedSegmentIndex]
    }
    private func child(_ route: ScrivUIKitRoute) -> UIViewController {
        if let existing = cached[route.kind] { return existing }
        guard let controller = ScrivUIKitRouter.shared.controller(for: route, store: store) else {
            preconditionFailure("Missing required UIKit workspace route: \(route.kind)")
        }
        cached[route.kind] = controller; return controller
    }
    private func installContent() {
        for controller in children where controller !== discussion {
            controller.willMove(toParent: nil); content.removeArrangedSubview(controller.view)
            controller.view.removeFromSuperview(); controller.removeFromParent()
        }
        let controllers: [UIViewController]
        switch store.tab {
        case .script: controllers = [child(.script), child(.preview)]
        case .characters: controllers = [child(.script), child(.characters)]
        case .storyboard: controllers = [child(.storyboard)]
        }
        for controller in controllers {
            addChild(controller); content.addArrangedSubview(controller.view); controller.didMove(toParent: self)
            controller.view.layer.cornerRadius = 16; controller.view.clipsToBounds = true
        }
        if controllers.count == 2 {
            controllers[0].view.widthAnchor.constraint(equalTo: controllers[1].view.widthAnchor, multiplier: store.tab == .script ? 1.55 : 1.1).isActive = true
        }
        installedTab = store.tab
    }
    private func updateDiscussion() {
        if store.showDiscussion, discussion == nil {
            let panel = ScrivDiscussionController(store: store); discussion = panel
            let dock = UIView(); discussionDock = dock
            dock.widthAnchor.constraint(equalToConstant: 368).isActive = true
            workspaceBody.addArrangedSubview(dock)
            addChild(panel); dock.addSubview(panel.view); panel.didMove(toParent: self)
            panel.view.translatesAutoresizingMaskIntoConstraints = false
            panel.view.backgroundColor = ScrivUIKitTheme.panel
            panel.view.layer.cornerRadius = 16; panel.view.clipsToBounds = true
            let height = panel.view.heightAnchor.constraint(equalToConstant: panel.preferredContentSize.height > 0 ? panel.preferredContentSize.height : 515)
            height.priority = .defaultHigh; discussionHeight = height
            NSLayoutConstraint.activate([
                panel.view.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
                panel.view.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
                panel.view.topAnchor.constraint(equalTo: dock.topAnchor),
                panel.view.bottomAnchor.constraint(lessThanOrEqualTo: dock.bottomAnchor), height
            ])
        } else if !store.showDiscussion, let panel = discussion {
            panel.willMove(toParent: nil); panel.view.removeFromSuperview(); panel.removeFromParent(); discussion = nil
            if let dock = discussionDock { workspaceBody.removeArrangedSubview(dock); dock.removeFromSuperview() }
            discussionDock = nil; discussionHeight = nil
        }
        if let panel = discussion, panel.preferredContentSize.height > 0 { discussionHeight?.constant = panel.preferredContentSize.height }
    }
    override func preferredContentSizeDidChange(forChildContentContainer container: any UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        if let panel = discussion, container === panel { discussionHeight?.constant = max(200,panel.preferredContentSize.height) }
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Save", action: #selector(saveProject), input: "s", modifierFlags: .command),
         UIKeyCommand(title: "New project", action: #selector(newProject), input: "n", modifierFlags: .command),
         UIKeyCommand(title: "Open project", action: #selector(openProject), input: "o", modifierFlags: .command),
         UIKeyCommand(title: "Undo", action: #selector(undoProject), input: "z", modifierFlags: .command),
         UIKeyCommand(title: "Redo", action: #selector(redoProject), input: "z", modifierFlags: [.command,.shift])]
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undoProject) || action == #selector(redoProject) {
            guard !ScrivKeyboardTextContext.state(for:ScrivKeyboardTextContext.firstResponder()).editingText else { return false }
            return action == #selector(undoProject) ? store.canUndo : store.canRedo
        }
        return super.canPerformAction(action,withSender:sender)
    }
    @objc private func saveProject() { UIKitPresentation.finishEditing(); store.saveProject() }
    @objc private func newProject() { store.newProject() }
    @objc private func openProject() { store.openProject() }
    @objc private func undoProject() { store.undo() }
    @objc private func redoProject() { store.redo() }
}
