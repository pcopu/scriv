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
                Text(store.peerTransferStatus).font(.caption).foregroundStyle(.secondary)
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
                ScrivEmailSignInForm(cloud:store.cloud)
                Text("ChatGPT sign-in is separate, under Codex on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            SettingsLink { Label("Settings…", systemImage: "gearshape") }
        }.padding(19).frame(width: 330).buttonStyle(.borderless)
    }
}

/// Shared by the account popover, settings and team sign-in. The only persisted
/// credential is the completed server session in the origin-scoped Keychain.
struct ScrivEmailSignInForm: View {
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject var cloud: CloudClient
    @State private var email = ""
    @State private var code = ""
    @State private var operationTask: Task<Void,Never>?
    @State private var operationID: UUID?
    @State private var browserError: String?
    @State private var ownerID = UUID()
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case email, code }
    private var busy: Bool { cloud.emailSignIn.isBusy || operationID != nil }
    private var ownedElsewhere: Bool { cloud.signInOwnerID != nil && cloud.signInOwnerID != ownerID }

    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { timeline in
            let flow = cloud.emailSignIn
            VStack(alignment:.leading,spacing:10) {
                if ownedElsewhere {
                    Text("Sign-in is open in another Scriv window.").font(.callout).foregroundStyle(.secondary)
                    Button("Start sign-in here") { cloud.cancelSignIn(); email = ""; code = ""; focusedField = .email }
                } else if flow.challengeID != nil {
                    Text("Check your email").font(.headline)
                    Text("Enter the six-digit code sent to \(flow.email).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    TextField("Six-digit code",text:$code)
                        .textFieldStyle(.roundedBorder).textContentType(.oneTimeCode)
                        .font(.system(.body,design:.monospaced)).focused($focusedField,equals:.code)
                        .disabled(busy || flow.isExpired(at:timeline.date))
                        .accessibilityLabel("Email sign-in code")
                        .onChange(of:code) { _, value in
                            let clean = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                            if clean != value { code = clean }
                        }
                        .onSubmit { verifyCode() }
                    Button(action:verifyCode) {
                        HStack(spacing:7) {
                            if flow.phase == .verifying { ProgressView().controlSize(.mini) }
                            Text(flow.phase == .verifying ? "Signing in…" : "Sign in with code")
                        }
                    }.buttonStyle(.borderedProminent)
                        .disabled(busy || (try? EmailSignInFlow.normalizedCode(code)) == nil || flow.isExpired(at:timeline.date))
                    Text(flow.isExpired(at:timeline.date) ? "This code has expired. Request a new one below." : "Expires in \(countdown(flow.expirySeconds(at:timeline.date))) · Check spam if needed.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    HStack(spacing:12) {
                        Button(flow.resendSeconds(at:timeline.date) > 0 ? "Resend in \(flow.resendSeconds(at:timeline.date))s" : "Resend code") { requestCode() }
                            .disabled(busy || !flow.canResend(at:timeline.date))
                        Button("Use another email") { cancel(); focusedField = .email }
                    }.font(.caption)
                } else {
                    TextField("Email address",text:$email)
                        .textFieldStyle(.roundedBorder).textContentType(.emailAddress)
                        .focused($focusedField,equals:.email).accessibilityLabel("Scriv account email address")
                        .disabled(busy || !flow.email.isEmpty)
                        .onChange(of:email) { _, value in if value.utf8.count > 254 { email = String(value.prefix(254)) } }
                        .onSubmit { requestCode() }
                    HStack(spacing:12) {
                        Button(action:requestCode) {
                            HStack(spacing:7) {
                                if flow.phase == .requesting { ProgressView().controlSize(.mini) }
                                Text(flow.phase == .requesting ? "Sending code…" : flow.resendSeconds(at:timeline.date) > 0 ? "Try again in \(flow.resendSeconds(at:timeline.date))s" : "Continue with email")
                            }
                        }.buttonStyle(.borderedProminent)
                            .disabled(busy || flow.resendSeconds(at:timeline.date) > 0 || (try? EmailSignInFlow.normalizedEmail(email)) == nil)
                        if busy || !flow.email.isEmpty { Button("Cancel") { cancel(); focusedField = .email } }
                    }
                    Text("We'll email you a one-time sign-in code. No password required.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                if !ownedElsewhere, let error = browserError ?? flow.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                        .accessibilityLabel("Sign-in error: \(error)")
                }
                if !ownedElsewhere, flow.challengeID != nil { Button("Cancel sign-in") { cancel(); focusedField = .email }.font(.caption) }
                if !ownedElsewhere, flow.phase == .idle, flow.email.isEmpty {
                    Button("Existing GitHub account…") { signInWithGitHub() }
                        .font(.caption).disabled(busy).help("For Scriv accounts previously created with GitHub.")
                }
            }.font(.system(size:12))
        }
        .onAppear { email = cloud.emailSignIn.email }
        .onDisappear {
            // Account publication removes this form before account/team refresh
            // finishes. Do not cancel that successful session's refresh request.
            if cloud.account == nil { cancel() }
            code = ""; email = ""
        }
        .onChange(of:store.cloudBaseURL) { _, _ in cancel(); email = "" }
        .onChange(of:store.navigationContext) { _, _ in cancel() }
        .onChange(of:cloud.emailSignIn.challengeID) { _, _ in code = "" }
        .onChange(of:cloud.signInOwnerID) { _, next in if next != ownerID, operationID != nil, cloud.account == nil { cancel() } }
    }
    private func countdown(_ seconds: Int) -> String { "\(seconds / 60):" + String(format:"%02d",seconds % 60) }
    private func requestCode() {
        guard !busy, (try? EmailSignInFlow.normalizedEmail(email)) != nil, cloud.emailSignIn.resendSeconds(at:Date()) == 0 else { return }
        let address = email; code = ""; browserError = nil
        let id = UUID(); operationID = id
        operationTask = Task {
            await store.requestEmailCode(address,ownerID:ownerID)
            guard operationID == id else { return }
            operationID = nil; operationTask = nil
            if cloud.emailSignIn.challengeID != nil { focusedField = .code }
        }
    }
    private func verifyCode() {
        guard !busy, (try? EmailSignInFlow.normalizedCode(code)) != nil, !cloud.emailSignIn.isExpired(at:Date()) else { return }
        let enteredCode = code, id = UUID(); operationID = id; browserError = nil
        operationTask = Task {
            await store.verifyEmailCode(enteredCode,ownerID:ownerID)
            guard operationID == id else { return }
            operationID = nil; operationTask = nil; code = ""
            if cloud.account == nil { focusedField = .code }
        }
    }
    private func signInWithGitHub() {
        guard !busy else { return }
        let id = UUID(); operationID = id; browserError = nil
        operationTask = Task {
            do { try await store.signInWithGitHub(ownerID:ownerID) }
            catch is CancellationError { }
            catch { if operationID == id { browserError = error.localizedDescription } }
            guard operationID == id else { return }
            operationID = nil; operationTask = nil
        }
    }
    private func cancel() {
        operationID = nil; operationTask?.cancel(); operationTask = nil
        cloud.cancelSignIn(ownerID:ownerID); code = ""; browserError = nil
    }
}

struct ScrivSignInSheet: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Label("Sign in to Scriv",systemImage:"person.crop.circle").font(.title2.weight(.semibold)); Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Keep writing locally, or sign in for free script storage and team access.").font(.callout).foregroundStyle(.secondary)
            ScrivEmailSignInForm(cloud:store.cloud)
            Text("Codex and ChatGPT sign-in stay separate on this Mac.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width:420)
            .onChange(of:store.account?.id) { _, id in if id != nil { dismiss() } }
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

struct GenerationJobsSheet: View {
    @ObservedObject var controller: CodexController
    @Environment(\.dismiss) private var dismiss
    @State private var retrying: LocalGenerationJob?
    @State private var error: String?
    @State private var source = "This Mac"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("Generation jobs on this Mac", systemImage: "sparkles.rectangle.stack").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Jobs survive app restarts. Inspect an existing turn before retrying. Reconnecting never starts paid generation automatically.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                PillSegmentPicker(values: ["This Mac", "Shared project"], selection: $source) { $0 }
                Spacer()
                if source == "Shared project" { Button("Refresh") { controller.onRefreshSharedJobs?() } }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let issue = controller.journalError { Text(issue).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if source == "Shared project" {
                sharedJobs
            } else if controller.jobs.isEmpty {
                EmptyPanel(symbol: "sparkles", title: "No local image jobs yet", message: "Each requested generation keeps its original prompt, references and runtime identity on this Mac for safe recovery.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(controller.jobs) { job in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(job.context?.projectTitle ?? "Local image generation").font(.headline)
                                        if let context = job.context { Text("\(context.targetCue.label.isEmpty ? "Image placement" : context.targetCue.label) · source revision \(context.sourceRevision)").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Text(job.status.label).font(.caption.weight(.medium)).foregroundStyle(job.status == .failed ? Color.red : job.status == .completed ? Color.green : Color.secondary)
                                }
                                Text(job.progressText).font(.callout)
                                if let detail = job.errorDetail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled) }
                                HStack {
                                    Text(job.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                                    Text("This Mac").font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    if job.outputImageID != nil { Label("Imported", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                                    if job.artifactRelativePath != nil {
                                        Button("Reveal image") { run { NSWorkspace.shared.activateFileViewerSelecting([try controller.artifactURL(for: job.id)]) } }
                                        if controller.onRecoverJob != nil, job.outputImageID == nil || job.context?.cloudProjectID != nil {
                                            Button(job.outputImageID != nil ? "Finish shared status" : job.status == .completed ? "Use in original project" : "Use local candidate") { controller.onRecoverJob?(job) }.buttonStyle(.borderedProminent)
                                        }
                                    }
                                    if job.status != .completed {
                                        Button(controller.inspectingJobID == job.id ? "Inspecting…" : "Inspect existing turn") { run { try await controller.inspectJob(job.id) } }
                                            .disabled(controller.isGenerating || controller.inspectingJobID != nil)
                                    }
                                    if job.canRetry, controller.onRetryJob != nil {
                                        Button("Retry…") { retrying = job }.disabled(controller.isGenerating || !controller.isConnected || controller.inspectingJobID != nil)
                                    }
                                }.controlSize(.small)
                                DisclosureGroup("Original prompt (stored only on this Mac)") {
                                    Text(job.prompt).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.caption)
                            }.padding(14).background(ScrivTheme.inset.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
                        }
                    }
                }
            }
        }.padding(22).frame(width: 760, height: 590)
            .onChange(of: source) { _, value in if value == "Shared project" { controller.onRefreshSharedJobs?() } }
            .confirmationDialog("Start a new image generation?", isPresented: Binding(get: { retrying != nil }, set: { if !$0 { retrying = nil } }), presenting: retrying) { job in
                Button("Start new generation") { controller.onRetryJob?(job); retrying = nil }
                Button("Cancel", role: .cancel) { retrying = nil }
            } message: { _ in Text("This is a new request using the original prompt and reference snapshots. The old turn may still be running. It can consume additional Codex usage; inspect the original turn first.") }
    }
    private var sharedJobs: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Status only. Another collaborator cannot run work under this Mac's ChatGPT identity.").font(.caption).foregroundStyle(.secondary)
                if let message = controller.sharedJobsError { Text(message).font(.callout).foregroundStyle(.orange) }
                if controller.sharedJobs.isEmpty {
                    Text("No shared generation jobs are available for the current project. Local prompts, paths and runtime credentials are never uploaded.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                }
                ForEach(controller.sharedJobs) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(job.ownerDeviceName).font(.headline); Spacer(); Text(job.status == .running ? "Running on owning Mac" : job.status == .queued ? "Queued" : job.status.label).font(.caption.weight(.medium)) }
                        Text(job.progressText).font(.callout)
                        HStack {
                            Text("Source revision \(job.sourceRevision)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Date(timeIntervalSince1970: Double(job.updatedAt) / 1000), style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        if job.status == .waiting { Text("Waiting for its owning Mac. Refresh after that Mac reconnects.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(14).background(ScrivTheme.inset.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil; Task { do { try await action() } catch { self.error = error.localizedDescription } }
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
                else { ScrivEmailSignInForm(cloud:store.cloud) }
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
