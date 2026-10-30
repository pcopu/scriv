import SwiftUI
import AppKit
import ScrivCore

@MainActor
struct TeamSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTeamID = ""
    @State private var teamName = ""
    @State private var invite = ""
    @State private var creating = false
    @State private var joining = false
    @State private var renaming = false
    @State private var renameTeamID = ""
    @State private var pendingRemoval: Removal?
    @State private var showingRemoval = false
    @State private var teamDetails: JSONValue?
    @State private var loadID = UUID()
    @State private var isLoading = false
    @State private var isWorking = false
    @State private var isVisible = false
    @State private var operationError: String?
    @State private var copiedInvitation: (teamID: String, url: String)?
    @State private var invitationRole = "member"
    @State private var invitationDays = 7
    @State private var section = "Members"
    @State private var inviting = false

    private struct Removal { let teamID: String; let userID: String; let name: String; let isSelf: Bool }
    private var team: CloudTeam? { store.teams.first { $0.id == selectedTeamID } }
    private var canManage: Bool { team?.role == "owner" || team?.role == "admin" }
    private var details: JSONValue? { teamDetails?["team"]?["id"]?.string == selectedTeamID ? teamDetails : nil }
    private var members: [JSONValue] { details?["members"]?.array ?? [] }
    private var links: [JSONValue] { details?["joinLinks"]?.array ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Teams & sharing").font(.system(size: 19, weight: .semibold))
                Spacer()
                if isWorking { ProgressView().controlSize(.small).accessibilityLabel("Updating team") }
                Button("Done") { dismiss() }.buttonStyle(ScrivPrimaryButtonStyle()).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 24).padding(.vertical, 18)
            Divider().opacity(0.5)
            if store.account == nil { signInPanel.padding(24) }
            else {
                VStack(spacing: 16) {
                    teamPicker
                    if team != nil { PillSegmentPicker(values: ["Overview", "Members", "Invitations"], selection: $section) { $0 } }
                    if let operationError {
                        ScrivNotice(tone: .warning, title: "This change needs attention", message: operationError)
                    }
                    if let team {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                planCard(team)
                                if section != "Invitations" { sharingCard(team) }
                                if section == "Members" { membersCard(team) }
                                if section == "Overview" {
                                    ScrivNotice(title: "One plan for the whole team", message: "Members can edit. Viewers can read and discuss. Your scripts, timing and image prompts stay in the cloud; hosted image files require an active Team plan.")
                                }
                                if section == "Invitations" {
                                    if canManage { invitationCard(team) }
                                    else { ScrivNotice(title: "Invitations are managed by your team", message: "Ask an owner or administrator for an invitation link.") }
                                }
                            }.padding(.bottom, 4)
                        }
                    } else {
                        EmptyPanel(symbol: "person.2", title: "Make room for your collaborators", message: "Create a team, or join one with an invitation link. A Team subscription is $9.99/month for the whole team.")
                    }
                }.padding(24)
                Divider().opacity(0.5)
                HStack {
                    Text("Viewers can read and discuss. Members can edit.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if canManage, let team {
                        Button("Invite people") { inviting = true }.buttonStyle(ScrivPrimaryButtonStyle(fontSize: 14))
                            .disabled(isWorking || !team.isPaid)
                    }
                }.padding(.horizontal, 24).padding(.vertical, 17)
            }
        }.frame(width: 840, height: 720).background(ScrivTheme.sheetBackground)
            .sheet(isPresented: $inviting) {
                if let team {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text("Invite to \(team.name)").font(.system(size: 20, weight: .semibold)); Spacer(); Button("Done") { inviting = false }.keyboardShortcut(.cancelAction) }
                            .padding(24)
                        Divider().opacity(0.5)
                        ScrollView { invitationCard(team).padding(24) }
                    }.frame(width: 520, height: 570).background(ScrivTheme.sheetBackground)
                }
            }
            .onAppear { isVisible = true; if selectedTeamID.isEmpty { selectedTeamID = store.teams.first?.id ?? "" } }
            .onDisappear { isVisible = false; loadID = UUID() }
            .task(id: selectedTeamID) {
                copiedInvitation = nil; operationError = nil; inviting = false
                if !selectedTeamID.isEmpty { await reload(selectedTeamID) }
                else { teamDetails = nil; isLoading = false }
            }
            .onChange(of: store.teams) { old, teams in
                let previousIDs = Set(old.map(\.id))
                if let added = teams.first(where: { !previousIDs.contains($0.id) }) { selectedTeamID = added.id }
                else if !teams.contains(where: { $0.id == selectedTeamID }) { selectedTeamID = teams.first?.id ?? "" }
            }
            .alert("Create a team", isPresented: $creating) {
                TextField("Team name", text: $teamName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
                    run { let created = try await store.cloud.createTeam(name: name); if isVisible { selectedTeamID = created.id; teamName = "" } }
                }.disabled(teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: { Text("Create the team first, then subscribe to enable shared projects and hosted images.") }
            .alert("Join a team", isPresented: $joining) {
                TextField("Invitation link or token", text: $invite)
                Button("Cancel", role: .cancel) {}
                Button("Join") {
                    let input = invite
                    run { let token = try TeamInvitation.token(from: input, serverURL: store.cloud.baseURL); let joined = try await store.cloud.joinTeam(token: token); if isVisible { selectedTeamID = joined.id; invite = ""; await reload(joined.id) } }
                }.disabled(invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("Rename team", isPresented: $renaming) {
                TextField("Team name", text: $teamName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let id = renameTeamID, name = teamName.trimmingCharacters(in: .whitespacesAndNewlines)
                    run { try await store.cloud.renameTeam(teamId: id, name: name); await reload(id) }
                }.disabled(teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog(pendingRemoval?.isSelf == true ? "Leave this team?" : "Remove \(pendingRemoval?.name ?? "member") from the team?", isPresented: $showingRemoval, titleVisibility: .visible, presenting: pendingRemoval) { removal in
                Button(removal.isSelf ? "Leave team" : "Remove member", role: .destructive) {
                    pendingRemoval = nil
                    run {
                        try await store.cloud.removeMember(teamId: removal.teamID, userId: removal.userID)
                        try await store.cloud.refreshAccount()
                        if !removal.isSelf { await reload(removal.teamID) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: { _ in Text("Access to this team's shared projects ends immediately. Prior edits and messages stay in history. Revoke shared invitation links too if the person must not rejoin.") }
    }

    private var signInPanel: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.circle").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(ScrivTheme.accent)
            Text("Your entire team. One subscription.").font(.title2.weight(.semibold))
            Text("$9.99/month per team. Invite collaborators with a link, share projects, edit live, and keep images available in the cloud.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
            ScrivEmailSignInForm(cloud:store.cloud).frame(width:350)
            Text("Single-person editing and script storage stay free.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
    private var teamPicker: some View {
        HStack(spacing: 12) {
            Picker("Team", selection: $selectedTeamID) {
                if store.teams.isEmpty { Text("No teams yet").tag("") }
                ForEach(store.teams) { Text($0.name).tag($0.id) }
            }.labelsHidden().frame(maxWidth: 330)
            if canManage, let team {
                Button { renameTeamID = team.id; teamName = team.name; renaming = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Rename team")
            }
            Spacer()
            Button("Join") { joining = true }.buttonStyle(ScrivSecondaryButtonStyle())
            Button("New team") { teamName = ""; creating = true }.buttonStyle(ScrivSecondaryButtonStyle())
        }.disabled(isWorking)
    }
    private func planCard(_ team: CloudTeam) -> some View {
        let needsAttention = !team.isPaid && !["free", "canceled", "incomplete_expired"].contains(team.status ?? "free")
        return VStack(spacing: 12) {
            ScrivCard {
                HStack(spacing: 15) {
                    Image(systemName: "creditcard").font(.system(size: 24)).foregroundStyle(.secondary)
                        .frame(width: 54, height: 54).background(ScrivTheme.inset.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Team plan").font(.system(size: 16, weight: .semibold))
                        Text("$9.99 / month").font(.system(size: 14))
                        Text("For the whole team · no per-seat charge").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(team.isPaid ? "Active" : needsAttention ? "Needs attention" : "Not active", systemImage: "circle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(team.isPaid ? Color.green : needsAttention ? .orange : .secondary)
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background((team.isPaid ? Color.green : Color.orange).opacity(team.isPaid || needsAttention ? 0.10 : 0.04), in: Capsule())
                    if team.role == "owner" {
                        if !team.isPaid, ["free", "canceled", "incomplete_expired"].contains(team.status ?? "free") {
                            Button("Subscribe…") { openBilling(team.id, portal: false) }.buttonStyle(ScrivPrimaryButtonStyle()).disabled(isWorking)
                        }
                        if team.isPaid || team.status != nil && team.status != "free" || details?["team"]?["billingCustomer"] == .bool(true) {
                            Button("Manage billing") { openBilling(team.id, portal: true) }.buttonStyle(ScrivSecondaryButtonStyle()).disabled(isWorking)
                        }
                    }
                }
            }
            if needsAttention {
                ScrivNotice(tone: .warning, title: "Billing needs attention", message: "Manage the existing subscription — do not subscribe again. Your team’s access follows its current billing status.")
            }
        }
    }
    private func sharingCard(_ team: CloudTeam) -> some View {
        ScrivCard {
            HStack(spacing: 18) {
                AssetImageView(url: store.project.asset(store.project.cues.first?.imageId).flatMap { store.assetURL($0) }, title: store.project.title, cornerRadius: 9, unavailableText: "No preview")
                    .frame(width: 154, height: 82)
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.project.title).font(.system(size: 16, weight: .semibold))
                    Text(currentTeamID == team.id ? "Shared with this team" : "This project is not shared with this team")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if !team.isPaid { Text("Activate Team to share projects and image files.").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer()
                if currentTeamID == team.id {
                    Button("Open project") { dismiss() }.buttonStyle(ScrivSecondaryButtonStyle())
                } else {
                    Button("Share team copy") { store.shareProjectWithTeam(team.id) }.buttonStyle(ScrivSecondaryButtonStyle())
                        .disabled(!team.isPaid || team.role == "viewer" || store.isSyncing || isWorking)
                }
            }
        }
    }
    private var currentTeamID: String? { store.cloudProjects.first { $0.id == store.project.cloudProjectId }?.teamId }
    private func membersCard(_ team: CloudTeam) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Members (\(members.count))").font(.system(size: 13, weight: .semibold)); Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Text("Role").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 132, alignment: .leading)
                Button { run { try await store.cloud.refreshAccount(); await reload(team.id) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh members").disabled(isWorking || isLoading)
            }.padding(.horizontal, 14).padding(.vertical, 13)
            Divider().opacity(0.5)
            ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                memberRow(member, team: team)
                Divider().opacity(0.4)
            }
            if members.isEmpty, !isLoading { Text("No member details loaded yet.").font(.callout).foregroundStyle(.secondary).padding(18) }
            if team.role != "owner", let userID = store.account?.id {
                Button("Leave team…", role: .destructive) { requestRemoval(Removal(teamID: team.id, userID: userID, name: "you", isSelf: true)) }
                    .buttonStyle(.borderless).padding(14).disabled(isWorking)
            }
        }
    }
    private func memberRow(_ member: JSONValue, team: CloudTeam) -> some View {
        let id = member["id"]?.string ?? "", role = member["role"]?.string ?? "member", name = member["name"]?.string ?? "Team member"
        let editable = (team.role == "owner" || team.role == "admin" && role != "admin") && role != "owner"
        return HStack(spacing: 14) {
            InitialAvatar(name: name, color: role == "owner" ? ScrivTheme.accent : role == "viewer" ? .pink : .green, size: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text(name + (id == store.account?.id ? " (you)" : "")).font(.system(size: 14, weight: .semibold))
                Text(role == "owner" ? "Owner of this team" : role == "viewer" ? "Can read and discuss" : role == "admin" ? "Can edit and manage the team" : "Can edit project content")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if editable {
                Menu {
                    if team.role == "owner", role != "admin" { Button("Admin · can manage team") { setRole("admin", team: team.id, user: id) } }
                    if role != "member" { Button("Member · can edit") { setRole("member", team: team.id, user: id) } }
                    if role != "viewer" { Button("Viewer · can read and discuss") { setRole("viewer", team: team.id, user: id) } }
                } label: { HStack { Text(role.capitalized); Spacer(); Image(systemName: "chevron.down").font(.system(size: 9)) }.frame(width: 117) }
                    .menuStyle(.borderlessButton).padding(.horizontal, 11).padding(.vertical, 9)
                    .background(ScrivTheme.inset.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ScrivTheme.hairline)).disabled(isWorking)
                Menu { Button("Remove member…", role: .destructive) { requestRemoval(Removal(teamID: team.id, userID: id, name: name, isSelf: id == store.account?.id)) } }
                    label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(isWorking)
            } else { Text(role.capitalized).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 170, alignment: .leading) }
        }.padding(.horizontal, 14).padding(.vertical, 14)
    }
    private func invitationCard(_ team: CloudTeam) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if inviting, let operationError { ScrivNotice(tone: .warning, title: "Invitation not ready", message: operationError) }
            HStack {
                Text("Access").font(.system(size: 14, weight: .medium)).frame(width: 70, alignment: .leading)
                Picker("Access", selection: $invitationRole) { Text("Member · can edit").tag("member"); Text("Viewer · read & discuss").tag("viewer") }
                    .labelsHidden().frame(maxWidth: .infinity)
            }
            HStack {
                Text("Expires").font(.system(size: 14, weight: .medium)).frame(width: 70, alignment: .leading)
                Picker("Expires", selection: $invitationDays) { Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30) }
                    .labelsHidden().frame(maxWidth: .infinity)
            }
            Text("Anyone with the link can sign in and join. Links are reusable.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { createInvitation(team.id) } label: { Text("Create & copy link").frame(maxWidth: .infinity) }
                .buttonStyle(ScrivPrimaryButtonStyle(fontSize: 14)).disabled(!canManage || !team.isPaid || isWorking)
            if !team.isPaid { ScrivNotice(tone: .warning, title: "Activate Team first", message: "New invitation links are unavailable until Team is active.") }
            Divider().padding(.vertical, 4).opacity(0.5)
            Text("Invitation links").font(.system(size: 13)).foregroundStyle(.secondary)
            if let copiedInvitation, copiedInvitation.teamID == team.id {
                ScrivCard {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 23))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Link created and copied").font(.system(size: 14, weight: .semibold))
                            Text("Copy it again before closing this window.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy") { copy(copiedInvitation.url) }.buttonStyle(ScrivSecondaryButtonStyle())
                    }
                }
            }
            if links.isEmpty, !isLoading { Text("No invitation links yet.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 6) }
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                let revoked = link["revokedAt"] != nil && link["revokedAt"] != .null
                let expiration = link["expiresAt"]?.int ?? 0
                let expired = expiration <= Int(Date().timeIntervalSince1970 * 1000)
                ScrivCard {
                    HStack(spacing: 12) {
                        Image(systemName: "link").font(.system(size: 21)).foregroundStyle(.secondary)
                            .frame(width: 40, height: 40).background(ScrivTheme.inset.opacity(0.5), in: Circle())
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\((link["role"]?.string ?? "member").capitalized) invitation").font(.system(size: 14, weight: .semibold))
                            Text(revoked ? "Revoked" : expired ? "Expired" : "Expires \(Date(timeIntervalSince1970: Double(expiration) / 1000).formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !revoked && !expired, let id = link["id"]?.string {
                            Button("Revoke", role: .destructive) {
                                run {
                                    try await store.cloud.revokeJoinLink(teamId: team.id, linkId: id)
                                    if copiedInvitation?.teamID == team.id { copiedInvitation = nil }
                                    await reload(team.id)
                                }
                            }.buttonStyle(.bordered).tint(.red).disabled(isWorking || !canManage)
                        }
                    }
                }
            }
            ScrivNotice(title: "", message: "Revoking a link stops new joins. Existing members keep access.")
            Text("For security, old link secrets cannot be retrieved. Create a new link when you no longer have its saved copy.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(isWorking)
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true; operationError = nil
        Task {
            defer { isWorking = false }
            do { try await operation() }
            catch is CancellationError {}
            catch { if isVisible { operationError = error.localizedDescription } }
        }
    }
    private func reload(_ teamID: String) async {
        guard isVisible, selectedTeamID == teamID, !teamID.isEmpty else { return }
        let requestID = UUID(); loadID = requestID; isLoading = true
        defer { if loadID == requestID { isLoading = false } }
        do {
            let response = try await store.cloud.teamDetails(teamID)
            guard !Task.isCancelled, isVisible, loadID == requestID, selectedTeamID == teamID else { return }
            teamDetails = response
        } catch is CancellationError {} catch {
            guard isVisible, loadID == requestID, selectedTeamID == teamID else { return }
            operationError = error.localizedDescription
        }
    }
    private func setRole(_ role: String, team: String, user: String) {
        run { try await store.cloud.setMemberRole(teamId: team, userId: user, role: role); try await store.cloud.refreshAccount(); await reload(team) }
    }
    private func requestRemoval(_ removal: Removal) { pendingRemoval = removal; showingRemoval = true }
    private func createInvitation(_ teamID: String) {
        let role = invitationRole, days = invitationDays
        run {
            let url = try await store.cloud.joinLink(teamId: teamID, role: role, expiresInDays: days)
            guard isVisible, selectedTeamID == teamID else { return }
            copiedInvitation = (teamID, url.absoluteString); copy(url.absoluteString)
            await reload(teamID)
        }
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func openBilling(_ teamID: String, portal: Bool) {
        run {
            let url: URL
            do { url = try await store.cloud.billing(teamId: teamID, portal: portal) }
            catch let error as CloudRequestError where error.status == 409 {
                // Checkout may have repaired a delayed webhook. Reflect that
                // canonical state before offering the owner another action.
                try? await store.cloud.refreshAccount()
                await reload(teamID)
                throw error
            }
            guard isVisible, selectedTeamID == teamID else { return }
            guard NSWorkspace.shared.open(url) else { throw ScrivError.unavailable("Your browser could not open billing. Please try again.") }
        }
    }
}
