import UIKit
import UniformTypeIdentifiers
import ScrivCore

final class AudioLibraryController: ScrivScreenController, UIDocumentPickerDelegate {
    private let sceneID: String
    private let content = ScrivUIKitTheme.stack(spacing: 16)
    private let cards = ScrivUIKitTheme.stack(spacing: 13)
    private let sceneLabel = ScrivUIKitTheme.label("", size: 13, color: ScrivUIKitTheme.secondary)
    private let statusLabel = ScrivUIKitTheme.label("", size: 11, color: ScrivUIKitTheme.secondary)
    private let importButton = UIButton(type: .system)
    private let empty = ScrivUIKitTheme.notice("Add a recording or soundtrack", message: "Import audio for this scene or a selected dialogue line. Real recordings stay local; importing does not transcribe or retime words.")
    private var cardViews: [String: AudioClipCardView] = [:]
    private var visibleIDs: [String] = []
    private var selectedClipID: String?
    private var importEntryID: String?
    private var isImporting = false
    private var importTask: Task<Void, Never>?

    override init(store: WorkspaceStore, scopeToProject: Bool = true) {
        sceneID = store.selectedSceneID; super.init(store: store, scopeToProject: scopeToProject)
        preferredContentSize = CGSize(width: 780, height: 680)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.accessibilityIdentifier = "local-audio-sheet"
        var configuration = UIButton.Configuration.filled(); configuration.title = "Import audio"
        configuration.image = UIImage(systemName: "chevron.down"); configuration.imagePlacement = .trailing; configuration.imagePadding = 10
        configuration.baseBackgroundColor = ScrivUIKitTheme.accent; configuration.cornerStyle = .medium
        configuration.contentInsets = .init(top: 11, leading: 16, bottom: 11, trailing: 16)
        importButton.configuration = configuration; importButton.showsMenuAsPrimaryAction = true
        importButton.accessibilityIdentifier = "audio-import-menu"
        importButton.setContentHuggingPriority(.required, for: .horizontal)
        let close = AudioUIKitLayout.symbolButton("xmark", label: "Close local audio") { [weak self] in self?.dismiss(animated: true) }
        let title = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Local audio", size: 22, weight: .semibold), sceneLabel], spacing: 7)
        content.addArrangedSubview(AudioUIKitLayout.row([title, importButton, close], spacing: 16))
        content.addArrangedSubview(AudioUIKitLayout.separator())
        let lock = UIImageView(image: UIImage(systemName: "lock.fill")); lock.tintColor = ScrivUIKitTheme.secondary
        lock.contentMode = .scaleAspectFit; lock.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let local = ScrivUIKitTheme.card(AudioUIKitLayout.row([lock, ScrivUIKitTheme.label("Stored in this project on this Mac · Not shared", size: 13, color: ScrivUIKitTheme.secondary)], spacing: 10), padding: 14)
        local.backgroundColor = ScrivUIKitTheme.inset
        content.addArrangedSubview(local); content.addArrangedSubview(empty); content.addArrangedSubview(cards)
        content.addArrangedSubview(statusLabel); content.addArrangedSubview(AudioUIKitLayout.separator())
        content.addArrangedSubview(ScrivUIKitTheme.label("ⓘ  Dialogue audio follows its line. Scene audio stays at its scene time.", size: 12, color: ScrivUIKitTheme.secondary))
        _ = AudioUIKitLayout.scrollContent(content, in: view)
        storeDidChange()
    }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        guard contextIsCurrent, sceneID == store.selectedSceneID else { dismiss(animated: true); return }
        sceneLabel.text = store.project.title + " · " + (store.project.scenes.first { $0.id == sceneID }?.title ?? "Scene")
        let clips = store.project.audioClips.filter { $0.sceneId == sceneID }
        let ids = clips.map(\.id)
        if selectedClipID == nil || !ids.contains(selectedClipID ?? "") { selectedClipID = ids.first }
        if ids != visibleIDs {
            cards.arrangedSubviews.forEach { cards.removeArrangedSubview($0); $0.removeFromSuperview() }
            cardViews = cardViews.filter { ids.contains($0.key) }
            for clip in clips {
                let card = cardViews[clip.id] ?? makeCard(id: clip.id)
                cardViews[clip.id] = card; cards.addArrangedSubview(card)
            }
            visibleIDs = ids
        }
        let placements = AudioTimeline.placements(project: store.project, sceneId: sceneID)
        for clip in clips {
            guard let asset = store.project.audioAssets.first(where: { $0.id == clip.assetId }) else { continue }
            let placement = placements.first { $0.clipId == clip.id }
            cardViews[clip.id]?.configure(clip: clip, asset: asset, placement: placement, project: store.project,
                available: store.audioURL(asset) != nil, selected: selectedClipID == clip.id,
                playheadMs: store.playheadMs, isPlaying: store.isPlaying)
        }
        empty.isHidden = !clips.isEmpty; cards.isHidden = clips.isEmpty
        statusLabel.text = store.audioStatus; statusLabel.isHidden = store.audioStatus.isEmpty
        importButton.isEnabled = !isImporting
        var actions: [UIAction] = [UIAction(title: "Import scene audio…", image: UIImage(systemName: "waveform")) { [weak self] _ in self?.chooseAudio(entryID: nil) }]
        if let entry = store.selectedEntry, entry.sceneId == sceneID, entry.kind == .dialogue {
            actions.append(UIAction(title: "Import audio for selected dialogue…", image: UIImage(systemName: "quote.bubble")) { [weak self] _ in self?.chooseAudio(entryID: entry.id) })
        }
        importButton.menu = UIMenu(children: actions)
    }
    private func makeCard(id: String) -> AudioClipCardView {
        let card = AudioClipCardView()
        card.onSelect = { [weak self] in self?.selectedClipID = id; self?.storeDidChange() }
        card.onPlay = { [weak self] in self?.play(id: id) }
        card.onTrim = { [weak self] in
            guard let self, self.requireCurrentContext(), self.sceneID == self.store.selectedSceneID, let clip = self.store.project.audioClips.first(where: { $0.id == id }) else { return }
            self.selectedClipID = id
            let editor = AudioClipEditorController(store: self.store, clip: clip); editor.modalPresentationStyle = .formSheet
            self.present(editor, animated: true)
        }
        card.onVolume = { [weak self] value in self?.update(id: id) { $0.volume = value } }
        card.onMute = { [weak self] in self?.update(id: id) { $0.isMuted.toggle() } }
        card.onRemove = { [weak self] in self?.confirmRemove(id: id) }
        return card
    }
    private func update(id: String, _ change: (inout AudioClip) -> Void) {
        guard requireCurrentContext(), sceneID == store.selectedSceneID, var clip = store.project.audioClips.first(where: { $0.id == id }) else { return }
        change(&clip); _ = store.updateAudioClip(clip)
    }
    private func play(id: String) {
        guard requireCurrentContext(), sceneID == store.selectedSceneID, let clip = store.project.audioClips.first(where: { $0.id == id }),
              let asset = store.project.audioAssets.first(where: { $0.id == clip.assetId }), store.audioURL(asset) != nil,
              let placement = AudioTimeline.placements(project: store.project, sceneId: sceneID).first(where: { $0.clipId == id }) else { return }
        selectedClipID = id
        if store.isPlaying, placement.sourcePosition(at: Int(store.playheadMs)) != nil { store.togglePlayback() }
        else { store.seek(toMs: Double(placement.startMs)); if !store.isPlaying { store.togglePlayback() } }
    }
    private func confirmRemove(id: String) {
        guard requireCurrentContext() else { return }
        let alert = UIAlertController(title: "Remove this audio clip?", message: "This removes the placement, not the original recording or script text.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove clip", style: .destructive) { [weak self] _ in
            guard let self, self.requireCurrentContext(), self.sceneID == self.store.selectedSceneID else { return }
            self.store.deleteAudioClip(id)
        })
        present(alert, animated: true)
    }
    private func chooseAudio(entryID: String?) {
        guard requireCurrentContext(), sceneID == store.selectedSceneID, !isImporting else { return }
        importEntryID = entryID
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: false)
        picker.allowsMultipleSelection = false; picker.delegate = self
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard requireCurrentContext(), sceneID == store.selectedSceneID, !isImporting, let url = urls.first else { return }
        let entryID = importEntryID; importEntryID = nil; isImporting = true; storeDidChange()
        importTask = Task { [weak self] in
            guard let self else { return }
            guard self.contextIsCurrent, self.store.selectedSceneID == self.sceneID else {
                self.isImporting = false; self.importTask = nil; return
            }
            // Store owns the security scope and captures project/scene identity
            // before decoding. Closing this sheet does not abandon a valid import.
            _ = await self.store.importAudio(from: url, entryId: entryID)
            self.isImporting = false; self.importTask = nil
            if self.isViewLoaded { self.storeDidChange() }
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { importEntryID = nil }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeAudio))]
    }
    @objc private func closeAudio() { dismiss(animated: true) }
}

private final class AudioClipCardView: UIView {
    var onSelect: (() -> Void)?; var onPlay: (() -> Void)?; var onTrim: (() -> Void)?
    var onVolume: ((Double) -> Void)?; var onMute: (() -> Void)?; var onRemove: (() -> Void)?
    private let nameLabel = ScrivUIKitTheme.label("", size: 17, weight: .semibold, lines: 2)
    private let badge = ScrivUIKitTheme.label("", size: 11, lines: 2)
    private let badgeContainer = UIView()
    private let waveform = MeasuredAudioWaveformView()
    private let timeLabel = ScrivUIKitTheme.label("", size: 13, lines: 1)
    private let warning = ScrivUIKitTheme.label("", size: 11, color: .systemOrange)
    private let play = UIButton(type: .system), mute = UIButton(type: .system), more = UIButton(type: .system)
    private let volume = UISlider()
    private var trimButton: UIButton!
    private var isSelectedCard = false
    init() {
        super.init(frame: .zero)
        layer.cornerRadius = 12; layer.borderWidth = 0.7
        let fileIcon = UIImageView(image: UIImage(systemName: "waveform")); fileIcon.tintColor = ScrivUIKitTheme.accent; fileIcon.contentMode = .scaleAspectFit
        let iconBox = UIView(); iconBox.backgroundColor = ScrivUIKitTheme.panel; iconBox.layer.cornerRadius = 6
        iconBox.addSubview(fileIcon); fileIcon.scrivPinEdges(to: iconBox, insets: .init(top: 12, leading: 8, bottom: 12, trailing: 8))
        NSLayoutConstraint.activate([iconBox.widthAnchor.constraint(equalToConstant: 40), iconBox.heightAnchor.constraint(equalToConstant: 48)])
        badgeContainer.layer.cornerRadius = 13; badgeContainer.addSubview(badge)
        badge.scrivPinEdges(to: badgeContainer, insets: .init(top: 5, leading: 10, bottom: 5, trailing: 10))
        badgeContainer.setContentHuggingPriority(.required, for: .horizontal)
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal); more.showsMenuAsPrimaryAction = true
        NSLayoutConstraint.activate([more.widthAnchor.constraint(equalToConstant: 32), more.heightAnchor.constraint(equalToConstant: 32)])
        let titleRow = AudioUIKitLayout.row([nameLabel, badgeContainer, more], spacing: 10)
        play.backgroundColor = ScrivUIKitTheme.accent; play.tintColor = .white; play.layer.cornerRadius = 22
        play.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .primaryActionTriggered)
        NSLayoutConstraint.activate([play.widthAnchor.constraint(equalToConstant: 44), play.heightAnchor.constraint(equalToConstant: 44), waveform.heightAnchor.constraint(equalToConstant: 42)])
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        let playback = AudioUIKitLayout.row([play, waveform, timeLabel], spacing: 16)
        volume.minimumValue = 0; volume.maximumValue = 1; volume.tintColor = ScrivUIKitTheme.accent
        volume.addTarget(self, action: #selector(volumeChanged), for: .valueChanged)
        volume.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
        volume.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        let speaker = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill")); speaker.tintColor = ScrivUIKitTheme.secondary; speaker.contentMode = .scaleAspectFit
        speaker.widthAnchor.constraint(equalToConstant: 21).isActive = true
        mute.tintColor = ScrivUIKitTheme.secondary
        mute.addAction(UIAction { [weak self] _ in self?.onMute?() }, for: .primaryActionTriggered)
        mute.widthAnchor.constraint(equalToConstant: 30).isActive = true
        trimButton = ScrivUIKitTheme.button("Trim & timing") { [weak self] in self?.onTrim?() }
        trimButton.setContentHuggingPriority(.required, for: .horizontal)
        let volumeRow = AudioUIKitLayout.row([speaker, volume, mute, UIView(), trimButton], spacing: 12)
        let details = ScrivUIKitTheme.stack([titleRow, playback, volumeRow, warning], spacing: 16)
        let row = AudioUIKitLayout.row([iconBox, details], spacing: 16); row.alignment = .top
        addSubview(row); row.scrivPinEdges(to: self, insets: .init(top: 18, leading: 18, bottom: 18, trailing: 18))
        let tap = UITapGestureRecognizer(target: self, action: #selector(selected)); tap.cancelsTouchesInView = false; addGestureRecognizer(tap)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init") }
    override func layoutSubviews() { super.layoutSubviews(); layer.borderColor = (isSelectedCard ? ScrivUIKitTheme.accent.withAlphaComponent(0.22) : ScrivUIKitTheme.hairline).cgColor }
    func configure(clip: AudioClip, asset: AudioAsset, placement: AudioPlacement?, project: ScrivProject, available: Bool, selected: Bool, playheadMs: Double, isPlaying: Bool) {
        nameLabel.text = asset.originalName; isSelectedCard = selected
        backgroundColor = selected ? ScrivUIKitTheme.accent.withAlphaComponent(0.075) : ScrivUIKitTheme.panel
        if let entry = project.entries.first(where: { $0.id == clip.entryId }) {
            if let character = project.characters.first(where: { $0.id == entry.characterId }), entry.kind == .dialogue { badge.text = "Follows \(character.name)’s dialogue" }
            else { badge.text = entry.kind == .dialogue ? "Follows dialogue" : "Follows direction" }
        } else { badge.text = "Scene track" }
        badgeContainer.backgroundColor = clip.entryId == nil ? ScrivUIKitTheme.inset : UIColor.systemPurple.withAlphaComponent(0.12)
        let active = isPlaying && placement?.sourcePosition(at: Int(playheadMs)) != nil
        play.setImage(UIImage(systemName: active ? "pause.fill" : "play.fill"), for: .normal)
        play.isEnabled = available && placement != nil; play.alpha = play.isEnabled ? 1 : 0.4
        play.accessibilityLabel = active ? "Pause scene playback" : "Play scene from " + asset.originalName
        play.accessibilityHint = "Overlapping scene audio plays together."
        play.accessibilityIdentifier = "audio-clip-play-" + clip.id
        trimButton.accessibilityIdentifier = "audio-clip-trim-" + clip.id
        if let placement {
            waveform.peaks = AudioTimeline.waveform(for: placement, asset: asset)
            waveform.sourceDurationMs = placement.durationMs
            waveform.playedFraction = (playheadMs - Double(placement.startMs)) / Double(max(1, placement.durationMs))
            timeLabel.text = "\(ScrivFormat.time(placement.startMs)) – \(ScrivFormat.time(placement.endMs))"
        } else { waveform.peaks = []; timeLabel.text = "Outside scene" }
        waveform.muted = clip.isMuted
        if !volume.isTracking { volume.value = Float(clip.volume) }
        volume.accessibilityLabel = "Clip volume for " + asset.originalName
        volume.accessibilityValue = "\(Int(clip.volume * 100)) percent"
        mute.setImage(UIImage(systemName: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill"), for: .normal)
        mute.accessibilityLabel = (clip.isMuted ? "Unmute " : "Mute ") + asset.originalName
        var issues: [String] = []
        if !available { issues.append("Audio file unavailable on this Mac. Restore the recording in this project package, or import it again.") }
        if placement == nil { issues.append("This placement is outside the scene’s current duration. Adjust timing to hear it.") }
        warning.text = issues.joined(separator: "\n"); warning.isHidden = issues.isEmpty
        more.accessibilityLabel = "Audio options for " + asset.originalName
        more.menu = UIMenu(children: [
            UIAction(title: "Trim & timing…") { [weak self] _ in self?.onTrim?() },
            UIAction(title: clip.isMuted ? "Unmute clip" : "Mute clip") { [weak self] _ in self?.onMute?() },
            UIAction(title: "Remove clip…", attributes: .destructive) { [weak self] _ in self?.onRemove?() }
        ])
        setNeedsLayout()
    }
    @objc private func volumeChanged() { onVolume?(Double(volume.value)) }
    @objc private func selected() { onSelect?() }
}
