import UIKit
import ScrivCore

private enum UIKitHistorySelection {
    case working(ScrivProject), local(HistoryEntry), cloud(CloudEvent)
    var id: String { switch self { case .working(let project): return "working:\(project.id):\(project.revision)"; case .local(let event): return "local:" + event.id; case .cloud(let event): return "cloud:\(event.seq)" } }
    var title: String { switch self { case .working: return "Current revision"; case .local(let event): return event.label; case .cloud(let event): return event.label } }
    var date: Date { switch self { case .working(let project): return project.modifiedAt; case .local(let event): return event.date; case .cloud(let event): return Date(timeIntervalSince1970: Double(event.at) / 1000) } }
}

@MainActor
final class HistoryController: ScrivScreenController, UITableViewDataSource, UITableViewDelegate {
    private let source = UISegmentedControl(items: ["This Mac", "Cloud"])
    private let detailTabs = UISegmentedControl(items: ["Changes", "Revision preview"])
    private let table = UITableView(frame: .zero, style: .plain)
    private let detail = ScrivUIKitTheme.stack([], spacing: 16)
    private let detailTitle = ScrivUIKitTheme.label("Select a revision", size: 24, weight: .semibold)
    private let detailSubtitle = ScrivUIKitTheme.label("", size: 15, color: ScrivUIKitTheme.secondary)
    private let progress = UIActivityIndicatorView(style: .medium)
    private var restoreButton: UIButton!, refreshButton: UIButton!
    private var events: [UIKitHistorySelection] = []
    private var selection: UIKitHistorySelection?
    private var preview: ScrivProject?
    private var loading = false, refreshing = false
    private var previewIssue: String?
    private var previewTask: Task<Void, Never>?
    private var technicalExpanded: Set<String> = []
    private var characterExpanded: Set<String> = []

    init(store: WorkspaceStore) { super.init(store: store); preferredContentSize = CGSize(width: 1040, height: 740) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        source.selectedSegmentIndex = 0; source.addTarget(self, action: #selector(sourceChanged), for: .valueChanged); source.widthAnchor.constraint(equalToConstant: 260).isActive = true
        refreshButton = ScrivUIKitTheme.button("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.refresh() }
        let title = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("History", size: 23, weight: .semibold), ScrivUIKitTheme.label(store.project.title, size: 14, color: ScrivUIKitTheme.secondary, lines: 1)], spacing: 5)
        let header = ScrivUIKitTheme.stack([title, UIView(), progress, refreshButton, source], axis: .horizontal, spacing: 16); header.alignment = .center
        table.dataSource = self; table.delegate = self; table.separatorStyle = .none; table.backgroundColor = ScrivUIKitTheme.chrome.withAlphaComponent(0.18); table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 110
        table.register(HistoryEventCell.self, forCellReuseIdentifier: "history"); table.widthAnchor.constraint(equalToConstant: 330).isActive = true
        detailTabs.selectedSegmentIndex = 0; detailTabs.addTarget(self, action: #selector(detailChanged), for: .valueChanged)
        let tabRow = ScrivUIKitTheme.stack([detailTabs, UIView()], axis: .horizontal); detailTabs.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let scroll = UIScrollView(); scroll.addSubview(detail); detail.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([detail.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), detail.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), detail.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), detail.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12), detail.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)])
        let right = ScrivUIKitTheme.stack([detailTitle, detailSubtitle, tabRow, scroll], spacing: 16)
        let body = ScrivUIKitTheme.stack([table, verticalLine(), padded(right, amount: 26)], axis: .horizontal, spacing: 0)
        restoreButton = ScrivUIKitTheme.button("Restore revision…", primary: true) { [weak self] in self?.confirmRestore() }
        let note = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Restore creates a new revision. Current work stays in history.", size: 12, weight: .medium), ScrivUIKitTheme.label("Restoring does not rewind discussion, membership or billing.", size: 11, color: ScrivUIKitTheme.secondary)], spacing: 5)
        let footer = ScrivUIKitTheme.stack([note, UIView(), ScrivUIKitTheme.button("Close") { [weak self] in self?.dismiss(animated: true) }, restoreButton], axis: .horizontal, spacing: 16); footer.alignment = .center
        let root = ScrivUIKitTheme.stack([padded(header, amount: 24), line(), body, line(), padded(footer, amount: 22)], spacing: 0)
        view.addSubview(root); root.scrivPinEdges(to: view)
        reloadEvents(); choose(events.dropFirst().first ?? events.first)
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if isBeingDismissed { previewTask?.cancel() } }
    override func storeDidChange() {
        guard isViewLoaded else { return }; guard contextIsCurrent else { previewTask?.cancel(); dismiss(animated: true); return }
        reloadEvents()
        if case .working = selection { selection = .working(store.project); preview = store.project; renderDetail() }
        else { updateRestoreState() }
    }
    private var local: Bool { source.selectedSegmentIndex == 0 }
    private var before: ScrivProject? {
        let revision: Int
        switch selection { case .working(let project): revision = project.revision; case .local(let event): revision = event.revision; default: return nil }
        return store.history.filter { $0.revision < revision }.max { $0.revision < $1.revision }?.snapshot
    }
    private var canRestore: Bool {
        guard contextIsCurrent, preview != nil, !loading, previewIssue == nil, let selection else { return false }
        switch selection { case .working: return false; case .local(let event): return event.revision != store.project.revision; case .cloud(let event): return !event.kind.hasPrefix("discussion.") && event.seq != store.cloud.headSeq }
    }
    private func reloadEvents() {
        if local { events = [.working(store.project)] + store.history.filter { $0.revision != store.project.revision }.sorted { $0.revision > $1.revision }.map(UIKitHistorySelection.local) }
        else { events = store.cloudHistory.sorted { $0.seq > $1.seq }.map(UIKitHistorySelection.cloud) }
        refreshButton.isHidden = local; refreshButton.isEnabled = !refreshing && store.project.cloudProjectId != nil
        table.reloadData()
        if let index = events.firstIndex(where: { $0.id == selection?.id }) { table.selectRow(at: IndexPath(row: index, section: 0), animated: false, scrollPosition: .none) }
        if !local && events.isEmpty {
            let empty = ScrivUIKitTheme.label(store.project.cloudProjectId == nil ? "This project is local. Switch to This Mac for saved history." : "No cloud changes have been recorded yet.", size: 13, color: ScrivUIKitTheme.secondary)
            table.backgroundView = padded(empty, amount: 28)
        } else { table.backgroundView = nil }
    }
    @objc private func sourceChanged() { previewTask?.cancel(); reloadEvents(); choose(local ? events.dropFirst().first ?? events.first : events.first); if !local { refresh() } }
    @objc private func detailChanged() { renderDetail() }
    private func choose(_ value: UIKitHistorySelection?) {
        previewTask?.cancel(); selection = value; preview = nil; previewIssue = nil; technicalExpanded = []; characterExpanded = []
        guard let value else { loading = false; renderDetail(); return }
        loading = true; renderDetail()
        let context = store.navigationContext
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot: ScrivProject?
                switch value { case .working(let project): snapshot = project; case .local(let event): snapshot = event.snapshot; case .cloud(let event): snapshot = event.kind.hasPrefix("discussion.") ? nil : try await store.previewCloudHistory(event) }
                guard !Task.isCancelled, context == store.navigationContext, selection?.id == value.id else { return }
                preview = snapshot; loading = false; renderDetail()
            } catch is CancellationError { } catch {
                guard !Task.isCancelled, context == store.navigationContext, selection?.id == value.id else { return }
                previewIssue = error.localizedDescription; loading = false; renderDetail()
            }
        }
    }
    private func refresh() {
        guard store.project.cloudProjectId != nil, !refreshing else { return }
        refreshing = true; progress.startAnimating(); refreshButton.isEnabled = false
        let context = store.navigationContext
        Task { [weak self] in
            guard let self else { return }
            do { try await store.refreshDiscussionActivity() }
            catch is CancellationError { } catch { if context == store.navigationContext { previewIssue = error.localizedDescription } }
            guard context == store.navigationContext else { return }
            refreshing = false; progress.stopAnimating(); reloadEvents()
            if !local, selection == nil { choose(events.first) } else { renderDetail() }
        }
    }
    private func author(_ selection: UIKitHistorySelection) -> String {
        if case .cloud(let event) = selection { return event.actorId == store.account?.id ? "You" : store.discussionMembers.first { $0.id == event.actorId }?.name ?? "Collaborator" }
        return "This Mac"
    }
    private func renderDetail() {
        guard isViewLoaded else { return }
        for child in detail.arrangedSubviews { detail.removeArrangedSubview(child); child.removeFromSuperview() }
        detailTitle.text = selection?.title ?? "Select a revision"
        detailSubtitle.text = selection.map { "\(author($0)) · \($0.date.formatted(date: .abbreviated, time: .shortened))" }
        updateRestoreState()
        if loading { detail.addArrangedSubview(ScrivUIKitTheme.label("Loading read-only revision…", size: 13, color: ScrivUIKitTheme.secondary)) }
        if let previewIssue { detail.addArrangedSubview(ScrivUIKitTheme.notice("Revision preview unavailable", message: previewIssue, warning: true)) }
        guard let selection else { detail.addArrangedSubview(ScrivUIKitTheme.label("Choose a change to compare its contents before restoring.", size: 14, color: ScrivUIKitTheme.secondary)); return }
        if detailTabs.selectedSegmentIndex == 1 {
            if let preview { renderSnapshot(preview) }
            else if !loading { detail.addArrangedSubview(ScrivUIKitTheme.label("No script snapshot is available for this event.", size: 14, color: ScrivUIKitTheme.secondary)) }
            return
        }
        let changes: [CloudChange]
        switch selection { case .cloud(let event): changes = event.changes; default: changes = preview.map { HistoryPresentation.localChanges(before: before, after: $0) } ?? [] }
        if changes.isEmpty && !loading {
            if case .cloud(let event) = selection, event.kind.hasPrefix("discussion.") { detail.addArrangedSubview(ScrivUIKitTheme.notice("Discussion activity", message: "This event is not a script restore point. Restoring never rewinds the conversation.")) }
            else { detail.addArrangedSubview(ScrivUIKitTheme.notice("Read-only snapshot", message: "No item delta is available for this revision. Open Revision preview to read its saved contents.")) }
        }
        for change in changes { detail.addArrangedSubview(changeCard(change)) }
        if case .cloud(let event) = selection, let data = event.data {
            let expanded = technicalExpanded.contains("event")
            detail.addArrangedSubview(ScrivUIKitTheme.button("Event metadata", symbol: expanded ? "chevron.down" : "chevron.right") { [weak self] in self?.toggleTechnical("event") })
            if expanded { detail.addArrangedSubview(selectable(json(data), size: 11, monospaced: true)) }
        }
    }
    private func updateRestoreState() { restoreButton?.isEnabled = canRestore }
    private func changeCard(_ change: CloudChange) -> UIView {
        let fields = HistoryPresentation.fields(for: change, beforeProject: before, afterProject: preview)
        let content = ScrivUIKitTheme.stack([], spacing: 16)
        content.addArrangedSubview(ScrivUIKitTheme.stack([ScrivUIKitTheme.label(HistoryPresentation.title(for: change), size: 18, weight: .semibold), UIView(), ScrivUIKitTheme.label(HistoryPresentation.operation(for: change), size: 11, weight: .medium, color: ScrivUIKitTheme.secondary)], axis: .horizontal, spacing: 10))
        if let text = (change.after ?? change.before)?.data["text"]?.string, !fields.contains(where: { $0.label == "Text" }) { content.addArrangedSubview(selectable("“\(text)”", size: 15)) }
        if fields.isEmpty { content.addArrangedSubview(ScrivUIKitTheme.label("Item details changed. Expand Technical details to inspect every stored value.", size: 13, color: ScrivUIKitTheme.secondary)) }
        else {
            let old = column("Before", fields: fields, after: false), new = column("After", fields: fields, after: true)
            let arrow = ScrivUIKitTheme.label("→", size: 25, color: ScrivUIKitTheme.secondary); arrow.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let comparison = ScrivUIKitTheme.stack([old, arrow, new], axis: .horizontal, spacing: 13); comparison.alignment = .top
            old.widthAnchor.constraint(equalTo: new.widthAnchor).isActive = true; content.addArrangedSubview(comparison)
        }
        if let before, let preview, let entry = preview.entries.first(where: { $0.id == change.id }),
           let cue = preview.activeCue(at: preview.startMs(of: entry.id), sceneId: entry.sceneId), let oldCue = before.cues.first(where: { $0.id == cue.id }),
           oldCue.imageId == cue.imageId, let asset = preview.asset(cue.imageId), before.asset(oldCue.imageId) == asset {
            let cover = ProjectCoverView(); cover.widthAnchor.constraint(equalToConstant: 130).isActive = true; cover.heightAnchor.constraint(equalToConstant: 72).isActive = true; cover.setURL(store.assetURL(asset))
            let labels = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("\(cue.label.isEmpty ? "Image" : cue.label) · unchanged", size: 14, weight: .medium), ScrivUIKitTheme.label("This image was not changed in this revision.", size: 12, color: ScrivUIKitTheme.secondary)], spacing: 6)
            let imageRow = ScrivUIKitTheme.stack([cover, labels], axis: .horizontal, spacing: 15); imageRow.alignment = .center; content.addArrangedSubview(line()); content.addArrangedSubview(imageRow)
        }
        content.addArrangedSubview(line())
        let expanded = technicalExpanded.contains(change.id)
        content.addArrangedSubview(ScrivUIKitTheme.button("Technical details", symbol: expanded ? "chevron.down" : "chevron.right") { [weak self] in self?.toggleTechnical(change.id) })
        if expanded { content.addArrangedSubview(selectable("Item: \(change.id)\n\nBefore\n\(change.before.map { json($0.data) } ?? "Not present")\n\nAfter\n\(change.after.map { json($0.data) } ?? "Not present")", size: 10, monospaced: true)) }
        return ScrivUIKitTheme.card(content, padding: 20)
    }
    private func column(_ title: String, fields: [HistoryReadableField], after: Bool) -> UIView {
        let stack = ScrivUIKitTheme.stack([ScrivUIKitTheme.label(title, size: 14, weight: .semibold, color: after ? ScrivUIKitTheme.accent : ScrivUIKitTheme.ink)], spacing: 13)
        for field in fields {
            stack.addArrangedSubview(ScrivUIKitTheme.stack([ScrivUIKitTheme.label(field.label, size: 12, color: ScrivUIKitTheme.secondary), selectable(after ? field.after : field.before, size: field.label == "Owned time" || field.label == "Coverage" ? 21 : 14)], spacing: 5))
        }
        let card = ScrivUIKitTheme.card(stack, padding: 16); card.backgroundColor = after ? ScrivUIKitTheme.accent.withAlphaComponent(0.065) : ScrivUIKitTheme.inset.withAlphaComponent(0.6); return card
    }
    private func renderSnapshot(_ project: ScrivProject) {
        detail.addArrangedSubview(ScrivUIKitTheme.label(project.title, size: 20, weight: .semibold))
        detail.addArrangedSubview(ScrivUIKitTheme.label("\(project.scenes.count) scenes · \(project.entries.count) entries · \(project.characters.count) characters · \(project.cues.count) image cues · \(project.audioClips.count) local audio clips", size: 12, color: ScrivUIKitTheme.secondary))
        for scene in project.orderedScenes {
            let body = ScrivUIKitTheme.stack([ScrivUIKitTheme.stack([ScrivUIKitTheme.label(scene.title, size: 17, weight: .semibold), UIView(), ScrivUIKitTheme.label(ScrivFormat.duration(project.durationMs(of: scene.id)), size: 12, color: ScrivUIKitTheme.secondary)], axis: .horizontal)], spacing: 14)
            for entry in project.entries(in: scene.id) {
                let time = ScrivUIKitTheme.label(ScrivFormat.time(project.startMs(of: entry.id)), size: 11, color: ScrivUIKitTheme.secondary, lines: 1); time.widthAnchor.constraint(equalToConstant: 58).isActive = true
                let text = ScrivUIKitTheme.stack([ScrivUIKitTheme.label(entry.kind == .direction ? "Direction" : project.character(entry.characterId)?.name ?? "Dialogue", size: 12, weight: .semibold, color: ScrivUIKitTheme.secondary), selectable(entry.text, size: 15)], spacing: 5)
                let row = ScrivUIKitTheme.stack([time, text, ScrivUIKitTheme.label(ScrivFormat.duration(entry.ownedDurationMs), size: 11, color: ScrivUIKitTheme.secondary)], axis: .horizontal, spacing: 12); row.alignment = .top; body.addArrangedSubview(row)
            }
            for cue in project.cues(in: scene.id) { body.addArrangedSubview(ScrivUIKitTheme.label("\(cue.label.isEmpty ? "Image placement" : cue.label) · \(ScrivFormat.time(cue.startMs))–\(ScrivFormat.time(cue.endMs))", size: 12, color: ScrivUIKitTheme.secondary)) }
            detail.addArrangedSubview(ScrivUIKitTheme.card(body, padding: 18))
        }
        for character in project.characters {
            let expanded = characterExpanded.contains(character.id)
            detail.addArrangedSubview(ScrivUIKitTheme.button(character.name, symbol: expanded ? "chevron.down" : "chevron.right") { [weak self] in guard let self else { return }; if expanded { characterExpanded.remove(character.id) } else { characterExpanded.insert(character.id) }; renderDetail() })
            if expanded { detail.addArrangedSubview(selectable(character.biography + "\n" + character.appearance, size: 14)) }
        }
    }
    private func toggleTechnical(_ id: String) { if technicalExpanded.contains(id) { technicalExpanded.remove(id) } else { technicalExpanded.insert(id) }; renderDetail() }
    private func confirmRestore() {
        guard canRestore, let captured = selection else { return }
        let alert = UIAlertController(title: "Restore the previewed revision?", message: "Your current state stays in history. Restoring creates a new revision. A cloud restore ends editing leases; local audio is not part of cloud history.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Restore as a new revision", style: .default) { [weak self] _ in
            guard let self, requireCurrentContext(), canRestore, selection?.id == captured.id else { return }
            switch captured { case .working: return; case .local(let event): store.restoreHistory(event); case .cloud(let event): store.restoreCloudHistory(event) }
            dismiss(animated: true)
        }); present(alert, animated: true)
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { events.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "history", for: indexPath) as! HistoryEventCell
        let event = events[indexPath.row], detail: String
        switch event { case .working: detail = "Working copy"; case .local(let item): detail = "Revision \(item.revision)"; case .cloud(let item): detail = item.kind.hasPrefix("discussion.") ? "Discussion activity" : "Change \(item.seq)" + (item.seq == store.cloud.headSeq ? " · Current" : "") }
        cell.configure(title: event.title, subtitle: "\(author(event)) · \(event.date.formatted(date: .abbreviated, time: .shortened))", detail: detail); return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { choose(events[indexPath.row]) }
    private func selectable(_ text: String, size: CGFloat, monospaced: Bool = false) -> UIView {
        let view = ScriptTextView(); view.setScriptStyle(size: size, direction: false); view.isEditable = false; view.isSelectable = true; view.text = text; view.textColor = ScrivUIKitTheme.ink
        if monospaced { view.font = .monospacedSystemFont(ofSize: size, weight: .regular) }; return view
    }
    private func json(_ value: JSONValue) -> String {
        let encoder = ScrivJSON.encoder; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "Unable to decode metadata" }
        return text.count > 40_000 ? String(text.prefix(40_000)) + "\n… Preview truncated; the full revision remains in history." : text
    }
    private func padded(_ child: UIView, amount: CGFloat) -> UIView { let container = UIView(); container.addSubview(child); child.scrivPinEdges(to: container, insets: NSDirectionalEdgeInsets(top: amount, leading: amount, bottom: amount, trailing: amount)); return container }
    private func line() -> UIView { let line = UIView(); line.backgroundColor = ScrivUIKitTheme.hairline; line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true; return line }
    private func verticalLine() -> UIView { let line = UIView(); line.backgroundColor = ScrivUIKitTheme.hairline; line.widthAnchor.constraint(equalToConstant: 0.5).isActive = true; return line }
}

private final class HistoryEventCell: UITableViewCell {
    private let dot = UIImageView(image: UIImage(systemName: "circle.fill"))
    private let heading = ScrivUIKitTheme.label("", size: 16, weight: .semibold)
    private let subtitle = ScrivUIKitTheme.label("", size: 12, color: ScrivUIKitTheme.secondary)
    private let detail = ScrivUIKitTheme.label("", size: 12, color: ScrivUIKitTheme.secondary)
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier); backgroundColor = .clear
        dot.contentMode = .scaleAspectFit; dot.widthAnchor.constraint(equalToConstant: 14).isActive = true; dot.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let row = ScrivUIKitTheme.stack([dot, ScrivUIKitTheme.stack([heading, subtitle, detail], spacing: 6)], axis: .horizontal, spacing: 18); row.alignment = .top
        contentView.addSubview(row); row.scrivPinEdges(to: contentView, insets: NSDirectionalEdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24))
        let selected = UIView(); selected.backgroundColor = ScrivUIKitTheme.accent.withAlphaComponent(0.1); selected.layer.cornerRadius = 12; selectedBackgroundView = selected
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func configure(title: String, subtitle: String, detail: String) { heading.text = title; self.subtitle.text = subtitle; self.detail.text = detail; dot.tintColor = isSelected ? ScrivUIKitTheme.accent : ScrivUIKitTheme.secondary.withAlphaComponent(0.4) }
    override func setSelected(_ selected: Bool, animated: Bool) { super.setSelected(selected, animated: animated); dot.tintColor = selected ? ScrivUIKitTheme.accent : ScrivUIKitTheme.secondary.withAlphaComponent(0.4) }
}
