import UIKit
import ScrivCore

@MainActor
final class ScriptDurationScrubDriver: NSObject {
    private weak var button: UIButton?
    private let store: WorkspaceStore
    private let entryID: String
    private let finishEditing: () -> Bool
    private var draft: ScriptDurationScrubDraft?
    private var origin = CGPoint.zero
    private var token: UUID?
    private var task: Task<Void, Never>?
    private var leaseReady = false
    private var released = false
    init(button: UIButton, store: WorkspaceStore, entryID: String, finishEditing: @escaping () -> Bool) {
        self.button = button; self.store = store; self.entryID = entryID; self.finishEditing = finishEditing
        super.init()
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(scrub(_:)))
        gesture.minimumPressDuration = 0.18; gesture.allowableMovement = 20; gesture.cancelsTouchesInView = true; button.addGestureRecognizer(gesture)
        button.accessibilityHint = "Click for precise owned duration. Hold and drag up to add time or down to remove time; release to apply once."
    }
    deinit { task?.cancel() }
    @objc private func scrub(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard finishEditing(), let entry = store.project.entries.first(where: { $0.id == entryID }), store.lockedByOther(entryID) == nil else { return }
            if store.isPlaying { store.togglePlayback() }
            let navigation = store.navigationContext, current = UUID()
            draft = ScriptDurationScrubDraft(entry: entry, navigation: navigation); origin = gesture.location(in: button?.window)
            token = current; released = false; leaseReady = false; refreshPreview()
            task = Task { [weak self] in
                guard let self else { return }; let allowed = await store.beginEdit(entryID)
                guard !Task.isCancelled, token == current, draft?.navigation == store.navigationContext else { if allowed { store.endEdit(entryID, context: navigation) }; return }
                leaseReady = allowed
                guard allowed else { cancel(); return }
                if released { commit() }
            }
        case .changed:
            draft?.update(translationY: Double(gesture.location(in: button?.window).y - origin.y)); refreshPreview()
        case .ended:
            guard draft != nil else { return }
            draft?.update(translationY: Double(gesture.location(in: button?.window).y - origin.y)); released = true
            if leaseReady { commit() } else { refreshPreview() }
        case .cancelled, .failed: cancel()
        default: break
        }
    }
    func refreshPreview() {
        guard let draft else { return }
        button?.setTitle(ScrivFormat.duration(draft.proposedMilliseconds) + (released && !leaseReady ? "…" : ""), for: .normal)
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
    func cancel() { task?.cancel(); draft?.cancel(); if let navigation = draft?.navigation { finish(navigation: navigation) } }
    private func finish(navigation: Int) {
        if leaseReady { store.endEdit(entryID, context: navigation) }
        token = nil; draft = nil; leaseReady = false; released = false
        if let entry = store.project.entries.first(where: { $0.id == entryID }) { button?.setTitle(ScrivFormat.duration(entry.ownedDurationMs), for: .normal) }
        button?.backgroundColor = ScrivUIKitTheme.inset; button?.accessibilityValue = nil
    }
}
