import UIKit
import Combine
import ImageIO
import ScrivCore

@MainActor
final class ScrivGenerationJobsController: ScrivScreenController {
    private let content = AccountUI.stack(spacing: 13)
    private let jobsContent = AccountUI.stack(spacing: 12)
    private let source = UISegmentedControl(items: ["This Mac", "Shared project"])
    private let errorLabel = AccountUI.label("", size: 13, color: .systemRed)
    private var working = false
    private var selectedID: String?
    private var thumbnails: [String: GenerationJobThumbnailView] = [:]
    private var lastSnapshot: [AnyHashable]?
    private var visibleJobCount = 20
    private var operationTask: Task<Void, Never>?
    private var presentationActive = false
    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false); preferredContentSize = CGSize(width: 900, height: 740) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Generation jobs"; view.backgroundColor = AccountUI.inset.withAlphaComponent(0.35)
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        _ = AccountUI.installScroll(in: self, content: content, padding: 20)
        source.selectedSegmentIndex = 0; source.addAction(UIAction { [weak self] _ in guard let self else { return }; if self.source.selectedSegmentIndex == 1 { self.store.codex.onRefreshSharedJobs?() }; self.render(force: true) }, for: .valueChanged)
        let sourceRow = AccountUI.stack([source], spacing: 0); sourceRow.alignment = .center
        source.widthAnchor.constraint(equalToConstant: 340).isActive = true; source.heightAnchor.constraint(equalToConstant: 32).isActive = true
        content.addArrangedSubview(sourceRow)
        content.addArrangedSubview(AccountUI.label("Jobs are saved on this Mac. Reconnecting never starts a new generation.", size: 13, color: ScrivUIKitTheme.secondary, centered: true))
        content.addArrangedSubview(ScrivGenerationProgressView(controller: store.codex))
        errorLabel.isHidden = true; content.addArrangedSubview(errorLabel); content.addArrangedSubview(jobsContent)
        content.addArrangedSubview(AccountUI.notice("View teammates' job status under Shared project. Only the owning Mac can run or recover its work.", warning: false))
        selectedID = store.codex.jobs.first(where: { $0.status == .waiting || $0.status == .failed })?.id
        store.codex.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        render(force: true)
    }
    override func storeDidChange() { guard isViewLoaded else { return }; render() }
    override func viewWillAppear(_ animated: Bool) {
        presentationActive = true; super.viewWillAppear(animated)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        thumbnails.values.forEach { $0.resumeLoading() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        presentationActive = false
        thumbnails.values.forEach { $0.cancelLoading() }
        if isBeingDismissed || navigationController?.isBeingDismissed == true { operationTask?.cancel() }
    }
    private func render(force: Bool = false) {
        guard isViewLoaded, presentationActive || lastSnapshot == nil else { return }; let controller = store.codex
        let visibleJobs = Array(controller.jobs.prefix(visibleJobCount))
        let artifacts = visibleJobs.map { try? controller.artifact(for: $0.id) }
        let snapshot: [AnyHashable] = [source.selectedSegmentIndex, selectedID, working, visibleJobCount, controller.isGenerating, controller.isConnected, controller.inspectingJobID, controller.sharedJobsError, controller.journalError, controller.jobs, controller.sharedJobs, artifacts]
        guard force || snapshot != lastSnapshot else { return }; lastSnapshot = snapshot; AccountUI.clear(jobsContent)
        if source.selectedSegmentIndex == 1 { thumbnails.removeAll(); shared(); return }
        let visibleIDs = Set(visibleJobs.map(\.id))
        thumbnails = thumbnails.filter { visibleIDs.contains($0.key) }
        if let issue = controller.journalError { jobsContent.addArrangedSubview(AccountUI.notice(issue)) }
        if controller.jobs.isEmpty { jobsContent.addArrangedSubview(AccountUI.card(AccountUI.stack([AccountUI.label("No generation jobs yet", size: 21, weight: .semibold), AccountUI.label("Select an image placement, write a direction and choose Generate. Starting or reconnecting Codex never starts generation.", size: 14, color: ScrivUIKitTheme.secondary)], spacing: 12), padding: 28)) }
        for job in visibleJobs { jobsContent.addArrangedSubview(card(job)) }
        addMoreButton(total: controller.jobs.count)
    }
    private func card(_ job: LocalGenerationJob) -> UIView {
        let controller = store.codex, selected = selectedID == job.id, imported = job.outputImageID != nil
        let operable = !working && !controller.isGenerating && controller.inspectingJobID == nil
        let title = job.context.map { $0.projectTitle + " · " + ($0.targetCue.label.isEmpty ? "Image placement" : $0.targetCue.label) } ?? "Local image generation"
        let status = imported ? "Imported" : job.status == .completed ? "Ready" : job.status == .waiting || job.status == .failed ? "Needs review" : job.status.label
        let color: UIColor = imported || job.status == .completed ? .systemGreen : job.status == .waiting || job.status == .failed ? .systemOrange : .secondaryLabel
        let text = AccountUI.stack([AccountUI.label(title, size: 16, weight: .semibold), AccountUI.label("● " + status, size: 13, weight: .medium, color: color), AccountUI.label(job.progressText, size: 13), AccountUI.label("Source revision \(job.context?.sourceRevision ?? 0) · This Mac", size: 12, color: ScrivUIKitTheme.secondary)], spacing: 8)
        let image = thumbnails[job.id] ?? GenerationJobThumbnailView()
        thumbnails[job.id] = image
        image.configure(artifact: try? controller.artifact(for: job.id), selected: selected)
        let detailsColumn = AccountUI.stack([text], spacing: 12)
        let body = ScrivSecondaryAdaptiveRow([image, detailsColumn], minimumHorizontalWidth: 680, spacing: 20, alignment: .top)
        if selected {
            detailsColumn.addArrangedSubview(AccountUI.card(AccountUI.stack([AccountUI.label("Captured prompt", size: 13, weight: .semibold, color: AccountUI.accent), AccountUI.label(job.prompt, size: 14)], spacing: 7), padding: 13, tint: AccountUI.accent.withAlphaComponent(0.06)))
            if let error = job.errorDetail { detailsColumn.addArrangedSubview(AccountUI.notice(error)) }
            if let exact = job.submittedPrompt, exact != job.prompt {
                let details = AccountUI.button("View exact submitted prompt") { [weak self] in self?.showPrompt(exact) }; detailsColumn.addArrangedSubview(details)
            }
        }
        let actions = CharacterChipWrapView(); var actionButtons: [UIView] = []
        if job.artifactRelativePath != nil {
            let open = AccountUI.button("Open image") { [weak self] in self?.open(job.id) }; open.isEnabled = !working; actionButtons.append(open)
            if !imported, job.context != nil {
                let recover = AccountUI.button("Use in original project", primary: true) { [weak self] in
                    guard let self, !self.working, !self.store.codex.isGenerating, let current = self.store.codex.jobs.first(where: { $0.id == job.id }), current.outputImageID == nil else { return }
                    self.store.codex.onRecoverJob?(current)
                }; recover.isEnabled = operable && controller.onRecoverJob != nil; actionButtons.append(recover)
            }
        }
        if job.status != .completed {
            let inspect = AccountUI.button("Inspect existing turn", primary: selected) { [weak self] in self?.run { try await controller.inspectJob(job.id) } }; inspect.isEnabled = operable; actionButtons.append(inspect)
        }
        if job.canRetry {
            let retry = AccountUI.button("Retry…") { [weak self] in self?.confirmRetry(job.id) }; retry.isEnabled = operable && controller.isConnected && controller.onRetryJob != nil; actionButtons.append(retry)
        }
        let details = AccountUI.button(selected ? "Hide details" : "View details") { [weak self] in guard let self else { return }; self.selectedID = selected ? nil : job.id; self.render(force: true) }; actionButtons.append(details)
        actions.chips = actionButtons; detailsColumn.addArrangedSubview(actions)
        if selected, job.canRetry { detailsColumn.addArrangedSubview(AccountUI.notice("Retry asks for confirmation and starts a new request. Additional usage may apply.")) }
        return AccountUI.card(body, selected: selected, tint: selected ? AccountUI.accent.withAlphaComponent(0.05) : AccountUI.panel)
    }
    private func shared() {
        let controller = store.codex
        if let error = controller.sharedJobsError { jobsContent.addArrangedSubview(AccountUI.notice(error)) }
        jobsContent.addArrangedSubview(AccountUI.button("Refresh shared jobs", symbol: "arrow.clockwise") { [weak self] in self?.store.codex.onRefreshSharedJobs?() })
        if controller.sharedJobs.isEmpty { jobsContent.addArrangedSubview(AccountUI.card(AccountUI.stack([AccountUI.label("No shared jobs for this project", size: 19, weight: .semibold), AccountUI.label("Image prompts sync with the project. Local recovery paths and runtime credentials stay on their owning Mac.", size: 14, color: ScrivUIKitTheme.secondary)]), padding: 28)) }
        for job in controller.sharedJobs.prefix(visibleJobCount) {
            jobsContent.addArrangedSubview(AccountUI.card(AccountUI.stack([AccountUI.label(job.ownerDeviceName, size: 15, weight: .semibold), AccountUI.label(job.status == .running ? "Running on owning Mac" : job.status.label, size: 13, color: ScrivUIKitTheme.secondary), AccountUI.label(job.progressText, size: 14), AccountUI.label("Source revision \(job.sourceRevision)", size: 12, color: ScrivUIKitTheme.secondary)])))
        }
        addMoreButton(total: controller.sharedJobs.count)
    }
    private func addMoreButton(total: Int) {
        guard total > visibleJobCount else { return }
        jobsContent.addArrangedSubview(AccountUI.button("Show more jobs (\(total - visibleJobCount) remaining)") { [weak self] in
            guard let self else { return }; self.visibleJobCount += 20; self.render(force: true)
        })
    }
    private func open(_ id: String) {
        run { [weak self] in
            guard let self else { return }
            let artifact = try self.store.codex.artifact(for: id)
            let url = try await GenerationJobThumbnailLoader.shared.validatedURL(for: artifact)
            try Task.checkCancellation()
            guard try self.store.codex.artifact(for: id) == artifact, self.viewIfLoaded?.window != nil else { return }
            UIKitFileAccess.shared.preview(url: url, from: self)
        }
    }
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
        operationTask = Task { [weak self] in defer { self?.working = false; self?.render(force: true) }; do { try Task.checkCancellation(); try await operation() } catch is CancellationError {} catch { if !Task.isCancelled { self?.showError(error) } } }
    }
}

/// Serial decoding caps simultaneous artifact reads. Only small, fully decoded
/// images enter the cache; opening the original still validates the disk bytes.
private actor GenerationJobThumbnailLoader {
    static let shared = GenerationJobThumbnailLoader()
    private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>(); cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 64; return cache
    }()
    func validatedURL(for artifact: CodexGenerationArtifact) throws -> URL {
        try artifact.validatedContents().url
    }
    func thumbnail(for artifact: CodexGenerationArtifact) throws -> CGImage {
        try Task.checkCancellation()
        let contents = try artifact.validatedContents()
        let key = (contents.url.absoluteString + "|" + artifact.sha256) as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithData(contents.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 600
              ] as CFDictionary) else { throw ScrivError.invalid("The saved generation image could not be decoded.") }
        try Task.checkCancellation()
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

@MainActor private final class GenerationJobThumbnailView: UIImageView {
    private var artifact: CodexGenerationArtifact?
    private var loadTask: Task<Void, Never>?
    private var requestID = UUID()
    private var loaded = false
    private var imageHeight: NSLayoutConstraint!
    init() {
        super.init(frame: .zero)
        clipsToBounds = true; layer.cornerRadius = 9; backgroundColor = AccountUI.inset; tintColor = .tertiaryLabel
        isAccessibilityElement = true; accessibilityTraits = .image
        let width = widthAnchor.constraint(equalToConstant: 175); width.priority = .defaultHigh; width.isActive = true
        imageHeight = heightAnchor.constraint(equalToConstant: 100); imageHeight.isActive = true
        showPlaceholder("No local image recovered")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init()") }
    deinit { loadTask?.cancel() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { resumeLoading() }
        else {
            // Rendering moves the same thumbnail between cards in one turn.
            // Cancel only when it remains detached, not during that move.
            DispatchQueue.main.async { [weak self] in if self?.window == nil { self?.cancelLoading() } }
        }
    }
    func configure(artifact: CodexGenerationArtifact?, selected: Bool) {
        imageHeight.constant = selected ? 180 : 100
        guard artifact != self.artifact else { return }
        cancelLoading(); self.artifact = artifact; loaded = false
        showPlaceholder(artifact == nil ? "No local image recovered" : "Loading local generation image")
        resumeLoading()
    }
    func cancelLoading() { loadTask?.cancel(); loadTask = nil; requestID = UUID() }
    func resumeLoading() {
        guard window != nil, let artifact, !loaded, loadTask == nil else { return }
        let request = requestID
        loadTask = Task { [weak self] in
            do {
                let image = try await GenerationJobThumbnailLoader.shared.thumbnail(for: artifact)
                guard !Task.isCancelled, let self, self.requestID == request, self.artifact == artifact else { return }
                self.image = UIImage(cgImage: image); self.contentMode = .scaleAspectFill; self.loaded = true
                self.accessibilityLabel = "Local generation image"; self.loadTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.requestID == request else { return }
                self.showPlaceholder("Local generation image unavailable"); self.loadTask = nil
            }
        }
    }
    private func showPlaceholder(_ title: String) {
        image = UIImage(systemName: "photo"); contentMode = .center; accessibilityLabel = title
    }
}
