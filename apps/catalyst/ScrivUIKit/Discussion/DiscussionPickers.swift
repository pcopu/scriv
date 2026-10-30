import UIKit
import ScrivCore

@MainActor
final class UIKitDiscussionMentionPicker: ScrivScreenController, UITableViewDataSource, UITableViewDelegate {
    private let search = UISearchTextField()
    private let table = UITableView(frame: .zero, style: .plain)
    private let count = ScrivUIKitTheme.label("", size: 11, color: ScrivUIKitTheme.secondary)
    private let state = ScrivUIKitTheme.stack([], spacing: 8)
    private let draftScope: String
    private var members: [DiscussionMember] = []
    private var loading = false
    private var error: String?
    private var task: Task<Void, Never>?
    init(store: WorkspaceStore) { draftScope = store.discussionDraftKey; super.init(store: store); preferredContentSize = CGSize(width: 360, height: 440) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        search.placeholder = "Search project members"; search.addTarget(self, action: #selector(render), for: .editingChanged)
        table.dataSource = self; table.delegate = self; table.backgroundColor = .clear; table.rowHeight = 58
        let done = ScrivUIKitTheme.button("Done", primary: true) { [weak self] in self?.dismiss(animated: true) }
        let clear = ScrivUIKitTheme.button("Clear") { [weak self] in guard let self, validScope else { return }; for id in store.discussionMentionedUserIDs { store.removeDiscussionMention(id) } }
        let root = ScrivUIKitTheme.stack([
            ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Mention a member", size: 18, weight: .semibold), UIView(), count], axis: .horizontal, spacing: 8),
            ScrivUIKitTheme.label("Choose who to include. They’ll see the mention in project activity; no email is sent.", size: 12, color: ScrivUIKitTheme.secondary), search, state, table,
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
        if loading { state.addArrangedSubview(ScrivUIKitTheme.label("Loading members…", size: 12, color: ScrivUIKitTheme.secondary)) }
        else if let error { state.addArrangedSubview(ScrivUIKitTheme.notice("Couldn’t load members", message: error, warning: true)); state.addArrangedSubview(ScrivUIKitTheme.button("Retry") { [weak self] in self?.reload() }) }
        else if members.isEmpty { state.addArrangedSubview(ScrivUIKitTheme.label(query.isEmpty ? "No members are available." : "No matching members.", size: 12, color: ScrivUIKitTheme.secondary)) }
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
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = member.name + (member.id == store.account?.id ? " (you)" : ""); cell.textLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        cell.detailTextLabel?.text = member.role.capitalized; cell.detailTextLabel?.textColor = ScrivUIKitTheme.secondary
        cell.accessoryType = selected ? .checkmark : .none; cell.backgroundColor = selected ? ScrivUIKitTheme.inset : .clear
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
    private let tabs = UISegmentedControl(items: ["Mentions", "Threads"])
    private let table = UITableView(frame: .zero, style: .plain)
    private let state = ScrivUIKitTheme.stack([], spacing: 8)
    private var loading = false
    private var error: String?
    private var task: Task<Void, Never>?
    init(store: WorkspaceStore) { super.init(store: store); preferredContentSize = CGSize(width: 390, height: 470) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); tabs.selectedSegmentIndex = 0; tabs.addTarget(self, action: #selector(render), for: .valueChanged)
        table.dataSource = self; table.delegate = self; table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 72; table.backgroundColor = .clear
        let close = ScrivUIKitTheme.button("Done") { [weak self] in self?.dismiss(animated: true) }
        let refresh = ScrivUIKitTheme.button("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.reload() }
        let header = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Project activity", size: 18, weight: .semibold), UIView(), close], axis: .horizontal, spacing: 8)
        let root = ScrivUIKitTheme.stack([header, tabs, ScrivUIKitTheme.label("Mentions and conversations in this project. In-app only; no email notifications.", size: 12, color: ScrivUIKitTheme.secondary), state, table, refresh], spacing: 12)
        view.addSubview(root); root.scrivPinEdges(to: view, insets: NSDirectionalEdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)); reload()
    }
    override func storeDidChange() { guard isViewLoaded else { return }; guard contextIsCurrent else { dismiss(animated: true); return }; render() }
    @objc private func render() {
        guard isViewLoaded else { return }
        for child in state.arrangedSubviews { state.removeArrangedSubview(child); child.removeFromSuperview() }
        if loading { state.addArrangedSubview(ScrivUIKitTheme.label("Loading activity…", size: 12, color: ScrivUIKitTheme.secondary)) }
        else if let error { state.addArrangedSubview(ScrivUIKitTheme.notice("Couldn’t load activity", message: error, warning: true)) }
        else if tabs.selectedSegmentIndex == 0 && store.discussionMentions.isEmpty || tabs.selectedSegmentIndex == 1 && store.discussionThreads.isEmpty {
            state.addArrangedSubview(ScrivUIKitTheme.label(tabs.selectedSegmentIndex == 0 ? "No one has mentioned you in this project yet." : "No conversations in this project yet.", size: 12, color: ScrivUIKitTheme.secondary))
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
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil); cell.backgroundColor = .clear
        cell.textLabel?.font = .systemFont(ofSize: 12, weight: .medium); cell.textLabel?.numberOfLines = 3; cell.detailTextLabel?.font = .systemFont(ofSize: 10); cell.detailTextLabel?.textColor = ScrivUIKitTheme.secondary; cell.detailTextLabel?.numberOfLines = 2
        if tabs.selectedSegmentIndex == 0 {
            let message = store.discussionMentions[indexPath.row]
            cell.textLabel?.text = message.body
            cell.detailTextLabel?.text = (message.name ?? "Editor") + ((message.createdAt != nil || message.at != nil) ? " · " + message.timestamp.formatted(date: .abbreviated, time: .shortened) : "")
            cell.imageView?.image = UIImage(systemName: store.isDiscussionMentionUnread(message) ? "circle.fill" : "at"); cell.imageView?.tintColor = ScrivUIKitTheme.accent
        } else {
            let thread = store.discussionThreads[indexPath.row]
            cell.textLabel?.text = UIKitDiscussionPresentation.threadLabel(thread, project: store.project)
            cell.detailTextLabel?.text = UIKitDiscussionPresentation.itemLabel(thread.itemId, project: store.project) + (thread.resolved ? " · Resolved" : " · Open")
            cell.imageView?.image = UIImage(systemName: thread.resolved ? "checkmark.circle" : "bubble.left"); cell.imageView?.tintColor = thread.resolved ? .systemGreen : ScrivUIKitTheme.accent
        }
        cell.accessoryType = .disclosureIndicator; return cell
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
