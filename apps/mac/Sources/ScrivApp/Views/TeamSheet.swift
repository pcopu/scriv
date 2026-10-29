import SwiftUI
import AppKit
import ScrivCore

struct TeamSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTeamID = ""
    @State private var teamName = ""
    @State private var invite = ""
    @State private var creating = false
    @State private var joining = false
    @State private var memberToRemove: String?
    @State private var removalName = ""
    private var team: CloudTeam? { store.teams.first { $0.id == selectedTeamID } }
    private var canManage: Bool { team?.role == "owner" || team?.role == "admin" }
    private var members: [JSONValue] { store.teamDetails?["members"]?.array ?? [] }
    private var links: [JSONValue] { store.teamDetails?["joinLinks"]?.array ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("Teams & sharing").font(.system(size: 25, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
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
            .onAppear { if let id = store.teams.first?.id { selectedTeamID = id; store.loadTeamDetails(teamId: id) } }
            .onChange(of: selectedTeamID) { _, id in store.lastJoinLink = nil; if !id.isEmpty { store.loadTeamDetails(teamId: id) } }
            .onChange(of: store.teams) { _, teams in if selectedTeamID.isEmpty, let id = teams.first?.id { selectedTeamID = id } }
            .alert("Create a team", isPresented: $creating) {
                TextField("Team name", text: $teamName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { let name = teamName.trimmingCharacters(in: .whitespacesAndNewlines); if !name.isEmpty { store.createTeam(name: name); teamName = "" } }
            } message: { Text("Create the team first, then subscribe to enable shared projects and hosted images.") }
            .alert("Join a team", isPresented: $joining) {
                TextField("Invitation link", text: $invite)
                Button("Cancel", role: .cancel) {}
                Button("Join") { store.joinTeam(token: invite); invite = "" }
            }
            .confirmationDialog("Remove \(removalName) from the team?", isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }), titleVisibility: .visible) {
                Button("Remove member", role: .destructive) { if let id = memberToRemove { store.removeMember(teamId: selectedTeamID, userId: id) }; memberToRemove = nil }
            } message: { Text("They will lose access to this team's shared projects. Their prior edits and messages stay in history.") }
    }
    private var signInPanel: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.circle").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(ScrivTheme.accent)
            Text("Your entire team. One subscription.").font(.title2.weight(.semibold))
            Text("$9.99/month per team. Invite collaborators with a link, share projects, edit live, and keep images available in the cloud.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
            Button("Sign in to Scriv") { store.signIn() }.buttonStyle(.borderedProminent).controlSize(.large)
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
            Button("New team", systemImage: "plus") { creating = true }.buttonStyle(.bordered)
        }
    }
    private func planCard(_ team: CloudTeam) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "person.2.fill").font(.system(size: 26, weight: .light)).foregroundStyle(ScrivTheme.accent).frame(width: 54, height: 54).background(ScrivTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text(team.name).font(.system(size: 18, weight: .semibold))
                Text(team.isPaid ? "Team · $9.99/month · no per-seat charge" : "Choose Team to enable collaboration")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("\(members.count) members · \((team.status ?? "free").capitalized)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if team.role == "owner" {
                if team.isPaid { Button("Manage billing") { store.billingPortal(teamId: team.id) }.buttonStyle(.bordered) }
                else { Button("Subscribe · $9.99/mo") { store.checkout(teamId: team.id) }.buttonStyle(.borderedProminent) }
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
                        .disabled(!team.isPaid || team.role == "viewer" || store.isSyncing)
                }
            }
            if !team.isPaid { Text("The owner must activate Team before people can join or edit shared projects.").font(.caption).foregroundStyle(.secondary) }
        }.padding(16).background(ScrivTheme.inset.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
    }
    private var currentTeamID: String? { store.cloudProjects.first { $0.id == store.project.cloudProjectId }?.teamId }
    private func membersCard(_ team: CloudTeam) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Members").font(.headline); Spacer(); Button("Refresh") { store.loadTeamDetails(teamId: team.id); store.refreshAccount() }.font(.caption).buttonStyle(.borderless) }
            ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                memberRow(member, team: team)
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
                    if team.role == "owner" { Button("Make admin") { store.setMemberRole(teamId: team.id, userId: id, role: "admin") } }
                    Button("Make member") { store.setMemberRole(teamId: team.id, userId: id, role: "member") }
                    Button("Make viewer") { store.setMemberRole(teamId: team.id, userId: id, role: "viewer") }
                    Divider()
                    Button("Remove…", role: .destructive) { removalName = name; memberToRemove = id }
                } label: { HStack(spacing: 5) { Text(role.capitalized); Image(systemName: "chevron.down").font(.system(size: 8)) } }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
            } else { Text(role.capitalized).font(.system(size: 11)).foregroundStyle(.secondary) }
        }.padding(.vertical, 7)
    }
    private func invitationCard(_ team: CloudTeam) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Invitation links").font(.headline)
                Spacer()
                Button("Create & copy link", systemImage: "link") { store.createJoinLink(teamId: team.id) }.buttonStyle(.borderedProminent).disabled(!team.isPaid)
            }
            Text("Anyone with an active link can sign in and join this team. Links are reusable for 30 days, with no seat limit. Revoke a link to stop new joins.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let link = store.lastJoinLink {
                HStack(spacing: 8) {
                    Text(link).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) }.controlSize(.small)
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
                    if !revoked && !expired, let id = link["id"]?.string { Button("Revoke", role: .destructive) { store.revokeJoinLink(teamId: team.id, linkId: id) }.controlSize(.small) }
                }.padding(.vertical, 4)
            }
        }.padding(16).background(ScrivTheme.inset.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
    }
}
