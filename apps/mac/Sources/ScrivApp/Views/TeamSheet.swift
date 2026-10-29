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
    @State private var invitationDays = 30

    private struct Removal { let teamID: String; let userID: String; let name: String; let isSelf: Bool }
    private var team: CloudTeam? { store.teams.first { $0.id == selectedTeamID } }
    private var canManage: Bool { team?.role == "owner" || team?.role == "admin" }
    private var details: JSONValue? { teamDetails?["team"]?["id"]?.string == selectedTeamID ? teamDetails : nil }
    private var members: [JSONValue] { details?["members"]?.array ?? [] }
    private var links: [JSONValue] { details?["joinLinks"]?.array ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("Teams & sharing").font(.system(size: 25, weight: .semibold))
                Spacer()
                if isWorking { ProgressView().controlSize(.small).accessibilityLabel("Updating team") }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let operationError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(operationError).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { self.operationError = nil }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if store.account == nil { signInPanel }
            else {
                teamPicker
                if let team {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            planCard(team)
                            sharingCard(team)
                            membersCard(team)
                            if canManage { invitationCard(team) }
                        }.padding(.bottom, 8)
                    }
                } else {
                    EmptyPanel(symbol: "person.2", title: "Make room for your collaborators", message: "Create a team, or join one with an invitation link. A Team subscription is $9.99/month for the whole team.")
                }
            }
        }.padding(24).frame(width: 710, height: 680)
            .onAppear { isVisible = true; if selectedTeamID.isEmpty { selectedTeamID = store.teams.first?.id ?? "" } }
            .onDisappear { isVisible = false; loadID = UUID() }
            .task(id: selectedTeamID) {
                copiedInvitation = nil; operationError = nil
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
            Button("Sign in to Scriv") { run { try await store.cloud.signIn() } }.buttonStyle(.borderedProminent).controlSize(.large).disabled(isWorking)
            Text("Single-person editing and script storage stay free.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity)
    }
    private var teamPicker: some View {
        HStack(spacing: 12) {
            Picker("Team", selection: $selectedTeamID) {
                if store.teams.isEmpty { Text("No teams yet").tag("") }
                ForEach(store.teams) { Text($0.name).tag($0.id) }
            }.frame(maxWidth: 330)
            Spacer()
            Button("Join…") { joining = true }
            Button("New team", systemImage: "plus") { teamName = ""; creating = true }.buttonStyle(.bordered)
        }.disabled(isWorking)
    }
    private func planCard(_ team: CloudTeam) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "person.2.fill").font(.system(size: 26, weight: .light)).foregroundStyle(ScrivTheme.accent).frame(width: 54, height: 54).background(ScrivTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(team.name).font(.system(size: 18, weight: .semibold))
                    if canManage {
                        Button("Rename team", systemImage: "pencil") { renameTeamID = team.id; teamName = team.name; renaming = true }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(isWorking)
                    }
                }
                Text(team.isPaid ? "Team · $9.99/month · no per-seat charge" : "Activate Team to enable collaboration")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("\(details == nil ? "Loading members" : "\(members.count) members") · \((team.status ?? "free").replacingOccurrences(of: "_", with: " ").capitalized)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if !team.isPaid, !["free", "canceled", "incomplete_expired"].contains(team.status ?? "free") {
                    Text("Use Manage billing to resolve your existing subscription. You won't be charged for a second one.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if team.role == "owner" {
                VStack(alignment: .trailing, spacing: 8) {
                    if !team.isPaid, ["free", "canceled", "incomplete_expired"].contains(team.status ?? "free") {
                        Button("Subscribe · $9.99/mo") { openBilling(team.id, portal: false) }.buttonStyle(.borderedProminent)
                    }
                    if team.isPaid || team.status != nil && team.status != "free" || details?["team"]?["billingCustomer"] == .bool(true) {
                        Button("Manage billing") { openBilling(team.id, portal: true) }.buttonStyle(.bordered)
                    }
                }.disabled(isWorking)
            }
        }.padding(17).background(ScrivTheme.inset.opacity(0.5), in: RoundedRectangle(cornerRadius: 13))
    }
    private func sharingCard(_ team: CloudTeam) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current project").font(.headline)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.project.title).font(.system(size: 13, weight: .medium))
                    Text(currentTeamID == team.id ? "Shared with everyone on this team" : "Create a shared team copy of this script and its image metadata")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if currentTeamID == team.id { Label("Shared", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12)) }
                else {
                    Button("Share team copy") { store.shareProjectWithTeam(team.id) }.buttonStyle(.bordered)
                        .disabled(!team.isPaid || team.role == "viewer" || store.isSyncing || isWorking)
                }
            }
            if !team.isPaid { Text("The owner must activate Team before people can join or edit shared projects. After cancellation, members have 30 days to read and export; the owner retains access.").font(.caption).foregroundStyle(.secondary) }
        }.padding(16).background(ScrivTheme.inset.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
    }
    private var currentTeamID: String? { store.cloudProjects.first { $0.id == store.project.cloudProjectId }?.teamId }
    private func membersCard(_ team: CloudTeam) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Members").font(.headline); Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { run { try await store.cloud.refreshAccount(); await reload(team.id) } }.font(.caption).buttonStyle(.borderless).disabled(isWorking || isLoading)
            }
            ForEach(Array(members.enumerated()), id: \.offset) { _, member in memberRow(member, team: team) }
            if team.role != "owner", let userID = store.account?.id {
                Divider()
                Button("Leave team…", role: .destructive) { requestRemoval(Removal(teamID: team.id, userID: userID, name: "you", isSelf: true)) }.disabled(isWorking)
            }
        }.padding(16).background(ScrivTheme.inset.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
    }
    private func memberRow(_ member: JSONValue, team: CloudTeam) -> some View {
        let id = member["id"]?.string ?? ""
        let role = member["role"]?.string ?? "member"
        let name = member["name"]?.string ?? "Team member"
        let editable = (team.role == "owner" || team.role == "admin" && role != "admin") && role != "owner"
        return HStack(spacing: 10) {
            InitialAvatar(name: name, size: 29)
            VStack(alignment: .leading, spacing: 3) {
                Text(name + (id == store.account?.id ? " (you)" : "")).font(.system(size: 12, weight: .medium))
                if let email = member["email"]?.string { Text(email).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Spacer()
            if editable {
                Menu {
                    if team.role == "owner", role != "admin" { Button("Make admin") { setRole("admin", team: team.id, user: id) } }
                    if role != "member" { Button("Make member") { setRole("member", team: team.id, user: id) } }
                    if role != "viewer" { Button("Make viewer") { setRole("viewer", team: team.id, user: id) } }
                    Divider()
                    Button("Remove…", role: .destructive) { requestRemoval(Removal(teamID: team.id, userID: id, name: name, isSelf: id == store.account?.id)) }
                } label: { HStack(spacing: 5) { Text(role.capitalized); Image(systemName: "chevron.down").font(.system(size: 8)) } }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).disabled(isWorking)
            } else { Text(role.capitalized).font(.system(size: 11)).foregroundStyle(.secondary) }
        }.padding(.vertical, 7)
    }
    private func invitationCard(_ team: CloudTeam) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Invitation links").font(.headline); Spacer()
                Button("Create & copy link", systemImage: "link") { createInvitation(team.id) }.buttonStyle(.borderedProminent).disabled(!team.isPaid || isWorking)
            }
            HStack {
                Picker("Access", selection: $invitationRole) { Text("Member · can edit").tag("member"); Text("Viewer · read & discuss").tag("viewer") }
                Picker("Expires", selection: $invitationDays) { Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30) }
            }.disabled(isWorking)
            Text("Anyone with an active link can sign in and join this team. Links are reusable with no seat limit. Revoking a link stops new joins but doesn't remove current members.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let copiedInvitation, copiedInvitation.teamID == team.id {
                HStack(spacing: 8) {
                    Text(copiedInvitation.url).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button("Copy") { copy(copiedInvitation.url) }.controlSize(.small)
                }.padding(10).background(ScrivTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                let revoked = link["revokedAt"] != nil && link["revokedAt"] != .null
                let expiration = link["expiresAt"]?.int ?? 0
                let expired = expiration <= Int(Date().timeIntervalSince1970 * 1000)
                HStack {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\((link["role"]?.string ?? "member").capitalized) invitation").font(.system(size: 11, weight: .medium))
                        Text(revoked ? "Revoked" : expired ? "Expired" : "Expires \(Date(timeIntervalSince1970: Double(expiration) / 1000).formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !revoked && !expired, let id = link["id"]?.string {
                        Button("Revoke", role: .destructive) {
                            run {
                                try await store.cloud.revokeJoinLink(teamId: team.id, linkId: id)
                                if copiedInvitation?.teamID == team.id { copiedInvitation = nil }
                                await reload(team.id)
                            }
                        }.controlSize(.small).disabled(isWorking)
                    }
                }.padding(.vertical, 4)
            }
        }.padding(16).background(ScrivTheme.inset.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
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
