import UIKit
import ScrivCore

@MainActor final class CueAnchorViewController: ScrivScreenController {
    private let original: ImageCue
    private var entryID: String
    private let offset = ImageUI.field()
    private let stepper = UIStepper()
    private let source = ImageUI.button("Choose an entry…") {}
    private let quote = ImageUI.text("")
    private let offsetHelp = ImageUI.label(size: 11, secondary: true)
    private let issue = ImageUI.label(size: 12)
    private var saveButton: UIButton!
    private var content: UIStackView!
    private var leaseTask: Task<Void, Never>?
    private var ready = false
    private var closed = false
    init(store: WorkspaceStore, cue: ImageCue) {
        original = cue; entryID = cue.startAnchor?.entryId ?? ""; super.init(store: store)
        offset.text = String(format: "%.3f", Double(cue.startAnchor?.offsetMs ?? 0) / 1000)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:cue:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Picture source"; isModalInPresentation = true; navigationController?.setNavigationBarHidden(true, animated: false); view.backgroundColor = ScrivUIKitTheme.panel
        content = ImageUI.scrollStack(in: self, spacing: 12, padding: 24); content.addArrangedSubview(ImageUI.label("Picture source", size: 25, weight: .semibold)); content.addArrangedSubview(ImageUI.label(original.label.isEmpty ? "Image placement" : original.label, size: 14, secondary: true))
        if let image = store.project.asset(original.imageId) {
            let picture = UIKitAssetImageView(); picture.configure(url: store.assetURL(image), title: original.label, missingText: "Not on this Mac")
            picture.heightAnchor.constraint(equalToConstant: 116).isActive = true; picture.widthAnchor.constraint(equalToConstant: 220).isActive = true; picture.layer.cornerRadius = 8; content.addArrangedSubview(ImageUI.row([picture, ImageUI.spacer()]))
        }
        content.addArrangedSubview(ImageUI.label("Follow this script entry", size: 16, weight: .regular)); source.showsMenuAsPrimaryAction = true; source.configuration?.image = UIImage(systemName: "chevron.down"); source.configuration?.imagePlacement = .trailing; source.contentHorizontalAlignment = .leading; source.configuration?.titleLineBreakMode = .byTruncatingTail; content.addArrangedSubview(source)
        let quoteCard = ImageUI.card(quote, padding: 14); quoteCard.backgroundColor = ScrivUIKitTheme.inset; content.addArrangedSubview(quoteCard); content.addArrangedSubview(ImageUI.label("Offset from entry", size: 16, weight: .regular))
        offset.widthAnchor.constraint(equalToConstant: 108).isActive = true; offset.keyboardType = .decimalPad; offset.accessibilityLabel = "Offset from entry, seconds"
        offset.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.synchronizeOffsetStepper()
            self.issue.text = nil; self.issue.isHidden = true
        }, for: .editingChanged)
        stepper.minimumValue = 0; stepper.stepValue = 0.001; stepper.accessibilityLabel = "Adjust source offset"
        stepper.addAction(UIAction { [weak self] _ in guard let self else { return }; self.offset.text = String(format: "%.3f", self.stepper.value); self.issue.text = nil; self.issue.isHidden = true }, for: .valueChanged)
        content.addArrangedSubview(ImageUI.row([offset, stepper, ImageUI.badge("seconds"), ImageUI.spacer()])); content.addArrangedSubview(offsetHelp)
        content.addArrangedSubview(ImageUI.divider()); content.addArrangedSubview(ImageUI.label("Forward coverage", size: 16, weight: .semibold)); content.addArrangedSubview(ImageUI.label(ScrivFormat.duration(original.authoredDurationMs ?? original.durationMs), size: 18, weight: .semibold))
        content.addArrangedSubview(ImageUI.notice("Moves with its source. Other pictures and audio stay unchanged."))
        issue.textColor = .systemRed; issue.isHidden = true; content.addArrangedSubview(issue)
        saveButton = ImageUI.button("Save source", primary: true) { [weak self] in self?.save() }
        content.addArrangedSubview(ImageUI.row([ImageUI.spacer(), ImageUI.button("Cancel") { [weak self] in self?.dismiss(animated: true) }, saveButton]))
        storeDidChange()
        leaseTask = Task { [weak self] in
            guard let self else { return }; let allowed = await self.store.beginEdit(self.original.id)
            guard !Task.isCancelled, !self.closed, self.contextIsCurrent, self.store.selectedSceneID == self.original.sceneId else { if allowed { self.store.endEdit(self.original.id, context: self.initialNavigationContext) }; return }
            self.ready = allowed; self.saveButton.isEnabled = allowed && self.entry != nil
            if !allowed { self.issue.isHidden = false; self.issue.text = "This picture cannot currently be edited. Close and retry when its editing lease is available." }
        }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if isBeingDismissed || navigationController?.isBeingDismissed == true { closed = true; leaseTask?.cancel(); if ready { store.endEdit(original.id, context: initialNavigationContext); ready = false } } }
    private var entry: ScriptEntry? { store.project.entries.first { $0.id == entryID && $0.sceneId == original.sceneId } }
    override func storeDidChange() {
        guard isViewLoaded, saveButton != nil else { return }
        guard contextIsCurrent, store.selectedSceneID == original.sceneId else { dismiss(animated: true); return }
        source.menu = UIMenu(children: store.project.entries(in: original.sceneId).map { candidate in
            UIAction(title: Self.entryLabel(candidate, project: store.project), state: candidate.id == entryID ? .on : .off) { [weak self] _ in
                guard let self else { return }; self.entryID = candidate.id; self.offset.text = "0.000"; self.issue.text = nil; self.issue.isHidden = true; self.storeDidChange()
            }
        })
        source.configuration?.title = entry.map { Self.entryLabel($0, project: store.project) } ?? "Choose an entry…"
        ImageUI.scriptFont(source, size: store.scriptFontSize * 1.1)
        quote.font = .systemFont(ofSize: store.scriptFontSize); quote.invalidateIntrinsicContentSize()
        quote.text = entry?.text ?? "Choose the dialogue or direction this picture belongs to."
        offset.isEnabled = entry?.ownedDurationMs ?? 0 > 0; stepper.isEnabled = offset.isEnabled
        stepper.maximumValue = Double(max(0, (entry?.ownedDurationMs ?? 0) - 1)) / 1000
        synchronizeOffsetStepper()
        offsetHelp.text = entry.map { $0.ownedDurationMs == 0 ? "This zero-owned direction starts at its authored position; its offset is 0." : "Within this entry’s \(ScrivFormat.duration($0.ownedDurationMs)) owned slot." }
        saveButton.isEnabled = ready && entry != nil
    }
    private func synchronizeOffsetStepper() {
        // Text edits are local drafts and do not publish through the store.
        // Keep +/- based on the displayed draft without replacing typed text.
        guard let seconds = Double(offset.text ?? ""), seconds.isFinite else { return }
        stepper.value = min(stepper.maximumValue, max(stepper.minimumValue, seconds))
    }
    private func save() {
        view.endEditing(true)
        guard requireCurrentContext(), ready, let entry, let current = store.project.cues.first(where: { $0.id == original.id }) else { return }
        guard current == original else { issue.isHidden = false; issue.text = "This placement changed. Close and reopen the editor to review its current source."; return }
        guard let seconds = Double(offset.text ?? ""), seconds.isFinite, seconds >= 0, seconds <= Double(entry.ownedDurationMs) / 1000 else { issue.isHidden = false; issue.text = "Enter an offset inside the selected source’s owned slot."; return }
        let ms = Int((seconds * 1000).rounded())
        guard ms < entry.ownedDurationMs || entry.kind == .direction && entry.ownedDurationMs == 0 && ms == 0 else { issue.isHidden = false; issue.text = "Offset must be before the source’s end; zero-owned directions use 0."; return }
        if current.startAnchor == ScriptTimeAnchor(entryId: entry.id, offsetMs: ms) { dismiss(animated: true); return }
        if store.setCueAnchor(cueId: current.id, entryId: entry.id, offsetMs: ms) { dismiss(animated: true) }
        else { issue.isHidden = false; issue.text = store.errorMessage ?? "This source cannot own the placement at that offset." }
    }
    static func entryLabel(_ entry: ScriptEntry, project: ScrivProject) -> String {
        (entry.kind == .direction ? "Direction" : project.character(entry.characterId)?.name ?? "Dialogue") + " · " + (entry.text.isEmpty ? "Untitled entry" : String(entry.text.prefix(100)))
    }
}
