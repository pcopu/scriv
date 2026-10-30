import UIKit
import ScrivCore

@MainActor
final class TeamsController: ScrivScreenController, UIAdaptivePresentationControllerDelegate {
    private var layout: CharacterTeamSheetLayout!
    private let teamBar = CharacterTeamUI.row([])
    private let segments = UISegmentedControl(items: ["Overview", "Members", "Invitations"])
    private let body = ScrivUIKitTheme.stack(spacing: 18)
    private let errorLabel = ScrivUIKitTheme.label("", size: 14, color: .systemRed)
    private let footerInfo = ScrivUIKitTheme.label("Viewers can read and discuss. Members can edit.", size: 12, color: ScrivUIKitTheme.secondary)
    private var inviteButton: UIButton!
    private var selectedTeamID = ""
    private var details: JSONValue?
    private var loading = false
    private var working = false
    private var active = true
    private var loadID = UUID()
    private var loadTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()
    private var invitationRole = "member"
    private var invitationDays = 7
    private var recentInvitation: (teamID: String, url: URL)?
    private var lastTeams: [CloudTeam] = []
    private var lastAccount = ""
    private var lastProjectID = ""
    private var lastCloudProjectID: String?
    private var lastSyncing = false
    private var team: CloudTeam? { store.teams.first { $0.id == selectedTeamID } }
    private var currentDetails: JSONValue? { details?["team"]?["id"]?.string == selectedTeamID ? details : nil }
    private var members: [JSONValue] { currentDetails?["members"]?.array ?? [] }
    private var joinLinks: [JSONValue] { currentDetails?["joinLinks"]?.array ?? [] }

    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false); preferredContentSize = CGSize(width: 960, height: 800) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        layout = CharacterTeamSheetLayout(title: "Teams & sharing") { [weak self] in self?.close() }
        view.addSubview(layout); layout.scrivPinEdges(to: view)
        layout.close.configuration?.title = "Done"; layout.close.configuration?.image = nil
        segments.selectedSegmentIndex = 1; segments.addAction(UIAction { [weak self] _ in self?.renderBody() }, for: .valueChanged)
        segments.heightAnchor.constraint(equalToConstant: 42).isActive = true
        errorLabel.isHidden = true
        [teamBar, segments, errorLabel, body].forEach(layout.content.addArrangedSubview)
        CharacterTeamUI.clear(layout.footer); layout.footer.addArrangedSubview(footerInfo); layout.footer.addArrangedSubview(CharacterTeamUI.spacer())
        inviteButton = CharacterTeamUI.button("Invite people", primary: true, size: 16) { [weak self] in self?.openInvitations() }
        layout.footer.addArrangedSubview(inviteButton)
        selectedTeamID = store.teams.first?.id ?? ""; render()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); presentationController?.delegate = self; active = true; reload() }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || presentingViewController == nil { stop() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { stop() }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        let account = store.editorAccountContext
        let accountChanged = lastAccount != account
        if accountChanged {
            loadTask?.cancel(); operationTask?.cancel(); loadID = UUID(); operationID = UUID(); details = nil; recentInvitation = nil; working = false; loading = false
        }
        let oldSelection = selectedTeamID
        if !store.teams.contains(where: { $0.id == selectedTeamID }) { selectedTeamID = store.teams.first?.id ?? ""; details = nil; recentInvitation = nil }
        if lastTeams != store.teams || accountChanged || lastProjectID != store.project.id || lastCloudProjectID != store.project.cloudProjectId || lastSyncing != store.isSyncing { render() }
        if accountChanged || oldSelection != selectedTeamID { reload() }
    }
    private func render() {
        lastTeams = store.teams; lastAccount = store.editorAccountContext; lastProjectID = store.project.id; lastCloudProjectID = store.project.cloudProjectId; lastSyncing = store.isSyncing
        CharacterTeamUI.clear(teamBar)
        let menu = CharacterTeamUI.menu(team?.name ?? "No teams yet", actions: store.teams.map { item in
            UIAction(title: item.name, state: item.id == selectedTeamID ? .on : .off) { [weak self] _ in self?.selectTeam(item.id) }
        }); menu.isEnabled = !working && !store.teams.isEmpty
        teamBar.addArrangedSubview(menu)
        if let team, UIKitTeamPolicy.canManage(team) {
            let rename = CharacterTeamUI.button("", symbol: "pencil") { [weak self] in self?.nameTeam(renaming: team) }; rename.accessibilityLabel = "Rename team"; rename.isEnabled = !working; teamBar.addArrangedSubview(rename)
        }
        teamBar.addArrangedSubview(CharacterTeamUI.spacer())
        let create = CharacterTeamUI.button("New team") { [weak self] in self?.nameTeam(renaming: nil) }
        let join = CharacterTeamUI.button("Join") { [weak self] in self?.joinTeam() }
        create.isEnabled = !working; join.isEnabled = !working
        teamBar.addArrangedSubview(create); teamBar.addArrangedSubview(join)
        teamBar.isHidden = store.account == nil; segments.isHidden = team == nil || store.account == nil
        segments.isEnabled = !working
        inviteButton.isHidden = team.map { !UIKitTeamPolicy.canManage($0) } ?? true
        inviteButton.isEnabled = team?.isPaid == true && !working
        renderBody()
    }
    private func renderBody() {
        CharacterTeamUI.clear(body)
        guard store.account != nil else {
            body.addArrangedSubview(ScrivUIKitTheme.notice("Your entire team. One subscription.", message: "$9.99/month per team, with no per-seat charge. Personal editing and hosted script, timing and image-prompt metadata remain free; Team adds collaboration and private image-file hosting."))
            body.addArrangedSubview(CharacterTeamUI.button("Sign in to Scriv", primary: true) { [weak self] in self?.show(.signIn) }); return
        }
        guard let team else {
            body.addArrangedSubview(ScrivUIKitTheme.notice("Make room for collaborators", message: "Create a team or join one with an invitation link. Creating a team does not start a paid subscription.")); return
        }
        body.addArrangedSubview(planCard(team))
        switch segments.selectedSegmentIndex {
        case 2:
            if UIKitTeamPolicy.canManage(team) {
                body.addArrangedSubview(TeamUIKitUI.invitationPanel(team: team, links: joinLinks, role: invitationRole, days: invitationDays,
                    recentURL: recentInvitation?.teamID == team.id ? recentInvitation?.url : nil, working: working, loading: loading,
                    onRole: { [weak self] in self?.invitationRole = $0; self?.renderBody() }, onDays: { [weak self] in self?.invitationDays = $0; self?.renderBody() },
                    onCreate: { [weak self] in self?.createInvitation(team) }, onCopy: { [weak self] in self?.copyInvitation(team.id) }, onRevoke: { [weak self] in self?.revokeInvitation($0, team: team) }))
            } else { body.addArrangedSubview(ScrivUIKitTheme.notice("Invitations are managed by your team", message: "Ask an owner or administrator for an invitation link.")) }
        case 1: body.addArrangedSubview(sharingCard(team)); body.addArrangedSubview(membersCard(team))
        default:
            body.addArrangedSubview(sharingCard(team))
            body.addArrangedSubview(ScrivUIKitTheme.notice("One plan for the whole team", message: "Members can edit. Viewers can read and discuss. Personal scripts, timing and image-prompt metadata stay free. Shared team projects and hosted image files require an active Team plan."))
        }
    }
    private func planCard(_ team: CloudTeam) -> UIView {
        let attention = UIKitTeamPolicy.billingNeedsAttention(team)
        let status = ScrivUIKitTheme.label(team.isPaid ? "● Active" : attention ? "● Needs attention" : "Not active", size: 13, weight: .medium, color: team.isPaid ? .systemGreen : attention ? .systemOrange : ScrivUIKitTheme.secondary)
        let title = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Team plan", size: 17, weight: .semibold), ScrivUIKitTheme.label("$9.99 / month", size: 15), ScrivUIKitTheme.label("For the whole team · no per-seat charge", size: 13, color: ScrivUIKitTheme.secondary)], spacing: 5)
        let row = CharacterTeamUI.row([CharacterTeamUI.symbol("creditcard", size: 30), title, CharacterTeamUI.spacer(), status], spacing: 18)
        if UIKitTeamPolicy.canStartCheckout(team) { let subscribe = CharacterTeamUI.button("Subscribe…", primary: true) { [weak self] in self?.confirmCheckout(team) }; subscribe.isEnabled = !working; row.addArrangedSubview(subscribe) }
        if team.role == "owner", team.isPaid || team.status != nil && team.status != "free" || currentDetails?["team"]?["billingCustomer"] == .bool(true) {
            let billing = CharacterTeamUI.button("Manage billing") { [weak self] in self?.openBilling(team, portal: true) }; billing.isEnabled = !working; row.addArrangedSubview(billing)
        }
        let result = ScrivUIKitTheme.stack([ScrivUIKitTheme.card(row)], spacing: 12)
        if attention { result.addArrangedSubview(ScrivUIKitTheme.notice("Billing needs attention", message: "Manage the existing subscription — do not subscribe again. Team access follows its current billing status.", warning: true)) }
        return result
    }
    private func sharingCard(_ team: CloudTeam) -> UIView {
        let currentTeamID = store.cloudProjects.first { $0.id == store.project.cloudProjectId }?.teamId
        let picture = UIKitAssetImageView(); picture.configure(url: store.project.asset(store.project.cues.first?.imageId).flatMap { store.assetURL($0) }, title: store.project.title, fill: true, missingText: "No preview")
        picture.widthAnchor.constraint(equalToConstant: 154).isActive = true; picture.heightAnchor.constraint(equalToConstant: 84).isActive = true
        let text = ScrivUIKitTheme.stack([ScrivUIKitTheme.label(store.project.title, size: 17, weight: .semibold), ScrivUIKitTheme.label(currentTeamID == team.id ? "Shared with this team" : "This project is not shared with this team", size: 13, color: ScrivUIKitTheme.secondary)], spacing: 6)
        let action = CharacterTeamUI.button(currentTeamID == team.id ? "Open project" : "Share team copy") { [weak self] in
            guard let self else { return }; if currentTeamID == team.id { self.close() } else { self.confirmShare(team) }
        }
        action.isEnabled = currentTeamID == team.id || (team.isPaid && team.role != "viewer" && !working && !store.isSyncing)
        return ScrivUIKitTheme.card(CharacterTeamUI.row([picture, text, CharacterTeamUI.spacer(), action], spacing: 18))
    }
    private func membersCard(_ team: CloudTeam) -> UIView {
        let refresh = CharacterTeamUI.button("", symbol: "arrow.clockwise") { [weak self] in self?.reload(refreshAccount: true) }; refresh.accessibilityLabel = "Refresh members"; refresh.isEnabled = !working && !loading
        let title = loading ? "Members · loading…" : "Members (\(members.count))"
        let content = ScrivUIKitTheme.stack([CharacterTeamUI.row([ScrivUIKitTheme.label(title, size: 15, weight: .semibold), CharacterTeamUI.spacer(), ScrivUIKitTheme.label("Role", size: 13, color: ScrivUIKitTheme.secondary), refresh]), CharacterTeamUI.separator()], spacing: 14)
        for member in members { content.addArrangedSubview(memberRow(member, team: team)); content.addArrangedSubview(CharacterTeamUI.separator()) }
        if members.isEmpty && !loading { content.addArrangedSubview(ScrivUIKitTheme.label("No member details loaded yet.", size: 14, color: ScrivUIKitTheme.secondary)) }
        if team.role != "owner", let user = store.account?.id {
            let leave = CharacterTeamUI.button("Leave team…") { [weak self] in self?.confirmRemoval(team: team, userID: user, name: "you", isSelf: true) }; leave.configuration?.baseForegroundColor = .systemRed; leave.isEnabled = !working; content.addArrangedSubview(leave)
        }
        return content
    }
    private func memberRow(_ member: JSONValue, team: CloudTeam) -> UIView {
        let id = member["id"]?.string ?? "", role = member["role"]?.string ?? "member", name = member["name"]?.string ?? "Team member"
        let text = ScrivUIKitTheme.stack([ScrivUIKitTheme.label(name + (id == store.account?.id ? " (you)" : ""), size: 15, weight: .semibold), ScrivUIKitTheme.label(UIKitTeamPolicy.roleDescription(role), size: 13, color: ScrivUIKitTheme.secondary)], spacing: 5)
        let row = CharacterTeamUI.row([TeamUIKitUI.avatar(name, color: role == "owner" ? ScrivUIKitTheme.accent : role == "viewer" ? .systemPink : .systemGreen), text, CharacterTeamUI.spacer()], spacing: 14)
        if !id.isEmpty, UIKitTeamPolicy.canEditMember(actorRole: team.role, targetRole: role) {
            let roles = team.role == "owner" ? ["admin", "member", "viewer"] : ["member", "viewer"]
            let menu = CharacterTeamUI.menu(role.capitalized, actions: roles.map { target in UIAction(title: "\(target.capitalized) · \(UIKitTeamPolicy.roleDescription(target).lowercased())", state: role == target ? .on : .off) { [weak self] _ in
                guard target != role else { return }; self?.setRole(target, team: team, userID: id)
            } }); menu.widthAnchor.constraint(equalToConstant: 150).isActive = true; menu.isEnabled = !working; row.addArrangedSubview(menu)
            let more = CharacterTeamUI.button("", symbol: "ellipsis") {}; more.accessibilityLabel = "Actions for \(name)"
            more.menu = UIMenu(children: [UIAction(title: "Remove member…", attributes: .destructive) { [weak self] _ in self?.confirmRemoval(team: team, userID: id, name: name, isSelf: id == self?.store.account?.id) }]); more.showsMenuAsPrimaryAction = true; more.isEnabled = !working; row.addArrangedSubview(more)
        } else { let roleLabel = ScrivUIKitTheme.label(role.capitalized, size: 14, color: ScrivUIKitTheme.secondary); roleLabel.widthAnchor.constraint(equalToConstant: 188).isActive = true; row.addArrangedSubview(roleLabel) }
        return row
    }
    private func selectTeam(_ id: String) {
        guard !working, id != selectedTeamID else { return }
        selectedTeamID = id; details = nil; recentInvitation = nil; errorLabel.isHidden = true; render(); reload()
    }
    private func reload(refreshAccount: Bool = false) {
        loadTask?.cancel(); loadID = UUID()
        guard active, store.account != nil, !selectedTeamID.isEmpty else { return }
        let id = selectedTeamID, request = loadID, account = store.editorAccountContext
        loading = true; renderBody()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if refreshAccount { try await self.store.cloud.refreshAccount() }
                let details = try await self.store.cloud.teamDetails(id)
                guard !Task.isCancelled, self.active, self.loadID == request, self.selectedTeamID == id, self.store.editorAccountContext == account else { return }
                guard details["team"]?["id"]?.string == id else { throw ScrivError.invalid("The server returned details for a different team.") }
                self.details = details; self.loading = false; self.renderBody()
            } catch is CancellationError {} catch {
                guard self.active, self.loadID == request, self.store.editorAccountContext == account else { return }
                self.loading = false; self.showError(error.localizedDescription); self.renderBody()
            }
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working, active, store.account != nil else { return }
        working = true; errorLabel.isHidden = true; let account = store.editorAccountContext, request = UUID(); operationID = request; render()
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.operationID == request { self.working = false; if self.active { self.render() } } }
            do { try await operation() }
            catch is CancellationError {} catch { if self.active, self.store.editorAccountContext == account { self.showError(error.localizedDescription) } }
        }
    }
    private func nameTeam(renaming team: CloudTeam?) {
        let account = store.editorAccountContext
        let alert = UIAlertController(title: team == nil ? "Create a team" : "Rename team", message: team == nil ? "Creating a team does not subscribe or charge you. Activate Team separately to enable shared projects and image-file hosting." : nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Team name"; $0.text = team?.name; $0.autocapitalizationType = .words }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: team == nil ? "Create" : "Rename", style: .default) { [weak self, weak alert] _ in
            guard let self, self.store.editorAccountContext == account else { return }
            let name = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf16.count <= 100 else { self.showError("Enter a team name of 1–100 characters."); return }
            self.run {
                if let team { try await self.store.cloud.renameTeam(teamId: team.id, name: name) }
                else { let created = try await self.store.cloud.createTeam(name: name); if self.active, self.store.editorAccountContext == account { self.selectedTeamID = created.id } }
                if self.active, self.store.editorAccountContext == account { self.details = nil; self.reload() }
            }
        }); present(alert, animated: true)
    }
    private func joinTeam() {
        let account = store.editorAccountContext
        let alert = UIAlertController(title: "Join a team", message: "Paste a Scriv invitation for the server selected in Settings.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Invitation link or token"; $0.autocorrectionType = .no; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Join", style: .default) { [weak self, weak alert] _ in
            guard let self, self.store.editorAccountContext == account else { return }
            let value = alert?.textFields?.first?.text ?? ""
            self.run { let token = try TeamInvitation.token(from: value, serverURL: self.store.cloud.baseURL); let joined = try await self.store.cloud.joinTeam(token: token)
                if self.active, self.store.editorAccountContext == account { self.selectedTeamID = joined.id; self.details = nil; self.reload() }
            }
        }); present(alert, animated: true)
    }
    private func setRole(_ role: String, team: CloudTeam, userID: String) {
        run { [self] in try await store.cloud.setMemberRole(teamId: team.id, userId: userID, role: role); try await store.cloud.refreshAccount(); reload() }
    }
    private func confirmRemoval(team: CloudTeam, userID: String, name: String, isSelf: Bool) {
        let account = store.editorAccountContext
        let alert = UIAlertController(title: isSelf ? "Leave this team?" : "Remove \(name)?", message: "Access to the team's shared projects ends immediately. Prior edits and messages remain in history. Revoke shared invitation links too if the person must not rejoin.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: isSelf ? "Leave team" : "Remove member", style: .destructive) { [weak self] _ in
            guard let self, self.store.editorAccountContext == account else { return }
            self.run { try await self.store.cloud.removeMember(teamId: team.id, userId: userID); try await self.store.cloud.refreshAccount(); if !isSelf { self.reload() } }
        }); present(alert, animated: true)
    }
    private func openInvitations() {
        guard let team else { return }
        let controller = TeamInvitationController(store: store, teamID: team.id)
        controller.onInvitationsChanged = { [weak self] in if self?.selectedTeamID == team.id { self?.reload() } }
        CharacterTeamUI.present(controller, from: self, width: 570, height: 650)
    }
    private func createInvitation(_ team: CloudTeam) {
        let role = invitationRole, days = invitationDays, account = store.editorAccountContext
        guard UIKitTeamPolicy.canManage(team), team.isPaid else { return }
        run {
            let url = try await self.store.cloud.joinLink(teamId: team.id, role: role, expiresInDays: days)
            guard self.active, !Task.isCancelled, self.selectedTeamID == team.id, self.store.editorAccountContext == account else { return }
            self.recentInvitation = (team.id, url); UIPasteboard.general.string = url.absoluteString; self.reload()
        }
    }
    private func copyInvitation(_ teamID: String) { if let recentInvitation, recentInvitation.teamID == teamID { UIPasteboard.general.string = recentInvitation.url.absoluteString } }
    private func revokeInvitation(_ id: String, team: CloudTeam) {
        run { try await self.store.cloud.revokeJoinLink(teamId: team.id, linkId: id); self.recentInvitation = nil; self.reload() }
    }
    private func confirmShare(_ team: CloudTeam) {
        let projectID = store.project.id, context = store.navigationContext, account = store.editorAccountContext
        let alert = UIAlertController(title: "Share with \(team.name)?", message: store.project.cloudProjectId == nil ? "Share the current project with this team. Local files remain on this device." : "Create a separate team copy. The original project and its history remain unchanged.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Share", style: .default) { [weak self] _ in
            guard let self, self.store.project.id == projectID, self.store.navigationContext == context, self.store.editorAccountContext == account else { return }
            self.store.shareProjectWithTeam(team.id)
        }); present(alert, animated: true)
    }
    private func confirmCheckout(_ team: CloudTeam) {
        guard UIKitTeamPolicy.canStartCheckout(team) else { return }
        let account = store.editorAccountContext
        let alert = UIAlertController(title: "Open Team subscription checkout?", message: "$9.99/month for the whole team, with no per-seat charge. Checkout opens in your browser; this button does not complete a payment.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Open checkout", style: .default) { [weak self] _ in
            guard let self, self.store.editorAccountContext == account, self.selectedTeamID == team.id else { return }
            self.openBilling(team, portal: false)
        }); present(alert, animated: true)
    }
    private func openBilling(_ team: CloudTeam, portal: Bool) {
        let account = store.editorAccountContext
        guard selectedTeamID == team.id, let current = store.teams.first(where: { $0.id == team.id }),
              current.role == "owner", portal || UIKitTeamPolicy.canStartCheckout(current) else { return }
        run {
            let url: URL
            do { url = try await self.store.cloud.billing(teamId: team.id, portal: portal) }
            catch let error as CloudRequestError where error.status == 409 { try? await self.store.cloud.refreshAccount(); self.reload(); throw error }
            guard self.active, self.selectedTeamID == team.id, self.store.editorAccountContext == account else { return }
            UIApplication.shared.open(url, options: [:]) { [weak self] opened in if !opened { Task { @MainActor in self?.showError("The browser could not open billing. Please try again.") } } }
        }
    }
    private func showError(_ value: String) { errorLabel.text = value; errorLabel.isHidden = false }
    private func stop() { active = false; loadID = UUID(); operationID = UUID(); loadTask?.cancel(); operationTask?.cancel(); recentInvitation = nil }
    private func close() { stop(); dismiss(animated: true) }
}
