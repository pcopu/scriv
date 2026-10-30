import UIKit
import Combine
import ScrivCore

@MainActor
final class ScrivGenerationJobsController: ScrivScreenController {
    private let content = AccountUI.stack(spacing: 13)
    private let jobsContent = AccountUI.stack(spacing: 12)
    private let source = UISegmentedControl(items: ["This Mac", "Shared project"])
    private let errorLabel = AccountUI.label("", size: 13, color: .systemRed)
    private var working = false
    private var selectedID: String?
    private var thumbnailCache: [String: UIImage] = [:]
    private var lastSnapshot = ""
    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false); preferredContentSize = CGSize(width: 900, height: 740) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Generation jobs"; view.backgroundColor = AccountUI.inset.withAlphaComponent(0.35)
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        _ = AccountUI.installScroll(in: self, content: content, padding: 20)
        source.selectedSegmentIndex = 0; source.addAction(UIAction { [weak self] _ in guard let self else { return }; if self.source.selectedSegmentIndex == 1 { self.store.codex.onRefreshSharedJobs?() }; self.render(force: true) }, for: .valueChanged)
        content.addArrangedSubview(source)
        content.addArrangedSubview(AccountUI.label("Jobs are saved on this Mac. Reconnecting never starts a new generation.", size: 13, color: .secondaryLabel, centered: true))
        content.addArrangedSubview(ScrivGenerationProgressView(controller: store.codex))
        content.addArrangedSubview(errorLabel); content.addArrangedSubview(jobsContent)
        content.addArrangedSubview(AccountUI.notice("View teammates' job status under Shared project. Only the owning Mac can run or recover its work.", warning: false))
        selectedID = store.codex.jobs.first(where: { $0.status == .waiting || $0.status == .failed })?.id
        store.codex.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        render(force: true)
    }
    override func storeDidChange() { guard isViewLoaded else { return }; render() }
    private func render(force: Bool = false) {
        guard isViewLoaded else { return }; let controller = store.codex
        let snapshot = "\(source.selectedSegmentIndex)-\(selectedID ?? "")-\(working)-\(controller.isGenerating)-\(controller.isConnected)-\(controller.inspectingJobID ?? "")-\(controller.sharedJobsError ?? "")-\(controller.journalError ?? "")" + ((try? ScrivDigest.sha256(ScrivJSON.encoder.encode(controller.jobs))) ?? "invalid-local") + ((try? ScrivDigest.sha256(ScrivJSON.encoder.encode(controller.sharedJobs))) ?? "invalid-shared")
        guard force || snapshot != lastSnapshot else { return }; lastSnapshot = snapshot; AccountUI.clear(jobsContent)
        if source.selectedSegmentIndex == 1 { shared(); return }
        if let issue = controller.journalError { jobsContent.addArrangedSubview(AccountUI.notice(issue)) }
        if controller.jobs.isEmpty { jobsContent.addArrangedSubview(AccountUI.card(AccountUI.stack([AccountUI.label("No generation jobs yet", size: 21, weight: .semibold), AccountUI.label("Select an image placement, write a direction and choose Generate. Starting or reconnecting Codex never starts generation.", size: 14, color: .secondaryLabel)], spacing: 12), padding: 28)) }
        for job in controller.jobs { jobsContent.addArrangedSubview(card(job)) }
    }
    private func card(_ job: LocalGenerationJob) -> UIView {
        let controller = store.codex, selected = selectedID == job.id, imported = job.outputImageID != nil
        let operable = !working && !controller.isGenerating && controller.inspectingJobID == nil
        let title = job.context.map { $0.projectTitle + " · " + ($0.targetCue.label.isEmpty ? "Image placement" : $0.targetCue.label) } ?? "Local image generation"
        let status = imported ? "Imported" : job.status == .completed ? "Ready" : job.status == .waiting || job.status == .failed ? "Needs review" : job.status.label
        let color: UIColor = imported || job.status == .completed ? .systemGreen : job.status == .waiting || job.status == .failed ? .systemOrange : .secondaryLabel
        let text = AccountUI.stack([AccountUI.label(title, size: 16, weight: .semibold), AccountUI.label("● " + status, size: 13, weight: .medium, color: color), AccountUI.label(job.progressText, size: 13), AccountUI.label("Source revision \(job.context?.sourceRevision ?? 0) · This Mac", size: 12, color: .secondaryLabel)], spacing: 8)
        let image = UIImageView(); image.contentMode = .scaleAspectFill; image.clipsToBounds = true; image.layer.cornerRadius = 9; image.backgroundColor = AccountUI.inset
        image.widthAnchor.constraint(equalToConstant: 145).isActive = true; image.heightAnchor.constraint(equalToConstant: selected ? 150 : 92).isActive = true
        if let hash = job.artifactSha256, let cached = thumbnailCache[hash] { image.image = cached }
        else if let url = try? controller.artifactURL(for: job.id), let loaded = UIImage(contentsOfFile: url.path) {
            image.image = loaded; if let hash = job.artifactSha256 { thumbnailCache[hash] = loaded }
        } else { image.image = UIImage(systemName: "photo"); image.contentMode = .center; image.tintColor = .tertiaryLabel }
        image.accessibilityLabel = job.artifactRelativePath == nil ? "No local image recovered" : "Local generation image"
        let top = AccountUI.stack([image, text], spacing: 16, horizontal: true); top.alignment = .top
        let body = AccountUI.stack([top], spacing: 12)
        if selected {
            body.addArrangedSubview(AccountUI.card(AccountUI.stack([AccountUI.label("Captured prompt", size: 13, weight: .semibold, color: AccountUI.accent), AccountUI.label(job.prompt, size: 14)], spacing: 7), padding: 13, tint: AccountUI.accent.withAlphaComponent(0.06)))
            if let error = job.errorDetail { body.addArrangedSubview(AccountUI.notice(error)) }
            if let exact = job.submittedPrompt, exact != job.prompt {
                let details = AccountUI.button("View exact submitted prompt") { [weak self] in self?.showPrompt(exact) }; body.addArrangedSubview(details)
            }
        }
        let actions = AccountUI.stack(spacing: 8, horizontal: true); actions.distribution = .fillProportionally
        if job.artifactRelativePath != nil {
            let open = AccountUI.button("Open image") { [weak self] in self?.open(job.id) }; open.isEnabled = !working; actions.addArrangedSubview(open)
            if !imported, job.context != nil {
                let recover = AccountUI.button("Use in original project", primary: true) { [weak self] in
                    guard let self, !self.working, !self.store.codex.isGenerating, let current = self.store.codex.jobs.first(where: { $0.id == job.id }), current.outputImageID == nil else { return }
                    self.store.codex.onRecoverJob?(current)
                }; recover.isEnabled = operable && controller.onRecoverJob != nil; actions.addArrangedSubview(recover)
            }
        }
        if job.status != .completed {
            let inspect = AccountUI.button("Inspect existing turn", primary: selected) { [weak self] in self?.run { try await controller.inspectJob(job.id) } }; inspect.isEnabled = operable; actions.addArrangedSubview(inspect)
        }
        if job.canRetry {
            let retry = AccountUI.button("Retry…") { [weak self] in self?.confirmRetry(job.id) }; retry.isEnabled = operable && controller.isConnected && controller.onRetryJob != nil; actions.addArrangedSubview(retry)
        }
        let details = AccountUI.button(selected ? "Hide details" : "View details") { [weak self] in guard let self else { return }; self.selectedID = selected ? nil : job.id; self.render(force: true) }; actions.addArrangedSubview(details)
        body.addArrangedSubview(actions)
        if selected, job.canRetry { body.addArrangedSubview(AccountUI.notice("Retry asks for confirmation and starts a new request. Additional usage may apply.")) }
        return AccountUI.card(body, selected: selected, tint: selected ? AccountUI.accent.withAlphaComponent(0.05) : AccountUI.panel)
    }
    private func shared() {
        let controller = store.codex
        if let error = controller.sharedJobsError { jobsContent.addArrangedSubview(AccountUI.notice(error)) }
        jobsContent.addArrangedSubview(AccountUI.button("Refresh shared jobs", symbol: "arrow.clockwise") { [weak self] in self?.store.codex.onRefreshSharedJobs?() })
        if controller.sharedJobs.isEmpty { jobsContent.addArrangedSubview(AccountUI.card(AccountUI.stack([AccountUI.label("No shared jobs for this project", size: 19, weight: .semibold), AccountUI.label("Image prompts sync with the project. Local recovery paths and runtime credentials stay on their owning Mac.", size: 14, color: .secondaryLabel)]), padding: 28)) }
        for job in controller.sharedJobs {
            jobsContent.addArrangedSubview(AccountUI.card(AccountUI.stack([AccountUI.label(job.ownerDeviceName, size: 15, weight: .semibold), AccountUI.label(job.status == .running ? "Running on owning Mac" : job.status.label, size: 13, color: .secondaryLabel), AccountUI.label(job.progressText, size: 14), AccountUI.label("Source revision \(job.sourceRevision)", size: 12, color: .secondaryLabel)])))
        }
    }
    private func open(_ id: String) { do { let url = try store.codex.artifactURL(for: id); UIKitFileAccess.shared.preview(url: url, from: self) } catch { showError(error) } }
    private func confirmRetry(_ id: String) {
        guard let job = store.codex.jobs.first(where: { $0.id == id }), job.canRetry, !working else { return }
        let alert = UIAlertController(title: "Start a new image request?", message: "The original turn may still exist. Inspect it first. Retrying uses the captured prompt and references and may consume additional usage; it does not resume the old turn.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Retry generation", style: .default) { [weak self] _ in
            guard let self, !self.working, !self.store.codex.isGenerating, self.store.codex.isConnected, self.store.codex.inspectingJobID == nil, let current = self.store.codex.jobs.first(where: { $0.id == id }), current.canRetry else { return }
            self.store.codex.onRetryJob?(current)
        }); present(alert, animated: true)
    }
    private func showPrompt(_ prompt: String) {
        let controller = UIViewController(); controller.title = "Exact submitted prompt"; controller.view.backgroundColor = AccountUI.panel
        let text = UITextView(); text.isEditable = false; text.font = .monospacedSystemFont(ofSize: 13, weight: .regular); text.text = prompt; text.textContainerInset = UIEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        controller.view.addSubview(text); text.scrivPinEdges(to: controller.view)
        navigationController?.pushViewController(controller, animated: true)
    }
    private func showError(_ error: Error) { errorLabel.text = error.localizedDescription; errorLabel.isHidden = false }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }; working = true; errorLabel.text = nil; errorLabel.isHidden = true; render(force: true)
        Task { [weak self] in defer { self?.working = false; self?.render(force: true) }; do { try await operation() } catch is CancellationError {} catch { self?.showError(error) } }
    }
}
