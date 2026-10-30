import UIKit
import ScrivCore

final class AudioClipEditorController: ScrivScreenController {
    private var draft: AudioClipTimingDraft
    private let waveform = MeasuredAudioWaveformView()
    private let sourceField: AudioSecondsField
    private let durationField: AudioSecondsField
    private let offsetField = AudioSecondsField(title: nil, accessibilityName: "Placement offset", maximumMs: 86_400_000, identifier: "audio-placement-offset")
    private let offsetLabel = ScrivUIKitTheme.label("", size: 13)
    private let attachment = UIButton(type: .system)
    private let filename = ScrivUIKitTheme.label("", size: 14, weight: .medium, lines: 2)
    private let trimHint = ScrivUIKitTheme.label("", size: 11, color: ScrivUIKitTheme.secondary)
    private let placementHint = ScrivUIKitTheme.label("", size: 11, color: ScrivUIKitTheme.secondary)
    private let anchorHint = ScrivUIKitTheme.label("", size: 11, color: ScrivUIKitTheme.secondary)
    private let notice = AudioTimingNotice()
    init(store: WorkspaceStore, clip: AudioClip) {
        draft = AudioClipTimingDraft(clip: clip)
        let maximum = store.project.audioAssets.first { $0.id == clip.assetId }?.durationMs ?? AudioTimeline.maximumDurationMs
        sourceField = AudioSecondsField(title: "Source in", accessibilityName: "Source in", maximumMs: maximum, identifier: "audio-source-in")
        durationField = AudioSecondsField(title: "Duration", accessibilityName: "Audio duration", maximumMs: maximum, minimumMs: 1, identifier: "audio-duration")
        super.init(store: store); preferredContentSize = CGSize(width: 500, height: 470)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:clip:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.accessibilityIdentifier = "audio-trim-editor"
        sourceField.text = draft.source; durationField.text = draft.duration; offsetField.text = draft.offset
        sourceField.onChange = { [weak self] text in self?.draft.source = text; self?.refreshPreview() }
        durationField.onChange = { [weak self] text in self?.draft.duration = text; self?.refreshPreview() }
        offsetField.onChange = { [weak self] text in self?.draft.offset = text; self?.refreshPreview() }
        waveform.onTrimChanged = { [weak self] range in
            guard let self else { return }; self.draft.setTrim(range)
            self.sourceField.text = self.draft.source; self.durationField.text = self.draft.duration; self.refreshPreview()
        }
        waveform.heightAnchor.constraint(equalToConstant: 65).isActive = true
        let fields = AudioUIKitLayout.row([sourceField, durationField], spacing: 30); fields.distribution = .fillEqually
        fields.alignment = .top
        var config = UIButton.Configuration.plain(); config.image = UIImage(systemName: "chevron.down")
        config.imagePlacement = .trailing; config.imagePadding = 10; config.baseForegroundColor = ScrivUIKitTheme.ink
        config.contentInsets = .init(top: 8, leading: 10, bottom: 8, trailing: 10)
        config.background.strokeColor = ScrivUIKitTheme.hairline; config.background.strokeWidth = 0.8; config.background.cornerRadius = 7
        attachment.configuration = config; attachment.showsMenuAsPrimaryAction = true; attachment.contentHorizontalAlignment = .leading
        attachment.accessibilityIdentifier = "audio-anchor"
        attachment.titleLabel?.lineBreakMode = .byTruncatingTail
        let attachLabel = ScrivUIKitTheme.label("Attach to", size: 13)
        attachLabel.widthAnchor.constraint(equalToConstant: 140).isActive = true
        offsetLabel.widthAnchor.constraint(equalToConstant: 140).isActive = true
        offsetField.widthAnchor.constraint(equalToConstant: 165).isActive = true
        let attachRow = AudioUIKitLayout.row([attachLabel, attachment], spacing: 16)
        let offsetRow = AudioUIKitLayout.row([offsetLabel, offsetField, UIView()], spacing: 16)
        anchorHint.isHidden = true
        let cancel = ScrivUIKitTheme.button("Cancel") { [weak self] in self?.dismiss(animated: true) }
        let apply = ScrivUIKitTheme.button("Apply", primary: true) { [weak self] in self?.applyDraft() }
        apply.accessibilityIdentifier = "audio-apply"
        cancel.setContentHuggingPriority(.required, for: .horizontal); apply.setContentHuggingPriority(.required, for: .horizontal)
        let footer = AudioUIKitLayout.row([
            ScrivUIKitTheme.label("Trimming changes this clip, not the recording.", size: 11, color: ScrivUIKitTheme.secondary), cancel, apply
        ], spacing: 10)
        let content = ScrivUIKitTheme.stack([
            ScrivUIKitTheme.label("Trim & timing", size: 19, weight: .semibold), filename, waveform, trimHint, fields,
            AudioUIKitLayout.separator(), attachRow, offsetRow, anchorHint, placementHint, notice, footer
        ], spacing: 16)
        _ = AudioUIKitLayout.scrollContent(content, in: view)
        storeDidChange()
    }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        guard contextIsCurrent, store.selectedSceneID == draft.original.sceneId else { dismiss(animated: true); return }
        refreshPreview(); refreshAttachmentMenu()
    }
    private func refreshPreview() {
        guard isViewLoaded, let asset = store.project.audioAssets.first(where: { $0.id == draft.original.assetId }) else {
            if isViewLoaded { notice.show("The source recording metadata is no longer in this project. Cancel and reopen audio to review the current clips.") }; return
        }
        filename.text = asset.originalName; waveform.peaks = asset.waveform; waveform.sourceDurationMs = asset.durationMs
        let range = draft.trim(asset: asset); waveform.trim = range
        trimHint.isHidden = range != nil
        trimHint.text = "Enter valid source in and duration to show the trim."
        offsetLabel.text = draft.entryID == nil ? "Scene start" : "Offset from line"
        offsetField.textField.accessibilityLabel = (draft.entryID == nil ? "Scene start" : "Offset from line") + ", seconds"
        waveform.playheadMs = nil
        guard let range, let start = draft.sceneStart(project: store.project) else { placementHint.isHidden = true; return }
        let length = range.upperBound - range.lowerBound, end = start + length
        let relative = Int(store.playheadMs) - start
        if relative >= 0, relative < length { waveform.playheadMs = range.lowerBound + relative }
        let sceneDuration = store.project.durationMs(of: draft.original.sceneId)
        var text = "Source length: \(ScrivFormat.duration(asset.durationMs)) · Scene placement: \(ScrivFormat.time(start)) – \(ScrivFormat.time(end))"
        if start >= sceneDuration { text += "\nThis starts after the scene ends. Move it earlier or extend the scene to hear it." }
        else if end > sceneDuration { text += "\nPlayback stops at the scene’s end; the saved source trim is unchanged." }
        let unavailable = store.audioURL(asset) == nil
        if unavailable { text += "\nThe recording is unavailable on this Mac. Its saved timing can still be edited." }
        placementHint.text = text; placementHint.textColor = end > sceneDuration || unavailable ? .systemOrange : ScrivUIKitTheme.secondary
        placementHint.isHidden = false
    }
    private func refreshAttachmentMenu() {
        let entries = store.project.entries(in: draft.original.sceneId)
        var actions: [UIAction] = [UIAction(title: "Scene time", state: draft.entryID == nil ? .on : .off) { [weak self] _ in self?.attach(to: nil) }]
        for entry in entries {
            actions.append(UIAction(title: title(for: entry), state: draft.entryID == entry.id ? .on : .off) { [weak self] _ in self?.attach(to: entry.id) })
        }
        attachment.menu = UIMenu(children: actions)
        var config = attachment.configuration
        if let entry = entries.first(where: { $0.id == draft.entryID }) { config?.title = title(for: entry) }
        else { config?.title = "Scene time" }
        attachment.configuration = config
    }
    private func title(for entry: ScriptEntry) -> String {
        let name = store.project.characters.first { $0.id == entry.characterId }?.name ?? (entry.kind == .dialogue ? "Dialogue" : "Direction")
        return name + " · " + String(entry.text.prefix(50))
    }
    private func attach(to id: String?) {
        guard requireCurrentContext() else { return }
        do {
            let shifted = try draft.attach(to: id, project: store.project)
            offsetField.text = draft.offset
            anchorHint.text = "Moved to the start of this line; negative offsets are not supported."; anchorHint.isHidden = !shifted
            refreshAttachmentMenu(); refreshPreview()
        } catch { notice.show(error.localizedDescription) }
    }
    @objc private func applyDraft() {
        view.endEditing(true)
        guard requireCurrentContext(), store.selectedSceneID == draft.original.sceneId else { return }
        do {
            let clip = try draft.applying(to: store.project)
            if clip == draft.original { dismiss(animated: true); return }
            if store.updateAudioClip(clip) { dismiss(animated: true) }
            else { notice.show(store.errorMessage ?? "This clip could not be changed. Review its source and attachment, then try again.") }
        } catch { notice.show(error.localizedDescription) }
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelDraft)), UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(applyDraft))]
    }
    @objc private func cancelDraft() { dismiss(animated: true) }
}
