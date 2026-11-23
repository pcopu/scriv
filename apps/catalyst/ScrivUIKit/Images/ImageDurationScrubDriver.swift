import UIKit
import ScrivCore

/// A normal click still opens the exact numeric editor. Hold + vertical drag
/// previews locally; release commits once through the existing authored-
/// coverage operation. It never moves a cut or writes on every pointer sample.
@MainActor final class ImageDurationScrubDriver: NSObject, UIGestureRecognizerDelegate {
    private weak var button: UIButton?
    private let store: WorkspaceStore
    private let cueID: String
    private var draft: ImageDurationScrubDraft?
    private var origin = CGPoint.zero
    private var token: UUID?
    private var leaseTask: Task<Void, Never>?
    private var leaseReady = false
    private var released = false
    private var feedback: DurationHoldFeedback!
    private var originalTitle = ""
    private var originalConfiguration: UIButton.Configuration?
    let recognizer: UILongPressGestureRecognizer
    init(button: UIButton, store: WorkspaceStore, cueID: String) {
        self.button = button; self.store = store; self.cueID = cueID
        recognizer = UILongPressGestureRecognizer(); super.init(); recognizer.delegate = self; feedback = DurationHoldFeedback(button: button)
        recognizer.minimumPressDuration = 0.18; recognizer.allowableMovement = 20; recognizer.cancelsTouchesInView = true
        recognizer.addTarget(self, action: #selector(scrub(_:))); button.addGestureRecognizer(recognizer)
        button.accessibilityHint = "Click for a precise duration. Hold and drag up to add time or down to remove time; release to apply."
    }
    deinit { leaseTask?.cancel() }
    private var canBegin: Bool { draft == nil && store.lockedByOther(cueID) == nil }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { canBegin }
    @objc private func scrub(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began: beginScrub(at: gesture.location(in: button?.window))
        case .changed, .ended:
            sampleScrub(Double(gesture.location(in: button?.window).y - origin.y), releasing: gesture.state == .ended)
        case .cancelled, .failed: cancel()
        default: break
        }
    }
    private func beginScrub(at point: CGPoint) {
        guard canBegin, let cue = store.project.cues.first(where: { $0.id == cueID }) else { return }
        if store.isPlaying { store.togglePlayback() }
        draft = ImageDurationScrubDraft(cue: cue, navigationContext: store.navigationContext, projectRevision: store.project.revision); origin = point
        originalConfiguration = button?.configuration
        originalTitle = button?.configuration?.title ?? ScrivFormat.duration(cue.authoredDurationMs ?? cue.durationMs)
        released = false; leaseReady = false; let current = UUID(); token = current
        feedback.lockIn(); preview()
        leaseTask = Task { [weak self] in
            guard let self else { return }; let context = self.draft?.navigationContext ?? self.store.navigationContext
            let allowed = await self.store.beginEdit(self.cueID)
            guard !Task.isCancelled, self.token == current, self.draft?.navigationContext == self.store.navigationContext else { if allowed { self.store.endEdit(self.cueID, context: context) }; return }
            self.leaseReady = allowed
            if !allowed { self.store.errorMessage = "This picture’s editing lease is unavailable. Its duration was not changed."; self.cancel(); return }
            if self.released { self.commit() }
        }
    }
    private func sampleScrub(_ translation: Double, releasing: Bool) {
        guard !released, var next = draft else { return }
        next.update(translationY: translation); draft = next
        guard releasing else { preview(); return }
        released = true
        if leaseReady { commit() } else { DurationHoldFeedback.tick(button, title: ScrivFormat.duration(next.proposedDurationMs) + "…") }
    }
    private func preview() {
        guard let draft else { return }
        DurationHoldFeedback.tick(button, title: ScrivFormat.duration(draft.proposedDurationMs)) { button in
            button.configuration?.baseBackgroundColor = ImageUI.accent
            button.configuration?.background.backgroundColor = ImageUI.accent
            button.configuration?.baseForegroundColor = .white
        }
        button?.accessibilityValue = ScrivFormat.duration(draft.proposedDurationMs) + ", preview; release to apply"
    }
    private func commit() {
        guard released, leaseReady, var draft else { return }
        let current = store.project.cues.first { $0.id == cueID }
        let duration = draft.finish(currentCue: current, navigation: store.navigationContext, sceneID: store.selectedSceneID, projectRevision: store.project.revision)
        self.draft = draft
        if let duration, button?.window != nil { _ = store.setCueDuration(cueId: cueID, durationMs: duration) }
        else if store.project.revision != draft.projectRevision || current != draft.original || store.navigationContext != draft.navigationContext || store.selectedSceneID != draft.original.sceneId {
            store.errorMessage = "This picture changed during the duration drag. No duration was applied; drag again from its current value."
        }
        finish(context: draft.navigationContext)
    }
    func cancel() {
        feedback.reset()
        let context = draft?.navigationContext; draft?.cancel(); leaseTask?.cancel()
        if let context { finish(context: context) }
    }
    private func finish(context: Int) {
        feedback.reset()
        if leaseReady { store.endEdit(cueID, context: context) }; leaseReady = false; released = false; token = nil; draft = nil
        let duration = store.project.cues.first { $0.id == cueID }.map { $0.authoredDurationMs ?? $0.durationMs }
        var configuration = originalConfiguration ?? button?.configuration
        configuration?.title = duration.map(ScrivFormat.duration) ?? originalTitle
        UIView.performWithoutAnimation { button?.configuration = configuration; button?.layoutIfNeeded(); button?.titleLabel?.layer.removeAllAnimations() }; button?.accessibilityValue = nil
    }
}

#if SCRIV_CLI_AUTOMATION
extension ImageDurationScrubDriver: ScrivCLIPictureTimingDriver {
    var cliGestureInFlight: Bool { draft != nil }
    var cliAcceptsSample: Bool { draft != nil && !released }
    func cliBeginGesture() { beginScrub(at: .zero) }
    func cliSampleGesture(_ translation: Double, shift _: Bool, releasing: Bool) { sampleScrub(translation, releasing: releasing) }
}
#endif

@MainActor enum StoryboardBackgroundSelectionPolicy {
    static func isBlankTouch(_ view: UIView?, within boundary: UIView) -> Bool {
        var candidate = view
        while let current = candidate, current !== boundary {
            if current is UIControl || current is UITextView || current is UIKitAssetImageView { return false }
            candidate = current.superview
        }
        return candidate === boundary
    }
}
