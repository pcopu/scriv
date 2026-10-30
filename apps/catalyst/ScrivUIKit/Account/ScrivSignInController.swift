import UIKit
import Combine
import ScrivCore

/// Email/code views share a single owner-fenced CloudClient flow. Codes stay in
/// this controller's transient text field and are never logged or persisted.
@MainActor
final class ScrivSignInController: ScrivScreenController, UITextFieldDelegate {
    private let ownerID = UUID()
    private let content = AccountUI.stack(spacing: 22)
    private let email = AccountUI.field("you@example.com")
    private let code = AccountUI.field("—  —  —  —  —  —")
    private let errorLabel = AccountUI.label("", size: 13, color: .systemRed)
    private var actionButton: UIButton?
    private var resendButton: UIButton?
    private var githubButton: UIButton?
    private var expiryLabel: UILabel?
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var timer: Timer?
    private var layoutKey = ""
    private var previousChallenge: String?
    private var browserError: String?
    private var githubExpanded = false
    private var originalServer = ""
    private var originalNavigation = 0
    private var visible = false
    private var closing = false
    private var busy: Bool { store.cloud.emailSignIn.isBusy || operationID != nil }
    private var ownedElsewhere: Bool { store.cloud.signInOwnerID != nil && store.cloud.signInOwnerID != ownerID }

    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false); preferredContentSize = CGSize(width: 540, height: 660) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = AccountUI.panel; preferredContentSize = CGSize(width: 540, height: 660)
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.close() })
        _ = AccountUI.installScroll(in: self, content: content, padding: 34)
        email.textContentType = .emailAddress; email.keyboardType = .emailAddress; email.autocapitalizationType = .none; email.returnKeyType = .continue
        code.textContentType = .oneTimeCode; code.keyboardType = .numberPad; code.font = .monospacedSystemFont(ofSize: 26, weight: .medium); code.textAlignment = .center
        email.delegate = self; code.delegate = self
        email.addTarget(self, action: #selector(changed), for: .editingChanged); code.addTarget(self, action: #selector(changed), for: .editingChanged)
        store.cloud.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.storeDidChange() }.store(in: &subscriptions)
        email.text = store.cloud.emailSignIn.email; originalServer = store.cloudBaseURL; originalNavigation = store.navigationContext
        render()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); visible = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateControls() } }
        if !ownedElsewhere { (store.cloud.emailSignIn.challengeID == nil ? email : code).becomeFirstResponder() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); visible = false; timer?.invalidate(); timer = nil
        // A system authentication browser may temporarily cover this view.
        // Only actual dismissal/navigation-away cancels its owned challenge.
        let leaving = closing || isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true
        if leaving {
            // Do not invalidate the refresh following a successful verify.
            if store.cloud.account == nil { cancel() }
            code.text = ""; email.text = ""
        }
    }
    override func storeDidChange() {
        guard isViewLoaded, !closing else { return }
        if store.cloud.account != nil { close(success: true); return }
        if originalServer != store.cloudBaseURL || originalNavigation != store.navigationContext {
            cancel(); originalServer = store.cloudBaseURL; originalNavigation = store.navigationContext; email.text = ""
        }
        if ownedElsewhere, operationID != nil { cancel() }
        let challenge = store.cloud.emailSignIn.challengeID
        if previousChallenge != challenge { code.text = ""; previousChallenge = challenge }
        render()
    }
    private func render() {
        let challenge = store.cloud.emailSignIn.challengeID
        let key = "\(ownedElsewhere)-\(challenge != nil)-\(githubExpanded)"
        if layoutKey != key {
            layoutKey = key; AccountUI.clear(content); actionButton = nil; resendButton = nil; githubButton = nil; expiryLabel = nil
            if ownedElsewhere {
                heading("person.fill", "Sign in to Scriv", "Sign-in is already open in another Scriv window.")
                content.addArrangedSubview(AccountUI.button("Start sign-in here", primary: true) { [weak self] in
                    guard let self else { return }; self.store.cloud.cancelSignIn(); self.email.text = ""; self.code.text = ""; self.render()
                })
                content.addArrangedSubview(AccountUI.link("Keep writing locally") { [weak self] in self?.close() })
            } else if challenge != nil {
                content.addArrangedSubview(AccountUI.link("Change email", symbol: "chevron.left") { [weak self] in self?.cancel(); self?.email.text = ""; self?.render() })
                heading("envelope", "Check your email", "Enter the 6-digit code sent to \(store.cloud.emailSignIn.email)")
                content.addArrangedSubview(code)
                let button = AccountUI.button("Sign in with code", primary: true) { [weak self] in self?.verify() }; actionButton = button; content.addArrangedSubview(button)
                let expiry = AccountUI.label("", size: 13, color: .secondaryLabel, centered: true); expiryLabel = expiry; content.addArrangedSubview(expiry)
                let resend = AccountUI.button("Resend code") { [weak self] in self?.request() }; resendButton = resend; content.addArrangedSubview(resend)
                content.addArrangedSubview(AccountUI.link("Cancel sign-in") { [weak self] in self?.close() })
                footer("You can keep editing locally while signing in.")
            } else {
                heading("person.fill", "Sign in to Scriv", "Save scripts to the cloud and join your team.")
                content.addArrangedSubview(AccountUI.stack([AccountUI.label("Email address", size: 14, weight: .medium, color: .secondaryLabel), email], spacing: 9))
                let button = AccountUI.button("Continue with email", primary: true) { [weak self] in self?.request() }; actionButton = button; content.addArrangedSubview(button)
                content.addArrangedSubview(AccountUI.label("We'll email a one-time code. No password needed.", size: 13, color: .secondaryLabel, centered: true))
                content.addArrangedSubview(AccountUI.link("Keep writing locally") { [weak self] in self?.close() })
                content.addArrangedSubview(AccountUI.divider())
                content.addArrangedSubview(AccountUI.link("Already used GitHub?", symbol: githubExpanded ? "chevron.down" : "chevron.right") { [weak self] in guard let self else { return }; self.githubExpanded.toggle(); self.render() })
                if githubExpanded {
                    content.addArrangedSubview(AccountUI.label("Use your existing GitHub-linked Scriv account.", size: 13, color: .secondaryLabel))
                    let button = AccountUI.button("Continue with GitHub…") { [weak self] in self?.github() }; button.isEnabled = !busy; githubButton = button; content.addArrangedSubview(button)
                }
                footer("ChatGPT sign-in is separate in Codex on this Mac.")
            }
            content.addArrangedSubview(errorLabel)
            if visible, !ownedElsewhere { (challenge == nil ? email : code).becomeFirstResponder() }
        }
        updateControls()
    }
    private func heading(_ symbol: String, _ title: String, _ subtitle: String) {
        let iconRow = AccountUI.stack([AccountUI.symbol(symbol)], spacing: 0); iconRow.alignment = .center
        content.addArrangedSubview(AccountUI.stack([iconRow, AccountUI.label(title, size: 29, weight: .semibold, centered: true), AccountUI.label(subtitle, size: 16, color: .secondaryLabel, centered: true)], spacing: 16))
    }
    private func footer(_ text: String) { content.addArrangedSubview(AccountUI.divider()); content.addArrangedSubview(AccountUI.label(text, size: 13, color: .secondaryLabel)) }
    @objc private func changed() {
        code.text = String((code.text ?? "").filter { $0.isASCII && $0.isNumber }.prefix(6)); updateControls()
    }
    private func updateControls() {
        guard isViewLoaded else { return }; let flow = store.cloud.emailSignIn, now = Date()
        githubButton?.isEnabled = !busy && !ownedElsewhere
        email.isEnabled = !busy && !ownedElsewhere; code.isEnabled = !busy && !ownedElsewhere && !flow.isExpired(at: now)
        if flow.challengeID != nil {
            actionButton?.configuration?.title = flow.phase == .verifying ? "Signing in…" : "Sign in with code"
            actionButton?.isEnabled = !busy && !ownedElsewhere && (try? EmailSignInFlow.normalizedCode(code.text ?? "")) != nil && !flow.isExpired(at: now)
            let seconds = flow.expirySeconds(at: now)
            expiryLabel?.text = flow.isExpired(at: now) ? "This code has expired. Request a new code." : String(format: "Code expires in %d:%02d", seconds / 60, seconds % 60)
            resendButton?.configuration?.title = flow.resendSeconds(at: now) > 0 ? "Resend in \(flow.resendSeconds(at: now))s" : "Resend code"
            resendButton?.isEnabled = !busy && !ownedElsewhere && flow.canResend(at: now)
        } else {
            actionButton?.configuration?.title = flow.phase == .requesting ? "Sending code…" : flow.resendSeconds(at: now) > 0 ? "Try again in \(flow.resendSeconds(at: now))s" : "Continue with email"
            actionButton?.isEnabled = !busy && !ownedElsewhere && flow.resendSeconds(at: now) == 0 && (try? EmailSignInFlow.normalizedEmail(email.text ?? "")) != nil
        }
        errorLabel.text = ownedElsewhere ? nil : browserError ?? flow.errorMessage; errorLabel.isHidden = errorLabel.text?.isEmpty != false
        isModalInPresentation = busy
    }
    private func request() {
        guard !busy, !ownedElsewhere, store.cloud.emailSignIn.resendSeconds(at: Date()) == 0 else { return }
        let address = store.cloud.emailSignIn.challengeID != nil ? store.cloud.emailSignIn.email : email.text ?? ""
        guard (try? EmailSignInFlow.normalizedEmail(address)) != nil else { return }
        code.text = ""; browserError = nil; run { [weak self] in guard let self else { return }; await self.store.requestEmailCode(address, ownerID: self.ownerID) }
    }
    private func verify() {
        guard !busy, !ownedElsewhere, !store.cloud.emailSignIn.isExpired(at: Date()), let entered = try? EmailSignInFlow.normalizedCode(code.text ?? "") else { return }
        browserError = nil; run { [weak self] in guard let self else { return }; await self.store.verifyEmailCode(entered, ownerID: self.ownerID); self.code.text = "" }
    }
    private func github() {
        guard !busy, !ownedElsewhere else { return }; browserError = nil
        run { [weak self] in guard let self else { return }; do { try await self.store.signInWithGitHub(ownerID: self.ownerID) } catch is CancellationError {} catch { self.browserError = error.localizedDescription } }
    }
    private func run(_ action: @escaping @MainActor () async -> Void) {
        let id = UUID(); operationID = id; updateControls()
        operation = Task { [weak self] in await action(); guard let self, self.operationID == id else { return }; self.operationID = nil; self.operation = nil; self.storeDidChange() }
    }
    private func cancel() { operationID = nil; operation?.cancel(); operation = nil; store.cloud.cancelSignIn(ownerID: ownerID); code.text = ""; browserError = nil }
    private func close(success: Bool = false) { guard !closing else { return }; closing = true; if !success { cancel() }; code.text = ""; dismiss(animated: true) }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { if textField === email { request() } else { verify() }; return true }
    func textFieldDidBeginEditing(_ textField: UITextField) { textField.layer.borderColor = AccountUI.accent.cgColor; textField.layer.borderWidth = 2 }
    func textFieldDidEndEditing(_ textField: UITextField) { textField.layer.borderColor = UIColor.separator.cgColor; textField.layer.borderWidth = 1 }
}

extension ScrivUIKitFeatures {
    @MainActor static func registerAccount(in router: ScrivUIKitRouter) {
        for kind in [ScrivUIKitRoute.Kind.signIn, .account, .settings, .generationJobs, .codex] {
            router.register(kind) { route, store in
                let controller: UIViewController
                switch route {
                case .signIn: controller = ScrivSignInController(store: store)
                case .account: controller = ScrivAccountController(store: store)
                case .settings: controller = ScrivSettingsController(store: store)
                case .generationJobs: controller = ScrivGenerationJobsController(store: store)
                case .codex: controller = ScrivCodexController(store: store)
                default: return nil
                }
                let navigation = UINavigationController(rootViewController: controller)
                navigation.preferredContentSize = controller.preferredContentSize; navigation.modalPresentationStyle = .formSheet
                return navigation
            }
        }
    }
}
