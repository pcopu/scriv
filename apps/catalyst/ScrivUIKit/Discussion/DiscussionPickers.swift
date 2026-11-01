import UIKit
import ScrivCore

@MainActor
final class UIKitDiscussionMentionPicker: ScrivScreenController, UITableViewDataSource, UITableViewDelegate {
    private let search = UISearchTextField()
    private let table = UITableView(frame: .zero, style: .plain)
    private let count = ScrivUIKitTheme.label("", size: 13, color: ScrivUIKitTheme.secondary)
    private let state = ScrivUIKitTheme.stack([], spacing: 8)
    private let draftScope: String
    private var members: [DiscussionMember] = []
    private var loading = false
    private var error: String?
    private var task: Task<Void, Never>?
    init(store: WorkspaceStore) { draftScope = store.discussionDraftKey; super.init(store: store); preferredContentSize = CGSize(width: 420, height: 480) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        search.placeholder = "Search project members"; search.font = .systemFont(ofSize: 15); search.heightAnchor.constraint(equalToConstant: 38).isActive = true; search.addTarget(self, action: #selector(render), for: .editingChanged)
        table.dataSource = self; table.delegate = self; table.backgroundColor = .clear; table.rowHeight = 72; table.separatorStyle = .none
        let done = ScrivUIKitTheme.button("Done", primary: true) { [weak self] in self?.dismiss(animated: true) }
        let clear = ScrivUIKitTheme.button("Clear") { [weak self] in guard let self, validScope else { return }; for id in store.discussionMentionedUserIDs { store.removeDiscussionMention(id) } }
        let root = ScrivUIKitTheme.stack([
            ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Mention a member", size: 22, weight: .semibold), UIView(), count], axis: .horizontal, spacing: 8),
            ScrivUIKitTheme.label("Mentions appear in this conversation. No email is sent.", size: 14, color: ScrivUIKitTheme.secondary), search, state, table,
            ScrivUIKitTheme.stack([clear, UIView(), done], axis: .horizontal, spacing: 8)
        ], spacing: 12)
        view.addSubview(root); root.scrivPinEdges(to: view, insets: NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)); reload()
    }
    private var validScope: Bool { contextIsCurrent && draftScope == store.discussionDraftKey }
    override func storeDidChange() { guard isViewLoaded else { return }; guard validScope else { dismiss(animated: true); return }; render() }
    @objc private func render() {
        guard isViewLoaded else { return }
        let query = search.text ?? ""
        members = store.discussionMembers.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.role.localizedCaseInsensitiveContains(query) }
        count.text = "\(store.discussionMentionedUserIDs.count) / 20"
        for child in state.arrangedSubviews { state.removeArrangedSubview(child); child.removeFromSuperview() }
        if loading { state.addArrangedSubview(ScrivUIKitTheme.label("Loading members…", size: 14, color: ScrivUIKitTheme.secondary)) }
        else if let error { state.addArrangedSubview(ScrivUIKitTheme.notice("Couldn’t load members", message: error, warning: true)); state.addArrangedSubview(ScrivUIKitTheme.button("Retry") { [weak self] in self?.reload() }) }
        else if members.isEmpty { state.addArrangedSubview(ScrivUIKitTheme.label(query.isEmpty ? "No members are available." : "No matching members.", size: 14, color: ScrivUIKitTheme.secondary)) }
        state.isHidden = state.arrangedSubviews.isEmpty; table.isHidden = loading || error != nil; table.reloadData()
    }
    private func reload() {
        guard validScope, !loading else { return }; loading = true; error = nil; render()
        task = Task { [weak self] in guard let self else { return }; defer { loading = false; if validScope { render() } }
            do { try await store.refreshDiscussionMembers() } catch is CancellationError { } catch { if validScope { self.error = error.localizedDescription } }
        }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); task?.cancel() }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { members.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let member = members[indexPath.row], selected = store.discussionMentionedUserIDs.contains(member.id)
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil); cell.selectionStyle = .none; cell.backgroundColor = .clear
        let avatar = DiscussionAvatarView(name: member.name, identity: member.id, mine: member.id == store.account?.id, diameter: 42)
        let name = ScrivUIKitTheme.label(member.name + (member.id == store.account?.id ? " (you)" : ""), size: 16, weight: .medium, color: ScrivUIKitTheme.ink, lines: 1)
        let detail = ScrivUIKitTheme.label(member.role.capitalized, size: 14, color: ScrivUIKitTheme.secondary, lines: 1)
        let selection = UIImageView(image: UIImage(systemName: selected ? "checkmark.circle.fill" : "circle"))
        selection.tintColor = selected ? ScrivUIKitTheme.accent : ScrivUIKitTheme.secondary.withAlphaComponent(0.5)
        selection.contentMode = .scaleAspectFit; selection.widthAnchor.constraint(equalToConstant: 25).isActive = true; selection.heightAnchor.constraint(equalToConstant: 25).isActive = true
        let row = ScrivUIKitTheme.stack([avatar, ScrivUIKitTheme.stack([name, detail], spacing: 3), UIView(), selection], axis: .horizontal, spacing: 14); row.alignment = .center
        cell.contentView.addSubview(row); row.scrivPinEdges(to: cell.contentView, insets: NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        cell.contentView.backgroundColor = selected ? ScrivUIKitTheme.accent.withAlphaComponent(0.09) : .clear
        cell.contentView.layer.cornerRadius = 10
        cell.isUserInteractionEnabled = selected || store.discussionMentionedUserIDs.count < 20; cell.contentView.alpha = cell.isUserInteractionEnabled ? 1 : 0.45
        cell.accessibilityLabel = (selected ? "Remove mention of " : "Mention ") + member.name + ", " + member.role
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard validScope, members.indices.contains(indexPath.row) else { return }; let member = members[indexPath.row]
        if store.discussionMentionedUserIDs.contains(member.id) { store.removeDiscussionMention(member.id) } else { store.addDiscussionMention(member) }
    }
}

@MainActor
final class UIKitDiscussionActivityController: ScrivScreenController, UITableViewDataSource, UITableViewDelegate {
    private let tabs = UISegmentedControl(items: ["Mentions", "Conversations"])
    private let table = UITableView(frame: .zero, style: .plain)
    private let state = ScrivUIKitTheme.stack([], spacing: 8)
    private var loading = false
    private var error: String?
    private var task: Task<Void, Never>?
    init(store: WorkspaceStore) { super.init(store: store); preferredContentSize = CGSize(width: 430, height: 490) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); tabs.heightAnchor.constraint(equalToConstant: 36).isActive = true
        tabs.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 14, weight: .medium)], for: .normal)
        tabs.selectedSegmentIndex = 0; tabs.addTarget(self, action: #selector(render), for: .valueChanged)
        table.dataSource = self; table.delegate = self; table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 100; table.backgroundColor = .clear; table.separatorStyle = .none
        let close = ScrivUIKitTheme.button("Done") { [weak self] in self?.dismiss(animated: true) }
        let refresh = ScrivUIKitTheme.button("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.reload() }
        let header = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Project activity", size: 22, weight: .semibold), UIView(), close], axis: .horizontal, spacing: 8)
        let privacy = ScrivUIKitTheme.label("In-app only. No email or push notification is sent.", size: 13, color: ScrivUIKitTheme.secondary)
        let root = ScrivUIKitTheme.stack([header, tabs, state, table, refresh, privacy], spacing: 14)
        view.addSubview(root); root.scrivPinEdges(to: view, insets: NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)); reload()
    }
    override func storeDidChange() { guard isViewLoaded else { return }; guard contextIsCurrent else { dismiss(animated: true); return }; render() }
    @objc private func render() {
        guard isViewLoaded else { return }
        for child in state.arrangedSubviews { state.removeArrangedSubview(child); child.removeFromSuperview() }
        if loading { state.addArrangedSubview(ScrivUIKitTheme.label("Loading activity…", size: 14, color: ScrivUIKitTheme.secondary)) }
        else if let error { state.addArrangedSubview(ScrivUIKitTheme.notice("Couldn’t load activity", message: error, warning: true)) }
        else if tabs.selectedSegmentIndex == 0 && store.discussionMentions.isEmpty || tabs.selectedSegmentIndex == 1 && store.discussionThreads.isEmpty {
            state.addArrangedSubview(ScrivUIKitTheme.label(tabs.selectedSegmentIndex == 0 ? "No one has mentioned you in this project yet." : "No conversations in this project yet.", size: 14, color: ScrivUIKitTheme.secondary))
        }
        state.isHidden = state.arrangedSubviews.isEmpty; table.reloadData()
    }
    private func reload() {
        guard contextIsCurrent, !loading else { return }; loading = true; error = nil; render()
        task = Task { [weak self] in guard let self else { return }; defer { loading = false; if contextIsCurrent { render() } }
            do { try await store.refreshDiscussionActivity() } catch is CancellationError { } catch { if contextIsCurrent { self.error = error.localizedDescription } }
        }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); task?.cancel() }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { tabs.selectedSegmentIndex == 0 ? store.discussionMentions.count : store.discussionThreads.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil); cell.backgroundColor = .clear; cell.selectionStyle = .none
        let content: UIStackView
        let leading: UIView
        if tabs.selectedSegmentIndex == 0 {
            let message = store.discussionMentions[indexPath.row], name = message.name ?? "Editor"
            leading = DiscussionAvatarView(name: name, identity: message.userId ?? message.authorId ?? name, mine: message.userId == store.account?.id || message.authorId == store.account?.id)
            let title = ScrivUIKitTheme.label(name, size: 16, weight: .semibold, color: ScrivUIKitTheme.ink, lines: 1)
            let timestamp = (message.createdAt != nil || message.at != nil) ? message.timestamp.formatted(date: .omitted, time: .shortened) : ""
            let time = ScrivUIKitTheme.label(timestamp, size: 12, color: ScrivUIKitTheme.secondary, lines: 1)
            let heading = ScrivUIKitTheme.stack([title, UIView(), time], axis: .horizontal, spacing: 8)
            let body = ScrivUIKitTheme.label(message.body, size: 14, color: ScrivUIKitTheme.accent, lines: 3)
            content = ScrivUIKitTheme.stack([heading, body], spacing: 5)
            if let thread = store.discussionThreads.first(where: { $0.id == message.threadId }) {
                content.addArrangedSubview(ScrivUIKitTheme.label(UIKitDiscussionPresentation.itemLabel(thread.itemId, project: store.project), size: 13, color: ScrivUIKitTheme.secondary, lines: 1))
            }
            if store.isDiscussionMentionUnread(message) {
                let unread = UIImageView(image: UIImage(systemName: "circle.fill")); unread.tintColor = ScrivUIKitTheme.accent; unread.contentMode = .scaleAspectFit
                unread.widthAnchor.constraint(equalToConstant: 8).isActive = true; unread.heightAnchor.constraint(equalToConstant: 8).isActive = true
                heading.insertArrangedSubview(unread, at: 0)
            }
        } else {
            let thread = store.discussionThreads[indexPath.row]
            let icon = UIImageView(image: UIImage(systemName: thread.resolved ? "checkmark.circle.fill" : "bubble.left")); icon.contentMode = .scaleAspectFit
            icon.tintColor = thread.resolved ? .systemGreen : ScrivUIKitTheme.accent
            icon.widthAnchor.constraint(equalToConstant: 42).isActive = true; icon.heightAnchor.constraint(equalToConstant: 42).isActive = true
            leading = icon
            content = ScrivUIKitTheme.stack([
                ScrivUIKitTheme.label(UIKitDiscussionPresentation.threadLabel(thread, project: store.project), size: 15, weight: .medium, color: ScrivUIKitTheme.ink, lines: 3),
                ScrivUIKitTheme.label(UIKitDiscussionPresentation.itemLabel(thread.itemId, project: store.project) + (thread.resolved ? " · Resolved" : " · Open"), size: 13, color: ScrivUIKitTheme.secondary, lines: 2)
            ], spacing: 5)
        }
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right")); chevron.tintColor = ScrivUIKitTheme.secondary; chevron.contentMode = .scaleAspectFit
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true
        let row = ScrivUIKitTheme.stack([leading, content, chevron], axis: .horizontal, spacing: 13); row.alignment = .top
        let divider = UIView(); divider.backgroundColor = ScrivUIKitTheme.hairline; divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        let column = ScrivUIKitTheme.stack([row, divider], spacing: 15)
        cell.contentView.addSubview(column); column.scrivPinEdges(to: cell.contentView, insets: NSDirectionalEdgeInsets(top: 15, leading: 0, bottom: 0, trailing: 0))
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard requireCurrentContext() else { return }
        if tabs.selectedSegmentIndex == 0 {
            guard store.discussionMentions.indices.contains(indexPath.row) else { return }; store.openDiscussionMention(store.discussionMentions[indexPath.row])
        } else {
            guard store.discussionThreads.indices.contains(indexPath.row) else { return }; store.openDiscussionThread(store.discussionThreads[indexPath.row])
        }
        dismiss(animated: true)
    }
}
