import SwiftUI
import AppKit
import ScrivCore

struct ProjectBrowserSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Projects").font(.system(size: 25, weight: .semibold))
                Spacer()
                Button("New project", systemImage: "plus") { store.newProject(); dismiss() }.buttonStyle(.borderedProminent)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Find a project", text: $search).textFieldStyle(.roundedBorder)
            List {
                Section("On this Mac") {
                    ForEach(store.localProjects, id: \.path) { url in LocalProjectRow(url: url, search: search) { store.openLocalProject(url); dismiss() } }
                    Button { store.openProject(); dismiss() } label: { Label("Open another project…", systemImage: "folder") }
                }
                Section("Scriv Cloud") {
                    if store.account == nil {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Sign in to access your scripts and team projects.").foregroundStyle(.secondary)
                            Button("Sign in to Scriv") { store.signIn() }.buttonStyle(.bordered)
                        }.padding(.vertical, 8)
                    }
                    ForEach(store.cloudProjects.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { project in
                        Button {
                            store.openCloudProject(project); dismiss()
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: project.teamId == nil ? "icloud" : "person.2").font(.system(size: 20, weight: .light)).foregroundStyle(ScrivTheme.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.title).font(.system(size: 13, weight: .medium))
                                    Text(project.teamId.flatMap { id in store.teams.first { $0.id == id }?.name } ?? "Private script")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }
                    if store.account != nil && store.cloudProjects.isEmpty { Text("Save a script to the cloud to see it here.").foregroundStyle(.secondary).padding(.vertical, 8) }
                }
            }.listStyle(.inset(alternatesRowBackgrounds: false))
            HStack {
                Button("Import Fountain or text…") { store.importScript(); dismiss() }
                Spacer()
                if store.account != nil { Button("Refresh cloud") { store.refreshAccount() } }
            }
        }.padding(24).frame(width: 670, height: 590)
            .onAppear { store.refreshLocalProjects(); if store.account != nil { store.refreshAccount() } }
    }
}

private struct LocalProjectRow: View {
    let url: URL
    let search: String
    var action: () -> Void
    @State private var title = ""
    @State private var modified: Date?
    var body: some View {
        Group {
            if search.isEmpty || title.localizedCaseInsensitiveContains(search) {
                Button(action: action) {
                    HStack(spacing: 11) {
                        Image(systemName: "doc.text").font(.system(size: 22, weight: .light)).foregroundStyle(ScrivTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title.isEmpty ? url.deletingPathExtension().lastPathComponent : title).font(.system(size: 13, weight: .medium))
                            if let modified { Text(modified, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.padding(.vertical, 5)
                }.buttonStyle(.plain)
            }
        }.task(id: url) {
            let value = await Task.detached(priority: .utility) { () -> ScrivProject? in
                let file = url.appendingPathComponent("project.json")
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 * 1024,
                      let bytes = try? Data(contentsOf: file) else { return nil }
                return try? ScrivJSON.decoder.decode(ScrivProject.self, from: bytes)
            }.value
            title = value?.title ?? url.deletingPathExtension().lastPathComponent; modified = value?.modifiedAt
        }
    }
}

private enum HistorySelection: Identifiable {
    case local(HistoryEntry), cloud(CloudEvent)
    var id: String { switch self { case .local(let event): return "local:" + event.id; case .cloud(let event): return "cloud:\(event.seq)" } }
    var title: String { switch self { case .local(let event): return event.label; case .cloud(let event): return event.label } }
}

struct HistorySheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = "This Mac"
    @State private var inspection: HistorySelection?
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("History", systemImage: "clock.arrow.circlepath").font(.system(size: 24, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Inspect authors, affected items and before/after content. Preview a read-only revision before restoring it as a new change.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                PillSegmentPicker(values: ["This Mac", "Cloud"], selection: $source) { $0 }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                if source == "Cloud" { Button("Refresh", systemImage: "arrow.clockwise") { refresh() }.disabled(store.project.cloudProjectId == nil || loading) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if source == "This Mac" {
                        if store.history.isEmpty { empty("Local history begins with your first saved change.") }
                        ForEach(store.history) { event in
                            historyRow(title:event.label,detail:"Revision \(event.revision) · This Mac",date:event.date,current:event.revision == store.project.revision) { inspection = .local(event) }
                        }
                    } else {
                        if store.cloudHistory.isEmpty { empty(store.project.cloudProjectId == nil ? "Save this project to the cloud to keep shared history." : "No cloud changes have been recorded yet.") }
                        ForEach(store.cloudHistory) { event in
                            historyRow(title:event.label,detail:"Change \(event.seq) · \(author(event.actorId)) · \(event.kind)",date:Date(timeIntervalSince1970:Double(event.at)/1000),current:event.seq == store.cloud.headSeq) { inspection = .cloud(event) }
                        }
                    }
                }
            }.background(ScrivTheme.inset.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }.padding(24).frame(width: 700, height: 600)
            .sheet(item:$inspection) { selection in HistoryInspector(selection:selection).environmentObject(store) }
            .onChange(of:source) { _, value in if value == "Cloud" { refresh() } }
    }
    private func author(_ id: String) -> String { store.discussionMembers.first { $0.id == id }?.name ?? (id == store.account?.id ? "You" : id) }
    private func empty(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.center).padding(40) }
    private func historyRow(title: String, detail: String, date: Date, current: Bool, inspect: @escaping () -> Void) -> some View {
        HStack(alignment:.top,spacing:13) {
            Circle().fill(current ? ScrivTheme.accent : ScrivTheme.secondary.opacity(0.4)).frame(width:8,height:8).padding(.top,5)
            VStack(alignment:.leading,spacing:5) {
                Text(title).font(.system(size:13,weight:.medium))
                Text(detail).font(.system(size:10)).foregroundStyle(.secondary).textSelection(.enabled)
                Text(date,format:.dateTime.month().day().year().hour().minute()).font(.system(size:10)).foregroundStyle(.secondary)
            }
            Spacer()
            if current { Text("Current").font(.system(size:10,weight:.medium)).foregroundStyle(ScrivTheme.accent) }
            Button("Inspect",action:inspect).controlSize(.small)
        }.padding(14).frame(minHeight:82)
    }
    private func refresh() {
        guard store.project.cloudProjectId != nil else { return }
        loading = true
        Task {
            defer { loading = false }
            do { try await store.refreshDiscussionActivity() }
            catch is CancellationError { }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}

private struct HistoryInspector: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let selection: HistorySelection
    @State private var preview: ScrivProject?
    @State private var loading = false
    @State private var error: String?
    @State private var tab = "Changes"
    @State private var confirming = false
    private var cloudEvent: CloudEvent? { if case .cloud(let event) = selection { return event }; return nil }
    private var canRestore: Bool {
        guard preview != nil else { return false }
        switch selection {
        case .local(let event): return event.revision != store.project.revision
        case .cloud(let event): return !event.kind.hasPrefix("discussion.") && event.seq != store.cloud.headSeq
        }
    }
    private var changes: [CloudChange] {
        if let event = cloudEvent { return event.changes }
        guard case .local(let event) = selection else { return [] }
        let before = store.history.filter { $0.revision < event.revision }.max { $0.revision < $1.revision }?.snapshot ?? ScrivProject(id:event.snapshot.id)
        guard let old = try? CloudCodec.items(from:before), let new = try? CloudCodec.items(from:event.snapshot) else { return [] }
        let oldByID = Dictionary(uniqueKeysWithValues:old.map { ($0.id,$0) }), newByID = Dictionary(uniqueKeysWithValues:new.map { ($0.id,$0) })
        return Set(oldByID.keys).union(newByID.keys).sorted().compactMap { id in
            guard oldByID[id]?.data != newByID[id]?.data else { return nil }
            return CloudChange(id:id,before:oldByID[id],after:newByID[id])
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    Text(selection.title).font(.title2.weight(.semibold))
                    if let event = cloudEvent {
                        Text("By \(store.discussionMembers.first { $0.id == event.actorId }?.name ?? event.actorId) · change \(event.seq) · epoch \(event.epoch)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else { Text("Local package revision · This Mac").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            PillSegmentPicker(values:["Changes","Revision preview"],selection:$tab) { $0 }
            if loading { ProgressView("Loading read-only revision…").controlSize(.small) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if tab == "Changes" { changesView }
                    else if let preview { snapshotView(preview) }
                    else if !loading { Text("No script snapshot is available for this event.").foregroundStyle(.secondary) }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(14)
            }.background(ScrivTheme.inset.opacity(0.4),in:RoundedRectangle(cornerRadius:10))
            HStack {
                Text("Read-only preview. Restoring never rewinds discussion, membership or billing.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore this revision…") { confirming = true }.buttonStyle(.borderedProminent).disabled(!canRestore || loading)
            }
        }.padding(24).frame(width:820,height:650)
            .task(id:selection.id) { await loadPreview() }
            .confirmationDialog("Restore the previewed revision?",isPresented:$confirming,titleVisibility:.visible) {
                Button("Restore as a new revision") {
                    switch selection { case .local(let event): store.restoreHistory(event); case .cloud(let event): store.restoreCloudHistory(event) }
                    dismiss()
                }
            } message: { Text("Your current state remains in history. A cloud restore ends editing leases. Local audio is not part of cloud history.") }
    }
    @ViewBuilder private var changesView: some View {
        if changes.isEmpty {
            if let event = cloudEvent, event.kind.hasPrefix("discussion.") { Text("Discussion activity — not a script restore point.").font(.headline) }
            else if cloudEvent?.data?["snapshotRequired"] == .bool(true) { Text("This change contains a full snapshot. Open Revision preview to inspect its complete script state.").foregroundStyle(.secondary) }
            else { Text("No cloud script-item delta. This local revision may change the project title, audio clips or other package metadata; inspect Revision preview.").foregroundStyle(.secondary) }
        }
        ForEach(changes,id:\.id) { change in
            DisclosureGroup {
                HStack(alignment:.top,spacing:14) {
                    valueColumn("Before",item:change.before)
                    valueColumn("After",item:change.after)
                }.padding(.top,8)
            } label: {
                VStack(alignment:.leading,spacing:3) {
                    Text("\(change.after?.kind ?? change.before?.kind ?? "item") · \(change.id)").font(.system(size:12,weight:.semibold)).textSelection(.enabled)
                    Text(change.after == nil || change.after?.deleted == true ? "Deleted" : change.before == nil || change.before?.deleted == true ? "Created" : "Updated").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(10).background(ScrivTheme.panel.opacity(0.6),in:RoundedRectangle(cornerRadius:8))
        }
        if let data = cloudEvent?.data {
            DisclosureGroup("Event metadata") { Text(json(data)).font(.system(size:10,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
        }
    }
    private func valueColumn(_ label: String, item: CloudItem?) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(label).font(.caption.weight(.semibold))
            Text(item.map { $0.deleted == true ? "Deleted (version \($0.version))" : json($0.data) } ?? "Not present")
                .font(.system(size:10,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
        }.frame(maxWidth:.infinity,alignment:.topLeading)
    }
    private func snapshotView(_ project: ScrivProject) -> some View {
        VStack(alignment:.leading,spacing:18) {
            Text(project.title).font(.title3.weight(.semibold))
            Text("\(project.scenes.count) scenes · \(project.entries.count) entries · \(project.characters.count) characters · \(project.cues.count) image cues · \(project.audioClips.count) local audio clips").font(.caption).foregroundStyle(.secondary)
            ForEach(project.orderedScenes) { scene in
                VStack(alignment:.leading,spacing:10) {
                    Text(scene.title).font(.headline)
                    Text(ScrivFormat.duration(project.durationMs(of:scene.id))).font(.caption).foregroundStyle(.secondary)
                    ForEach(project.entries(in:scene.id)) { entry in
                        HStack(alignment:.top,spacing:12) {
                            Text(ScrivFormat.time(project.startMs(of:entry.id))).font(.system(size:10,design:.monospaced)).frame(width:62,alignment:.leading)
                            VStack(alignment:.leading,spacing:4) {
                                Text(entry.kind == .direction ? "Direction" : project.character(entry.characterId)?.name ?? "Dialogue").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(entry.text).font(.system(size:12)).textSelection(.enabled)
                            }
                            Spacer(minLength:0)
                            Text(ScrivFormat.duration(entry.ownedDurationMs)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(project.cues(in:scene.id)) { cue in
                        Text("\(cue.label.isEmpty ? "Image cue" : cue.label) · \(ScrivFormat.time(cue.startMs))–\(ScrivFormat.time(cue.endMs)) · \(cue.imageId ?? "No image")").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.padding(12).background(ScrivTheme.panel.opacity(0.6),in:RoundedRectangle(cornerRadius:8))
            }
            ForEach(project.characters) { character in
                DisclosureGroup(character.name) { Text(character.biography + "\n" + character.appearance).font(.callout).textSelection(.enabled) }
            }
        }
    }
    private func json(_ value: JSONValue) -> String {
        let encoder = ScrivJSON.encoder; encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        guard let bytes = try? encoder.encode(value), let text = String(data:bytes,encoding:.utf8) else { return "Unable to decode metadata" }
        return text.count > 40_000 ? String(text.prefix(40_000)) + "\n… Preview truncated; the full revision is retained in history." : text
    }
    @MainActor private func loadPreview() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            switch selection {
            case .local(let event): preview = event.snapshot
            case .cloud(let event):
                guard !event.kind.hasPrefix("discussion.") else { return }
                preview = try await store.previewCloudHistory(event)
            }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
