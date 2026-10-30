import UIKit
import ScrivCore

/// UI affordances mirror server roles; the server remains the authorization
/// boundary. Free script/timing/prompt metadata is never described as paid media.
enum UIKitTeamPolicy {
    static func canManage(_ team: CloudTeam) -> Bool { ["owner", "admin"].contains(team.role ?? "") }
    static func canEditMember(actorRole: String?, targetRole: String) -> Bool {
        guard targetRole != "owner" else { return false }
        return actorRole == "owner" || actorRole == "admin" && targetRole != "admin"
    }
    static func billingNeedsAttention(_ team: CloudTeam) -> Bool { !team.isPaid && !["free", "canceled", "incomplete_expired"].contains(team.status ?? "free") }
    static func canStartCheckout(_ team: CloudTeam) -> Bool { team.role == "owner" && !team.isPaid && ["free", "canceled", "incomplete_expired"].contains(team.status ?? "free") }
    static func roleDescription(_ role: String) -> String {
        switch role { case "owner": return "Owner of this team"; case "admin": return "Can edit and manage the team"; case "viewer": return "Can read and discuss"; default: return "Can edit project content" }
    }
    static func invitationState(_ link: JSONValue, now: Date = Date()) -> String {
        if link["revokedAt"] != nil && link["revokedAt"] != .null { return "Revoked" }
        let expiration = link["expiresAt"]?.int ?? 0
        if expiration <= Int(now.timeIntervalSince1970 * 1_000) { return "Expired" }
        return "Expires " + Date(timeIntervalSince1970: Double(expiration) / 1_000).formatted(date: .abbreviated, time: .omitted)
    }
    static func activeInvitation(_ link: JSONValue, now: Date = Date()) -> Bool {
        (link["revokedAt"] == nil || link["revokedAt"] == .null) && (link["expiresAt"]?.int ?? 0) > Int(now.timeIntervalSince1970 * 1_000)
    }
}

@MainActor
enum TeamUIKitUI {
    static func avatar(_ name: String, color: UIColor, size: CGFloat = 42) -> UIView {
        let label = ScrivUIKitTheme.label(String(name.prefix(1)).uppercased(), size: size * 0.44, weight: .semibold, color: .white, lines: 1)
        label.textAlignment = .center; label.backgroundColor = color; label.layer.cornerRadius = size / 2; label.clipsToBounds = true
        label.widthAnchor.constraint(equalToConstant: size).isActive = true; label.heightAnchor.constraint(equalToConstant: size).isActive = true
        label.isAccessibilityElement = false; return label
    }
    static func invitationPanel(team: CloudTeam, links: [JSONValue], role: String, days: Int, recentURL: URL?, working: Bool, loading: Bool,
                                onRole: @escaping (String) -> Void, onDays: @escaping (Int) -> Void,
                                onCreate: @escaping () -> Void, onCopy: @escaping () -> Void, onRevoke: @escaping (String) -> Void) -> UIView {
        let roleMenu = CharacterTeamUI.menu(role == "viewer" ? "Viewer · read & discuss" : "Member · can edit", actions: ["member", "viewer"].map { value in
            UIAction(title: value == "member" ? "Member · can edit" : "Viewer · read & discuss", state: value == role ? .on : .off) { _ in onRole(value) }
        })
        let daysMenu = CharacterTeamUI.menu("\(days) \(days == 1 ? "day" : "days")", actions: [1, 7, 30].map { value in
            UIAction(title: "\(value) \(value == 1 ? "day" : "days")", state: value == days ? .on : .off) { _ in onDays(value) }
        })
        let accessLabel = ScrivUIKitTheme.label("Access", size: 15, weight: .medium); accessLabel.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let expiryLabel = ScrivUIKitTheme.label("Expires", size: 15, weight: .medium); expiryLabel.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let create = CharacterTeamUI.button("Create & copy link", primary: true, size: 17, action: onCreate)
        create.isEnabled = UIKitTeamPolicy.canManage(team) && team.isPaid && !working
        let content = ScrivUIKitTheme.stack([
            CharacterTeamUI.row([accessLabel, roleMenu]), CharacterTeamUI.row([expiryLabel, daysMenu]),
            ScrivUIKitTheme.label("Anyone with the link can sign in and join. Links are reusable.", size: 15, color: ScrivUIKitTheme.secondary), create
        ], spacing: 22)
        if !team.isPaid { content.addArrangedSubview(ScrivUIKitTheme.notice("Activate Team first", message: "New invitation links require an active Team plan. Personal script, timing and image-prompt storage remains free.", warning: true)) }
        content.addArrangedSubview(CharacterTeamUI.separator())
        content.addArrangedSubview(ScrivUIKitTheme.label("Invitation links", size: 15, color: ScrivUIKitTheme.secondary))
        if recentURL != nil {
            let copied = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Link created and copied", size: 15, weight: .semibold), ScrivUIKitTheme.label("Copy it again before closing this window.", size: 12, color: ScrivUIKitTheme.secondary)], spacing: 4)
            content.addArrangedSubview(ScrivUIKitTheme.card(CharacterTeamUI.row([CharacterTeamUI.symbol("checkmark.circle.fill", color: .systemGreen), copied, CharacterTeamUI.spacer(), CharacterTeamUI.button("Copy", action: onCopy)])))
        }
        if links.isEmpty { content.addArrangedSubview(ScrivUIKitTheme.label(loading ? "Loading invitation links…" : "No invitation links yet.", size: 14, color: ScrivUIKitTheme.secondary)) }
        for link in links {
            let title = "\((link["role"]?.string ?? "member").capitalized) invitation"
            let details = ScrivUIKitTheme.stack([ScrivUIKitTheme.label(title, size: 15, weight: .semibold), ScrivUIKitTheme.label(UIKitTeamPolicy.invitationState(link), size: 13, color: ScrivUIKitTheme.secondary)], spacing: 5)
            let row = CharacterTeamUI.row([CharacterTeamUI.symbol("link"), details, CharacterTeamUI.spacer()])
            if UIKitTeamPolicy.activeInvitation(link), let id = link["id"]?.string, UIKitTeamPolicy.canManage(team) {
                let revoke = CharacterTeamUI.button("Revoke") { onRevoke(id) }; revoke.configuration?.baseForegroundColor = .systemRed; revoke.isEnabled = !working
                row.addArrangedSubview(revoke)
            }
            content.addArrangedSubview(ScrivUIKitTheme.card(row))
        }
        content.addArrangedSubview(ScrivUIKitTheme.notice("", message: "Revoking a link stops new joins. Existing members keep access."))
        content.addArrangedSubview(ScrivUIKitTheme.label("For security, old link secrets cannot be retrieved. Create a new link if you no longer have its saved copy.", size: 12, color: ScrivUIKitTheme.secondary))
        roleMenu.isEnabled = !working; daysMenu.isEnabled = !working
        return content
    }
}
