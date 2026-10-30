import UIKit
import Combine
import ScrivCore

/// A truthful shared waiting state. The spinner is indeterminate; the timer is
/// elapsed wall time, not an ETA. Stage text comes only from the durable job or
/// live controller events. It never displays imagined percentage/preview output.
@MainActor
final class ScrivGenerationProgressView: UIView {
    private let controller: CodexController
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stage = AccountUI.label("", size: 14, weight: .medium)
    private let elapsed = AccountUI.label("", size: 12, color: .secondaryLabel)
    private let cancel = AccountUI.button("Cancel") {}
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var fallbackStart: Date?
    private var requestedCancellation = false
    private var observedJobID: String?
    init(controller: CodexController) {
        self.controller = controller; super.init(frame: .zero)
        backgroundColor = AccountUI.accent.withAlphaComponent(0.065); layer.cornerRadius = 11
        spinner.color = AccountUI.accent; spinner.hidesWhenStopped = true
        elapsed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let text = AccountUI.stack([stage, elapsed], spacing: 4)
        let row = AccountUI.stack([spinner, text, cancel], spacing: 12, horizontal: true)
        spinner.setContentHuggingPriority(.required, for: .horizontal); cancel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(row); row.scrivPinEdges(to: self, insets: .init(top: 13, leading: 14, bottom: 13, trailing: 14))
        cancel.addAction(UIAction { [weak self] _ in
            guard let self, self.controller.isGenerating, !self.requestedCancellation else { return }
            self.requestedCancellation = true; self.update()
            Task { [weak self] in await self?.controller.cancelGeneration(); self?.update() }
        }, for: .touchUpInside)
        cancel.accessibilityLabel = "Cancel the current image generation"
        subscription = controller.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.update() }
        update()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(controller:)") }
    override func didMoveToWindow() { super.didMoveToWindow(); updateTimer() }
    private func update() {
        isHidden = !controller.isGenerating
        if controller.isGenerating {
            if observedJobID != controller.activeGenerationJob?.id { observedJobID = controller.activeGenerationJob?.id; requestedCancellation = false; fallbackStart = nil }
            if fallbackStart == nil { fallbackStart = Date() }
            stage.text = controller.isCancellingGeneration || requestedCancellation ? "Requesting cancellation…" : controller.activeGenerationJob?.progressText ?? controller.status
            spinner.startAnimating(); cancel.isEnabled = !controller.isCancellingGeneration && !requestedCancellation
            cancel.configuration?.title = cancel.isEnabled ? "Cancel" : "Cancelling…"
            updateElapsed()
        } else {
            spinner.stopAnimating(); fallbackStart = nil; requestedCancellation = false; observedJobID = nil; elapsed.text = nil
        }
        updateTimer()
    }
    private func updateElapsed() {
        guard controller.isGenerating else { return }
        // The journal's createdAt remains the source of truth across UI changes.
        // The fallback measures only this view's observed wait, never completion.
        let start = controller.activeGenerationJob?.createdAt ?? fallbackStart ?? Date()
        let duration = max(0, Int(Date().timeIntervalSince(start)))
        let time = duration >= 3600 ? String(format: "%d:%02d:%02d", duration / 3600, duration / 60 % 60, duration % 60) : String(format: "%d:%02d", duration / 60, duration % 60)
        elapsed.text = "Elapsed \(time) · no time estimate"
        stage.accessibilityLabel = stage.text
    }
    private func updateTimer() {
        if window != nil, controller.isGenerating {
            if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateElapsed() } } }
        } else { timer?.invalidate(); timer = nil }
    }
    deinit { timer?.invalidate() }
}
