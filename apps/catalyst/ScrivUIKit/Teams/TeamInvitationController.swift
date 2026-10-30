import UIKit
import ScrivCore

/// A team/account-bound invitation sheet. Secrets exist only for the freshly
/// created link in this presentation; old secrets are never reconstructed.
@MainActor
final class TeamInvitationController: ScrivScreenController, UIAdaptivePresentationControllerDelegate {
    var onInvitationsChanged: (() -> Void)?
    private let teamID: String
    private let accountContext: String
    private var layout: CharacterTeamSheetLayout!
    private let panel = ScrivUIKitTheme.stack(spacing: 18)
    private let issue = ScrivUIKitTheme.label("", size: 14, color: .systemRed)
    private var role = "member"
    private var days = 7
    private var details: JSONValue?
    private var recentURL: URL?
    private var active = true
    private var working = false
    private var loading = false
    private var loadID = UUID()
    private var loadTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var team: CloudTeam? { store.teams.first { $0.id == teamID } }
    private var contextValid: Bool { store.editorAccountContext == accountContext && store.account != nil }

    init(store: WorkspaceStore, teamID: String) {
        self.teamID = teamID; accountContext = store.editorAccountContext
        super.init(store: store, scopeToProject: false); preferredContentSize = CGSize(width: 570, height: 650)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:teamID:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        layout = CharacterTeamSheetLayout(title: "Invite to \(team?.name ?? "team")") { [weak self] in self?.close() }
        view.addSubview(layout); layout.scrivPinEdges(to: view)
        issue.isHidden = true; layout.content.addArrangedSubview(issue); layout.content.addArrangedSubview(panel)
        layout.footer.addArrangedSubview(CharacterTeamUI.button("Done", primary: true) { [weak self] in self?.close() })
        render()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); presentationController?.delegate = self; reload() }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || presentingViewController == nil { stop() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { stop() }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        if !contextValid { loadTask?.cancel(); operationTask?.cancel(); recentURL = nil; showIssue("The account or server changed. Close and reopen invitations for the current account.") }
        render()
    }
    private func render() {
        CharacterTeamUI.clear(panel)
        guard contextValid, let team else {
            panel.addArrangedSubview(ScrivUIKitTheme.notice("This team is not available", message: "Sign in to the same account and reopen this team before changing invitations.", warning: true)); return
        }
        layout.heading.text = "Invite to \(team.name)"
        guard UIKitTeamPolicy.canManage(team) else {
            panel.addArrangedSubview(ScrivUIKitTheme.notice("Invitations are managed by your team", message: "Ask an owner or administrator for an invitation link.")); return
        }
        panel.addArrangedSubview(TeamUIKitUI.invitationPanel(team: team, links: details?["joinLinks"]?.array ?? [], role: role, days: days, recentURL: recentURL,
            working: working, loading: loading, onRole: { [weak self] in self?.role = $0; self?.render() }, onDays: { [weak self] in self?.days = $0; self?.render() },
            onCreate: { [weak self] in self?.createLink() }, onCopy: { [weak self] in if let self, let url = self.recentURL { UIPasteboard.general.string = url.absoluteString } },
            onRevoke: { [weak self] in self?.revoke($0) }))
    }
    private func reload() {
        loadTask?.cancel(); loadID = UUID()
        guard active, contextValid, team != nil else { return }
        let request = loadID; loading = true; render()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.store.cloud.teamDetails(self.teamID)
                guard self.active, self.contextValid, !Task.isCancelled, self.loadID == request else { return }
                guard response["team"]?["id"]?.string == self.teamID else { throw ScrivError.invalid("The server returned details for a different team.") }
                self.details = response; self.loading = false; self.render()
            } catch is CancellationError {} catch {
                guard self.active, self.contextValid, self.loadID == request else { return }
                self.loading = false; self.showIssue(error.localizedDescription); self.render()
            }
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard active, contextValid, !working else { return }
        working = true; issue.isHidden = true; render()
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.working = false; if self.active { self.render() } }
            do { try await operation() }
            catch is CancellationError {} catch { if self.active, self.contextValid { self.showIssue(error.localizedDescription) } }
        }
    }
    private func createLink() {
        guard let team, UIKitTeamPolicy.canManage(team), team.isPaid else { return }
        let chosenRole = role, chosenDays = days
        perform {
            let url = try await self.store.cloud.joinLink(teamId: self.teamID, role: chosenRole, expiresInDays: chosenDays)
            guard self.active, self.contextValid, !Task.isCancelled else { return }
            self.recentURL = url; UIPasteboard.general.string = url.absoluteString; self.onInvitationsChanged?(); self.reload()
        }
    }
    private func revoke(_ linkID: String) {
        guard let team, UIKitTeamPolicy.canManage(team) else { return }
        perform {
            try await self.store.cloud.revokeJoinLink(teamId: self.teamID, linkId: linkID)
            guard self.active, self.contextValid else { return }
            self.recentURL = nil; self.onInvitationsChanged?(); self.reload()
        }
    }
    private func showIssue(_ message: String) { issue.text = message; issue.isHidden = false }
    private func stop() { active = false; loadID = UUID(); loadTask?.cancel(); operationTask?.cancel(); recentURL = nil }
    private func close() { stop(); dismiss(animated: true) }
}
