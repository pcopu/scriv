import UIKit
import ScrivCore

@MainActor
final class ScrivWorkspaceController: ScrivScreenController {
    private let chrome = ScrivWorkspaceHeader(frame: .zero)
    private let content = UIStackView()
    /// Reports its own layout so the stack/side-by-side decision uses this
    /// view's final width; the controller's viewDidLayoutSubviews can run before
    /// it is resized, leaving two crushed panels after the window narrows.
    private final class LayoutReportingView: UIView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    }
    private let contentContainer = LayoutReportingView()
    private let workspaceBody = UIStackView()
    private let footer = UIStackView()
    private var discussionDock: UIView?
    private var tabs: UISegmentedControl { chrome.tabs }
    private lazy var transport = AudioTransportView(store: store, compact: false)
    private let statusLabel = ScrivUIKitTheme.label("", size: 12, color: ScrivUIKitTheme.secondary)
    private var splitConstraint: NSLayoutConstraint?
    private var menuState = ""
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
        content.axis = .horizontal; content.spacing = ScrivWorkspaceLayout.panelGap; content.alignment = .fill
        content.scrivPinEdges(to: contentContainer)
        contentContainer.onLayout = { [weak self] in self?.updatePanelLayout() }
        footer.axis = .vertical; footer.spacing = 5; footer.addArrangedSubview(statusLabel)
        workspaceBody.axis = .horizontal; workspaceBody.spacing = ScrivWorkspaceLayout.panelGap; workspaceBody.alignment = .fill
        workspaceBody.addArrangedSubview(contentContainer)
        let column = ScrivUIKitTheme.stack([chrome, workspaceBody, footer], spacing: 12)
        column.setCustomSpacing(6, after: workspaceBody)
        column.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: ScrivWorkspaceLayout.outerInset),
            column.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -ScrivWorkspaceLayout.outerInset),
            column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            column.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            chrome.heightAnchor.constraint(equalToConstant: 64)
        ])
        footer.setContentHuggingPriority(.required, for: .vertical)
        storeDidChange()
    }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        chrome.configure(title: store.project.title, accountName: store.account?.name)
        chrome.isUserInteractionEnabled = !store.isBootstrapping
        workspaceBody.isUserInteractionEnabled = !store.isBootstrapping
        tabs.selectedSegmentIndex = WorkspaceTab.allCases.firstIndex(of: store.tab) ?? 0
        let status = store.statusMessage + " · " + store.syncStatus
        if statusLabel.text != status { statusLabel.text = status }
        chrome.moreButton.accessibilityValue = ScrivFormat.count(store.unreadDiscussionMentionCount, "unread discussion mention")
        updateTransport()
        // Rebuild only when menu-visible state changes, not on every playhead tick.
        let nextMenuState = "\(store.account?.id ?? "")|\(store.showDiscussion)|\(store.unreadDiscussionMentionCount)"
        if nextMenuState != menuState { menuState = nextMenuState; chrome.moreButton.menu = workspaceMenu() }
        if installedTab != store.tab { installContent() }
        updateDiscussion()
        if store.showAccountSignIn, !(presentedViewController is ScrivSignInController) {
            store.showAccountSignIn = false
            show(.signIn)
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        StartupTrace.process.record(.rootViewAppeared)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePanelLayout()
        ScrivSheetFitting.fitPresentedSheets(above: self)
    }
    private func updateTransport() {
        let shouldShow = ScrivWorkspaceLayout.usesFooterTransport(for: store.tab)
        transport.accessibilityIdentifier = "workspace-playback-transport"
        // Remove rather than collapse a transport with fixed-height internal
        // controls: UIStackView's zero-height hiding constraint would conflict.
        if !shouldShow, transport.superview != nil {
            footer.removeArrangedSubview(transport); transport.removeFromSuperview()
        }
        transport.isHidden = !ScrivWorkspaceLayout.usesFooterTransport(for: store.tab)
        if shouldShow, transport.superview == nil { footer.insertArrangedSubview(transport, at: 0) }
    }
    private func configureChrome() {
        chrome.titleButton.addAction(UIAction { [weak self] _ in self?.show(.projects) }, for: .primaryActionTriggered)
        tabs.addTarget(self, action: #selector(changeTab), for: .valueChanged)
        chrome.searchButton.addAction(UIAction { [weak self] _ in self?.findInScript() }, for: .primaryActionTriggered)
        chrome.shareButton.addAction(UIAction { [weak self] _ in self?.show(.teams) }, for: .primaryActionTriggered)
        chrome.accountButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.show(self.store.account == nil ? .signIn : .account)
        }, for: .primaryActionTriggered)
        chrome.codexButton.addAction(UIAction { [weak self] _ in self?.show(.codex) }, for: .primaryActionTriggered)
        chrome.moreButton.menu = workspaceMenu(); chrome.moreButton.showsMenuAsPrimaryAction = true
    }
    @objc func findInScript() {
        guard presentedViewController == nil else { return }
        UIKitPresentation.finishEditing()
        if store.tab != .script { store.tab = .script; installContent() }
        (child(.script) as? ScriptScreenController)?.focusSearch()
    }
    private func toggleDiscussion() {
        if store.showDiscussion { store.showDiscussion = false }
        else { store.loadDiscussion(itemId: store.discussionItemID) }
    }
    private func workspaceMenu() -> UIMenu {
        let mentions = store.unreadDiscussionMentionCount
        let discussionTitle = (store.showDiscussion ? "Hide discussion" : "Discussion") + (mentions > 0 ? " (\(mentions) unread)" : "")
        return UIMenu(children: [
            projectMenu(),
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Find in script…", image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in self?.findInScript() },
                UIAction(title: "Audio library…", image: UIImage(systemName: "waveform")) { [weak self] _ in self?.show(.audio) },
                UIAction(title: "History…", image: UIImage(systemName: "clock.arrow.circlepath")) { [weak self] _ in self?.show(.history) },
                UIAction(title: discussionTitle, image: UIImage(systemName: "bubble.left.and.bubble.right")) { [weak self] _ in self?.toggleDiscussion() },
                UIAction(title: "Teams and sharing…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.show(.teams) }
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: store.account == nil ? "Sign in…" : "Scriv account…", image: UIImage(systemName: "person.crop.circle")) { [weak self] _ in
                    guard let self else { return }; self.show(self.store.account == nil ? .signIn : .account)
                },
                UIAction(title: "Codex on this Mac…", image: UIImage(systemName: "sparkles")) { [weak self] _ in self?.show(.codex) },
                UIAction(title: "Generation history…", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.show(.generationJobs) }
            ])
        ])
    }
    private func projectMenu() -> UIMenu {
        UIMenu(title: "Project", children: [
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
        // Cached controllers return on every tab switch. Deactivate the old pair
        // before reparenting so a Script/Characters constraint cannot survive
        // into Script/Preview or accumulate on repeated navigation.
        splitConstraint?.isActive = false; splitConstraint = nil
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
        installedTab = store.tab
        updatePanelLayout()
    }
    private func updatePanelLayout() {
        let panels = content.arrangedSubviews
        let axis: NSLayoutConstraint.Axis = ScrivWorkspaceLayout.stacksWorkPanels(
            availableWidth: contentContainer.bounds.width, discussionVisible: store.showDiscussion, tab: store.tab
        ) ? .vertical : .horizontal
        guard panels.count == 2 else {
            splitConstraint?.isActive = false; splitConstraint = nil; content.axis = .horizontal
            return
        }
        guard content.axis != axis || splitConstraint == nil else { return }
        splitConstraint?.isActive = false
        content.axis = axis
        // At the supported minimum width an open discussion leaves too little
        // room for two side-by-side editors. Stack the same live controllers in
        // the work column, retaining both scroll views and every action.
        if axis == .horizontal {
            splitConstraint = panels[0].widthAnchor.constraint(equalTo: panels[1].widthAnchor, multiplier: ScrivWorkspaceLayout.scriptPanelRatio)
        } else {
            splitConstraint = panels[0].heightAnchor.constraint(equalTo: panels[1].heightAnchor, multiplier: ScrivWorkspaceLayout.scriptPanelRatio)
        }
        splitConstraint?.isActive = true
    }
    private func updateDiscussion() {
        if store.showDiscussion, discussion == nil {
            let panel = ScrivDiscussionController(store: store); discussion = panel
            let dock = UIView(); discussionDock = dock
            workspaceBody.addArrangedSubview(dock)
            let preferredWidth = dock.widthAnchor.constraint(equalTo: workspaceBody.widthAnchor, multiplier: 0.28)
            preferredWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                dock.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
                dock.widthAnchor.constraint(lessThanOrEqualToConstant: 500), preferredWidth
            ])
            addChild(panel); dock.addSubview(panel.view); panel.didMove(toParent: self)
            panel.view.translatesAutoresizingMaskIntoConstraints = false
            panel.view.backgroundColor = ScrivUIKitTheme.panel
            panel.view.layer.cornerRadius = 16; panel.view.clipsToBounds = true
            // The dock fills the work area; preferredContentSize belongs to a
            // standalone presentation and must not make the dock jump in height
            // when a conversation becomes empty or receives its first message.
            NSLayoutConstraint.activate([
                panel.view.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
                panel.view.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
                panel.view.topAnchor.constraint(equalTo: dock.topAnchor),
                panel.view.bottomAnchor.constraint(equalTo: dock.bottomAnchor)
            ])
        } else if !store.showDiscussion, let panel = discussion {
            panel.willMove(toParent: nil); panel.view.removeFromSuperview(); panel.removeFromParent(); discussion = nil
            if let dock = discussionDock { workspaceBody.removeArrangedSubview(dock); dock.removeFromSuperview() }
            discussionDock = nil
        }
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Save", action: #selector(saveProject), input: "s", modifierFlags: .command),
         UIKeyCommand(title: "New project", action: #selector(newProject), input: "n", modifierFlags: .command),
         UIKeyCommand(title: "Open project", action: #selector(openProject), input: "o", modifierFlags: .command),
         UIKeyCommand(title: "Undo", action: #selector(undoProject), input: "z", modifierFlags: .command),
         UIKeyCommand(title: "Redo", action: #selector(redoProject), input: "z", modifierFlags: [.command,.shift])]
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(findInScript) {
            let responder = ScrivKeyboardTextContext.firstResponder()
            let context = ScrivKeyboardTextContext.state(for: responder)
            // Do not steal find/composition from editable fields or modal editors.
            return presentedViewController == nil && !context.editingText && !context.markedText
        }
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
