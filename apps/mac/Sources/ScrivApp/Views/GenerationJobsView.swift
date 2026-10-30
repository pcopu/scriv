import SwiftUI
import AppKit
import ScrivCore

/// Recovery is read-first. A reconnect, selection, thumbnail load or details
/// expansion must never submit a fresh generation request.
struct GenerationJobsSheet: View {
    @ObservedObject var controller: CodexController
    @Environment(\.dismiss) private var dismiss
    @State private var retrying: LocalGenerationJob?
    @State private var error: String?
    @State private var source = "This Mac"
    @State private var selectedID: String?
    @State private var working = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Generation jobs").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 22).padding(.vertical, 16).background(ScrivTheme.chrome.opacity(0.35))
            Divider()
            VStack(spacing: 15) {
                HStack {
                    Spacer()
                    PillSegmentPicker(values: ["This Mac", "Shared project"], selection: $source) { $0 }.frame(width: 350)
                    Spacer()
                }.padding(.top, 17)
                Text("Jobs are saved on this Mac. Reconnecting never starts a new generation.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { AccountInlineMessage(text: error, color: .red) }
                if let issue = controller.journalError { AccountInlineMessage(text: issue) }
                if source == "Shared project" { sharedJobs }
                else if controller.jobs.isEmpty {
                    EmptyPanel(symbol: "sparkles.rectangle.stack", title: "No image jobs yet", message: "Generate an image from the script or storyboard. Its captured prompt and recovery information will stay on this Mac.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(controller.jobs) { job in
                                GenerationJobCard(controller: controller, job: job, selected: selectedID == job.id, working: working,
                                                  select: { selectedID = selectedID == job.id ? nil : job.id },
                                                  inspect: { run { try await controller.inspectJob(job.id) } },
                                                  reveal: { run { NSWorkspace.shared.activateFileViewerSelecting([try controller.artifactURL(for: job.id)]) } },
                                                  recover: { controller.onRecoverJob?(job) },
                                                  retry: { retrying = job },
                                                  cancel: { run { await controller.cancelGeneration() } })
                            }
                        }.padding(.vertical, 2)
                    }
                }
                footer
            }.padding(.horizontal, 20).padding(.bottom, 18)
        }.frame(width: 880, height: 720).background(ScrivTheme.panel)
            .onAppear { selectedID = controller.jobs.first(where: { $0.status == .waiting || $0.status == .failed })?.id }
            .onChange(of: source) { _, value in if value == "Shared project" { controller.onRefreshSharedJobs?() } }
            .confirmationDialog("Start a new image generation?", isPresented: Binding(get: { retrying != nil }, set: { if !$0 { retrying = nil } }), presenting: retrying) { job in
                Button("Start new generation") {
                    // Re-resolve after the confirmation. A job may have completed
                    // while the user was reading the additional-usage warning.
                    guard let current = controller.jobs.first(where: { $0.id == job.id }), current.canRetry,
                          !controller.isGenerating, controller.isConnected, controller.inspectingJobID == nil else {
                        error = "This job changed. Inspect its current status before retrying."; retrying = nil; return
                    }
                    controller.onRetryJob?(current); retrying = nil
                }
                Button("Cancel", role: .cancel) { retrying = nil }
            } message: { _ in
                Text("This starts a new request with the captured prompt and reference snapshots. The original turn may still be running. Additional Codex usage may apply; inspect the existing turn first.")
            }
    }

    private var footer: some View {
        VStack(spacing: 13) {
            Divider()
            HStack(spacing: 14) {
                Image(systemName: "person.2.fill").font(.system(size: 20)).foregroundStyle(ScrivTheme.accent)
                    .frame(width: 43, height: 43).background(ScrivTheme.accent.opacity(0.07), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shared project").font(.system(size: 13, weight: .semibold))
                    Text("View teammates’ job status. Only the owning Mac can run or recover its work.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if source == "Shared project" {
                    Button("Refresh") { controller.onRefreshSharedJobs?() }.buttonStyle(.bordered)
                        .disabled(controller.onRefreshSharedJobs == nil)
                } else {
                    Button("View shared jobs") { source = "Shared project" }.buttonStyle(.bordered)
                }
            }.padding(12).background(ScrivTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        }
    }
    private var sharedJobs: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let message = controller.sharedJobsError { AccountInlineMessage(text: message) }
                if controller.sharedJobs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.wave.2").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                        Text("No shared jobs for this project").font(.system(size: 17, weight: .semibold))
                        Text("Image prompts sync with the project. Local recovery paths and runtime credentials stay on their owning Mac.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 470)
                    }.frame(maxWidth: .infinity).padding(.vertical, 55)
                }
                ForEach(controller.sharedJobs) { job in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Label(job.ownerDeviceName, systemImage: "laptopcomputer").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text(job.status == .running ? "Running on owning Mac" : job.status == .queued ? "Queued" : job.status.label)
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        }
                        Text(job.progressText).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Text("Source revision \(job.sourceRevision)")
                            Spacer()
                            Text(Date(timeIntervalSince1970: Double(job.updatedAt) / 1000), style: .relative)
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                        if job.status == .waiting {
                            Text("Waiting for its owning Mac. Refresh after that Mac reconnects.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ScrivTheme.inset.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ScrivTheme.hairline.opacity(0.55)))
                }
            }.padding(.vertical, 2)
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true; error = nil
        Task {
            defer { working = false }
            do { try await action() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct GenerationJobCard: View {
    @ObservedObject var controller: CodexController
    let job: LocalGenerationJob
    let selected: Bool
    let working: Bool
    var select: () -> Void
    var inspect: () -> Void
    var reveal: () -> Void
    var recover: () -> Void
    var retry: () -> Void
    var cancel: () -> Void
    @State private var thumbnailURL: URL?
    private var canOperate: Bool { !working && !controller.isGenerating && controller.inspectingJobID == nil }
    private var imported: Bool { job.outputImageID != nil }
    private var needsReview: Bool { job.status == .waiting || job.status == .failed }
    private var active: Bool { controller.isGenerating && (job.status == .running || job.status == .queued) }
    private var statusColor: Color { imported || job.status == .completed ? .green : needsReview ? .orange : .secondary }
    private var statusTitle: String {
        if imported { return "Imported" }
        switch job.status {
        case .completed: return "Ready"
        case .waiting: return "Needs review"
        default: return job.status.label
        }
    }
    private var targetLabel: String {
        guard let context = job.context else { return "Local image generation" }
        return context.projectTitle + " · " + (context.targetCue.label.isEmpty ? "Image placement" : context.targetCue.label)
    }
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            thumbnail
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(targetLabel).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            if active { ProgressView().controlSize(.mini) }
                            else { StatusDot(color: statusColor) }
                            Text(statusTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(statusColor)
                        }
                    }
                    Spacer(minLength: 4)
                    Button(selected ? "Hide details" : "View details", action: select).buttonStyle(.borderless).font(.system(size: 12))
                }
                if !imported || selected {
                    Text(job.progressText).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 5) {
                    if let context = job.context { Text("Source revision \(context.sourceRevision) ·") }
                    Text("This Mac")
                    Text("·")
                    Text(job.createdAt, format: .dateTime.month().day().hour().minute())
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                if selected {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(job.submittedPrompt == nil ? "Original brief · full submission unknown" : "Captured prompt")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(ScrivTheme.accent)
                        Text(job.submittedPrompt ?? job.prompt).font(.system(size: 12)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ScrivTheme.accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
                    if let detail = job.errorDetail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !imported || selected { actions }
                if selected && job.canRetry {
                    Label("Retry asks for confirmation and starts a new request. Additional usage may apply.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(15)
            .background(selected ? ScrivTheme.accent.opacity(0.055) : ScrivTheme.inset.opacity(0.18), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? ScrivTheme.accent.opacity(0.8) : ScrivTheme.hairline.opacity(0.6), lineWidth: selected ? 1.3 : 1))
            .task(id: job.artifactSha256) {
                // Read an already-existing validated artifact only; no generation
                // or turn inspection is triggered by displaying a thumbnail.
                thumbnailURL = job.artifactRelativePath == nil ? nil : try? controller.artifactURL(for: job.id)
            }
    }
    private var thumbnail: some View {
        Group {
            if let thumbnailURL {
                AssetImageView(url: thumbnailURL, title: "Generated image")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: active ? "sparkles" : "photo").font(.system(size: 26, weight: .light))
                    Text(active ? "Generating" : "No local image").font(.system(size: 10)).multilineTextAlignment(.center)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ScrivTheme.inset)
            }
        }.frame(width: 128, height: selected ? 146 : 88).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons }
            VStack(alignment: .leading, spacing: 8) { actionButtons }
        }.controlSize(.regular).padding(.top, 2)
    }
    @ViewBuilder private var actionButtons: some View {
        if job.artifactRelativePath != nil {
            Button("Reveal image", action: reveal).buttonStyle(.bordered).disabled(working)
            if controller.onRecoverJob != nil, !imported || job.context?.cloudProjectID != nil {
                Button(imported ? "Finish shared status" : job.status == .completed ? "Use in original project" : "Use local candidate", action: recover)
                    .buttonStyle(.borderedProminent).disabled(!canOperate)
            }
        }
        if job.status != .completed && !active {
            Button(controller.inspectingJobID == job.id ? "Inspecting…" : "Inspect existing turn", action: inspect)
                .buttonStyle(.borderedProminent).disabled(!canOperate)
        }
        if job.canRetry, controller.onRetryJob != nil {
            Button("Retry…", action: retry).buttonStyle(.bordered).disabled(!canOperate || !controller.isConnected)
        }
        if active {
            Button("Cancel generation", role: .destructive, action: cancel).buttonStyle(.bordered).disabled(working)
        }
    }
}
