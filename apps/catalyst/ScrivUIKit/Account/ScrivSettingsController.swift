import UIKit
import Combine
import UniformTypeIdentifiers
import ScrivCore

@MainActor
class ScrivSettingsController: ScrivScreenController, UIDocumentPickerDelegate, UITextFieldDelegate, UIPopoverPresentationControllerDelegate {
    private let content = AccountUI.stack(spacing: 22)
    private let accountContent = AccountUI.stack(spacing: 14)
    private let follow = UISwitch()
    private let server = AccountUI.field("https://your-scriv-service", height: 32)
    private let executable = AccountUI.field("automatic", height: 32)
    private let endpoint = AccountUI.field("ws://127.0.0.1:4500", height: 32)
    private var serverExpanded = false
    private var serverDraft: String?
    private var working = false
    private var connectionTask: Task<Void, Never>?
    private var connectionAttempt: UUID?
    private var localError: String?
    private var choosingPairing = false
    private var choosingHistory = false
    private var runtimeOnly = false
    private let pane: ScrivSettingsPane
    private let prepareLocalRuntime: (@MainActor (UIViewController) async throws -> Void)?
    private var accountKey = ""
    private var accountName: UILabel?
    private var accountDetails: UILabel?
    private var setupView: ScrivCodexSetupView?
    private var previousNavigationBarHidden: Bool?
    init(store: WorkspaceStore, runtimeOnly: Bool = false, pane: ScrivSettingsPane = .general,
         prepareLocalRuntime: (@MainActor (UIViewController) async throws -> Void)? = nil) {
        self.runtimeOnly = runtimeOnly; self.pane = pane; self.prepareLocalRuntime = prepareLocalRuntime; super.init(store: store, scopeToProject: false)
        preferredContentSize = runtimeOnly ? ScrivCodexSetupView.preferredPopupSize : CGSize(width: 640, height: 800)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = runtimeOnly ? "Codex on this Mac" : pane.title
        view.backgroundColor = runtimeOnly ? .systemBackground : .systemGroupedBackground
        follow.addAction(UIAction { [weak self] _ in guard let self else { return }; self.store.followPlayback = self.follow.isOn }, for: .valueChanged)
        server.addAction(UIAction { [weak self] _ in self?.serverDraft = self?.server.text }, for: .editingChanged)
        server.text = store.cloudBaseURL; executable.text = store.codex.executablePath; endpoint.text = store.codex.endpoint
        for field in [server, executable, endpoint] { field.delegate = self; field.autocapitalizationType = .none; field.font = .systemFont(ofSize: 13) }
        if runtimeOnly || pane == .codex {
            installCodexSetup()
            store.codex.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.storeDidChange() }.store(in: &subscriptions)
            storeDidChange()
            return
        }
        _ = AccountUI.installScroll(in: self, content: content)
        switch pane {
        case .general:
            buildGeneral()
        case .account:
            content.addArrangedSubview(AccountUI.stack([AccountUI.label("Scriv account", size: 18, weight: .semibold), AccountUI.card(accountContent, tint: .secondarySystemGroupedBackground), AccountUI.label("Sign out before changing servers.", size: 12, color: ScrivUIKitTheme.secondary)], spacing: 8))
        case .codex: break // Installed above, directly inside this native pane.
        }
        storeDidChange()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if runtimeOnly, let navigationController {
            if previousNavigationBarHidden == nil { previousNavigationBarHidden = navigationController.isNavigationBarHidden }
            navigationController.setNavigationBarHidden(true, animated: false)
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if runtimeOnly, isBeingDismissed || navigationController?.isBeingDismissed == true { cancelPendingConnectionCheck() }
        if let previousNavigationBarHidden {
            navigationController?.setNavigationBarHidden(previousNavigationBarHidden, animated: false)
            self.previousNavigationBarHidden = nil
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { if runtimeOnly { cancelPendingConnectionCheck() } }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
    override func closeFromEscape() { if runtimeOnly { cancelPendingConnectionCheck() }; dismiss(animated: true) }
    func cancelPendingConnectionCheck() {
        guard let connectionTask else { return }
        connectionTask.cancel()
        // A cancelled task can still be unwinding after another surface starts
        // a new attempt. Only cancel the global check this controller owns.
        guard let connectionAttempt, store.codex.connectionCheck.accepts(connectionAttempt) else { return }
        store.codex.cancelConnectionCheck()
    }
    private func installCodexSetup() {
        // Both surfaces present the same runtime. Construction is read-only;
        // connection, consent, account and pairing work need explicit actions.
        let setup = ScrivCodexSetupView(executable: executable, endpoint: endpoint,
                                       progress: ScrivGenerationProgressView(controller: store.codex),
                                       surface: runtimeOnly ? .popup : .settings)
        setupView = setup; setup.scrivPinEdges(to: view)
        setup.onDone = { [weak self] in self?.cancelPendingConnectionCheck(); self?.dismiss(animated: true) }
        setup.onAdvanced = { [weak self] in self?.openAdvancedSettings() }
        setup.onCheck = { [weak self] in self?.checkConnection() }
        setup.onCancelCheck = { [weak self] in self?.connectionTask?.cancel(); self?.store.codex.cancelConnectionCheck() }
        setup.onRefreshAccount = { [weak self] in self?.run { [weak self] in await self?.store.codex.checkAndConnect() } }
        setup.onGuide = { UIApplication.shared.open(URL(string: "https://learn.chatgpt.com/docs/cli")!) }
        setup.onOpen = { [weak self] in self?.run { [weak self] in try await self?.store.codex.openRuntimeCompanion() } }
        setup.onPair = { [weak self] in self?.pick(pairing: true) }
        setup.onStart = { [weak self] in self?.run { [weak self] in guard let self else { return }; self.saveRuntimeFields(); try await self.store.codex.start() } }
        setup.onConnect = { [weak self] in self?.run { [weak self] in guard let self else { return }; self.saveRuntimeFields(); try await self.store.codex.connect() } }
        setup.onStop = { [weak self] in
            guard let self else { return }
            if self.store.codex.isRunning { self.store.codex.stop() } else { self.store.codex.disconnect() }
        }
        setup.onChooseExecutable = { [weak self] in self?.pick(pairing: false) }
        setup.onAccount = { [weak self] in self?.accountAction() }
        setup.onRotate = { [weak self] in self?.confirmRotate() }
        setup.onForget = { [weak self] in self?.confirmForget() }
        setup.onHistory = { [weak self] in self?.pickHistory() }
        setup.onJobs = { [weak self] in self?.show(.generationJobs) }
    }
    private func buildGeneral() {
        let followRow = AccountUI.stack([AccountUI.label("Follow active line during playback", size: 14), follow], horizontal: true); follow.setContentHuggingPriority(.required, for: .horizontal)
        let fileActions = AccountUI.stack([AccountUI.link("Show package…") { [weak self] in self?.revealPackage() }, AccountUI.button("Export project…") { [weak self] in self?.store.exportProject() }], spacing: 8, horizontal: true)
        let files = ScrivSecondaryAdaptiveRow([AccountUI.label("Local project package", size: 14), fileActions], minimumHorizontalWidth: 500, spacing: 10)
        content.addArrangedSubview(AccountUI.stack([AccountUI.label("General", size: 18, weight: .semibold), AccountUI.card(AccountUI.stack([followRow, AccountUI.divider(), files], spacing: 10), tint: .secondarySystemGroupedBackground), AccountUI.label("Changes save automatically.", size: 12, color: ScrivUIKitTheme.secondary)], spacing: 8))
    }
    override func storeDidChange() {
        guard isViewLoaded else { return }; follow.setOn(store.followPlayback, animated: false)
        if !runtimeOnly, pane == .account { buildAccountIfNeeded() }
        if runtimeOnly || pane == .codex { updateRuntime() }
    }
    private func buildAccountIfNeeded() {
        guard !runtimeOnly else { return }
        let key = "\(store.account?.id ?? "local")-\(serverExpanded)"
        if accountKey != key {
            accountKey = key; AccountUI.clear(accountContent)
            let name = AccountUI.label(store.account?.name ?? "Write locally, or sign in", size: 16, weight: .semibold), details = AccountUI.label(store.account == nil ? "Free script storage and team access" : "Signed in", size: 12, color: ScrivUIKitTheme.secondary)
            accountName = name; accountDetails = details
            let action = AccountUI.button(store.account == nil ? "Sign in" : "Sign out", primary: store.account == nil) { [weak self] in guard let self else { return }; if self.store.account == nil { self.show(.signIn) } else { self.store.signOut() } }
            accountContent.addArrangedSubview(AccountUI.stack([AccountUI.avatar(store.account?.name ?? "S"), AccountUI.stack([name, details], spacing: 4), action], horizontal: true))
            accountContent.addArrangedSubview(AccountUI.divider())
            accountContent.addArrangedSubview(AccountUI.link("Server settings", symbol: serverExpanded ? "chevron.down" : "chevron.right") { [weak self] in guard let self else { return }; self.view.endEditing(true); self.serverExpanded.toggle(); self.storeDidChange() })
            if serverExpanded {
                accountContent.addArrangedSubview(server)
                let save = AccountUI.button("Save address") { [weak self] in guard let self, self.store.account == nil else { return }; self.store.cloudBaseURL = self.server.text ?? ""; self.serverDraft = nil }
                save.isEnabled = store.account == nil; accountContent.addArrangedSubview(save)
                accountContent.addArrangedSubview(AccountUI.label("Use your Scriv service's HTTPS address. Changing servers cancels any pending sign-in.", size: 12, color: ScrivUIKitTheme.secondary))
            }
        }
        accountName?.text = store.account?.name ?? "Write locally, or sign in"; server.isEnabled = store.account == nil
        if serverDraft == nil, !server.isFirstResponder { server.text = store.cloudBaseURL }
    }
    private func openAdvancedSettings() {
        guard runtimeOnly, !(navigationController ?? self).isBeingDismissed,
              let presenter = (navigationController ?? self).presentingViewController else { return }
        cancelPendingConnectionCheck()
        let store = store
        // Finish dismissing the popup before opening/focusing Settings. This
        // avoids a second setup sheet and leaves the workspace unobscured.
        dismiss(animated: true) {
            ScrivUIKitRouter.shared.present(.codexSettings, from: presenter, store: store)
        }
    }
    private func updateRuntime() {
        let controller = store.codex
        if let setupView {
            let presentation = ScrivCodexSetupPresentation(controller: controller, working: working)
            if runtimeOnly {
                let size = ScrivCodexSetupView.preferredSize(available: presentingViewController?.view.bounds.size ?? navigationController?.presentingViewController?.view.bounds.size, accessibility: traitCollection.preferredContentSizeCategory.isAccessibilityCategory)
                preferredContentSize = size; navigationController?.preferredContentSize = size
            }
            setupView.update(presentation,
                             error: localError ?? controller.lastError, journalError: controller.journalError,
                             log: controller.log)
            setupView.modelButton.menu = UIMenu(children: controller.availableModels.map { model in
                UIAction(title: model, state: model == controller.selectedModel ? .on : .off) { [weak self] _ in
                    guard let self, !self.working, !self.store.codex.isGenerating,
                          self.store.codex.availableModels.contains(model) else { return }
                    self.store.codex.selectedModel = model
                }
            })
            if !executable.isFirstResponder { executable.text = controller.executablePath }
            if !endpoint.isFirstResponder { endpoint.text = controller.endpoint }
            return
        }
    }
    private func saveRuntimeFields() {
        guard !runtimeOnly, !store.codex.isConnected, !store.codex.isConnecting else { return }
        store.codex.executablePath = executable.text ?? ""; store.codex.endpoint = endpoint.text ?? ""
    }
    private func confirmRotate() {
        guard !working, !store.codex.isRunning, !store.codex.isConnected, !store.codex.isConnecting else { return }
        let alert = UIAlertController(title: "Replace local pairing?", message: "Stop Codex first. This revokes the saved capability for every paired Scriv window. You will need to import the companion's new pairing file. No ChatGPT credentials change.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rotate pairing", style: .destructive) { [weak self] _ in self?.run { [weak self] in try await self?.store.codex.rotateRuntimePairing() } })
        present(alert, animated: true)
    }
    private func confirmForget() {
        guard !working, !store.codex.isRunning, !store.codex.isConnected, !store.codex.isConnecting else { return }
        let alert = UIAlertController(title: "Forget this app's pairing?", message: "Only Scriv's saved copy is removed. The companion's private pairing file and your ChatGPT credentials stay unchanged. Choose the original file again to reconnect.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Forget local pairing", style: .destructive) { [weak self] _ in
            guard let self, !self.working, !self.store.codex.isRunning, !self.store.codex.isConnected, !self.store.codex.isConnecting else { return }
            self.store.codex.forgetRuntimePairing()
        })
        present(alert, animated: true)
    }
    private func accountAction() {
        let controller = store.codex
        if controller.accountLabel != nil {
            let alert = UIAlertController(title: "ChatGPT on this Mac", message: controller.accountLabel, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Refresh account", style: .default) { [weak self] _ in self?.run { try await controller.readAccount() } })
            alert.addAction(UIAlertAction(title: "Sign out of ChatGPT", style: .destructive) { [weak self] _ in self?.run { try await controller.signOut() } })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
        } else { run { if controller.pendingLoginID != nil { try await controller.cancelSignIn() } else { try await controller.signIn() } } }
    }
    private func checkConnection() {
        guard connectionTask == nil else { return }
        connectionTask = run { [weak self] in
            guard let self else { return }
            defer { self.connectionTask = nil; self.connectionAttempt = nil }
            try Task.checkCancellation()
            self.saveRuntimeFields()
            await self.store.codex.checkAndConnect(prepareLocalRuntime: { [weak self] in
                guard let self else { throw CancellationError() }
                self.connectionAttempt = self.store.codex.connectionCheck.attempt
                if let prepareLocalRuntime = self.prepareLocalRuntime { try await prepareLocalRuntime(self); return }
                let bootstrap = ScrivRuntimeBootstrapCoordinator()
                // The runtime retains its helper beyond either UI surface.
                self.store.codex.releaseBundledRuntime = { bootstrap.cancel() }
                try await bootstrap.prepare(from: self)
            })
        }
    }
    @discardableResult
    private func run(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Never>? {
        guard !working else { return nil }; working = true; localError = nil; updateRuntime()
        return Task { [weak self] in
            defer { self?.working = false; self?.storeDidChange() }
            do { try await operation() } catch is CancellationError {} catch { self?.localError = error.localizedDescription }
        }
    }
    private func pickHistory() {
        guard !store.codex.isConnected, !store.codex.isConnecting else { localError = "Disconnect Codex before choosing existing generation history."; updateRuntime(); return }
        let alert = UIAlertController(title: "Use the original generation history?", message: "Choose the original Scriv/Generation folder. Jobs and artifacts stay in place with their original identity. New jobs will also save there. No project, original image or captured prompt is deleted or replaced.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Choose original folder…", style: .default) { [weak self] _ in
            guard let self else { return }; self.choosingHistory = true; self.choosingPairing = false
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false); picker.delegate = self; picker.allowsMultipleSelection = false; picker.title = "Choose Scriv/Generation"; self.present(picker, animated: true)
        }); present(alert, animated: true)
    }
    private func pick(pairing: Bool) {
        guard !store.codex.isConnected, !store.codex.isConnecting else { return }; choosingPairing = pairing; choosingHistory = false
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false); picker.delegate = self; picker.allowsMultipleSelection = false
        picker.title = pairing ? "Choose Pair with Scriv.scrivbridge" : "Choose the installed Codex executable"
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, !store.codex.isConnected, !store.codex.isConnecting else { return }
        if choosingHistory {
            do { try store.codex.useExistingGenerationFolder(url); localError = nil } catch { localError = error.localizedDescription }
        } else if choosingPairing { do { try store.codex.importRuntimePairing(from: url); localError = nil } catch { localError = error.localizedDescription } }
        else { executable.text = url.path; store.codex.executablePath = url.path }
        storeDidChange()
    }
    func textFieldDidEndEditing(_ textField: UITextField) { if textField !== server { saveRuntimeFields() } }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }
    private func revealPackage() {
        guard let url = store.projectURL else { return }
        UIKitFileAccess.shared.choose(types: [.folder, UIKitFileAccess.projectType], directory: url.deletingLastPathComponent(), from: self) { _ in }
        // Browsing here is read-only. Choosing a folder never replaces the project.
    }
}

@MainActor
final class ScrivCodexController: ScrivSettingsController {
    init(store: WorkspaceStore) { super.init(store: store, runtimeOnly: true) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
}
