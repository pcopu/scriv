import SwiftUI
import AppKit
import ScrivCore

private enum ProjectBrowserSource: String, CaseIterable, Identifiable {
    case recent = "Recent", local = "On this Mac", cloud = "Scriv Cloud", team = "Team projects"
    var id: Self { self }
    var symbol: String { switch self { case .recent: return "clock"; case .local: return "laptopcomputer"; case .cloud: return "icloud"; case .team: return "person.2" } }
    var heading: String { self == .recent ? "Recent projects" : rawValue }
}
private struct BrowserProject: Identifiable {
    let id: String
    let title: String
    let localURL: URL?
    let cloud: CloudProject?
    let summary: ProjectBrowserLocalSummary?
    let source: String
    let symbol: String
    var modified: Date? { summary?.project?.modifiedAt }
    var sceneCount: Int? { summary?.project?.scenes.count }
    var subtitle: String { sceneCount.map { "\($0) scene\($0 == 1 ? "" : "s")" } ?? (summary?.issue == nil ? (cloud == nil ? "Reading project…" : "Cloud project") : "Metadata unavailable — open to inspect") }
}

struct ProjectBrowserSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var source: ProjectBrowserSource = .recent
    @State private var selectedID: String?
    @State private var summaries: [String: ProjectBrowserLocalSummary] = [:]
    @State private var showingSignIn = false

    private var projects: [BrowserProject] {
        let locals = store.localProjects.map { url in
            let summary = summaries[url.path]
            return BrowserProject(id: "local:" + url.path, title: summary?.project?.title ?? url.deletingPathExtension().lastPathComponent,
                                  localURL: url, cloud: nil, summary: summary, source: "This Mac", symbol: "laptopcomputer")
        }
        let remotes = (store.account == nil ? [] : store.cloudProjects).map { remote in
            BrowserProject(id: "cloud:" + remote.id, title: remote.title, localURL: nil, cloud: remote, summary: nil,
                           source: remote.teamId.flatMap { id in store.teams.first { $0.id == id }?.name } ?? (remote.teamId == nil ? "Private cloud" : "Team"),
                           symbol: remote.teamId == nil ? "icloud" : "person.2")
        }
        let candidates: [BrowserProject]
        switch source {
        case .local: candidates = locals
        case .cloud: candidates = remotes.filter { $0.cloud?.teamId == nil }
        case .team: candidates = remotes.filter { $0.cloud?.teamId != nil }
        case .recent:
            // A cloud-backed local copy is listed once in Recent. Cloud filters
            // still explicitly open the remote, rather than silently using a copy.
            let cached = Set(locals.compactMap { $0.summary?.project?.cloudProjectId })
            candidates = locals + remotes.filter { !cached.contains($0.cloud?.id ?? "") }
        }
        return candidates.filter { search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.title.localizedCaseInsensitiveContains(search.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .sorted {
                if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }
    private var selected: BrowserProject? { projects.first { $0.id == selectedID } }
    private var cloudSource: Bool { source == .cloud || source == .team }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(ScrivTheme.hairline)
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider().opacity(0.45)
                    HStack {
                        Text(source.heading).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        if cloudSource && store.account != nil {
                            Button { store.refreshAccount() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(ScrivTheme.accent).help("Refresh cloud projects")
                        }
                    }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 14)
                    if cloudSource && store.account == nil { signedOut }
                    else if projects.isEmpty { emptyProjects }
                    else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(projects) { project in
                                    LocalProjectRow(project: project, selected: selectedID == project.id) { selectedID = project.id }
                                        .simultaneousGesture(TapGesture(count: 2).onEnded { open(project) })
                                }
                            }.padding(.horizontal, 18).padding(.bottom, 20)
                        }
                    }
                }
            }
            Divider().opacity(0.45)
            selectedProjectFooter
            Divider().opacity(0.45)
            HStack(spacing: 11) {
                Image(systemName: "laptopcomputer").font(.system(size: 15))
                Text("Local editing is always available. No sign-in required.").font(.system(size: 12))
                Spacer()
                if store.account == nil { Button("Sign in to Scriv…") { showingSignIn = true }.buttonStyle(.plain).foregroundStyle(ScrivTheme.accent) }
            }.foregroundStyle(ScrivTheme.secondary).padding(.horizontal, 26).frame(height: 48).background(ScrivTheme.chrome.opacity(0.22))
        }.frame(width: 960, height: 740).background(ScrivTheme.panel)
            .onAppear { store.refreshLocalProjects(); if store.account != nil { store.refreshAccount() } }
            .task(id: store.localProjects) { await loadSummaries() }
            .onChange(of: projects.map(\.id)) { _, ids in reconcileSelection(ids) }
            .sheet(isPresented: $showingSignIn) { ScrivSignInSheet().environmentObject(store) }
            .onChange(of: store.account?.id) { _, id in if id != nil { store.refreshAccount() } }
            // A canceled picker leaves this browser open. Only a successful
            // project switch dismisses it; failed opens retain the selection.
            .onChange(of: store.project.id) { _, _ in dismiss() }
            .onChange(of: store.projectURL) { _, _ in dismiss() }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("Library").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary); Spacer() }.frame(height: 64).padding(.horizontal, 18)
            ForEach(ProjectBrowserSource.allCases) { item in
                Button { source = item } label: {
                    HStack(spacing: 13) {
                        Image(systemName: item.symbol).font(.system(size: 19, weight: .regular)).frame(width: 23)
                        Text(item.rawValue).font(.system(size: 14, weight: source == item ? .medium : .regular))
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 15).frame(height: 44)
                        .foregroundStyle(source == item ? ScrivTheme.accent : ScrivTheme.ink)
                        .background(source == item ? ScrivTheme.accent.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityAddTraits(source == item ? .isSelected : [])
            }
            Spacer()
        }.padding(.horizontal, 10).frame(width: 190).background(ScrivTheme.chrome.opacity(0.26))
    }
    private var header: some View {
        HStack(spacing: 12) {
            Text("Projects").font(.system(size: 18, weight: .semibold))
            Spacer(minLength: 20)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(ScrivTheme.secondary)
                TextField("Find a project", text: $search).textFieldStyle(.plain).font(.system(size: 14)).accessibilityLabel("Find a project")
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear project search") }
            }.padding(.horizontal, 12).frame(width: 235, height: 37).background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ScrivTheme.hairline))
            Button("New project") { store.newProject(); dismiss() }.buttonStyle(ScrivPrimaryButtonStyle())
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .medium)) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(6).help("Close projects").accessibilityLabel("Close projects").keyboardShortcut(.cancelAction)
        }.padding(.horizontal, 24).frame(height: 72).background(ScrivTheme.chrome.opacity(0.1))
    }
    private var selectedProjectFooter: some View {
        HStack(spacing: 20) {
            if let selected {
                ProjectBrowserThumbnail(url: selected.summary?.thumbnailURL).frame(width: 112, height: 74)
                VStack(alignment: .leading, spacing: 7) {
                    Text(selected.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Text(selected.subtitle).font(.system(size: 13)).foregroundStyle(ScrivTheme.secondary)
                    Text(selected.source).font(.system(size: 12)).foregroundStyle(ScrivTheme.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your next script starts here").font(.system(size: 16, weight: .semibold))
                    Text("Create a project, open a .scriv package, or import a script.").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Button("Open…") { store.openProject() }.buttonStyle(ScrivSecondaryButtonStyle()).help("Open a .scriv project package")
                Button("Import script…") { store.importScript() }.buttonStyle(ScrivSecondaryButtonStyle()).help("Import Fountain, text or Scriv JSON")
                Button("Open project") { if let selected { open(selected) } }.buttonStyle(ScrivPrimaryButtonStyle()).disabled(selected == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(.horizontal, 26).frame(height: 116)
    }
    private var signedOut: some View {
        VStack(spacing: 14) {
            Image(systemName: source.symbol).font(.system(size: 34, weight: .light)).foregroundStyle(ScrivTheme.secondary)
            Text(source == .team ? "Your team projects" : "Your Scriv Cloud projects").font(.system(size: 21, weight: .semibold))
            Text("Sign in for free script storage and team access.\nYour local projects stay available without an account.").font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            Button("Sign in to Scriv") { showingSignIn = true }.buttonStyle(ScrivPrimaryButtonStyle()).padding(.top, 4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
    private var emptyProjects: some View {
        VStack(spacing: 12) {
            Image(systemName: search.isEmpty ? "doc.text" : "magnifyingglass").font(.system(size: 34, weight: .light)).foregroundStyle(ScrivTheme.secondary)
            Text(search.isEmpty ? "No projects here yet" : "No matching projects").font(.system(size: 20, weight: .semibold))
            Text(search.isEmpty ? (cloudSource ? "Cloud projects appear here when you save or join one." : "Start with New project, Open… or Import script… below.") : "Try another title or choose a different source.").font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !search.isEmpty { Button("Clear search") { search = "" }.buttonStyle(ScrivSecondaryButtonStyle()) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
    private func open(_ project: BrowserProject) {
        if let url = project.localURL { store.openLocalProject(url) }
        else if let remote = project.cloud { store.openCloudProject(remote) }
        // The active project may be selected again without changing its ID.
        if project.localURL != nil && project.localURL == store.projectURL || (project.cloud != nil && project.cloud?.id == store.project.cloudProjectId) { dismiss() }
    }
    private func reconcileSelection(_ ids: [String]) {
        if let selectedID, ids.contains(selectedID) { return }
        selectedID = ids.first
    }
    @MainActor private func loadSummaries() async {
        let urls = store.localProjects
        summaries = summaries.filter { key, _ in urls.contains { $0.path == key } }
        reconcileSelection(projects.map(\.id))
        for url in urls {
            let summary = await Task.detached(priority: .utility) { ProjectBrowserLocalSummary.load(at: url) }.value
            guard !Task.isCancelled else { return }
            summaries[url.path] = summary
        }
        reconcileSelection(projects.map(\.id))
    }
}

private struct LocalProjectRow: View {
    let project: BrowserProject
    let selected: Bool
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            HStack(spacing: 20) {
                ProjectBrowserThumbnail(url: project.summary?.thumbnailURL).frame(width: 112, height: 76)
                VStack(alignment: .leading, spacing: 7) {
                    Text(project.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(ScrivTheme.ink).lineLimit(1)
                    Text(project.subtitle).font(.system(size: 13)).foregroundStyle(ScrivTheme.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Label(project.source, systemImage: project.symbol).font(.system(size: 13)).foregroundStyle(ScrivTheme.secondary).frame(width: 125, alignment: .leading).lineLimit(2)
                Group {
                    if let date = project.modified { Text("Edited \(date.formatted(.relative(presentation: .named)))") }
                    else if project.cloud != nil { Text("Open to view") }
                    else { Text("") }
                }.font(.system(size: 12)).foregroundStyle(ScrivTheme.secondary).frame(width: 112, alignment: .trailing).multilineTextAlignment(.trailing)
            }.padding(12).frame(minHeight: 100).background(selected ? ScrivTheme.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel("\(project.title), \(project.source), \(project.subtitle)")
    }
}
private struct ProjectBrowserThumbnail: View {
    let url: URL?
    var body: some View {
        Group {
            if let url { AssetImageView(url: url, title: "Project cover", cornerRadius: 8, unavailableText: "No preview") }
            else { RoundedRectangle(cornerRadius: 8).fill(ScrivTheme.inset).overlay(Image(systemName: "doc.text").font(.system(size: 28, weight: .light)).foregroundStyle(ScrivTheme.secondary)) }
        }.accessibilityHidden(true)
    }
}

private enum HistorySelection: Identifiable {
    case working(ScrivProject), local(HistoryEntry), cloud(CloudEvent)
    var id: String { switch self { case .working(let project): return "working:\(project.id):\(project.revision)"; case .local(let event): return "local:" + event.id; case .cloud(let event): return "cloud:\(event.seq)" } }
    var title: String { switch self { case .working: return "Current revision"; case .local(let event): return event.label; case .cloud(let event): return event.label } }
    var date: Date { switch self { case .working(let project): return project.modifiedAt; case .local(let event): return event.date; case .cloud(let event): return Date(timeIntervalSince1970: Double(event.at) / 1000) } }
}

struct HistorySheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = "This Mac"
    @State private var inspection: HistorySelection?
    @State private var preview: ScrivProject?
    @State private var loading = false
    @State private var refreshing = false
    @State private var previewError: String?
    @State private var confirming = false
    private var localEvents: [HistoryEntry] { store.history.filter { $0.revision != store.project.revision }.sorted { $0.revision > $1.revision } }
    private var before: ScrivProject? {
        let revision: Int
        switch inspection { case .local(let event): revision = event.revision; case .working(let project): revision = project.revision; default: return nil }
        return store.history.filter { $0.revision < revision }.max { $0.revision < $1.revision }?.snapshot
    }
    private var canRestore: Bool {
        guard preview != nil, !loading, previewError == nil, let inspection else { return false }
        switch inspection { case .working: return false; case .local(let event): return event.revision != store.project.revision; case .cloud(let event): return !event.kind.hasPrefix("discussion.") && event.seq != store.cloud.headSeq }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 23, weight: .light)).foregroundStyle(ScrivTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("History").font(.system(size: 23, weight: .semibold))
                    Text(store.project.title).font(.system(size: 14)).foregroundStyle(ScrivTheme.secondary).lineLimit(1)
                }
                Spacer()
                if refreshing { ProgressView().controlSize(.small) }
                if source == "Cloud" { Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(ScrivTheme.accent).disabled(store.project.cloudProjectId == nil || refreshing).help("Refresh cloud history") }
                Picker("History source", selection: $source) { Text("This Mac").tag("This Mac"); Text("Cloud").tag("Cloud") }.pickerStyle(.segmented).frame(width: 260)
            }.padding(.horizontal, 28).frame(height: 82).background(ScrivTheme.chrome.opacity(0.12))
            Divider().opacity(0.45)
            HStack(spacing: 0) {
                historyList.frame(width: 330).background(ScrivTheme.chrome.opacity(0.18))
                Divider().opacity(0.45)
                if let inspection {
                    HistoryInspector(selection: inspection, preview: preview, before: before, loading: loading, error: previewError, author: author(inspection))
                        .environmentObject(store).id(inspection.id)
                } else {
                    EmptyPanel(symbol: "clock.arrow.circlepath", title: "Select a revision", message: source == "Cloud" && store.project.cloudProjectId == nil ? "Save this project to Scriv Cloud to keep shared history. Local history is available on This Mac." : "Choose a change to compare its contents before restoring.")
                }
            }.frame(maxHeight: .infinity)
            Divider().opacity(0.45)
            HStack(spacing: 16) {
                Image(systemName: "info.circle").font(.system(size: 21)).foregroundStyle(ScrivTheme.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Restore creates a new revision. Current work stays in history.").font(.system(size: 12, weight: .medium))
                    Text("Restoring does not rewind discussion, membership or billing.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button("Close") { dismiss() }.buttonStyle(ScrivSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Restore revision…") { confirming = true }.buttonStyle(ScrivPrimaryButtonStyle()).disabled(!canRestore)
            }.padding(.horizontal, 28).frame(height: 80).background(ScrivTheme.chrome.opacity(0.12))
        }.frame(width: 1040, height: 740).background(ScrivTheme.panel)
            .onAppear { selectLocalDefault() }
            .onChange(of: source) { _, value in
                preview = nil; previewError = nil
                if value == "Cloud" { inspection = store.cloudHistory.first.map(HistorySelection.cloud); refresh() }
                else { selectLocalDefault() }
            }
            .task(id: inspection?.id) { await loadPreview() }
            .confirmationDialog("Restore the previewed revision?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Restore as a new revision") {
                    guard canRestore, let inspection else { return }
                    switch inspection { case .working: break; case .local(let event): store.restoreHistory(event); case .cloud(let event): store.restoreCloudHistory(event) }
                    dismiss()
                }
            } message: { Text("Your current state remains in history. A cloud restore ends editing leases. Local audio is not part of cloud history.") }
    }
    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if source == "This Mac" {
                    historyRow(.working(store.project), detail: "Working copy", current: true)
                    ForEach(localEvents) { event in historyRow(.local(event), detail: "Revision \(event.revision)", current: false) }
                } else {
                    if store.cloudHistory.isEmpty {
                        Text(store.project.cloudProjectId == nil ? "This project is local. Switch to This Mac for its saved history." : "No cloud changes have been recorded yet.").font(.system(size: 13)).foregroundStyle(.secondary).padding(28)
                    }
                    ForEach(store.cloudHistory.sorted { $0.seq > $1.seq }) { event in historyRow(.cloud(event), detail: event.kind.hasPrefix("discussion.") ? "Discussion activity" : "Change \(event.seq)", current: event.seq == store.cloud.headSeq) }
                }
            }.padding(.horizontal, 12).padding(.vertical, 12)
        }
    }
    private func historyRow(_ selection: HistorySelection, detail: String, current: Bool) -> some View {
        let selected = inspection?.id == selection.id
        return Button { inspection = selection } label: {
            HStack(alignment: .top, spacing: 18) {
                Circle().fill(selected ? ScrivTheme.accent : ScrivTheme.secondary.opacity(0.4)).frame(width: 14, height: 14)
                    .overlay(Circle().fill(ScrivTheme.panel).frame(width: selected ? 5 : 0, height: selected ? 5 : 0)).padding(.top, 5)
                    .overlay(alignment: .bottom) { Rectangle().fill(ScrivTheme.hairline).frame(width: 1, height: 68).offset(y: 74) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(selection.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(ScrivTheme.ink).lineLimit(3).multilineTextAlignment(.leading)
                    Text("\(author(selection)) · \(selection.date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 12)).foregroundStyle(ScrivTheme.secondary).multilineTextAlignment(.leading)
                    Text(current && source == "Cloud" ? detail + " · Current" : detail).font(.system(size: 12)).foregroundStyle(ScrivTheme.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 18).padding(.vertical, 18).frame(minHeight: 110, alignment: .top).background(selected ? ScrivTheme.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func author(_ selection: HistorySelection) -> String {
        if case .cloud(let event) = selection { return event.actorId == store.account?.id ? "You" : store.discussionMembers.first { $0.id == event.actorId }?.name ?? "Collaborator" }
        return "This Mac"
    }
    private func selectLocalDefault() { inspection = localEvents.first.map(HistorySelection.local) ?? .working(store.project) }
    private func refresh() {
        guard store.project.cloudProjectId != nil, !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false }
            do {
                try await store.refreshDiscussionActivity()
                if source == "Cloud", inspection == nil { inspection = store.cloudHistory.first.map(HistorySelection.cloud) }
            } catch is CancellationError { } catch { store.errorMessage = error.localizedDescription }
        }
    }
    @MainActor private func loadPreview() async {
        preview = nil; previewError = nil
        guard let selection = inspection else { return }
        loading = true
        defer { if inspection?.id == selection.id { loading = false } }
        do {
            let loaded: ScrivProject?
            switch selection {
            case .working(let project): loaded = project
            case .local(let event): loaded = event.snapshot
            case .cloud(let event): loaded = event.kind.hasPrefix("discussion.") ? nil : try await store.previewCloudHistory(event)
            }
            guard !Task.isCancelled, inspection?.id == selection.id else { return }
            preview = loaded
        } catch is CancellationError { } catch { if !Task.isCancelled, inspection?.id == selection.id { previewError = error.localizedDescription } }
    }
}

private struct HistoryInspector: View {
    @EnvironmentObject private var store: WorkspaceStore
    let selection: HistorySelection
    let preview: ScrivProject?
    let before: ScrivProject?
    let loading: Bool
    let error: String?
    let author: String
    @State private var tab = "Changes"
    private var cloudEvent: CloudEvent? { if case .cloud(let event) = selection { return event }; return nil }
    private var changes: [CloudChange] {
        if let event = cloudEvent { return event.changes }
        guard let preview else { return [] }
        return HistoryPresentation.localChanges(before: before, after: preview)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selection.title).font(.system(size: 24, weight: .semibold)).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                Text("\(author) · \(selection.date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 15)).foregroundStyle(ScrivTheme.secondary)
            }
            Picker("Revision detail", selection: $tab) { Text("Changes").tag("Changes"); Text("Revision preview").tag("Revision preview") }.pickerStyle(.segmented).frame(width: 320)
            if loading { ProgressView("Loading read-only revision…").controlSize(.small) }
            if let error { ScrivNotice(tone: .error, title: "Revision preview unavailable", message: error) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tab == "Changes" { changesView }
                    else if let preview { HistorySnapshotView(project: preview) }
                    else if !loading { Text("No script snapshot is available for this event.").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
            }
        }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    @ViewBuilder private var changesView: some View {
        if changes.isEmpty && !loading {
            if let event = cloudEvent, event.kind.hasPrefix("discussion.") { ScrivNotice(tone: .information, title: "Discussion activity", message: "This event is not a script restore point. Restoring a script never rewinds the conversation.") }
            else if cloudEvent?.data?["snapshotRequired"] == .bool(true) { ScrivNotice(tone: .information, title: "Full snapshot", message: "Open Revision preview to read the complete script state stored in this change.") }
            else { Text("No item changes in this revision. Open Revision preview to read its saved contents.").font(.system(size: 14)).foregroundStyle(.secondary) }
        }
        ForEach(changes, id: \.id) { change in
            HistoryChangeCard(change: change, beforeProject: before, afterProject: preview)
        }
        if let data = cloudEvent?.data {
            DisclosureGroup("Event metadata") { Text(historyJSON(data)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }.font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

private struct HistoryChangeCard: View {
    @EnvironmentObject private var store: WorkspaceStore
    let change: CloudChange
    let beforeProject: ScrivProject?
    let afterProject: ScrivProject?
    private var fields: [HistoryReadableField] { HistoryPresentation.fields(for: change, beforeProject: beforeProject, afterProject: afterProject) }
    private var unchangedImage: (ImageCue, ImageAsset)? {
        guard let beforeProject, let afterProject,
              let entry = afterProject.entries.first(where: { $0.id == change.id }),
              let cue = afterProject.activeCue(at: afterProject.startMs(of: entry.id), sceneId: entry.sceneId),
              let oldCue = beforeProject.cues.first(where: { $0.id == cue.id }), oldCue.imageId == cue.imageId,
              let asset = afterProject.asset(cue.imageId), beforeProject.asset(oldCue.imageId) == asset else { return nil }
        return (cue, asset)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(HistoryPresentation.title(for: change)).font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(HistoryPresentation.operation(for: change)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            if let text = (change.after ?? change.before)?.data["text"]?.string, !fields.contains(where: { $0.label == "Text" }) {
                Text("“\(text)”").font(.system(size: 15)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if fields.isEmpty {
                Text("Item details changed. Expand Technical details to inspect every stored value.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 13) {
                    column("Before", after: false)
                    Image(systemName: "arrow.right").font(.system(size: 21, weight: .light)).foregroundStyle(ScrivTheme.secondary).padding(.top, 48)
                    column("After", after: true)
                }
            }
            if let (cue, asset) = unchangedImage {
                Divider().opacity(0.45)
                HStack(spacing: 15) {
                    AssetImageView(url: store.assetURL(asset), title: "Unchanged image", cornerRadius: 8, unavailableText: "Image unavailable").frame(width: 130, height: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(cue.label.isEmpty ? "Image" : cue.label) · unchanged").font(.system(size: 14, weight: .medium))
                        Text("This image was not changed in this revision.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            Divider().opacity(0.45)
            DisclosureGroup("Technical details") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Item: \(change.id)").font(.system(size: 11, design: .monospaced))
                    Text("Before\n" + (change.before.map { historyJSON($0.data) } ?? "Not present"))
                    Text("After\n" + (change.after.map { historyJSON($0.data) } ?? "Not present"))
                }.font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(20).background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ScrivTheme.hairline))
    }
    private func column(_ title: String, after: Bool) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(after ? ScrivTheme.accent : ScrivTheme.ink)
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    Text(field.label).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(after ? field.after : field.before).font(.system(size: field.label == "Owned time" || field.label == "Coverage" ? 21 : 14, weight: field.label == "Owned time" ? .medium : .regular)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading).padding(16).background(after ? ScrivTheme.accent.opacity(0.065) : ScrivTheme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct HistorySnapshotView: View {
    let project: ScrivProject
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(project.title).font(.system(size: 20, weight: .semibold))
            Text("\(project.scenes.count) scenes · \(project.entries.count) entries · \(project.characters.count) characters · \(project.cues.count) image cues · \(project.audioClips.count) local audio clips").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(project.orderedScenes) { scene in
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text(scene.title).font(.system(size: 17, weight: .semibold)); Spacer(); Text(ScrivFormat.duration(project.durationMs(of: scene.id))).font(.system(size: 12)).foregroundStyle(.secondary) }
                    ForEach(project.entries(in: scene.id)) { entry in
                        HStack(alignment: .top, spacing: 12) {
                            Text(ScrivFormat.time(project.startMs(of: entry.id))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.kind == .direction ? "Direction" : project.character(entry.characterId)?.name ?? "Dialogue").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                Text(entry.text).font(.system(size: 15)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(ScrivFormat.duration(entry.ownedDurationMs)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(project.cues(in: scene.id)) { cue in
                        Label("\(cue.label.isEmpty ? "Image placement" : cue.label) · \(ScrivFormat.time(cue.startMs))–\(ScrivFormat.time(cue.endMs))", systemImage: "photo").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(18).background(ScrivTheme.inset.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            }
            ForEach(project.characters) { character in
                DisclosureGroup(character.name) { Text(character.biography + "\n" + character.appearance).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }.font(.system(size: 14, weight: .medium))
            }
        }
    }
}
private func historyJSON(_ value: JSONValue) -> String {
    let encoder = ScrivJSON.encoder; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let bytes = try? encoder.encode(value), let text = String(data: bytes, encoding: .utf8) else { return "Unable to decode metadata" }
    return text.count > 40_000 ? String(text.prefix(40_000)) + "\n… Preview truncated; the full revision is retained in history." : text
}
