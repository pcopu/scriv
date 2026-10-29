import SwiftUI
import AppKit
import ScrivCore

struct AccountPopover: View {
    @EnvironmentObject private var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Scriv account", systemImage: "person.crop.circle").font(.headline)
            if let account = store.account {
                HStack(spacing: 11) {
                    InitialAvatar(name: account.name, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name).font(.system(size: 13, weight: .semibold))
                        if let email = account.email { Text(email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                Divider()
                Text(store.syncStatus).font(.caption).foregroundStyle(.secondary)
                Button("Sync this script") { store.syncProject() }.buttonStyle(.borderedProminent)
                if store.hasConflicts {
                    Text("Your local draft is safe. Export a copy before opening a different cloud revision.").font(.caption).foregroundStyle(.orange)
                    Button("Retry saved cloud commands") { store.retryCloudSync() }
                }
                Button("Refresh account") { store.refreshAccount() }
                Button("Sign out") { store.signOut() }
            } else {
                Text("Single-person editing is free. Sign in for free script storage, then add a team when you are ready to collaborate.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Continue with GitHub") { store.signIn() }.buttonStyle(.borderedProminent)
                Text("ChatGPT sign-in is separate, under Codex on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
        }.padding(19).frame(width: 295).buttonStyle(.borderless)
    }
}

struct CodexToolbarButton: View {
    @ObservedObject var controller: CodexController
    @Binding var isOpen: Bool
    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 7) {
                StatusDot(color: controller.isGenerating ? .orange : controller.isConnected ? .green : .gray)
                Text("Codex · Local").font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8))
            }.padding(.vertical, 9).padding(.horizontal, 10).background(ScrivTheme.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ScrivTheme.hairline.opacity(0.4)))
        }.buttonStyle(.plain).help("Codex on this Mac: \(controller.status)")
    }
}

struct CodexPopover: View {
    @ObservedObject var controller: CodexController
    @State private var connecting = false
    @State private var busy = false
    @State private var error: String?
    @State private var showLog = false
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Codex on this Mac").font(.system(size: 15, weight: .semibold))
            VStack(spacing: 10) {
                HStack { StatusDot(color: controller.isConnected ? .green : .gray); Text(controller.status); Spacer(); if busy { ProgressView().controlSize(.mini) } }
                Divider()
                HStack {
                    Text("ChatGPT").fontWeight(.medium)
                    Spacer()
                    if let account = controller.accountLabel {
                        Text(account).lineLimit(1).foregroundStyle(.secondary)
                        Menu { Button("Refresh account") { run { try await controller.readAccount() } }; Button("Sign out of ChatGPT") { run { try await controller.signOut() } } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    } else { Button("Sign in") { run { try await controller.signIn() } }.buttonStyle(.borderless).disabled(!controller.isConnected || busy) }
                }
            }.font(.system(size: 12)).padding(11).background(ScrivTheme.inset.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 7) {
                Button("Start") { run { try await controller.start() } }.buttonStyle(.borderedProminent).disabled(busy || controller.isConnected)
                Button("Connect…") { connecting.toggle() }.buttonStyle(.bordered).disabled(busy || controller.isConnected)
                if controller.isRunning { Button("Stop") { controller.stop() }.buttonStyle(.bordered) }
                else { Button("Disconnect") { controller.disconnect() }.buttonStyle(.bordered).disabled(!controller.isConnected) }
            }.controlSize(.large)
            if connecting {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("ws://127.0.0.1:4500", text: $controller.endpoint).textFieldStyle(.roundedBorder)
                    Button("Connect to running server") { run { try await controller.connect(); connecting = false } }.buttonStyle(.borderedProminent).disabled(busy)
                }.font(.system(size: 11))
            }
            if controller.isConnected && !controller.availableModels.isEmpty {
                Picker("Model", selection: $controller.selectedModel) { ForEach(controller.availableModels, id: \.self) { Text($0).tag($0) } }.font(.system(size: 11))
            }
            if controller.isGenerating { Button("Cancel generation", role: .destructive) { Task { await controller.cancelGeneration() } }.buttonStyle(.bordered) }
            if let text = error ?? controller.lastError { Text(text).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Text(controller.isRunning ? "Scriv started this process and can stop it." : "Start here, or connect to a running local server.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !controller.log.isEmpty {
                DisclosureGroup("Generation response", isExpanded: $showLog) { ScrollView { Text(controller.log).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 170) }
            }
            SettingsLink { Label("Codex settings…", systemImage: "gearshape") }.font(.system(size: 11))
        }.padding(18).frame(width: 345)
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
}

struct ScrivSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var tab = "General"
    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().environmentObject(store).tabItem { Label("General", systemImage: "gearshape") }.tag("General")
            CloudSettings().environmentObject(store).tabItem { Label("Scriv Cloud", systemImage: "icloud") }.tag("Cloud")
            CodexSettings(controller: store.codex).tabItem { Label("Codex", systemImage: "sparkles") }.tag("Codex")
        }.padding(16).frame(width: 620, height: 440)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var store: WorkspaceStore
    var body: some View {
        Form {
            Section("Editing") {
                Toggle("Follow the active line during playback", isOn: $store.followPlayback)
                LabeledContent("Project format", value: ".scriv package with JSON, local images and history")
                LabeledContent("Script import and export", value: "Fountain and UTF-8 text")
            }
            Section("Storage") {
                if let url = store.projectURL {
                    Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Show project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Export project with images…") { store.exportProject() }
                Text("Changes are saved automatically. Export a project package to keep a separate backup or transfer it to another Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct CloudSettings: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var endpoint = ""
    var body: some View {
        Form {
            Section("Scriv server") {
                TextField("Server URL", text: $endpoint).textFieldStyle(.roundedBorder)
                Button("Save server address") { store.cloudBaseURL = endpoint }.disabled(store.account != nil)
                Text(store.account == nil ? "Use the HTTPS address of your Scriv service. Local development may use http://127.0.0.1:8787." : "Sign out before changing servers so account credentials stay scoped to their original server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Account") {
                if let account = store.account { LabeledContent("Signed in", value: account.name); Button("Sign out") { store.signOut() } }
                else { Button("Sign in to Scriv") { store.signIn() } }
                Text("Solo script storage is free. Teams are $9.99/month, with no per-seat charge. Team subscriptions include collaboration and hosted images.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).onAppear { endpoint = store.cloudBaseURL }
    }
}

private struct CodexSettings: View {
    @ObservedObject var controller: CodexController
    var body: some View {
        Form {
            Section("Local runtime") {
                TextField("Codex executable", text: $controller.executablePath).textFieldStyle(.roundedBorder)
                Button("Choose executable…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { controller.executablePath = url.path }
                }
                TextField("External local server", text: $controller.endpoint).textFieldStyle(.roundedBorder)
                Text("Scriv starts codex app-server over a private pipe. External connections are limited to this Mac. Codex keeps its own ChatGPT authentication.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Generation") {
                Text("Image generation depends on the installed Codex runtime and the account's available tools. A missing capability returns an error and preserves the existing storyboard image.").font(.caption).foregroundStyle(.secondary)
                if !controller.availableModels.isEmpty {
                    Picker("Model", selection: $controller.selectedModel) { ForEach(controller.availableModels, id: \.self) { Text($0).tag($0) } }
                }
                LabeledContent("Runtime", value: controller.status)
            }
        }.formStyle(.grouped)
    }
}
