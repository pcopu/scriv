import SwiftUI
import AppKit
import ScrivCore

/// The approved single-page settings layout. Advanced connection fields are
/// disclosed separately; Scriv identity never stands in for local ChatGPT auth.
struct ScrivSettingsView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var serverExpanded = false
    @State private var endpoint = ""
    @State private var signInOpen = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 24).padding(.vertical, 17)
                .background(ScrivTheme.chrome.opacity(0.35))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    generalSection
                    accountSection
                    CodexSettingsSection(controller: store.codex)
                }.padding(24)
            }
        }.frame(width: 620, height: 760).background(ScrivTheme.panel)
            .onAppear { endpoint = store.cloudBaseURL }
            .onChange(of: store.cloudBaseURL) { _, value in endpoint = value }
            .sheet(isPresented: $signInOpen) { ScrivSignInSheet().environmentObject(store) }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("General")
            VStack(spacing: 0) {
                Toggle("Follow active line during playback", isOn: $store.followPlayback)
                    .toggleStyle(.switch).controlSize(.small).padding(14)
                Divider().padding(.horizontal, 14)
                HStack(spacing: 12) {
                    Text("Local project package")
                    Spacer(minLength: 10)
                    Button("Show in Finder") {
                        if let url = store.projectURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }.buttonStyle(.borderless).disabled(store.projectURL == nil)
                    Button("Export project…") { store.exportProject() }.buttonStyle(.bordered)
                }.padding(14)
            }.accountSettingsCard()
            Text("Changes save automatically.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Scriv account")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 13) {
                    InitialAvatar(name: store.account?.name ?? "S", size: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.account?.name ?? "Write locally, or sign in").fontWeight(.semibold)
                        Text(store.account == nil ? "Free script storage and team access" : "Signed in")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if store.account != nil {
                        Button("Sign out") { store.signOut() }.buttonStyle(.bordered)
                    } else {
                        Button("Sign in") { signInOpen = true }.buttonStyle(.borderedProminent)
                    }
                }.padding(14)
                Divider().padding(.horizontal, 14)
                DisclosureGroup("Server settings", isExpanded: $serverExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Server URL", text: $endpoint).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Scriv server URL").disabled(store.account != nil)
                        HStack {
                            Text("Use the HTTPS address of your Scriv service.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Save address") { store.cloudBaseURL = endpoint }
                                .buttonStyle(.bordered).disabled(store.account != nil || endpoint == store.cloudBaseURL)
                        }
                    }.padding(.top, 12)
                }.padding(14)
            }.accountSettingsCard()
            Text("Sign out before changing servers.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 17, weight: .semibold))
    }
}

private struct CodexSettingsSection: View {
    @ObservedObject var controller: CodexController
    @State private var advancedExpanded = true
    @State private var jobsOpen = false
    @State private var busy = false
    @State private var error: String?
    private var statusColor: Color { controller.isGenerating ? .orange : controller.isConnected ? .green : .secondary }
    private var runtimeStatus: String {
        if controller.isGenerating || controller.isConnecting || controller.pendingLoginID != nil { return controller.status }
        if controller.isConnected { return controller.isRunning ? "Connected · started by Scriv" : "Connected · external server" }
        return controller.status
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Codex on this Mac").font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    StatusDot(color: statusColor)
                    Text(runtimeStatus).foregroundStyle(statusColor).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }.padding(14)
                Divider().padding(.horizontal, 14)
                chatGPTAccount.padding(14)
                Divider().padding(.horizontal, 14)
                HStack(spacing: 16) {
                    Text("Selected model")
                    Spacer(minLength: 8)
                    Picker("Selected model", selection: $controller.selectedModel) {
                        if controller.availableModels.isEmpty { Text("Choose available model").tag("") }
                        ForEach(controller.availableModels, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().frame(maxWidth: 300)
                        .disabled(busy || controller.isGenerating || controller.availableModels.isEmpty)
                        .accessibilityLabel("Selected Codex model")
                }.padding(14)
                HStack(spacing: 8) {
                    Button("Start") { run { try await controller.start() } }
                        .frame(maxWidth: .infinity).disabled(busy || controller.isConnecting || controller.isConnected)
                    Button("Connect") { run { try await controller.connect() } }
                        .frame(maxWidth: .infinity).disabled(busy || controller.isConnecting || controller.isConnected)
                    if controller.isRunning {
                        Button("Stop") { controller.stop() }.frame(maxWidth: .infinity)
                            .help("Stop the local Codex process Scriv started.")
                    } else {
                        Button("Disconnect") { controller.disconnect() }.frame(maxWidth: .infinity)
                            .disabled(controller.isGenerating || (busy && !controller.isConnecting) || (!controller.isConnected && !controller.isConnecting))
                            .help(controller.isGenerating ? "Cancel generation before disconnecting." : "Leave the external runtime running.")
                    }
                }.buttonStyle(.bordered).controlSize(.large).padding(.horizontal, 14).padding(.bottom, 14)
                if controller.isGenerating {
                    Button("Cancel generation", role: .destructive) { run { await controller.cancelGeneration() } }
                        .buttonStyle(.bordered).disabled(busy).padding(.horizontal, 14).padding(.bottom, 14)
                }
                Divider().padding(.horizontal, 14)
                DisclosureGroup("Advanced connection", isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Text("Codex executable").frame(width: 126, alignment: .leading)
                            TextField("Codex executable", text: $controller.executablePath).labelsHidden().textFieldStyle(.roundedBorder)
                            Button("Choose…", action: chooseExecutable).buttonStyle(.bordered)
                        }
                        HStack(spacing: 10) {
                            Text("External local server").frame(width: 126, alignment: .leading)
                            TextField("ws://127.0.0.1:4500", text: $controller.endpoint).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("External local Codex server")
                        }
                        Text("Connection settings apply the next time you start or connect. External connections are limited to this Mac.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 13).disabled(busy || controller.isConnecting || controller.isConnected)
                }.padding(14)
            }.accountSettingsCard()
            Text("Credentials stay on this Mac. Disconnecting an external server leaves it running.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            if let message = error ?? controller.lastError { AccountInlineMessage(text: message, color: .red) }
            if let message = controller.journalError { AccountInlineMessage(text: message) }
            Button { jobsOpen = true } label: { Label("Generation jobs (\(controller.jobs.count))", systemImage: "clock.arrow.circlepath") }
                .buttonStyle(.borderless)
        }.font(.system(size: 13))
            .sheet(isPresented: $jobsOpen) { GenerationJobsSheet(controller: controller) }
    }
    private var chatGPTAccount: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 21)).foregroundStyle(.white)
                .frame(width: 38, height: 38).background(Color(red: 0.10, green: 0.65, blue: 0.51), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("ChatGPT").fontWeight(.semibold)
                Text(controller.pendingLoginID != nil ? "Complete sign-in in your browser" : controller.accountLabel != nil ? "Signed in on this Mac" : "Not signed in")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if controller.accountLabel != nil {
                Menu("Manage…") {
                    if let account = controller.accountLabel { Text(account) }
                    Button("Refresh account") { run { try await controller.readAccount() } }
                    Button("Sign out of ChatGPT") { run { try await controller.signOut() } }
                }.fixedSize().disabled(busy || controller.isGenerating)
            } else if controller.pendingLoginID != nil {
                Button("Cancel sign-in") { run { try await controller.cancelSignIn() } }.buttonStyle(.bordered).disabled(busy)
            } else {
                Button("Sign in") { run { try await controller.signIn() } }
                    .buttonStyle(.bordered).disabled(busy || !controller.isConnected || controller.isGenerating)
            }
        }
    }
    private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { controller.executablePath = url.path }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

private extension View {
    func accountSettingsCard() -> some View {
        self.font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            .background(ScrivTheme.inset.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ScrivTheme.hairline.opacity(0.65)))
    }
}
