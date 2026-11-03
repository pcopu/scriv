import UIKit
import ScrivCore

/// Display only. A saved pairing, installed app, connected transport and checked
/// account are different facts; showing this sheet never initiates a check.
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

/// Imagegen reference: design/connection/codex-connection-states.png.
/// Persistent controls preserve edits and keyboard focus. State changes mount
/// bounded sections; expanded details cannot obscure the fixed header/footer.
@MainActor
final class ScrivCodexSetupView: UIView {
    // Imagegen is a 1× desktop layout: 26-point heading, 17-point body,
    // 584-point panels. The reference drew connected panels shorter, but their
    // real content needs ~594 points; at 538 the actions scrolled out of view.
    // Keep one height for every phase so nothing is hidden and the sheet does
    // not jump in size as the connection state changes.
    static let preferredSheetSize = CGSize(width: 584, height: 614)
    static func preferredSize(for phase: CodexConnectionCheck.Phase, available: CGSize? = nil, accessibility: Bool = false) -> CGSize {
        var size = preferredSheetSize
        if accessibility { size.height = 760 }
        if let available, available.width > 0, available.height > 0 {
            size.width = min(size.width, max(1, available.width - 32))
            size.height = min(size.height, max(1, available.height - 32))
        }
        return size
    }
    var onDone: (() -> Void)?
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

    let header = AccountUI.stack(spacing: 8)
    let footer = AccountUI.stack(spacing: 12)
    let scroll = UIScrollView()
    let body = AccountUI.stack(spacing: 16)
    let advancedContent = AccountUI.stack(spacing: 12)
    let pairingContent = AccountUI.stack(spacing: 12)
    let modelButton = AccountUI.button("Choose available model") {}
    private let executable: UITextField
    private let endpoint: UITextField
    private let connection = AccountUI.label("Not connected", size: 14, color: ScrivUIKitTheme.secondary)
    private let connectionDot = UIView()
    private let hero = UIImageView()
    private let iconRow = AccountUI.stack()
    private let connectionRow = AccountUI.stack(spacing: 10, horizontal: true)
    private var heroWidth: NSLayoutConstraint!
    private var heroHeight: NSLayoutConstraint!
    private var bodyTop: NSLayoutConstraint!
    private var footerBottom: NSLayoutConstraint!
    private let headline = AccountUI.label("", size: 26, weight: .bold, centered: true)
    private let subtitle = AccountUI.label("", size: 17, color: ScrivUIKitTheme.secondary, centered: true)
    private let accountStatus = AccountUI.label("", size: 15, color: ScrivUIKitTheme.secondary)
    private let explanation = AccountUI.label("Scriv finds and starts Codex on this Mac. No server address is needed.", size: 14, color: ScrivUIKitTheme.secondary, centered: true)
    private let errorLabel = AccountUI.label("", size: 14, color: .systemRed)
    private let journalLabel = AccountUI.label("", size: 14, color: .systemOrange)
    private let response = UITextView()
    private let responseContent = AccountUI.stack(spacing: 8)
    private let heroSection = AccountUI.stack(spacing: 14)
    private let installation = AccountUI.stack(spacing: 13)
    private let readyDetails = AccountUI.stack(spacing: 10)
    private let authActions = AccountUI.stack(spacing: 10)
    private let primaryActions = AccountUI.stack(spacing: 12)
    private let advancedSection = AccountUI.stack(spacing: 12)
    private let pairingSection = AccountUI.stack(spacing: 12)
    private var controls: [String: UIButton] = [:]
    private var advancedExpanded = false
    private var pairingExpanded = false
    private var installationExpanded = false
    private var pendingScrollToTop = false
    private weak var pendingRevealTarget: UIView?
    private var state = ScrivCodexSetupPresentation()

    init(executable: UITextField, endpoint: UITextField, progress: UIView) {
        self.executable = executable; self.endpoint = endpoint
        super.init(frame: .zero)
        overrideUserInterfaceStyle = .light; backgroundColor = ScrivUIKitTheme.color("F5F9FF")
        accessibilityIdentifier = "codex-setup-sheet"
        buildHeader(); buildBody(progress: progress); buildFooter(); installLayout()
        update(state, error: nil, journalError: nil, log: "")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(executable:endpoint:progress:)") }

    private func buildHeader() {
        let title = AccountUI.label("Codex on this Mac", size: 26, weight: .bold); title.accessibilityTraits.insert(.header)
        let done = button("Done", id: "done", plain: true) { [weak self] in self?.onDone?() }
        done.contentHorizontalAlignment = .trailing; done.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let row = AccountUI.stack([title, done], spacing: 16, horizontal: true); row.alignment = .top
        header.addArrangedSubview(row); connection.accessibilityIdentifier = "codex-connection-status"
        connectionDot.layer.cornerRadius = 6
        NSLayoutConstraint.activate([connectionDot.widthAnchor.constraint(equalToConstant: 12), connectionDot.heightAnchor.constraint(equalToConstant: 12)])
        connectionRow.addArrangedSubview(connectionDot); connectionRow.addArrangedSubview(connection); header.addArrangedSubview(connectionRow); header.spacing = 4
        header.accessibilityIdentifier = "codex-setup-header"
    }
    private func buildBody(progress: UIView) {
        hero.contentMode = .center; hero.layer.cornerRadius = 30; hero.isAccessibilityElement = false
        heroWidth = hero.widthAnchor.constraint(equalToConstant: 130); heroHeight = hero.heightAnchor.constraint(equalToConstant: 130)
        NSLayoutConstraint.activate([heroWidth, heroHeight]); iconRow.addArrangedSubview(hero); iconRow.alignment = .center; heroSection.spacing = 8; primaryActions.spacing = 8
        headline.accessibilityIdentifier = "codex-setup-headline"; headline.accessibilityTraits.insert(.header)
        heroSection.addArrangedSubview(iconRow); heroSection.addArrangedSubview(headline); heroSection.addArrangedSubview(subtitle); heroSection.setCustomSpacing(16, after: iconRow)
        body.addArrangedSubview(heroSection)
        buildInstallation(); body.addArrangedSubview(installation)
        accountStatus.accessibilityIdentifier = "codex-account-status"
        readyDetails.addArrangedSubview(detailRow("Connection", value: AccountUI.label("This Mac", size: 15, color: ScrivUIKitTheme.secondary)))
        readyDetails.addArrangedSubview(divider()); readyDetails.addArrangedSubview(detailRow("ChatGPT account", value: accountStatus))
        readyDetails.addArrangedSubview(divider())
        modelButton.showsMenuAsPrimaryAction = true; modelButton.accessibilityIdentifier = "codex-model"
        readyDetails.addArrangedSubview(detailRow("Model", value: modelButton)); body.addArrangedSubview(readyDetails)
        let check = button("Check & connect", id: "check", primary: true) { [weak self] in guard let self, self.state.canConnect else { return }; self.onCheck?() }
        primaryActions.addArrangedSubview(check)
        primaryActions.addArrangedSubview(button("Cancel check", id: "cancel-check", plain: true) { [weak self] in self?.onCancelCheck?() })
        primaryActions.addArrangedSubview(explanation)
        primaryActions.addArrangedSubview(button("Done", id: "ready-done", primary: true) { [weak self] in self?.onDone?() })
        body.addArrangedSubview(primaryActions)
        let account = button("Sign in with ChatGPT", id: "account", primary: true) { [weak self] in guard let self, self.state.canUseAccount else { return }; self.onAccount?() }
        authActions.addArrangedSubview(account)
        authActions.addArrangedSubview(button("I've signed in — check again", id: "refresh-account", outlined: true) { [weak self] in guard let self, self.state.canUseAccount else { return }; self.onRefreshAccount?() })
        authActions.addArrangedSubview(AccountUI.label("Sign-in opens in your browser. Nothing is generated.", size: 13, color: ScrivUIKitTheme.secondary, centered: true))
        authActions.spacing = 8; body.addArrangedSubview(authActions)
        body.addArrangedSubview(button("Disconnect", id: "stop", plain: true) { [weak self] in guard let self, self.state.canStop else { return }; self.onStop?() })
        body.addArrangedSubview(button("No Codex yet? Installation help", id: "installation-help", plain: true) { [weak self] in guard let self else { return }; self.installationExpanded.toggle(); self.update(self.state, error: self.errorLabel.text, journalError: self.journalLabel.text, log: self.response.text) })
        body.addArrangedSubview(button("Official setup guide", id: "guide", plain: true) { [weak self] in self?.onGuide?() })
        body.addArrangedSubview(progress)
        body.addArrangedSubview(divider())
        advancedSection.addArrangedSubview(disclosure("Advanced connection", id: "advanced") { [weak self] in guard let self else { return }; self.advancedExpanded.toggle(); self.updateDisclosures(); self.revealAfterLayout(self.advancedExpanded ? self.endpoint : self.controls["advanced"]) })
        body.addArrangedSubview(advancedSection); buildAdvanced()
        errorLabel.accessibilityIdentifier = "codex-setup-error"; errorLabel.accessibilityTraits.insert(.updatesFrequently)
        advancedContent.addArrangedSubview(errorLabel); body.addArrangedSubview(journalLabel)
        response.isEditable = false; response.isSelectable = true; response.backgroundColor = ScrivUIKitTheme.inset
        response.font = .monospacedSystemFont(ofSize: 13, weight: .regular); response.textColor = ScrivUIKitTheme.ink
        response.accessibilityLabel = "Generation response"; response.heightAnchor.constraint(equalToConstant: 150).isActive = true
        responseContent.addArrangedSubview(AccountUI.label("Generation response", size: 16, weight: .semibold)); responseContent.addArrangedSubview(response)
        advancedContent.addArrangedSubview(responseContent); updateDisclosures()
    }
    private func buildInstallation() {
        installation.addArrangedSubview(commandStep(1, "Install the CLI in Terminal", command: CodexLocalSetup.installCommand, id: "copy-install"))
        installation.addArrangedSubview(commandStep(2, "Sign in", command: CodexLocalSetup.signInCommand, id: "copy-sign-in"))
        installation.addArrangedSubview(AccountUI.label("Return here and choose Check & connect. Scriv finds and starts the local runtime for you.", size: 13, color: ScrivUIKitTheme.secondary))
    }
    private func commandStep(_ number: Int, _ title: String, command: String, id: String) -> UIView {
        let badge = AccountUI.label(String(number), size: 18, weight: .semibold, color: ScrivUIKitTheme.accent, centered: true)
        badge.backgroundColor = ScrivUIKitTheme.accent.withAlphaComponent(0.1); badge.layer.cornerRadius = 18; badge.clipsToBounds = true
        NSLayoutConstraint.activate([badge.widthAnchor.constraint(equalToConstant: 36), badge.heightAnchor.constraint(equalToConstant: 36)])
        let code = AccountUI.label(command, size: 12, color: ScrivUIKitTheme.secondary); code.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        code.accessibilityIdentifier = "codex-" + id + "-command"
        let copy = button("Copy", id: id, outlined: true) {
            // Literal public installation instructions only; never execute them.
            UIPasteboard.general.string = command
            UIAccessibility.post(notification: .announcement, argument: "Command copied")
        }
        copy.setContentHuggingPriority(.required, for: .horizontal)
        let box = AccountUI.card(AccountUI.stack([code, copy], spacing: 10, horizontal: true), padding: 4); box.backgroundColor = ScrivUIKitTheme.inset; box.layer.borderWidth = 0
        let details = AccountUI.stack([AccountUI.label(title, size: 16, weight: .semibold), box], spacing: 4)
        let row = AccountUI.stack([badge, details], spacing: 12, horizontal: true); row.alignment = .top; return row
    }
    private func buildAdvanced() {
        executable.accessibilityLabel = "Installed Codex executable"; endpoint.accessibilityLabel = "Saved loopback server address"
        advancedContent.addArrangedSubview(AccountUI.stack([AccountUI.label("Custom local app-server address (optional)", size: 15, weight: .semibold), endpoint], spacing: 6))
        advancedContent.addArrangedSubview(AccountUI.label("No address is needed for Check & connect. Use this only for a separately started local WebSocket server. Disconnect leaves that server running.", size: 14, color: ScrivUIKitTheme.secondary))
        advancedContent.addArrangedSubview(button("Connect to this address", id: "connect", outlined: true) { [weak self] in guard let self, self.state.canConnect else { return }; self.onConnect?() })
        advancedContent.addArrangedSubview(commandStep(1, "Optional: start a custom server in Terminal", command: CodexLocalSetup.serverCommand, id: "copy-server"))
        advancedContent.addArrangedSubview(AccountUI.label("Local WebSocket mode is experimental. Keep that Terminal window open and use the address from its command above.", size: 13, color: ScrivUIKitTheme.secondary))
        advancedContent.addArrangedSubview(divider())
        advancedContent.addArrangedSubview(AccountUI.label("Optional paired runtime", size: 16, weight: .semibold))
        advancedContent.addArrangedSubview(AccountUI.label("Check & connect uses Scriv's bundled helper automatically. You can also pair a separate Scriv Runtime Companion and use Start paired runtime. Nothing starts just by opening this sheet.", size: 14, color: ScrivUIKitTheme.secondary))
        let open = button("Open companion", id: "open", outlined: true) { [weak self] in guard let self, !self.state.working else { return }; self.onOpen?() }
        let pair = button("Choose file…", id: "pair", outlined: true) { [weak self] in guard let self, self.state.canEditConnection else { return }; self.onPair?() }
        pair.accessibilityLabel = "Choose private pairing file…"
        advancedContent.addArrangedSubview(ScrivSecondaryAdaptiveRow([open, pair], minimumHorizontalWidth: 480, spacing: 12))
        advancedContent.addArrangedSubview(AccountUI.label("Choose the original private pairing file. Expected file: Pair with Scriv.scrivbridge", size: 13, color: ScrivUIKitTheme.secondary))
        let choose = button("Choose…", id: "choose-executable", outlined: true) { [weak self] in guard let self, self.state.canEditConnection else { return }; self.onChooseExecutable?() }
        advancedContent.addArrangedSubview(ScrivSecondaryAdaptiveRow([executable, choose], minimumHorizontalWidth: 400, spacing: 10))
        advancedContent.addArrangedSubview(button("Start paired runtime", id: "start", outlined: true) { [weak self] in guard let self, self.state.canStart else { return }; self.onStart?() })
        pairingSection.addArrangedSubview(disclosure("Pairing controls", id: "pairing-controls") { [weak self] in guard let self else { return }; self.pairingExpanded.toggle(); self.updateDisclosures(); self.revealAfterLayout(self.controls["pairing-controls"]) })
        pairingContent.addArrangedSubview(AccountUI.label("Saved pairing survives restarts. Stop Codex before rotating or forgetting it. Rotation requires a new private pairing file; it does not change ChatGPT credentials.", size: 14, color: ScrivUIKitTheme.secondary))
        pairingContent.addArrangedSubview(button("Rotate local pairing…", id: "rotate", plain: true) { [weak self] in guard let self, self.state.canManagePairing else { return }; self.onRotate?() })
        pairingContent.addArrangedSubview(button("Forget local pairing…", id: "forget", plain: true) { [weak self] in guard let self, self.state.canManagePairing else { return }; self.onForget?() })
        advancedContent.addArrangedSubview(pairingSection)
    }
    private func buildFooter() {
        let history = button("Existing history…", id: "history", plain: true) { [weak self] in self?.onHistory?() }
        let jobs = button("Generation jobs", id: "jobs", plain: true) { [weak self] in self?.onJobs?() }
        let links = ScrivCodexFooterLinks(history: jobs, jobs: history)
        let info = UIImageView(image: UIImage(systemName: "info.circle")); info.tintColor = ScrivUIKitTheme.accent
        info.widthAnchor.constraint(equalToConstant: 22).isActive = true; info.contentMode = .scaleAspectFit
        let note = AccountUI.stack([info, AccountUI.label("Your Codex account stays on this Mac. Scriv sign-in is separate.", size: 12, color: ScrivUIKitTheme.secondary)], spacing: 12, horizontal: true)
        let box = AccountUI.card(note, padding: 10); box.backgroundColor = ScrivUIKitTheme.accent.withAlphaComponent(0.07); box.layer.borderWidth = 0
        footer.addArrangedSubview(divider()); footer.addArrangedSubview(links); footer.addArrangedSubview(box); footer.accessibilityIdentifier = "codex-setup-footer"
    }
    private func installLayout() {
        scroll.keyboardDismissMode = .interactive; scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "codex-setup-scroll"
        let topRule = divider()
        [header, topRule, scroll, footer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        body.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(body)
        bodyTop = body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20)
        footerBottom = footer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -20)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            topRule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8), topRule.leadingAnchor.constraint(equalTo: header.leadingAnchor), topRule.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topRule.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30), footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30), footerBottom,
            bodyTop, body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 30), body.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -30), body.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -60)
        ])
        header.setContentCompressionResistancePriority(.required, for: .vertical); footer.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    func update(_ state: ScrivCodexSetupPresentation, error: String?, journalError: String?, log: String) {
        let previousPhase = self.state.phase
        let previouslyShowingInstallation = installation.superview === body
        self.state = state; let phase = state.phase
        connection.text = state.connectionText
        let color: UIColor = phase == .ready ? .systemGreen : [.notFound, .incompatible, .signInRequired].contains(phase) ? .systemOrange : ScrivUIKitTheme.accent
        connectionDot.backgroundColor = color; hero.tintColor = color; hero.backgroundColor = color.withAlphaComponent(0.1)
        hero.image = UIImage(systemName: phase == .ready ? "checkmark" : phase == .signInRequired ? "person" : phase == .checking ? "arrow.triangle.2.circlepath" : "powerplug", withConfiguration: UIImage.SymbolConfiguration(pointSize: [.ready, .signInRequired].contains(phase) ? 42 : 64, weight: .medium))
        let showingInstallation = phase == .notFound || (installationExpanded && !state.connected)
        let compact = phase == .ready || phase == .signInRequired
        heroWidth.constant = compact ? (phase == .ready ? 80 : 88) : 130
        heroHeight.constant = heroWidth.constant; hero.layer.cornerRadius = compact ? heroWidth.constant / 2 : 36
        mount(iconRow, in: heroSection, visible: !showingInstallation, before: headline)
        if !showingInstallation { heroSection.setCustomSpacing(16, after: iconRow) }
        mount(connectionRow, in: header, visible: phase != .idle && phase != .cancelled)
        headline.textAlignment = showingInstallation ? .left : .center; subtitle.textAlignment = headline.textAlignment
        body.spacing = showingInstallation ? 8 : compact ? 12 : 16
        bodyTop.constant = showingInstallation ? 8 : compact ? 12 : 20
        heroSection.spacing = showingInstallation ? 4 : 8; installation.spacing = 10
        headline.font = .systemFont(ofSize: showingInstallation ? 24 : 26, weight: .bold)
        subtitle.font = .systemFont(ofSize: showingInstallation ? 16 : 17)
        footer.spacing = compact ? 4 : 8; footerBottom.constant = compact ? -10 : -20
        headline.text = showingInstallation ? "Get Codex ready" : phase == .ready ? "Codex is ready" : phase == .signInRequired ? "Sign in to Codex" : phase == .checking ? "Checking Codex…" : phase == .incompatible ? "This server can't connect" : "Connect Codex in one click"
        subtitle.text = showingInstallation ? "Install Codex, then choose Check & connect. Scriv starts the local runtime for you." : phase == .ready ? (state.requiresAuthentication ? "Local app server connected. Your account is signed in." : "Local app server connected. This provider does not require an account.") : phase == .signInRequired ? (state.pendingLogin ? "Complete the sign-in in your browser, then return here. You can cancel without changing your project." : "The local app server is connected, but it reports no signed-in account. A ChatGPT account with Codex access is required.") : phase == .checking ? "Checking the app-server protocol and existing account. No image is being generated." : phase == .incompatible ? "The local Codex runtime could not be verified. Update Codex or inspect Advanced connection, then try again." : "Connect using the Codex installation and account on this Mac."
        mount(installation, in: body, visible: showingInstallation, before: primaryActions)
        mount(readyDetails, in: body, visible: phase == .ready, before: primaryActions)
        mount(authActions, in: body, visible: phase == .signInRequired, before: controls["stop"])
        controls["check"]?.isHidden = state.connected || phase == .checking
        controls["check"]?.configuration?.title = [.notFound, .incompatible, .cancelled].contains(phase) || showingInstallation ? "Check again" : "Check & connect"
        controls["check"]?.accessibilityLabel = controls["check"]?.configuration?.title
        controls["check"]?.isEnabled = state.canConnect
        controls["cancel-check"]?.isHidden = phase != .checking
        controls["ready-done"]?.isHidden = phase != .ready
        explanation.isHidden = showingInstallation || (phase != .idle && phase != .cancelled)
        controls["installation-help"]?.isHidden = state.connected || phase == .checking || showingInstallation
        controls["guide"]?.isHidden = !showingInstallation && phase != .incompatible
        controls["stop"]?.isHidden = !state.connected && !state.managed; controls["stop"]?.isEnabled = state.canStop
        controls["stop"]?.configuration?.title = state.stopTitle; controls["stop"]?.accessibilityLabel = state.stopTitle
        controls["account"]?.configuration?.title = state.accountActionTitle; controls["account"]?.accessibilityLabel = state.accountActionTitle
        controls["account"]?.isEnabled = state.canUseAccount; controls["refresh-account"]?.isEnabled = state.canUseAccount && !state.pendingLogin
        accountStatus.text = state.accountText
        modelButton.configuration?.title = state.modelTitle; modelButton.accessibilityLabel = state.modelTitle
        modelButton.isEnabled = !state.working && !state.generating && state.connected && !state.availableModels.isEmpty
        controls["open"]?.isEnabled = !state.working; controls["pair"]?.isEnabled = state.canEditConnection
        controls["start"]?.isEnabled = state.canStart; controls["connect"]?.isEnabled = state.canConnect; controls["choose-executable"]?.isEnabled = state.canEditConnection
        controls["rotate"]?.isEnabled = state.canManagePairing; controls["forget"]?.isEnabled = state.canManagePairing
        executable.isEnabled = state.canEditConnection; endpoint.isEnabled = state.canEditConnection
        errorLabel.text = error; errorLabel.isHidden = error?.isEmpty != false; journalLabel.text = journalError; journalLabel.isHidden = journalError?.isEmpty != false
        if response.text != log { response.text = log }; mount(responseContent, in: advancedContent, visible: !log.isEmpty)
        // A section change is navigation, not a scroll-position continuation.
        // Ordinary state/log refreshes must not jump away from an edited field.
        if previousPhase != phase || previouslyShowingInstallation != showingInstallation {
            pendingScrollToTop = true; pendingRevealTarget = nil
        }
        setNeedsLayout()
    }
    private var revealAttempts = 0
    private func revealAfterLayout(_ target: UIView?) {
        pendingScrollToTop = false; pendingRevealTarget = target; revealAttempts = 0; setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard scroll.bounds.height > 0 else { return }
        // The body's new height reaches contentSize only on the scroll view's
        // next layout; lay it out again so reveals are not clamped to the old size.
        scroll.layoutIfNeeded(); body.layoutIfNeeded(); scroll.setNeedsLayout(); scroll.layoutIfNeeded()
        if pendingScrollToTop {
            pendingScrollToTop = false
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        } else if let target = pendingRevealTarget, target.isDescendant(of: scroll) {
            let frame = target.convert(target.bounds, to: scroll)
            // A just-mounted control may not be measured on this pass, and
            // scrollRectToVisible ignores an empty rect. Retry a few passes.
            if frame.height <= 0 || frame.maxY > scroll.contentSize.height {
                if revealAttempts < 4 { revealAttempts += 1; setNeedsLayout() } else { pendingRevealTarget = nil; revealAttempts = 0 }
                return
            }
            pendingRevealTarget = nil; revealAttempts = 0
            let rect = CGRect(x: 0, y: frame.minY - 12, width: max(1, scroll.bounds.width), height: frame.height + 24)
            scroll.scrollRectToVisible(rect, animated: false)
        }
    }
    private func updateDisclosures() {
        mount(advancedContent, in: advancedSection, visible: advancedExpanded)
        mount(pairingContent, in: pairingSection, visible: pairingExpanded)
        for (id, expanded) in [("advanced", advancedExpanded), ("pairing-controls", pairingExpanded)] {
            controls[id]?.configuration?.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.right"); controls[id]?.accessibilityValue = expanded ? "Expanded" : "Collapsed"
        }
    }
    private func mount(_ child: UIView, in stack: UIStackView, visible: Bool, before next: UIView? = nil) {
        if visible {
            if child.superview !== stack {
                if let next, let index = stack.arrangedSubviews.firstIndex(of: next) { stack.insertArrangedSubview(child, at: index) }
                else { stack.addArrangedSubview(child) }
            }
        } else if child.superview === stack { stack.removeArrangedSubview(child); child.removeFromSuperview() }
    }
    private func detailRow(_ title: String, value: UIView) -> UIView {
        let label = AccountUI.label(title, size: 15); label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return ScrivSecondaryAdaptiveRow([label, value], minimumHorizontalWidth: 420, spacing: 12)
    }
    private func divider() -> UIView { let view = AccountUI.divider(); view.backgroundColor = ScrivUIKitTheme.hairline; return view }
    private func button(_ title: String, id: String, primary: Bool = false, outlined: Bool = false, plain: Bool = false, action: @escaping () -> Void) -> UIButton {
        let button = AccountUI.button(title, primary: primary, action: action); button.accessibilityIdentifier = "codex-" + id
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes; result.font = .systemFont(ofSize: id.hasPrefix("copy-") ? 13 : ["done", "guide", "stop"].contains(id) ? 16 : ["advanced", "pairing-controls", "jobs", "history", "installation-help"].contains(id) ? 14 : 16, weight: plain ? .regular : .semibold); return result
        }
        button.configuration?.contentInsets = .init(top: plain ? 4 : id.hasPrefix("copy-") ? 5 : 10, leading: plain ? 2 : 14, bottom: plain ? 4 : id.hasPrefix("copy-") ? 5 : 10, trailing: plain ? 2 : 14)
        if outlined || plain { button.configuration?.baseBackgroundColor = .clear; button.configuration?.baseForegroundColor = ScrivUIKitTheme.accent; button.configuration?.background.strokeColor = ScrivUIKitTheme.accent; button.configuration?.background.strokeWidth = outlined ? 1 : 0 }
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        button.titleLabel?.numberOfLines = 0; button.configuration?.titleLineBreakMode = .byWordWrapping
        controls[id] = button; return button
    }
    private func disclosure(_ title: String, id: String, action: @escaping () -> Void) -> UIButton {
        let button = button(title, id: id, plain: true, action: action); button.contentHorizontalAlignment = .leading
        button.configuration?.baseForegroundColor = ScrivUIKitTheme.ink; button.configuration?.imagePadding = 14; return button
    }
}
/// Only the Codex footer uses this optical link spacing. A separate trailing
/// spacer absorbs spare width instead of stretching either configured button.
/// The 584pt reference sheet has 524pt inside its 30pt side insets. Keep
/// that standard width horizontal; stack only at genuinely compact widths.
/// Both complete controls still fill their rows when stacked at compact widths.
@MainActor final class ScrivCodexFooterLinks: UIStackView {
    private let trailingSpace = UIView()
    init(history: UIButton, jobs: UIButton) {
        super.init(frame: .zero)
        axis = .horizontal; alignment = .center; spacing = 48
        history.contentHorizontalAlignment = .leading; jobs.contentHorizontalAlignment = .leading
        history.setContentHuggingPriority(UILayoutPriority(751), for: .horizontal)
        jobs.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        trailingSpace.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        trailingSpace.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        addArrangedSubview(history); addArrangedSubview(jobs); addArrangedSubview(trailingSpace)
        trailingSpace.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        trailingSpace.heightAnchor.constraint(equalToConstant: 0).isActive = true
        setCustomSpacing(0, after: jobs)
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError("Use init(history:jobs:)") }
    override func layoutSubviews() {
        if bounds.width > 0 {
            let next: NSLayoutConstraint.Axis = bounds.width < 440 ? .vertical : .horizontal
            if axis != next {
                axis = next; alignment = next == .vertical ? .fill : .center
                spacing = next == .vertical ? 18 : 48
                trailingSpace.isHidden = next == .vertical
                invalidateIntrinsicContentSize()
            }
        }
        super.layoutSubviews()
    }
}
