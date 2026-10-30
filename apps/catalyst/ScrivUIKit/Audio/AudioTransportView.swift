import UIKit
import Combine
import ScrivCore

/// Shared native UIKit transport used by the workspace, preview and layers.
/// It controls the actual scene clock and imported local audio engine.
final class AudioTransportView: UIView {
    private let store: WorkspaceStore
    private let compact: Bool
    private let play = UIButton(type: .system), previous = UIButton(type: .system), nextButton = UIButton(type: .system), mute = UIButton(type: .system)
    private let time = ScrivUIKitTheme.label("", size: 12, weight: .medium, lines: 1)
    private let seek = UISlider(), volume = UISlider()
    private var subscription: AnyCancellable?
    private var refreshQueued = false
    init(store: WorkspaceStore, compact: Bool = false) {
        self.store = store; self.compact = compact; super.init(frame: .zero)
        backgroundColor = ScrivUIKitTheme.inset.withAlphaComponent(0.5); layer.cornerRadius = 11; layer.borderWidth = 0.5
        configureButton(previous, symbol: "backward.end.fill", label: "Previous image") { [weak self] in self?.previousImage() }
        configureButton(nextButton, symbol: "forward.end.fill", label: "Next image") { [weak self] in self?.nextImage() }
        configureButton(play, symbol: "play.fill", label: "Play scene") { [weak self] in self?.store.togglePlayback() }
        play.backgroundColor = ScrivUIKitTheme.accent; play.tintColor = .white; play.layer.cornerRadius = 20
        NSLayoutConstraint.activate([play.widthAnchor.constraint(equalToConstant: 40), play.heightAnchor.constraint(equalToConstant: 40)])
        configureButton(mute, symbol: "speaker.wave.2.fill", label: "Mute local audio") { [weak self] in self?.store.toggleAudioMute() }
        seek.minimumValue = 0; seek.tintColor = ScrivUIKitTheme.accent; seek.accessibilityLabel = "Playback position"
        seek.accessibilityIdentifier = "scene-playback-position"
        seek.addTarget(self, action: #selector(seekChanged), for: .valueChanged)
        volume.minimumValue = 0; volume.maximumValue = 1; volume.tintColor = ScrivUIKitTheme.accent
        volume.accessibilityLabel = "Local audio volume"; volume.addTarget(self, action: #selector(volumeChanged), for: .valueChanged)
        volume.widthAnchor.constraint(equalToConstant: compact ? 55 : 70).isActive = true
        time.font = .monospacedDigitSystemFont(ofSize: compact ? 11 : 12, weight: .medium)
        time.setContentHuggingPriority(.required, for: .horizontal)
        var views: [UIView] = [previous, play, nextButton]
        if !compact { views.append(time) }
        views.append(seek); if compact { views.append(time) }; views += [mute, volume]
        let row = AudioUIKitLayout.row(views, spacing: compact ? 8 : 10)
        addSubview(row); row.scrivPinEdges(to: self, insets: .init(top: 7, leading: 13, bottom: 7, trailing: 13))
        subscription = store.objectWillChange.sink { [weak self] _ in self?.queueRefresh() }
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func layoutSubviews() { super.layoutSubviews(); layer.borderColor = ScrivUIKitTheme.hairline.cgColor }
    private func configureButton(_ button: UIButton, symbol: String, label: String, action: @escaping () -> Void) {
        button.setImage(UIImage(systemName: symbol), for: .normal); button.accessibilityLabel = label
        button.tintColor = ScrivUIKitTheme.accent; button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 25).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
    }
    private func queueRefresh() {
        guard !refreshQueued else { return }; refreshQueued = true
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.refreshQueued = false; self.refresh() }
    }
    func refresh() {
        let duration = store.sceneDurationMs
        play.setImage(UIImage(systemName: store.isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        play.accessibilityLabel = store.isPlaying ? "Pause scene" : "Play scene"
        play.isEnabled = duration > 0; previous.isEnabled = duration > 0; nextButton.isEnabled = duration > 0
        seek.maximumValue = Float(max(1, duration)); seek.isEnabled = duration > 0
        if !seek.isTracking { seek.value = Float(min(Double(duration), max(0, store.playheadMs))) }
        let current = ScrivFormat.time(Int(store.playheadMs))
        time.text = compact ? current : current + " / " + ScrivFormat.time(duration)
        seek.accessibilityValue = current + " of " + ScrivFormat.time(duration)
        let hasAudio = !store.project.audioClips.isEmpty
        mute.isEnabled = hasAudio; volume.isEnabled = hasAudio
        let muted = store.project.audioVolume == 0
        mute.setImage(UIImage(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill"), for: .normal)
        mute.accessibilityLabel = muted ? "Unmute local audio" : "Mute local audio"
        mute.accessibilityHint = hasAudio ? "Affects all imported project audio." : "Import local audio to enable sound."
        if !volume.isTracking { volume.value = Float(store.project.audioVolume) }
        volume.accessibilityValue = "\(Int(store.project.audioVolume * 100)) percent"
    }
    @objc private func seekChanged() { store.seek(toMs: Double(seek.value)) }
    @objc private func volumeChanged() { store.setAudioVolume(Double(volume.value)) }
    private func previousImage() {
        let previous = store.sceneCues.map(\.startMs).filter { Double($0) < store.playheadMs - 100 }.last ?? 0
        store.seek(toMs: Double(previous))
    }
    private func nextImage() {
        let next = store.sceneCues.first { Double($0.startMs) > store.playheadMs + 100 }?.startMs ?? store.sceneDurationMs
        store.seek(toMs: Double(next))
    }
}

extension ScrivUIKitFeatures {
    static func registerAudio(in router: ScrivUIKitRouter) {
        router.register(.audio) { route, store in
            guard case .audio = route else { return nil }
            return AudioLibraryController(store: store)
        }
        router.register(.wordTiming) { route, store in
            guard case let .wordTiming(entryID, wordIDs) = route,
                  let entry = store.project.entries.first(where: { $0.id == entryID && $0.kind == .dialogue }),
                  let word = entry.words.first(where: { wordIDs.contains($0.id) }) ?? entry.words.first else { return nil }
            return WordTimingEditorController(store: store, entry: entry, word: word)
        }
    }
}
