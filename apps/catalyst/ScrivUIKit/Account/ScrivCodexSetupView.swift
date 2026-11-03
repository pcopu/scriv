import UIKit
import ScrivCore

/// Display only. A saved pairing, installed app, connected transport and checked
/// account are different facts; opening either surface never initiates a check.
struct ScrivCodexSetupPresentation {
    var paired = false
    var connected = false
    var connecting = false
    var managed = false
    var generating = false
    var accountChecked = false
    var accountLabel: String?
    var pendingLogin = false
    var working = false
    var runtimeStatus = "Stopped"
    var availableModels: [String] = []
    var selectedModel = ""
    var checkPhase: CodexConnectionCheck.Phase = .idle
    var requiresAuthentication = true

    var phase: CodexConnectionCheck.Phase {
        if connecting || checkPhase == .checking { return .checking }
        if connected && !accountChecked { return .checking }
        if connected { return accountLabel != nil || !requiresAuthentication ? .ready : .signInRequired }
        return checkPhase == .ready || checkPhase == .signInRequired ? .idle : checkPhase
    }
    var canEditConnection: Bool { !working && !connected && !connecting && !managed && phase != .checking }
    var canStart: Bool { canEditConnection && paired }
    var canConnect: Bool { canEditConnection }
    var canStop: Bool { managed || (!generating && (connected || connecting)) }
    var canManagePairing: Bool { canEditConnection && paired }
    var canUseAccount: Bool { !working && connected && accountChecked && !generating }
    var stopTitle: String { managed ? "Stop" : "Disconnect" }
    var connectionText: String {
        if generating { return runtimeStatus }
        switch phase {
        case .checking: return "Checking local connection…"
        case .notFound: return "Could not start Codex on this Mac"
        case .incompatible: return "Codex needs attention"
        case .signInRequired: return pendingLogin ? "Connected · waiting for sign-in" : "Connected · sign-in needed"
        case .ready: return "Connected"
        case .cancelled: return "Check cancelled"
        case .idle: return "Not connected"
        }
    }
    var accountText: String {
        guard connected else { return "Not checked yet" }
        guard accountChecked else { return "Checking existing account…" }
        if pendingLogin { return "Complete sign-in in your browser" }
        return accountLabel ?? (requiresAuthentication ? "Not signed in" : "Not required by this provider")
    }
    var accountActionTitle: String { accountLabel != nil ? "Manage…" : pendingLogin ? "Cancel sign-in" : "Sign in with ChatGPT" }
    var modelTitle: String {
        if connected && availableModels.isEmpty { return "No available models reported" }
        return availableModels.contains(selectedModel) ? selectedModel : "Choose available model"
    }
}

extension ScrivCodexSetupPresentation {
    @MainActor init(controller: CodexController, working: Bool) {
        self.init(paired: controller.bridgePaired, connected: controller.isConnected,
                  connecting: controller.isConnecting, managed: controller.isRunning,
                  generating: controller.isGenerating, accountChecked: controller.accountChecked,
                  accountLabel: controller.accountLabel, pendingLogin: controller.pendingLoginID != nil,
                  working: working, runtimeStatus: controller.status,
                  availableModels: controller.availableModels, selectedModel: controller.selectedModel,
                  checkPhase: controller.connectionCheck.phase,
                  requiresAuthentication: controller.requiresAccountAuthentication)
    }
}

/// The everyday connection popup and the native Settings pane share state and
/// actions. Manual setup lives only in Settings, never in a nested modal.
@MainActor
final class ScrivCodexSetupView: UIView {
    enum Surface: Equatable { case popup, settings }
    static let preferredPopupSize = CGSize(width: 360, height: 360)
    static func preferredSize(available: CGSize? = nil, accessibility: Bool = false) -> CGSize {
        var size = preferredPopupSize
        if accessibility { size.height = 480 }
        if let available, available.width > 0, available.height > 0 {
            size.width = min(size.width, max(1, available.width - 32))
            size.height = min(size.height, max(1, available.height - 32))
        }
        return size
    }
    var onDone: (() -> Void)?
    var onAdvanced: (() -> Void)?
    var onCheck: (() -> Void)?
    var onCancelCheck: (() -> Void)?
    var onRefreshAccount: (() -> Void)?
    var onOpen: (() -> Void)?
    var onPair: (() -> Void)?
    var onStart: (() -> Void)?
    var onConnect: (() -> Void)?
    var onStop: (() -> Void)?
    var onChooseExecutable: (() -> Void)?
    var onAccount: (() -> Void)?
    var onRotate: (() -> Void)?
    var onForget: (() -> Void)?
    var onHistory: (() -> Void)?
    var onJobs: (() -> Void)?
    var onGuide: (() -> Void)?

    let surface: Surface
    let header = AccountUI.stack(spacing: 6)
    let footer = AccountUI.stack(spacing: 8)
    let scroll = UIScrollView()
    let body = AccountUI.stack(spacing: 12)
    let advancedContent = AccountUI.stack(spacing: 12)
    let pairingContent = AccountUI.stack(spacing: 10)
    let modelButton = AccountUI.button("Choose available model") {}
    private let executable: UITextField
    private let endpoint: UITextField
    private let connection = AccountUI.label("Not connected", size: 13, color: .secondaryLabel)
    private let accountStatus = AccountUI.label("", size: 13, color: .secondaryLabel)
    private let hint = AccountUI.label("Scriv starts Codex on this Mac when you connect.", size: 13, color: .secondaryLabel)
    private let errorLabel = AccountUI.label("", size: 13, color: .systemRed)
    private let journalLabel = AccountUI.label("", size: 13, color: .systemOrange)
    private let accountContent = AccountUI.stack(spacing: 8)
    private let modelContent = AccountUI.stack(spacing: 6)
    private let installation = AccountUI.stack(spacing: 10)
    private let responseContent = AccountUI.stack(spacing: 6)
    private let response = UITextView()
    private var controls: [String: UIButton] = [:]
    private var installationExpanded = false
    private var pairingExpanded = false
    private var state = ScrivCodexSetupPresentation()

    init(executable: UITextField, endpoint: UITextField, progress: UIView, surface: Surface = .popup) {
        self.executable = executable; self.endpoint = endpoint; self.surface = surface
        super.init(frame: .zero)
        backgroundColor = surface == .popup ? .systemBackground : .systemGroupedBackground
        accessibilityIdentifier = surface == .popup ? "codex-connection-popup" : "codex-settings"
        buildHeader(); buildConnection(progress: progress)
        if surface == .settings { buildSettings() }
        else { buildFooter() }
        installLayout()
        update(state, error: nil, journalError: nil, log: "")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(executable:endpoint:progress:surface:)") }

    private func buildHeader() {
        let title = AccountUI.label("Codex on this Mac", size: 17, weight: .semibold, color: .label)
        title.accessibilityTraits.insert(.header)
        if surface == .popup {
            let done = button("Done", id: "done", plain: true) { [weak self] in self?.onDone?() }
            done.setContentHuggingPriority(.required, for: .horizontal)
            header.addArrangedSubview(AccountUI.stack([title, done], spacing: 12, horizontal: true))
        } else { header.addArrangedSubview(title) }
        connection.accessibilityIdentifier = "codex-connection-status"
        header.addArrangedSubview(connection)
        header.accessibilityIdentifier = "codex-setup-header"
    }
    private func buildConnection(progress: UIView) {
        body.addArrangedSubview(hint)
        accountStatus.accessibilityIdentifier = "codex-account-status"
        accountContent.addArrangedSubview(accountStatus)
        accountContent.addArrangedSubview(button("Sign in with ChatGPT", id: "account") { [weak self] in
            guard let self, self.state.canUseAccount else { return }; self.onAccount?()
        })
        accountContent.addArrangedSubview(button("Refresh account", id: "refresh-account", plain: true) { [weak self] in
            guard let self, self.state.canUseAccount, !self.state.pendingLogin else { return }; self.onRefreshAccount?()
        })
        body.addArrangedSubview(accountContent)
        modelContent.addArrangedSubview(AccountUI.label("Model", size: 12, color: .secondaryLabel))
        modelButton.showsMenuAsPrimaryAction = true; modelButton.accessibilityIdentifier = "codex-model"
        modelButton.configuration?.titleLineBreakMode = .byWordWrapping; modelButton.titleLabel?.numberOfLines = 0
        modelContent.addArrangedSubview(modelButton); body.addArrangedSubview(modelContent)
        body.addArrangedSubview(button("Connect", id: "check", primary: true) { [weak self] in
            guard let self, self.state.canConnect else { return }; self.onCheck?()
        })
        body.addArrangedSubview(button("Cancel connection", id: "cancel-check") { [weak self] in self?.onCancelCheck?() })
        body.addArrangedSubview(button("Disconnect", id: "stop") { [weak self] in
            guard let self, self.state.canStop else { return }; self.onStop?()
        })
        errorLabel.accessibilityIdentifier = "codex-setup-error"; errorLabel.accessibilityTraits.insert(.updatesFrequently)
        body.addArrangedSubview(errorLabel); body.addArrangedSubview(journalLabel); body.addArrangedSubview(progress)
    }
    private func buildFooter() {
        footer.accessibilityIdentifier = "codex-setup-footer"
        footer.addArrangedSubview(AccountUI.divider())
        let advanced = button("Advanced…", id: "advanced", plain: true) { [weak self] in self?.onAdvanced?() }
        advanced.accessibilityHint = "Opens Codex in Settings"
        footer.addArrangedSubview(advanced)
    }
    private func buildSettings() {
        body.addArrangedSubview(AccountUI.label("Your Codex account stays on this Mac. Scriv sign-in is separate. Opening Settings does not connect or sign in.", size: 12, color: .secondaryLabel))
        body.addArrangedSubview(AccountUI.divider())
        body.addArrangedSubview(button("Installation help", id: "installation-help", plain: true) { [weak self] in
            guard let self else { return }; self.installationExpanded.toggle(); self.updateDisclosures()
        })
        installation.addArrangedSubview(commandStep("Install the CLI in Terminal", command: CodexLocalSetup.installCommand, id: "copy-install"))
        installation.addArrangedSubview(commandStep("Sign in", command: CodexLocalSetup.signInCommand, id: "copy-sign-in"))
        installation.addArrangedSubview(AccountUI.label("Then choose Connect. Scriv finds and starts the local runtime for you. These commands are copied only, never run by Scriv.", size: 13, color: .secondaryLabel))
        installation.addArrangedSubview(button("Official setup guide", id: "guide", plain: true) { [weak self] in self?.onGuide?() })
        body.addArrangedSubview(installation)
        body.addArrangedSubview(AccountUI.divider())
        body.addArrangedSubview(advancedContent)
        executable.accessibilityLabel = "Installed Codex executable"; endpoint.accessibilityLabel = "Saved loopback server address"
        advancedContent.addArrangedSubview(AccountUI.label("Manual connection", size: 16, weight: .semibold, color: .label))
        advancedContent.addArrangedSubview(AccountUI.label("Connect needs no server address. Use these settings only for a separately started local WebSocket server. Disconnect leaves that server running.", size: 13, color: .secondaryLabel))
        advancedContent.addArrangedSubview(AccountUI.stack([AccountUI.label("Custom local app-server address (optional)", size: 13, color: .label), endpoint], spacing: 6))
        advancedContent.addArrangedSubview(button("Connect to this address", id: "connect") { [weak self] in
            guard let self, self.state.canConnect else { return }; self.onConnect?()
        })
        advancedContent.addArrangedSubview(commandStep("Optional: start a custom server in Terminal", command: CodexLocalSetup.serverCommand, id: "copy-server"))
        advancedContent.addArrangedSubview(AccountUI.label("Local WebSocket mode is experimental. Keep that Terminal window open.", size: 12, color: .secondaryLabel))
        advancedContent.addArrangedSubview(AccountUI.divider())
        advancedContent.addArrangedSubview(AccountUI.label("Local runtime", size: 16, weight: .semibold, color: .label))
        advancedContent.addArrangedSubview(AccountUI.label("Use “automatic” for discovery, or choose the installed Codex executable.", size: 13, color: .secondaryLabel))
        let choose = button("Choose…", id: "choose-executable") { [weak self] in
            guard let self, self.state.canEditConnection else { return }; self.onChooseExecutable?()
        }
        advancedContent.addArrangedSubview(ScrivSecondaryAdaptiveRow([executable, choose], minimumHorizontalWidth: 400, spacing: 10))
        advancedContent.addArrangedSubview(button("Separate runtime pairing", id: "pairing-controls", plain: true) { [weak self] in
            guard let self else { return }; self.pairingExpanded.toggle(); self.updateDisclosures()
        })
        pairingContent.addArrangedSubview(AccountUI.label("Connect uses Scriv’s bundled helper with your permission. To use a separate Scriv Runtime Companion, choose its original private Pair with Scriv.scrivbridge file.", size: 13, color: .secondaryLabel))
        pairingContent.addArrangedSubview(button("Open companion", id: "open") { [weak self] in
            guard let self, !self.state.working else { return }; self.onOpen?()
        })
        pairingContent.addArrangedSubview(button("Choose private pairing file…", id: "pair") { [weak self] in
            guard let self, self.state.canEditConnection else { return }; self.onPair?()
        })
        pairingContent.addArrangedSubview(button("Start paired runtime", id: "start") { [weak self] in
            guard let self, self.state.canStart else { return }; self.onStart?()
        })
        pairingContent.addArrangedSubview(AccountUI.label("Stop Codex before rotating or forgetting a pairing. Rotation requires a new private pairing file; it does not change ChatGPT credentials.", size: 12, color: .secondaryLabel))
        pairingContent.addArrangedSubview(button("Rotate local pairing…", id: "rotate", plain: true) { [weak self] in
            guard let self, self.state.canManagePairing else { return }; self.onRotate?()
        })
        pairingContent.addArrangedSubview(button("Forget local pairing…", id: "forget", plain: true) { [weak self] in
            guard let self, self.state.canManagePairing else { return }; self.onForget?()
        })
        advancedContent.addArrangedSubview(pairingContent)
        body.addArrangedSubview(AccountUI.divider())
        body.addArrangedSubview(button("Generation jobs", id: "jobs", plain: true) { [weak self] in self?.onJobs?() })
        body.addArrangedSubview(button("Use existing generation history…", id: "history", plain: true) { [weak self] in self?.onHistory?() })
        response.isEditable = false; response.isSelectable = true; response.backgroundColor = .secondarySystemGroupedBackground
        response.font = .monospacedSystemFont(ofSize: 12, weight: .regular); response.textColor = .label
        response.accessibilityLabel = "Generation response"
        let responseHeight = response.heightAnchor.constraint(equalToConstant: 150); responseHeight.priority = .defaultHigh; responseHeight.isActive = true
        responseContent.addArrangedSubview(AccountUI.label("Generation response", size: 13, weight: .semibold, color: .label))
        responseContent.addArrangedSubview(response); body.addArrangedSubview(responseContent)
        updateDisclosures()
    }
    private func commandStep(_ title: String, command: String, id: String) -> UIView {
        let code = AccountUI.label(command, size: 12, color: .secondaryLabel)
        code.font = .monospacedSystemFont(ofSize: 12, weight: .regular); code.accessibilityIdentifier = "codex-" + id + "-command"
        let copy = button("Copy", id: id) {
            // Public instructions only. Never execute installation commands.
            UIPasteboard.general.string = command
            UIAccessibility.post(notification: .announcement, argument: "Command copied")
        }
        let row = ScrivSecondaryAdaptiveRow([code, copy], minimumHorizontalWidth: 430, spacing: 8)
        return AccountUI.stack([AccountUI.label(title, size: 13, weight: .medium, color: .label), row], spacing: 6)
    }
    private func installLayout() {
        scroll.keyboardDismissMode = .interactive; scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "codex-setup-scroll"
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        body.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(body)
        let padding: CGFloat = surface == .popup ? 16 : 24
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: padding),
            body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -padding),
            body.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: padding),
            body.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -padding),
            body.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * padding)
        ])
        if surface == .settings {
            // One scrolling native pane: no header can clip its content.
            body.insertArrangedSubview(header, at: 0)
            NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)])
        } else {
            [header, footer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
                header.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: padding), header.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -padding),
                scroll.topAnchor.constraint(equalTo: header.bottomAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
                footer.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: padding), footer.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -padding),
                footer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -12)
            ])
            header.setContentCompressionResistancePriority(.required, for: .vertical)
            footer.setContentCompressionResistancePriority(.required, for: .vertical)
        }
    }
    func update(_ state: ScrivCodexSetupPresentation, error: String?, journalError: String?, log: String) {
        self.state = state
        connection.text = state.connectionText
        connection.textColor = state.phase == .ready ? .systemGreen : .secondaryLabel
        hint.isHidden = state.connected
        hint.text = state.phase == .checking ? "Checking the local runtime and account…" : "Scriv starts Codex on this Mac when you connect."
        accountContent.isHidden = !state.connected
        accountStatus.text = state.accountText
        controls["account"]?.configuration?.title = state.accountActionTitle
        controls["account"]?.accessibilityLabel = state.accountActionTitle
        controls["account"]?.isEnabled = state.canUseAccount
        controls["refresh-account"]?.isHidden = state.phase != .signInRequired
        controls["refresh-account"]?.isEnabled = state.canUseAccount && !state.pendingLogin
        modelContent.isHidden = state.phase != .ready
        modelButton.configuration?.title = state.modelTitle; modelButton.accessibilityLabel = "Model: " + state.modelTitle
        modelButton.isEnabled = !state.working && !state.generating && state.connected && !state.availableModels.isEmpty
        controls["check"]?.isHidden = state.connected || state.phase == .checking
        controls["check"]?.isEnabled = state.canConnect
        controls["check"]?.configuration?.title = [.notFound, .incompatible, .cancelled].contains(state.phase) ? "Try again" : "Connect"
        controls["check"]?.accessibilityLabel = controls["check"]?.configuration?.title
        controls["cancel-check"]?.isHidden = state.phase != .checking
        controls["stop"]?.isHidden = !state.connected && !state.managed
        controls["stop"]?.configuration?.title = state.stopTitle; controls["stop"]?.accessibilityLabel = state.stopTitle
        controls["stop"]?.isEnabled = state.canStop
        controls["open"]?.isEnabled = !state.working; controls["pair"]?.isEnabled = state.canEditConnection
        controls["start"]?.isEnabled = state.canStart; controls["connect"]?.isEnabled = state.canConnect
        controls["choose-executable"]?.isEnabled = state.canEditConnection
        controls["rotate"]?.isEnabled = state.canManagePairing; controls["forget"]?.isEnabled = state.canManagePairing
        executable.isEnabled = state.canEditConnection; endpoint.isEnabled = state.canEditConnection
        errorLabel.text = error; errorLabel.isHidden = error?.isEmpty != false
        journalLabel.text = journalError; journalLabel.isHidden = journalError?.isEmpty != false
        if response.text != log { response.text = log }; responseContent.isHidden = log.isEmpty
        setNeedsLayout()
    }
    private func updateDisclosures() {
        installation.isHidden = !installationExpanded; pairingContent.isHidden = !pairingExpanded
        for (id, expanded) in [("installation-help", installationExpanded), ("pairing-controls", pairingExpanded)] {
            controls[id]?.configuration?.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.right")
            controls[id]?.configuration?.imagePadding = 8
            controls[id]?.accessibilityValue = expanded ? "Expanded" : "Collapsed"
        }
        setNeedsLayout()
    }
    private func button(_ title: String, id: String, primary: Bool = false, plain: Bool = false, action: @escaping () -> Void) -> UIButton {
        let button = AccountUI.button(title, primary: primary, action: action)
        button.accessibilityIdentifier = "codex-" + id
        if plain {
            button.configuration?.baseBackgroundColor = .clear; button.configuration?.background.strokeWidth = 0
            button.configuration?.baseForegroundColor = .systemBlue; button.contentHorizontalAlignment = .leading
        } else if !primary { button.configuration?.baseForegroundColor = .label }
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        button.titleLabel?.numberOfLines = 0; button.configuration?.titleLineBreakMode = .byWordWrapping
        controls[id] = button; return button
    }
}
