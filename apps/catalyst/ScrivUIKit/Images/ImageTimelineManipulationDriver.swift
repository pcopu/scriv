import UIKit
import ScrivCore

@MainActor final class ImageTimelineManipulationDriver: NSObject, UIGestureRecognizerDelegate {
    private weak var surface: UIView?
    private weak var tile: UIView?
    private weak var canvas: UIView?
    private weak var coverageGrip: UIView?
    private var originalGripFrame = CGRect.zero
    private let store: WorkspaceStore
    private let cueID: String
    private let mode: ImageTimelineDragDraft.Mode
    private let scale: CGFloat
    private let snapping: () -> Bool
    private let onBegin: () -> Void
    private let onFinish: () -> Void
    private var draft: ImageTimelineDragDraft?
    private var leaseTask: Task<Void, Never>?
    private var token: UUID?
    private var ready = false
    private var released = false
    private var originalFrame = CGRect.zero
    private var originalSurfaceFrame = CGRect.zero
    private let ghost = UIView(), ownerSlot = UIView(), badge = UILabel()
    let recognizer: ImageTimingPanRecognizer
    var isActive: Bool { draft != nil }
    var sourceIsCurrent: Bool { draft?.isCurrent(project: store.project, navigation: store.navigationContext, sceneID: store.selectedSceneID) ?? true }
    init(surface: UIView, tile: UIView, canvas: UIView, store: WorkspaceStore, cueID: String, mode: ImageTimelineDragDraft.Mode, scale: CGFloat, coverageGrip: UIView? = nil, snapping: @escaping () -> Bool, onBegin: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.surface = surface; self.tile = tile; self.canvas = canvas; self.coverageGrip = coverageGrip; self.store = store; self.cueID = cueID; self.mode = mode; self.scale = scale; self.snapping = snapping; self.onBegin = onBegin; self.onFinish = onFinish
        recognizer = ImageTimingPanRecognizer(); super.init(); recognizer.delegate = self; recognizer.addTarget(self, action: #selector(pan(_:))); surface.addGestureRecognizer(recognizer)
        ghost.layer.borderColor = ImageUI.accent.withAlphaComponent(0.45).cgColor; ghost.layer.borderWidth = 1; ghost.layer.cornerRadius = 6; ghost.isUserInteractionEnabled = false
        ownerSlot.backgroundColor = ImageUI.accent.withAlphaComponent(0.08); ownerSlot.layer.borderColor = ImageUI.accent.withAlphaComponent(0.25).cgColor; ownerSlot.layer.borderWidth = 1; ownerSlot.isUserInteractionEnabled = false
        badge.font = .systemFont(ofSize: 11, weight: .medium); badge.textColor = .white; badge.backgroundColor = ImageUI.accent; badge.layer.cornerRadius = 6; badge.clipsToBounds = true; badge.numberOfLines = 0; badge.isUserInteractionEnabled = false
        surface.accessibilityHint = mode == .offset ? "Drag horizontally to adjust offset within this source. Change source is an explicit menu action. Hold Shift to bypass snapping." : "Drag this lower right grip to change authored forward coverage. Hold Shift to bypass snapping."
    }
    deinit { leaseTask?.cancel() }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { let velocity = recognizer.velocity(in: surface); return !isActive && abs(velocity.x) > abs(velocity.y) && store.lockedByOther(cueID) == nil }
    @objc private func pan(_ sender: UIPanGestureRecognizer) {
        switch sender.state {
        case .began:
            do {
                draft = try ImageTimelineDragDraft(project: store.project, cueID: cueID, mode: mode, navigation: store.navigationContext)
                originalFrame = tile?.frame ?? .zero; originalSurfaceFrame = surface?.frame ?? .zero; originalGripFrame = coverageGrip?.frame ?? .zero; released = false; ready = false; let current = UUID(); token = current
                if store.isPlaying { store.togglePlayback() }; onBegin()
                if let canvas, let draft {
                    ghost.frame = originalFrame; canvas.insertSubview(ghost, at: 0)
                    let geometry = draft.geometry(pointsPerMillisecond: Double(scale))
                    ownerSlot.frame = CGRect(x: CGFloat(geometry.ownerStartX), y: originalFrame.minY - 2, width: CGFloat(geometry.ownerWidth), height: originalFrame.height + 4); canvas.insertSubview(ownerSlot, at: 0); canvas.addSubview(badge)
                }
                preview()
                leaseTask = Task { [weak self] in
                    guard let self else { return }; let context = self.draft?.navigation ?? self.store.navigationContext
                    let allowed = await self.store.beginEdit(self.cueID)
                    guard !Task.isCancelled, self.token == current else { if allowed { self.store.endEdit(self.cueID, context: context) }; return }
                    guard self.sourceIsCurrent else { if allowed { self.store.endEdit(self.cueID, context: context) }; self.cancel(); return }
                    self.ready = allowed
                    if !allowed { self.store.errorMessage = "This picture’s editing lease is unavailable. Its timing was not changed."; self.cancel() }
                    else if self.released { self.commit() }
                }
            } catch { store.errorMessage = error.localizedDescription; cancel() }
        case .changed: update(sender)
        case .ended: update(sender); released = true; if ready { commit() }
        case .cancelled, .failed: cancel()
        default: break
        }
    }
    private func update(_ sender: UIPanGestureRecognizer) {
        draft?.update(translationX: Double(sender.translation(in: canvas).x), pointsPerMillisecond: Double(scale), snapping: snapping() && !recognizer.modifiers.contains(.shift)); preview()
    }
    private func preview() {
        guard let draft, let canvas else { return }
        let geometry = draft.geometry(pointsPerMillisecond: Double(scale))
        let start = CGFloat(geometry.startX), visibleWidth = CGFloat(geometry.visibleWidth)
        tile?.frame = CGRect(x: start, y: originalFrame.minY, width: visibleWidth, height: originalFrame.height)
        if mode == .coverage, surface !== tile { surface?.frame.origin.x = start + visibleWidth - originalSurfaceFrame.width }
        coverageGrip?.frame.origin.x = start + visibleWidth - originalGripFrame.width
        let sourceName = draft.source.kind == .direction ? "Direction" : store.project.character(draft.source.characterId)?.name ?? "Dialogue"
        switch mode {
        case .offset:
            let boundary = draft.source.ownedDurationMs == 0 ? " · zero-owned: offset stays 0" : draft.atOwnerBoundary ? " · source limit — Change source to move farther" : ""
            badge.text = "  \(sourceName) · +\(String(format: "%.3f", Double(draft.offsetMs) / 1000)) s\(boundary)  "
        case .coverage:
            badge.text = "  \(ScrivFormat.duration(draft.authoredDurationMs)) authored" + (draft.hasClippedTail ? " · tail preserved beyond scene" : "") + "  "
        }
        let width = min(430, max(220, canvas.bounds.width - 80))
        let height = max(24, badge.sizeThatFits(CGSize(width: width, height: 100)).height + 6)
        badge.frame = CGRect(x: min(max(70, start), max(70, canvas.bounds.width - width)), y: max(0, originalFrame.minY - height - 1), width: width, height: height)
        surface?.accessibilityValue = badge.text
    }
    private func commit() {
        guard released, ready, var draft else { return }
        let sourceCurrent = draft.isCurrent(project: store.project, navigation: store.navigationContext, sceneID: store.selectedSceneID)
        let command = draft.finish(project: store.project, navigation: store.navigationContext, sceneID: store.selectedSceneID); self.draft = draft
        if surface?.window != nil, let command {
            switch command {
            case let .offset(entryID, milliseconds): _ = store.setCueAnchor(cueId: cueID, entryId: entryID, offsetMs: milliseconds)
            case let .coverage(milliseconds): _ = store.setCueDuration(cueId: cueID, durationMs: milliseconds)
            }
        } else if !sourceCurrent { store.errorMessage = "This source changed during the drag. No timing was applied; drag again from its current position." }
        cleanup()
    }
    func cancel() { draft?.cancel(); leaseTask?.cancel(); cleanup() }
    private func cleanup() {
        guard let draft else { return }
        if ready { store.endEdit(cueID, context: draft.navigation) }; ready = false; released = false; token = nil; self.draft = nil
        tile?.frame = originalFrame; coverageGrip?.frame = originalGripFrame; if surface !== tile { surface?.frame = originalSurfaceFrame }; ghost.removeFromSuperview(); ownerSlot.removeFromSuperview(); badge.removeFromSuperview(); surface?.accessibilityValue = nil; onFinish()
    }
}

@MainActor final class ImageTimingPanRecognizer: UIPanGestureRecognizer {
    private(set) var modifiers: UIKeyModifierFlags = []
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { modifiers = event.modifierFlags; super.touchesBegan(touches, with: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { modifiers = event.modifierFlags; super.touchesMoved(touches, with: event) }
}
