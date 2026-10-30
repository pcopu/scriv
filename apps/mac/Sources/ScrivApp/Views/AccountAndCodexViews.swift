import SwiftUI
import AppKit
import ScrivCore

/// Signed-in status follows the approved sync-recovery popover. Signed-out
/// entry points open the focused ScrivSignInSheet instead of nesting a form here.
struct AccountPopover: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Scriv account").font(.system(size: 22, weight: .semibold))
            if let account = store.account {
                HStack(spacing: 14) {
                    InitialAvatar(name: account.name, size: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.name).font(.system(size: 16, weight: .semibold))
                        Text(account.email ?? "Signed in").font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 13) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Current project").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(store.project.title).font(.system(size: 15, weight: .medium))
                    }
                    Label { Text(store.syncStatus).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: store.hasConflicts ? "exclamationmark.circle" : "arrow.triangle.2.circlepath")
                    }
                    Label { Text(store.peerTransferStatus).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "laptopcomputer")
                    }.foregroundStyle(.secondary)
                }.font(.system(size: 13))
                if store.hasConflicts {
                    VStack(alignment: .leading, spacing: 11) {
                        Label("Sync needs attention", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
                        Text("Your local draft is safe. Export a copy before opening a different cloud revision.")
                            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Button("Export safety copy…") { store.exportProject() }
                            .buttonStyle(AccountPrimaryButtonStyle())
                        Button("Retry saved cloud commands") { store.retryCloudSync() }
                            .buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
                        Text("Review before switching revisions.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.085), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.22)))
                } else {
                    Button("Sync this script") { store.syncProject() }.buttonStyle(AccountPrimaryButtonStyle())
                }
                Divider()
                VStack(alignment: .leading, spacing: 17) {
                    Button { store.refreshAccount() } label: { Label("Refresh account", systemImage: "arrow.clockwise") }
                    Button { store.signOut(); dismiss() } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                    SettingsLink { Label("Settings…", systemImage: "gearshape") }
                }.font(.system(size: 14)).buttonStyle(.borderless)
            } else {
                Text("Local editing is free. Sign in for script storage and team access.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Sign in to Scriv") { dismiss(); store.signIn() }.buttonStyle(AccountPrimaryButtonStyle())
            }
            Divider()
            Text("ChatGPT sign-in is separate, under Codex on this Mac.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(23).frame(width: 420).background(ScrivTheme.panel)
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
    @State private var showJobs = false
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
                        Menu { Button("Refresh account") { run { try await controller.readAccount() } }; Button("Sign out of ChatGPT") { run { try await controller.signOut() } }.disabled(controller.isGenerating) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    } else if controller.pendingLoginID != nil {
                        Button("Cancel sign-in") { run { try await controller.cancelSignIn() } }.buttonStyle(.borderless).disabled(busy)
                    } else { Button("Sign in") { run { try await controller.signIn() } }.buttonStyle(.borderless).disabled(!controller.isConnected || controller.isGenerating || busy) }
                }
            }.font(.system(size: 12)).padding(11).background(ScrivTheme.inset.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 7) {
                Button("Start") { run { try await controller.start() } }.buttonStyle(.borderedProminent).disabled(busy || controller.isConnecting || controller.isConnected)
                Button("Connect…") { connecting.toggle() }.buttonStyle(.bordered).disabled(busy || controller.isConnecting || controller.isConnected)
                if controller.isRunning { Button("Stop") { controller.stop() }.buttonStyle(.bordered) }
                else { Button("Disconnect") { controller.disconnect() }.buttonStyle(.bordered).disabled(controller.isGenerating || (busy && !controller.isConnecting) || (!controller.isConnected && !controller.isConnecting)).help(controller.isGenerating ? "Cancel generation before disconnecting from the external runtime." : "Leave the external runtime running.") }
            }.controlSize(.large)
            if connecting {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("ws://127.0.0.1:4500", text: $controller.endpoint).textFieldStyle(.roundedBorder)
                    Button("Connect to running server") { run { try await controller.connect(); connecting = false } }.buttonStyle(.borderedProminent).disabled(busy)
                }.font(.system(size: 11))
            }
            if controller.isConnected && !controller.availableModels.isEmpty {
                Picker("Model", selection: $controller.selectedModel) { ForEach(controller.availableModels, id: \.self) { Text($0).tag($0) } }.font(.system(size: 11)).disabled(controller.isGenerating)
            }
            if controller.isGenerating { Button("Cancel generation", role: .destructive) { run { await controller.cancelGeneration() } }.buttonStyle(.bordered).disabled(busy) }
            if let text = error ?? controller.lastError { Text(text).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Text(controller.isRunning ? "Scriv started this process and can stop it." : controller.isConnected ? "Connected to an external local server. Disconnect leaves it running." : "Start here, or connect to a running local server.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !controller.log.isEmpty {
                DisclosureGroup("Generation response", isExpanded: $showLog) { ScrollView { Text(controller.log).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 170) }
            }
            Button { showJobs = true } label: { Label("Generation jobs (\(controller.jobs.count))", systemImage: "clock.arrow.circlepath") }
                .buttonStyle(.borderless)
            if let journalError = controller.journalError { Text(journalError).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            SettingsLink { Label("Codex settings…", systemImage: "gearshape") }.font(.system(size: 11))
        }.padding(18).frame(width: 345)
            .sheet(isPresented: $showJobs) { GenerationJobsSheet(controller: controller) }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
}
