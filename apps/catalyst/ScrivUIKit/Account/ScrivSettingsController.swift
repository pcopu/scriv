import UIKit
import Combine
import UniformTypeIdentifiers
import ScrivCore

@MainActor
class ScrivSettingsController: ScrivScreenController, UIDocumentPickerDelegate, UITextFieldDelegate {
    private let content = AccountUI.stack(spacing: 24)
    private let runtimeContent = AccountUI.stack(spacing: 14)
    private let accountContent = AccountUI.stack(spacing: 14)
    private let follow = UISwitch()
    private let server = AccountUI.field("https://your-scriv-service")
    private let executable = AccountUI.field("/opt/homebrew/bin/codex")
    private let endpoint = AccountUI.field("ws://127.0.0.1:4500")
    private var serverExpanded = false
    private var advancedExpanded = true
    private var working = false
    private var localError: String?
    private var choosingPairing = false
    private var choosingHistory = false
    private var runtimeOnly = false
    private var renderKey = ""
    private var accountKey = ""
    private var statusLabel: UILabel?
    private var modelButton: UIButton?
    private var runtimeErrorLabel: UILabel?
    private var buttons: [String: UIButton] = [:]
    private var accountName: UILabel?
    private var accountDetails: UILabel?
    init(store: WorkspaceStore, runtimeOnly: Bool = false) {
        self.runtimeOnly = runtimeOnly; super.init(store: store, scopeToProject: false)
        preferredContentSize = CGSize(width: 640, height: runtimeOnly ? 650 : 800)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = runtimeOnly ? "Codex on this Mac" : "Settings"; view.backgroundColor = AccountUI.inset.withAlphaComponent(0.3)
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        _ = AccountUI.installScroll(in: self, content: content)
        follow.addAction(UIAction { [weak self] _ in guard let self else { return }; self.store.followPlayback = self.follow.isOn }, for: .valueChanged)
        server.text = store.cloudBaseURL; executable.text = store.codex.executablePath; endpoint.text = store.codex.endpoint
        for field in [server, executable, endpoint] { field.delegate = self; field.autocapitalizationType = .none; field.font = .systemFont(ofSize: 13) }
        if !runtimeOnly { buildGeneral(); content.addArrangedSubview(AccountUI.label("Scriv account", size: 18, weight: .semibold)); content.addArrangedSubview(AccountUI.card(accountContent)); content.addArrangedSubview(AccountUI.label("Sign out before changing servers.", size: 12, color: .secondaryLabel)) }
        content.addArrangedSubview(AccountUI.label("Codex on this Mac", size: 18, weight: .semibold)); content.addArrangedSubview(AccountUI.card(runtimeContent))
        content.addArrangedSubview(ScrivGenerationProgressView(controller: store.codex))
        content.addArrangedSubview(AccountUI.label("Credentials stay on this Mac. Disconnecting an external server leaves it running.", size: 12, color: .secondaryLabel))
        content.addArrangedSubview(AccountUI.link("Generation jobs", symbol: "clock.arrow.circlepath") { [weak self] in self?.show(.generationJobs) })
        content.addArrangedSubview(AccountUI.link("Use existing generation history…", symbol: "folder") { [weak self] in self?.pickHistory() })
        store.codex.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.storeDidChange() }.store(in: &subscriptions)
        storeDidChange()
    }
    private func buildGeneral() {
        content.addArrangedSubview(AccountUI.label("General", size: 18, weight: .semibold))
        let followRow = AccountUI.stack([AccountUI.label("Follow active line during playback", size: 14), follow], horizontal: true); follow.setContentHuggingPriority(.required, for: .horizontal)
        let files = AccountUI.stack([AccountUI.label("Local project package", size: 14), AccountUI.button("Show package…") { [weak self] in self?.revealPackage() }, AccountUI.button("Export project…") { [weak self] in self?.store.exportProject() }], spacing: 10, horizontal: true)
        content.addArrangedSubview(AccountUI.card(AccountUI.stack([followRow, AccountUI.divider(), files])))
        content.addArrangedSubview(AccountUI.label("Changes save automatically.", size: 12, color: .secondaryLabel))
    }
    override func storeDidChange() {
        guard isViewLoaded else { return }; follow.setOn(store.followPlayback, animated: false)
        buildAccountIfNeeded(); buildRuntimeIfNeeded(); updateRuntime()
    }
    private func buildAccountIfNeeded() {
        guard !runtimeOnly else { return }
        let key = "\(store.account?.id ?? "local")-\(serverExpanded)"
        if accountKey != key {
            accountKey = key; AccountUI.clear(accountContent)
            let name = AccountUI.label(store.account?.name ?? "Write locally, or sign in", size: 16, weight: .semibold), details = AccountUI.label(store.account == nil ? "Free script storage and team access" : "Signed in", size: 12, color: .secondaryLabel)
            accountName = name; accountDetails = details
            let action = AccountUI.button(store.account == nil ? "Sign in" : "Sign out", primary: store.account == nil) { [weak self] in guard let self else { return }; if self.store.account == nil { self.show(.signIn) } else { self.store.signOut() } }
            accountContent.addArrangedSubview(AccountUI.stack([AccountUI.avatar(store.account?.name ?? "S"), AccountUI.stack([name, details], spacing: 4), action], horizontal: true))
            accountContent.addArrangedSubview(AccountUI.divider())
            accountContent.addArrangedSubview(AccountUI.link("Server settings", symbol: serverExpanded ? "chevron.down" : "chevron.right") { [weak self] in guard let self else { return }; self.view.endEditing(true); self.serverExpanded.toggle(); self.storeDidChange() })
            if serverExpanded {
                accountContent.addArrangedSubview(server)
                let save = AccountUI.button("Save address") { [weak self] in guard let self, self.store.account == nil else { return }; self.store.cloudBaseURL = self.server.text ?? "" }
                save.isEnabled = store.account == nil; accountContent.addArrangedSubview(save)
                accountContent.addArrangedSubview(AccountUI.label("Use your Scriv service's HTTPS address. Changing servers cancels any pending sign-in.", size: 12, color: .secondaryLabel))
            }
        }
        accountName?.text = store.account?.name ?? "Write locally, or sign in"; server.isEnabled = store.account == nil
        if !server.isFirstResponder { server.text = store.cloudBaseURL }
    }
    private func buildRuntimeIfNeeded() {
        let controller = store.codex
        let key = "\(controller.isConnected)-\(controller.accountChecked)-\(controller.accountLabel ?? "")-\(controller.pendingLoginID != nil)-\(controller.isRunning)-\(controller.isGenerating)-\(advancedExpanded)-\(controller.bridgePaired)"
        guard key != renderKey else { return }; renderKey = key; AccountUI.clear(runtimeContent); buttons = [:]
        let status = AccountUI.label(controller.status, size: 14, weight: .medium); statusLabel = status; runtimeContent.addArrangedSubview(status)
        runtimeContent.addArrangedSubview(AccountUI.divider())
        let identity = AccountUI.stack([AccountUI.label("ChatGPT", size: 15, weight: .semibold), AccountUI.label(!controller.isConnected ? "Start or Connect to check your existing local sign-in" : !controller.accountChecked ? "Checking this runtime’s existing account…" : controller.pendingLoginID != nil ? "Complete sign-in in your browser" : controller.accountLabel ?? "This runtime reports no signed-in account", size: 12, color: .secondaryLabel)], spacing: 4)
        let accountButton = AccountUI.button(!controller.isConnected ? "Not connected" : !controller.accountChecked ? "Checking…" : controller.accountLabel != nil ? "Manage…" : controller.pendingLoginID != nil ? "Cancel sign-in" : "Sign in") { [weak self] in self?.accountAction() }
        buttons["account"] = accountButton
        runtimeContent.addArrangedSubview(AccountUI.stack([AccountUI.symbol("sparkles", size: 38), identity, accountButton], horizontal: true)); runtimeContent.addArrangedSubview(AccountUI.divider())
        let model = AccountUI.button("Choose available model") {}; modelButton = model; model.showsMenuAsPrimaryAction = true
        runtimeContent.addArrangedSubview(AccountUI.stack([AccountUI.label("Selected model", size: 14), model], horizontal: true))
        let start = AccountUI.button("Start", primary: true) { [weak self] in self?.run { [weak self] in guard let self else { return }; self.saveRuntimeFields(); try await self.store.codex.start() } }
        let connect = AccountUI.button("Connect") { [weak self] in self?.run { [weak self] in guard let self else { return }; self.saveRuntimeFields(); try await self.store.codex.connect() } }
        let stop = AccountUI.button(controller.isRunning ? "Stop" : "Disconnect") { [weak self] in self?.store.codex.disconnect() }
        buttons["start"] = start; buttons["connect"] = connect; buttons["stop"] = stop
        let controls = AccountUI.stack([start, connect, stop], spacing: 8, horizontal: true); controls.distribution = .fillEqually; runtimeContent.addArrangedSubview(controls)
        if !controller.isConnected {
            runtimeContent.addArrangedSubview(AccountUI.notice(controller.bridgePaired ? "A local pairing is saved. Open the companion before Start. The pairing survives restarts. Re-pair only if it was explicitly rotated. Connect uses an already-running loopback Codex server instead." : "Start requires the separately installed, signed Scriv Runtime Companion. Open it yourself, then select its private pairing file. No helper is downloaded, installed or started automatically.", warning: !controller.bridgePaired))
            let open = AccountUI.button("Open companion") { [weak self] in self?.run { [weak self] in try await self?.store.codex.openRuntimeCompanion() } }
            let pair = AccountUI.button("Pair companion…") { [weak self] in self?.pick(pairing: true) }; buttons["pair"] = pair
            runtimeContent.addArrangedSubview(AccountUI.stack([open, pair], horizontal: true))
            if controller.bridgePaired {
                runtimeContent.addArrangedSubview(AccountUI.link("Rotate local pairing…") { [weak self] in self?.confirmRotate() })
                runtimeContent.addArrangedSubview(AccountUI.link("Forget local pairing") { [weak self] in self?.store.codex.forgetRuntimePairing() })
            }
        }
        runtimeContent.addArrangedSubview(AccountUI.divider())
        runtimeContent.addArrangedSubview(AccountUI.link("Advanced connection", symbol: advancedExpanded ? "chevron.down" : "chevron.right") { [weak self] in guard let self else { return }; self.saveRuntimeFields(); self.advancedExpanded.toggle(); self.storeDidChange() })
        if advancedExpanded {
            runtimeContent.addArrangedSubview(AccountUI.label("Codex executable", size: 12, weight: .medium, color: .secondaryLabel))
            let choose = AccountUI.button("Choose…") { [weak self] in self?.pick(pairing: false) }; buttons["choose"] = choose
            runtimeContent.addArrangedSubview(AccountUI.stack([executable, choose], spacing: 8, horizontal: true))
            runtimeContent.addArrangedSubview(AccountUI.label("External local server", size: 12, weight: .medium, color: .secondaryLabel)); runtimeContent.addArrangedSubview(endpoint)
            runtimeContent.addArrangedSubview(AccountUI.label("Only this Mac's loopback interface is permitted. The companion never launches an external server.", size: 12, color: .secondaryLabel))
        }
        let error = AccountUI.label("", size: 12, color: .systemRed); runtimeErrorLabel = error; runtimeContent.addArrangedSubview(error)
        if let issue = controller.journalError { runtimeContent.addArrangedSubview(AccountUI.notice(issue)) }
        if runtimeOnly, !controller.log.isEmpty {
            let response = UITextView(); response.isEditable = false; response.text = controller.log; response.font = .monospacedSystemFont(ofSize: 11, weight: .regular); response.heightAnchor.constraint(equalToConstant: 150).isActive = true
            runtimeContent.addArrangedSubview(AccountUI.label("Generation response", size: 13, weight: .semibold)); runtimeContent.addArrangedSubview(response)
        }
    }
    private func updateRuntime() {
        let controller = store.codex
        statusLabel?.text = controller.isConnected && !controller.isGenerating && controller.pendingLoginID == nil ? controller.isRunning ? "● Connected · started by Scriv" : "● Connected · external server" : controller.status
        statusLabel?.textColor = controller.isGenerating ? .systemOrange : controller.isConnected ? .systemGreen : .secondaryLabel
        modelButton?.configuration?.title = controller.selectedModel.isEmpty ? "Choose available model" : controller.selectedModel
        modelButton?.menu = UIMenu(children: controller.availableModels.map { model in UIAction(title: model, state: model == controller.selectedModel ? .on : .off) { [weak self] _ in guard let self, !self.store.codex.isGenerating else { return }; self.store.codex.selectedModel = model } })
        modelButton?.isEnabled = !working && !controller.isGenerating && !controller.availableModels.isEmpty
        buttons["account"]?.isEnabled = !working && controller.isConnected && controller.accountChecked && !controller.isGenerating
        buttons["start"]?.isEnabled = !working && !controller.isConnecting && !controller.isConnected && controller.bridgePaired
        buttons["connect"]?.isEnabled = !working && !controller.isConnecting && !controller.isConnected
        buttons["stop"]?.isEnabled = controller.isRunning || (!controller.isGenerating && (controller.isConnected || controller.isConnecting))
        let editable = !working && !controller.isConnecting && !controller.isConnected
        executable.isEnabled = editable; endpoint.isEnabled = editable; buttons["choose"]?.isEnabled = editable; buttons["pair"]?.isEnabled = editable
        if !executable.isFirstResponder { executable.text = controller.executablePath }; if !endpoint.isFirstResponder { endpoint.text = controller.endpoint }
        runtimeErrorLabel?.text = localError ?? controller.lastError; runtimeErrorLabel?.isHidden = runtimeErrorLabel?.text?.isEmpty != false
    }
    private func saveRuntimeFields() { guard !store.codex.isConnected, !store.codex.isConnecting else { return }; store.codex.executablePath = executable.text ?? ""; store.codex.endpoint = endpoint.text ?? "" }
    private func confirmRotate() {
        let alert = UIAlertController(title: "Replace local pairing?", message: "Stop Codex first. This revokes the saved capability for every paired Scriv window. You will need to import the companion's new pairing file. No ChatGPT credentials change.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rotate pairing", style: .destructive) { [weak self] _ in self?.run { [weak self] in try await self?.store.codex.rotateRuntimePairing() } })
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
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }; working = true; localError = nil; updateRuntime()
        Task { [weak self] in defer { self?.working = false; self?.storeDidChange() }; do { try await operation() } catch is CancellationError {} catch { self?.localError = error.localizedDescription } }
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
