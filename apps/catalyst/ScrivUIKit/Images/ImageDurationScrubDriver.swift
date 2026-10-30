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
    private var originalTitle = ""
    private var originalConfiguration: UIButton.Configuration?
    let recognizer: UILongPressGestureRecognizer
    init(button: UIButton, store: WorkspaceStore, cueID: String) {
        self.button = button; self.store = store; self.cueID = cueID
        recognizer = UILongPressGestureRecognizer(); super.init(); recognizer.delegate = self
        recognizer.minimumPressDuration = 0.18; recognizer.allowableMovement = 20; recognizer.cancelsTouchesInView = true
        recognizer.addTarget(self, action: #selector(scrub(_:))); button.addGestureRecognizer(recognizer)
        button.accessibilityHint = "Click for a precise duration. Hold and drag up to add time or down to remove time; release to apply."
    }
    deinit { leaseTask?.cancel() }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { draft == nil && store.lockedByOther(cueID) == nil }
    @objc private func scrub(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let cue = store.project.cues.first(where: { $0.id == cueID }), store.lockedByOther(cueID) == nil else { return }
            if store.isPlaying { store.togglePlayback() }
            draft = ImageDurationScrubDraft(cue: cue, navigationContext: store.navigationContext, projectRevision: store.project.revision); origin = gesture.location(in: button?.window)
            originalConfiguration = button?.configuration
            originalTitle = button?.configuration?.title ?? ScrivFormat.duration(cue.authoredDurationMs ?? cue.durationMs)
            released = false; leaseReady = false; let current = UUID(); token = current
            preview()
            leaseTask = Task { [weak self] in
                guard let self else { return }; let context = self.draft?.navigationContext ?? self.store.navigationContext
                let allowed = await self.store.beginEdit(self.cueID)
                guard !Task.isCancelled, self.token == current, self.draft?.navigationContext == self.store.navigationContext else { if allowed { self.store.endEdit(self.cueID, context: context) }; return }
                self.leaseReady = allowed
                if !allowed { self.store.errorMessage = "This picture’s editing lease is unavailable. Its duration was not changed."; self.cancel(); return }
                if self.released { self.commit() }
            }
        case .changed:
            guard draft != nil else { return }; draft?.update(translationY: Double(gesture.location(in: button?.window).y - origin.y)); preview()
        case .ended:
            guard draft != nil else { return }; draft?.update(translationY: Double(gesture.location(in: button?.window).y - origin.y)); released = true
            if leaseReady { commit() } else { button?.configuration?.title = ScrivFormat.duration(draft!.proposedDurationMs) + "…" }
        case .cancelled, .failed: cancel()
        default: break
        }
    }
    private func preview() {
        guard let draft else { return }
        button?.configuration?.title = ScrivFormat.duration(draft.proposedDurationMs)
        button?.configuration?.baseBackgroundColor = ImageUI.accent
        button?.configuration?.baseForegroundColor = .white
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
        let context = draft?.navigationContext; draft?.cancel(); leaseTask?.cancel()
        if let context { finish(context: context) }
    }
    private func finish(context: Int) {
        if leaseReady { store.endEdit(cueID, context: context) }; leaseReady = false; released = false; token = nil; draft = nil
        let duration = store.project.cues.first { $0.id == cueID }.map { $0.authoredDurationMs ?? $0.durationMs }
        var configuration = originalConfiguration ?? button?.configuration
        configuration?.title = duration.map(ScrivFormat.duration) ?? originalTitle
        button?.configuration = configuration; button?.accessibilityValue = nil
    }
}

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
