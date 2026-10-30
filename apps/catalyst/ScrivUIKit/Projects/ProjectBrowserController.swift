import UIKit
import ScrivCore

private enum UIKitProjectSource: String, CaseIterable { case recent = "Recent", local = "On this Mac", cloud = "Scriv Cloud", team = "Team projects"
    var symbol: String { switch self { case .recent: return "clock"; case .local: return "laptopcomputer"; case .cloud: return "icloud"; case .team: return "person.2" } }
}
private struct UIKitBrowserProject {
    let id: String, title: String, source: String, symbol: String
    let localURL: URL?
    let remote: CloudProject?
    let summary: ProjectBrowserLocalSummary?
    var modified: Date? { summary?.project?.modifiedAt }
    var detail: String { summary?.project.map { "\($0.scenes.count) scene\($0.scenes.count == 1 ? "" : "s")" } ?? (summary?.issue != nil ? "Metadata unavailable — open to inspect" : remote == nil ? "Reading project…" : "Cloud project") }
}

@MainActor
final class ProjectBrowserController: ScrivScreenController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private let search = UISearchTextField()
    private let heading = ScrivUIKitTheme.label("Recent projects", size: 15, weight: .semibold)
    private let footerTitle = ScrivUIKitTheme.label("", size: 17, weight: .semibold, lines: 1)
    private let footerSubtitle = ScrivUIKitTheme.label("", size: 13, color: ScrivUIKitTheme.secondary)
    private let footerSource = ScrivUIKitTheme.label("", size: 12, color: ScrivUIKitTheme.secondary)
    private let footerImage = ProjectCoverView()
    private let empty = ScrivUIKitTheme.stack([], spacing: 15)
    private var openButton: UIButton!
    private var refreshButton: UIButton!
    private var sourceButtons: [UIKitProjectSource: UIButton] = [:]
    private var source: UIKitProjectSource = .recent
    private var summaries: [String: ProjectBrowserLocalSummary] = [:]
    private var visible: [UIKitBrowserProject] = []
    private var selectedID: String?
    private var lastPaths: [String] = []
    private var summaryTask: Task<Void, Never>?
    private var summaryGeneration = UUID()
    private let initialProjectID: String
    private let initialPackage: URL?

    init(store: WorkspaceStore) {
        initialProjectID = store.project.id; initialPackage = store.projectURL
        super.init(store: store, scopeToProject: false); preferredContentSize = CGSize(width: 960, height: 740)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        let sidebar = makeSidebar()
        search.placeholder = "Find a project"; search.delegate = self; search.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        search.widthAnchor.constraint(equalToConstant: 235).isActive = true
        let header = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Projects", size: 18, weight: .semibold), UIView(), search, ScrivUIKitTheme.button("New project", primary: true) { [weak self] in self?.store.newProject() }, ScrivUIKitTheme.button("Close", symbol: "xmark") { [weak self] in self?.dismiss(animated: true) }], axis: .horizontal, spacing: 12); header.alignment = .center
        refreshButton = ScrivUIKitTheme.button("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.store.refreshAccount() }
        let section = ScrivUIKitTheme.stack([heading, UIView(), refreshButton], axis: .horizontal, spacing: 12); section.alignment = .center
        table.dataSource = self; table.delegate = self; table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 100
        table.separatorStyle = .none; table.backgroundColor = .clear; table.register(ProjectBrowserCell.self, forCellReuseIdentifier: "project")
        table.contentInset = UIEdgeInsets(top: 0, left: 6, bottom: 20, right: 6)
        let doubleClick = UITapGestureRecognizer(target: self, action: #selector(openDoubleTapped(_:))); doubleClick.numberOfTapsRequired = 2; doubleClick.cancelsTouchesInView = false; table.addGestureRecognizer(doubleClick)
        let listContainer = UIView(); listContainer.addSubview(table); table.scrivPinEdges(to: listContainer)
        listContainer.addSubview(empty); empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor), empty.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor), empty.leadingAnchor.constraint(greaterThanOrEqualTo: listContainer.leadingAnchor, constant: 30), empty.trailingAnchor.constraint(lessThanOrEqualTo: listContainer.trailingAnchor, constant: -30), empty.widthAnchor.constraint(lessThanOrEqualToConstant: 500)])
        let right = ScrivUIKitTheme.stack([padded(header, top: 18, bottom: 18), line(), padded(section, top: 18, bottom: 12), listContainer], spacing: 0)
        let body = ScrivUIKitTheme.stack([sidebar, verticalLine(), right], axis: .horizontal, spacing: 0)
        let bottom = makeFooter()
        let local = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("⌨  Local editing is always available. No sign-in required.", size: 12, color: ScrivUIKitTheme.secondary), UIView(), ScrivUIKitTheme.button("Sign in to Scriv…") { [weak self] in self?.show(.signIn) }], axis: .horizontal, spacing: 12)
        let root = ScrivUIKitTheme.stack([body, line(), bottom, line(), padded(local, top: 6, bottom: 6)], spacing: 0)
        view.addSubview(root); root.scrivPinEdges(to: view)
        store.refreshLocalProjects(); if store.account != nil { store.refreshAccount() }; reload()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); loadSummaries() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if isBeingDismissed { summaryTask?.cancel() } }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        if store.project.id != initialProjectID || store.projectURL != initialPackage { dismiss(animated: true); return }
        let paths = store.localProjects.map(\.path)
        if paths != lastPaths { lastPaths = paths; loadSummaries() }
        reload()
    }
    private func makeSidebar() -> UIView {
        let content = ScrivUIKitTheme.stack([], spacing: 6)
        content.addArrangedSubview(padded(ScrivUIKitTheme.label("Library", size: 12, weight: .medium, color: ScrivUIKitTheme.secondary), top: 26, bottom: 22))
        for item in UIKitProjectSource.allCases {
            let button = ScrivUIKitTheme.button(item.rawValue, symbol: item.symbol) { [weak self] in self?.source = item; self?.reload() }
            button.contentHorizontalAlignment = .leading; sourceButtons[item] = button; content.addArrangedSubview(button)
        }
        content.addArrangedSubview(UIView())
        let sidebar = UIView(); sidebar.backgroundColor = ScrivUIKitTheme.chrome.withAlphaComponent(0.3); sidebar.widthAnchor.constraint(equalToConstant: 190).isActive = true
        sidebar.addSubview(content); content.scrivPinEdges(to: sidebar, insets: NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)); return sidebar
    }
    private func makeFooter() -> UIView {
        footerImage.widthAnchor.constraint(equalToConstant: 112).isActive = true; footerImage.heightAnchor.constraint(equalToConstant: 74).isActive = true
        let labels = ScrivUIKitTheme.stack([footerTitle, footerSubtitle, footerSource], spacing: 7)
        openButton = ScrivUIKitTheme.button("Open project", primary: true) { [weak self] in self?.openSelected() }
        let row = ScrivUIKitTheme.stack([footerImage, labels, UIView(), ScrivUIKitTheme.button("Open…") { [weak self] in self?.store.openProject() }, ScrivUIKitTheme.button("Import script…") { [weak self] in self?.store.importScript() }, openButton], axis: .horizontal, spacing: 16); row.alignment = .center
        return padded(row, top: 20, bottom: 20)
    }
    private func reload() {
        let locals = store.localProjects.map { url -> UIKitBrowserProject in
            let summary = summaries[url.path]
            return UIKitBrowserProject(id: "local:" + url.path, title: summary?.project?.title ?? url.deletingPathExtension().lastPathComponent, source: "This Mac", symbol: "laptopcomputer", localURL: url, remote: nil, summary: summary)
        }
        let remotes = (store.account == nil ? [] : store.cloudProjects).map { remote in
            UIKitBrowserProject(id: "cloud:" + remote.id, title: remote.title, source: remote.teamId.flatMap { id in store.teams.first { $0.id == id }?.name } ?? (remote.teamId == nil ? "Private cloud" : "Team"), symbol: remote.teamId == nil ? "icloud" : "person.2", localURL: nil, remote: remote, summary: nil)
        }
        let candidates: [UIKitBrowserProject]
        switch source {
        case .local: candidates = locals
        case .cloud: candidates = remotes.filter { $0.remote?.teamId == nil }
        case .team: candidates = remotes.filter { $0.remote?.teamId != nil }
        case .recent:
            let localCloudIDs = Set(locals.compactMap { $0.summary?.project?.cloudProjectId })
            candidates = locals + remotes.filter { !localCloudIDs.contains($0.remote?.id ?? "") }
        }
        let query = (search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        visible = candidates.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.sorted {
            if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        if !visible.contains(where: { $0.id == selectedID }) { selectedID = visible.first?.id }
        heading.text = source == .recent ? "Recent projects" : source.rawValue
        refreshButton.isHidden = source == .local || source == .recent || store.account == nil
        for (item, button) in sourceButtons {
            button.configuration?.baseBackgroundColor = item == source ? ScrivUIKitTheme.accent.withAlphaComponent(0.1) : .clear
            button.configuration?.baseForegroundColor = item == source ? ScrivUIKitTheme.accent : ScrivUIKitTheme.ink
            button.accessibilityTraits = item == source ? [.button, .selected] : [.button]
        }
        table.reloadData()
        if let index = visible.firstIndex(where: { $0.id == selectedID }) { table.selectRow(at: IndexPath(row: index, section: 0), animated: false, scrollPosition: .none) }
        updateFooter(); updateEmpty(query: query)
    }
    private func updateFooter() {
        if let project = visible.first(where: { $0.id == selectedID }) {
            footerTitle.text = project.title; footerSubtitle.text = project.detail; footerSource.text = project.source; footerImage.setURL(project.summary?.thumbnailURL); footerImage.isHidden = false; openButton.isEnabled = true
        } else {
            footerTitle.text = "Your next script starts here"; footerSubtitle.text = "Create a project, open a .scriv package, or import a script."; footerSource.text = nil; footerImage.isHidden = true; openButton.isEnabled = false
        }
    }
    private func updateEmpty(query: String) {
        empty.isHidden = !visible.isEmpty; table.isHidden = visible.isEmpty
        guard visible.isEmpty else { return }
        for child in empty.arrangedSubviews { empty.removeArrangedSubview(child); child.removeFromSuperview() }
        let signedOut = (source == .cloud || source == .team) && store.account == nil
        let icon = UIImageView(image: UIImage(systemName: signedOut ? source.symbol : query.isEmpty ? "doc.text" : "magnifyingglass")); icon.contentMode = .scaleAspectFit; icon.tintColor = ScrivUIKitTheme.secondary; icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let title = ScrivUIKitTheme.label(signedOut ? "Your \(source.rawValue.lowercased())" : query.isEmpty ? "No projects here yet" : "No matching projects", size: 22, weight: .semibold); title.textAlignment = .center
        let message = ScrivUIKitTheme.label(signedOut ? "Sign in for free script storage and team access. Your local projects stay available without an account." : query.isEmpty ? "Start with New project, Open… or Import script… below." : "Try another title or choose a different source.", size: 14, color: ScrivUIKitTheme.secondary); message.textAlignment = .center
        [icon, title, message].forEach { empty.addArrangedSubview($0) }
        if signedOut { empty.addArrangedSubview(ScrivUIKitTheme.button("Sign in to Scriv", primary: true) { [weak self] in self?.show(.signIn) }) }
        else if !query.isEmpty { empty.addArrangedSubview(ScrivUIKitTheme.button("Clear search") { [weak self] in self?.search.text = ""; self?.reload() }) }
    }
    private func loadSummaries() {
        summaryTask?.cancel(); let generation = UUID(); summaryGeneration = generation
        let urls = store.localProjects; lastPaths = urls.map(\.path)
        summaries = summaries.filter { key, _ in urls.contains { $0.path == key } }
        summaryTask = Task { [weak self] in
            for url in urls {
                let summary = await Task.detached(priority: .utility) { ProjectBrowserLocalSummary.load(at: url) }.value
                guard let self, !Task.isCancelled, summaryGeneration == generation else { return }
                summaries[url.path] = summary; reload()
            }
        }
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visible.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "project", for: indexPath) as! ProjectBrowserCell
        cell.configure(visible[indexPath.row]); return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { selectedID = visible[indexPath.row].id; updateFooter() }
    @objc private func openDoubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let index = table.indexPathForRow(at: recognizer.location(in: table)), visible.indices.contains(index.row) else { return }
        selectedID = visible[index.row].id; openSelected()
    }
    private func openSelected() {
        guard let project = visible.first(where: { $0.id == selectedID }) else { return }
        if let url = project.localURL { store.openLocalProject(url); if url == store.projectURL { dismiss(animated: true) } }
        else if let remote = project.remote { store.openCloudProject(remote); if remote.id == store.project.cloudProjectId { dismiss(animated: true) } }
    }
    @objc private func searchChanged() { reload() }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { openSelected(); return false }
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeCommand)), UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(openCommand))] }
    @objc private func closeCommand() { dismiss(animated: true) }
    @objc private func openCommand() { openSelected() }
    private func padded(_ child: UIView, top: CGFloat, bottom: CGFloat) -> UIView { let container = UIView(); container.addSubview(child); child.scrivPinEdges(to: container, insets: NSDirectionalEdgeInsets(top: top, leading: 24, bottom: bottom, trailing: 24)); return container }
    private func line() -> UIView { let view = UIView(); view.backgroundColor = ScrivUIKitTheme.hairline; view.heightAnchor.constraint(equalToConstant: 0.5).isActive = true; return view }
    private func verticalLine() -> UIView { let view = UIView(); view.backgroundColor = ScrivUIKitTheme.hairline; view.widthAnchor.constraint(equalToConstant: 0.5).isActive = true; return view }
}

private final class ProjectBrowserCell: UITableViewCell {
    private let cover = ProjectCoverView()
    private let title = ScrivUIKitTheme.label("", size: 18, weight: .semibold, lines: 1)
    private let detail = ScrivUIKitTheme.label("", size: 13, color: ScrivUIKitTheme.secondary, lines: 2)
    private let source = ScrivUIKitTheme.label("", size: 13, color: ScrivUIKitTheme.secondary, lines: 2)
    private let date = ScrivUIKitTheme.label("", size: 12, color: ScrivUIKitTheme.secondary, lines: 2)
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear; contentView.backgroundColor = .clear
        cover.widthAnchor.constraint(equalToConstant: 112).isActive = true; cover.heightAnchor.constraint(equalToConstant: 76).isActive = true
        source.widthAnchor.constraint(equalToConstant: 110).isActive = true; date.widthAnchor.constraint(equalToConstant: 112).isActive = true; date.textAlignment = .right
        let row = ScrivUIKitTheme.stack([cover, ScrivUIKitTheme.stack([title, detail], spacing: 7), source, date], axis: .horizontal, spacing: 20); row.alignment = .center
        contentView.addSubview(row); row.scrivPinEdges(to: contentView, insets: NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        let selected = UIView(); selected.backgroundColor = ScrivUIKitTheme.accent.withAlphaComponent(0.09); selected.layer.cornerRadius = 12; selectedBackgroundView = selected
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func configure(_ project: UIKitBrowserProject) {
        title.text = project.title; detail.text = project.detail; source.text = project.source
        date.text = project.modified.map { "Edited \($0.formatted(.relative(presentation: .named)))" } ?? (project.remote == nil ? "" : "Open to view")
        cover.setURL(project.summary?.thumbnailURL)
        accessibilityLabel = "\(project.title), \(project.source), \(project.detail)"
    }
}

@MainActor
final class ProjectCoverView: UIView {
    private let imageView = UIImageView(), placeholder = UIImageView(image: UIImage(systemName: "doc.text"))
    private var url: URL?
    private var load: Task<Void, Never>?
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = ScrivUIKitTheme.inset; layer.cornerRadius = 8; clipsToBounds = true
        imageView.contentMode = .scaleAspectFill; placeholder.contentMode = .center; placeholder.tintColor = ScrivUIKitTheme.secondary
        addSubview(imageView); imageView.scrivPinEdges(to: self); addSubview(placeholder); placeholder.scrivPinEdges(to: self); isAccessibilityElement = false
    }
    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func setURL(_ value: URL?) {
        guard value != url else { return }; url = value; load?.cancel(); imageView.image = nil; placeholder.isHidden = false
        guard let value, value.isFileURL else { return }
        load = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { () -> Data? in
                guard let size = try? value.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 25 * 1024 * 1024 else { return nil }
                return try? Data(contentsOf: value, options: .mappedIfSafe)
            }.value
            guard let self, !Task.isCancelled, self.url == value else { return }
            imageView.image = data.flatMap { UIImage(data: $0) }; placeholder.isHidden = imageView.image != nil
        }
    }
}
