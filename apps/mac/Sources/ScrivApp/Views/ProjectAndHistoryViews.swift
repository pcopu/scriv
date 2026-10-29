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

struct HistorySheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = "This Mac"
    @State private var localRestore: HistoryEntry?
    @State private var cloudRestore: CloudEvent?
    @State private var confirming = false
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("History", systemImage: "clock.arrow.circlepath").font(.system(size: 24, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Restore an earlier state as a new revision. Discussion, team membership and billing keep their current state.")
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
                            historyRow(title: event.label, detail: "Revision \(event.revision)", date: event.date, current: event.revision == store.project.revision) {
                                localRestore = event; cloudRestore = nil; confirming = true
                            }
                        }
                    } else {
                        if store.cloudHistory.isEmpty { empty(store.project.cloudProjectId == nil ? "Save this project to the cloud to keep shared history." : "No cloud changes have been recorded yet.") }
                        ForEach(store.cloudHistory) { event in
                            historyRow(title: event.label, detail: "Change \(event.seq) · \(event.kind)", date: Date(timeIntervalSince1970: Double(event.at) / 1000), current: false) {
                                cloudRestore = event; localRestore = nil; confirming = true
                            }
                        }
                    }
                }
            }.background(ScrivTheme.inset.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }.padding(24).frame(width: 660, height: 590)
            .confirmationDialog("Restore this revision?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Restore") {
                    if let localRestore { store.restoreHistory(localRestore) }
                    if let cloudRestore { store.restoreCloudHistory(cloudRestore) }
                }
            } message: { Text("The current state stays in history. A cloud restore also ends active editing leases so collaborators reload the restored revision.") }
            .onChange(of: source) { _, value in if value == "Cloud" { refresh() } }
    }
    private func empty(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(40) }
    private func historyRow(title: String, detail: String, date: Date, current: Bool, restore: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 3) { Circle().fill(current ? ScrivTheme.accent : ScrivTheme.secondary.opacity(0.4)).frame(width: 8, height: 8); Rectangle().fill(ScrivTheme.hairline).frame(width: 1).frame(maxHeight: .infinity) }.frame(width: 12)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(date, format: .dateTime.month().day().year().hour().minute()).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if current { Text("Current").font(.system(size: 10, weight: .medium)).foregroundStyle(ScrivTheme.accent) }
            else { Button("Restore", action: restore).controlSize(.small) }
        }.padding(14).frame(minHeight: 82)
    }
    private func refresh() {
        guard store.project.cloudProjectId != nil else { return }
        loading = true
        Task { defer { loading = false }; do { store.cloudHistory = try await store.cloud.history() } catch { store.errorMessage = error.localizedDescription } }
    }
}
