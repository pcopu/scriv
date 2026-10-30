import UIKit
import ScrivCore

/// Owned entry time and authored picture coverage share a numeric editor, not
/// a timing model: each commits through its separate existing Store action.
@MainActor final class ImageCoverageViewController: ScrivScreenController {
    private let cue: ImageCue?
    private let entry: ScriptEntry?
    private let seconds = ImageUI.field()
    private let issue = ImageUI.label(size: 12)
    private var applyButton: UIButton!
    private var ready = false
    private var leaseTask: Task<Void, Never>?
    private var itemID: String { cue?.id ?? entry!.id }
    init(store: WorkspaceStore, cue: ImageCue) { self.cue = cue; entry = nil; super.init(store: store) }
    init(store: WorkspaceStore, entry: ScriptEntry) { cue = nil; self.entry = entry; super.init(store: store) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use a source initializer") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = cue == nil ? "Owned duration" : "Authored image coverage"; isModalInPresentation = true
        let duration = cue.map { $0.authoredDurationMs ?? $0.durationMs } ?? entry!.ownedDurationMs
        seconds.text = String(format: "%.3f", Double(duration) / 1000); seconds.keyboardType = .decimalPad; seconds.accessibilityLabel = "Duration, seconds"
        let help = cue == nil ? "Owned time adds space at this entry’s source. A direction’s forward coverage is separate and may continue over later dialogue. Zero owned time adds no scene time." : "This picture’s forward coverage follows its script source. Overlapping pictures and audio are preserved. Playback uses the latest-starting active picture."
        issue.textColor = .systemRed
        applyButton = ImageUI.button("Apply", primary: true) { [weak self] in self?.apply() }; applyButton.isEnabled = false
        let stack = ImageUI.scrollStack(in: self); [ImageUI.row([seconds, ImageUI.label("seconds", size: 12, secondary: true)]), ImageUI.label(help, size: 12, secondary: true), issue, ImageUI.divider(), ImageUI.row([ImageUI.spacer(), ImageUI.button("Cancel") { [weak self] in self?.dismiss(animated: true) }, applyButton])].forEach(stack.addArrangedSubview)
        leaseTask = Task { [weak self] in guard let self else { return }; let allowed = await self.store.beginEdit(self.itemID); guard !Task.isCancelled, self.contextIsCurrent else { if allowed { self.store.endEdit(self.itemID, context: self.initialNavigationContext) }; return }; self.ready = allowed; self.applyButton.isEnabled = allowed; if !allowed { self.issue.text = "This item’s editing lease is unavailable. Close and retry." } }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if isBeingDismissed || navigationController?.isBeingDismissed == true { leaseTask?.cancel(); if ready { store.endEdit(itemID, context: initialNavigationContext); ready = false } } }
    override func storeDidChange() { if isViewLoaded, !contextIsCurrent { dismiss(animated: true) } }
    private func apply() {
        guard requireCurrentContext(), ready, let value = Double(seconds.text ?? ""), value.isFinite, value >= (cue == nil ? 0 : 0.001), value <= (cue == nil ? 3600 : 86_400) else { issue.text = cue == nil ? "Enter a valid duration up to 3,600 seconds." : "Enter positive image coverage up to 86,400 seconds (24 hours)."; return }
        let ms = Int((value * 1000).rounded())
        if let cue {
            guard store.project.cues.first(where: { $0.id == cue.id }) == cue else { issue.text = "This picture changed. Close and reopen to review it."; return }
            if store.setCueDuration(cueId: cue.id, durationMs: ms) { dismiss(animated: true) } else { issue.text = store.errorMessage }
        } else if let entry {
            guard store.project.entries.first(where: { $0.id == entry.id }) == entry else { issue.text = "This entry changed. Close and reopen to review it."; return }
            store.setDuration(entry.id, seconds: value)
            if store.project.entries.first(where: { $0.id == entry.id })?.ownedDurationMs == ms { dismiss(animated: true) } else { issue.text = store.errorMessage ?? "The duration could not be applied." }
        }
    }
}
