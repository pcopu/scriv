import UIKit
import ScrivCore

#if SCRIV_CLI_AUTOMATION
@MainActor
final class ScriptDurationHoldRecognizer: UILongPressGestureRecognizer {
    weak var driver: ScriptDurationScrubDriver?
}
#endif

@MainActor
final class ScriptDurationScrubDriver: NSObject {
    private weak var button: UIButton?
    private let store: WorkspaceStore
    private let entryID: String
    private let finishEditing: () -> Bool
    private var draft: ScriptDurationScrubDraft?
    private var originY: CGFloat = 0
    private var token: UUID?
    private var task: Task<Void, Never>?
    private var leaseReady = false
    private var released = false
    private var feedback: DurationHoldFeedback!
    init(button: UIButton, store: WorkspaceStore, entryID: String, finishEditing: @escaping () -> Bool) {
        self.button = button; self.store = store; self.entryID = entryID; self.finishEditing = finishEditing
        super.init(); feedback = DurationHoldFeedback(button: button)
        #if SCRIV_CLI_AUTOMATION
        let gesture = ScriptDurationHoldRecognizer(target: self, action: #selector(scrub(_:)))
        gesture.driver = self
        #else
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(scrub(_:)))
        #endif
        gesture.minimumPressDuration = 0.18; gesture.allowableMovement = 20; gesture.cancelsTouchesInView = true; button.addGestureRecognizer(gesture)
        button.accessibilityHint = "Click for precise owned duration. Hold and drag up to add time or down to remove time; release to apply once."
    }
    deinit { task?.cancel() }
    @objc private func scrub(_ gesture: UILongPressGestureRecognizer) {
        advance(gesture.state, y: gesture.location(in: button?.window).y)
    }
    #if SCRIV_CLI_AUTOMATION
    var cliGestureInFlight: Bool { draft != nil }
    var cliAcceptsSample: Bool { draft != nil && !released }
    func cliBeginGesture() { advance(.began, y: 0) }
    func cliSampleGesture(_ translation: Double, releasing: Bool) {
        advance(releasing ? .ended : .changed, y: CGFloat(translation))
    }
    #endif
    private func advance(_ state: UIGestureRecognizer.State, y: CGFloat) {
        switch state {
        case .began:
            guard finishEditing(), let entry = store.project.entries.first(where: { $0.id == entryID }), store.lockedByOther(entryID) == nil else { return }
            if store.isPlaying { store.togglePlayback() }
            let navigation = store.navigationContext, current = UUID()
            draft = ScriptDurationScrubDraft(entry: entry, navigation: navigation); originY = y
            token = current; released = false; leaseReady = false; feedback.lockIn(); refreshPreview()
            task = Task { [weak self] in
                guard let self else { return }; let allowed = await store.beginEdit(entryID)
                guard !Task.isCancelled, token == current, draft?.navigation == store.navigationContext else { if allowed { store.endEdit(entryID, context: navigation) }; return }
                leaseReady = allowed
                guard allowed else { cancel(); return }
                if released { commit() }
            }
        case .changed:
            draft?.update(translationY: Double(y - originY)); refreshPreview()
        case .ended:
            guard draft != nil else { return }
            draft?.update(translationY: Double(y - originY)); released = true
            if leaseReady { commit() } else { refreshPreview() }
        case .cancelled, .failed: cancel()
        default: break
        }
    }
    func refreshPreview() {
        guard let draft else { return }
        DurationHoldFeedback.tick(button, title: ScrivFormat.duration(draft.proposedMilliseconds) + (released && !leaseReady ? "…" : ""))
        button?.backgroundColor = ScrivUIKitTheme.accent.withAlphaComponent(0.22)
        button?.accessibilityValue = ScrivFormat.duration(draft.proposedMilliseconds) + ", preview; release to apply"
    }
    private func commit() {
        guard released, leaseReady, var draft else { return }
        let current = store.project.entries.first { $0.id == entryID }
        if let milliseconds = draft.finish(entry: current, navigation: store.navigationContext, sceneID: store.selectedSceneID), button?.window != nil, store.lockedByOther(entryID) == nil {
            store.setDuration(entryID, seconds: Double(milliseconds) / 1000)
        } else if current != draft.original || store.navigationContext != draft.navigation || store.selectedSceneID != draft.original.sceneId {
            store.errorMessage = "This line changed during the duration drag. No duration was applied; try again from its current value."
        }
        finish(navigation: draft.navigation)
    }
    func cancel() { feedback.reset(); task?.cancel(); draft?.cancel(); if let navigation = draft?.navigation { finish(navigation: navigation) } }
    private func finish(navigation: Int) {
        if leaseReady { store.endEdit(entryID, context: navigation) }
        feedback.reset(); token = nil; draft = nil; leaseReady = false; released = false
        if let entry = store.project.entries.first(where: { $0.id == entryID }) { DurationHoldFeedback.tick(button, title: ScrivFormat.duration(entry.ownedDurationMs)) }
        button?.backgroundColor = ScrivUIKitTheme.inset; button?.accessibilityValue = nil
    }
}
