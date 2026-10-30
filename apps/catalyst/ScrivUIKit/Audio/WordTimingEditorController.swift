import UIKit
import ScrivCore

/// All selected-word edits remain a local draft until one atomic Save timing.
/// UIKit is the editor, not a host for a SwiftUI view.
final class WordTimingEditorController: ScrivScreenController {
    private var draft: ManualWordTimingDraft
    private let chips = UIStackView()
    private let chipScroll = UIScrollView()
    private var wordButtons: [String: UIButton] = [:]
    private let timeline = ManualWordTimelineView()
    private let startField: AudioSecondsField
    private let endField: AudioSecondsField
    private let notice = AudioTimingNotice()
    private let acquiring = UIActivityIndicatorView(style: .medium)
    private let leaseLabel = ScrivUIKitTheme.label("Acquiring edit lease…", size: 11, color: ScrivUIKitTheme.secondary)
    private var leaseRow: UIStackView!
    private var saveButton: UIButton!
    private var leaseTask: Task<Void, Never>?
    private var leaseHeld = false
    private var closed = false
    init(store: WorkspaceStore, entry: ScriptEntry, word: TimedWord) {
        draft = ManualWordTimingDraft(entry: entry, wordID: word.id)
        startField = AudioSecondsField(title: "Start", accessibilityName: "Word start", maximumMs: entry.ownedDurationMs, identifier: "word-timing-start")
        endField = AudioSecondsField(title: "End", accessibilityName: "Word end", maximumMs: entry.ownedDurationMs, minimumMs: 1, identifier: "word-timing-end")
        super.init(store: store); preferredContentSize = CGSize(width: 500, height: 410)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:entry:word:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.accessibilityIdentifier = "word-timing-editor"
        chips.axis = .horizontal; chips.spacing = 8; chips.alignment = .center
        chipScroll.addSubview(chips); chips.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.trailingAnchor),
            chips.topAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.topAnchor),
            chips.bottomAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.bottomAnchor),
            chips.heightAnchor.constraint(equalTo: chipScroll.frameLayoutGuide.heightAnchor),
            chipScroll.heightAnchor.constraint(equalToConstant: 45)
        ])
        for word in draft.original.words {
            let button = UIButton(type: .system)
            button.accessibilityIdentifier = "word-timing-chip-" + word.id
            button.accessibilityLabel = "Edit timing for “" + word.text + "”"
            button.addAction(UIAction { [weak self] _ in self?.selectWord(word.id) }, for: .primaryActionTriggered)
            wordButtons[word.id] = button; chips.addArrangedSubview(button)
        }
        timeline.durationMs = draft.original.ownedDurationMs; timeline.heightAnchor.constraint(equalToConstant: 70).isActive = true
        timeline.onSelect = { [weak self] id in self?.selectWord(id) }
        timeline.onRangeChanged = { [weak self] range in
            guard let self else { return }; self.draft.setSelectedRange(range); self.refreshFields(); self.refreshTimeline()
        }
        startField.onChange = { [weak self] value in self?.changeField(start: true, text: value) }
        endField.onChange = { [weak self] value in self?.changeField(start: false, text: value) }
        let fields = AudioUIKitLayout.row([startField, endField], spacing: 30); fields.distribution = .fillEqually; fields.alignment = .top
        let cancel = ScrivUIKitTheme.button("Cancel") { [weak self] in self?.cancelDraft() }
        saveButton = ScrivUIKitTheme.button("Save timing", primary: true) { [weak self] in self?.saveTiming() }
        saveButton.isEnabled = false; saveButton.accessibilityIdentifier = "word-timing-save"
        cancel.setContentHuggingPriority(.required, for: .horizontal); saveButton.setContentHuggingPriority(.required, for: .horizontal)
        let footerCopy = ScrivUIKitTheme.stack([
            ScrivUIKitTheme.label("Image cuts and audio stay unchanged.", size: 11),
            ScrivUIKitTheme.label("Manual timing, not automatic alignment.", size: 11, color: ScrivUIKitTheme.secondary)
        ], spacing: 5)
        leaseRow = AudioUIKitLayout.row([acquiring, leaseLabel, UIView()], spacing: 8); acquiring.startAnimating()
        let content = ScrivUIKitTheme.stack([
            ScrivUIKitTheme.label("Word timing", size: 19, weight: .semibold), chipScroll, timeline, fields,
            ScrivUIKitTheme.label("Relative to this dialogue · \(AudioTimingInput.seconds(draft.original.ownedDurationMs)) s", size: 11, color: ScrivUIKitTheme.secondary),
            notice, leaseRow, AudioUIKitLayout.separator(), AudioUIKitLayout.row([footerCopy, cancel, saveButton], spacing: 10)
        ], spacing: 18)
        _ = AudioUIKitLayout.scrollContent(content, in: view)
        refreshFields(); refreshButtons(); refreshTimeline(); acquireLease()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); revealSelectedWord() }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { releaseLease() }
    }
    override func storeDidChange() {
        guard isViewLoaded, !closed else { return }
        guard contextIsCurrent, store.selectedSceneID == draft.original.sceneId else { cancelDraft(); return }
        refreshTimeline()
        // Never replace active text with published data or a changing playhead.
        let current = store.project.entries.first { $0.id == draft.original.id }
        if current == nil { saveButton.isEnabled = false; notice.show("This dialogue was removed. Cancel to return to the current script; no draft timing was applied.") }
    }
    private func acquireLease() {
        leaseTask = Task { [weak self] in
            guard let self else { return }
            let allowed = await self.store.beginEdit(self.draft.original.id)
            guard !Task.isCancelled, !self.closed, self.contextIsCurrent, self.store.selectedSceneID == self.draft.original.sceneId else {
                if allowed { self.store.endEdit(self.draft.original.id, context: self.initialNavigationContext) }; return
            }
            self.leaseHeld = allowed; self.leaseRow.isHidden = true; self.acquiring.stopAnimating(); self.saveButton.isEnabled = allowed
            if !allowed { self.notice.show("This line cannot currently be edited. Close and retry when its edit lease is available.") }
        }
    }
    private func releaseLease() {
        guard !closed else { return }; closed = true; leaseTask?.cancel(); leaseTask = nil
        if leaseHeld { store.endEdit(draft.original.id, context: initialNavigationContext); leaseHeld = false }
    }
    private func selectWord(_ id: String) {
        guard draft.times[id] != nil else { return }
        view.endEditing(true); draft.selectedWordID = id
        refreshFields(); refreshButtons(); refreshTimeline(); revealSelectedWord()
    }
    private func revealSelectedWord() {
        guard let selected = wordButtons[draft.selectedWordID] else { return }
        view.layoutIfNeeded(); chipScroll.scrollRectToVisible(selected.convert(selected.bounds.insetBy(dx: -16, dy: 0), to: chips), animated: true)
    }
    private func refreshButtons() {
        for word in draft.original.words {
            guard let button = wordButtons[word.id] else { continue }
            let selected = word.id == draft.selectedWordID
            var config = UIButton.Configuration.filled(); config.title = word.text
            config.baseBackgroundColor = selected ? ScrivUIKitTheme.accent : ScrivUIKitTheme.inset
            config.baseForegroundColor = selected ? .white : ScrivUIKitTheme.ink
            config.contentInsets = .init(top: 9, leading: 14, bottom: 9, trailing: 14)
            config.background.cornerRadius = 7; config.cornerStyle = .fixed
            button.configuration = config; button.accessibilityTraits = selected ? [.button, .selected] : [.button]
        }
    }
    private func refreshFields() {
        guard let values = draft.times[draft.selectedWordID], let word = draft.original.words.first(where: { $0.id == draft.selectedWordID }) else { return }
        startField.text = values.start; endField.text = values.end
        startField.textField.accessibilityLabel = "Start of “" + word.text + "”, seconds"
        endField.textField.accessibilityLabel = "End of “" + word.text + "”, seconds"
    }
    private func changeField(start: Bool, text: String) {
        guard var values = draft.times[draft.selectedWordID] else { return }
        if start { values.start = text } else { values.end = text }
        draft.times[draft.selectedWordID] = values; refreshTimeline()
    }
    private func refreshTimeline() {
        timeline.words = draft.previewWords; timeline.selectedID = draft.selectedWordID
        let elapsed = Int(store.playheadMs) - store.project.startMs(of: draft.original.id)
        timeline.playheadMs = (0...draft.original.ownedDurationMs).contains(elapsed) ? elapsed : nil
    }
    @objc private func saveTiming() {
        view.endEditing(true)
        guard leaseHeld, !closed, requireCurrentContext(), store.selectedSceneID == draft.original.sceneId else { return }
        guard let current = store.project.entries.first(where: { $0.id == draft.original.id }) else { notice.show("This dialogue was removed. Cancel and reopen timing for a current line."); return }
        do {
            let updated = try draft.updatedWords(current: current)
            if updated == current.words { cancelDraft(); return }
            if store.setWordTimings(entryId: current.id, expectedWords: draft.original.words, expectedDurationMs: draft.original.ownedDurationMs, updatedWords: updated) { cancelDraft() }
            else { notice.show(store.errorMessage ?? "Timing could not be changed. Keep words in source order without overlaps, then try again.") }
        } catch { notice.show(error.localizedDescription) }
    }
    @objc private func cancelDraft() { releaseLease(); dismiss(animated: true) }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelDraft)), UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(saveTiming))]
    }
}
