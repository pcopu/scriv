import UIKit
import ScrivCore

@MainActor final class LayerTimelineViewController: ScrivScreenController, UIScrollViewDelegate {
    private let scroll = UIScrollView(), canvas = UIView(), playhead = UIView()
    private let zoom = UISlider(), overview = UISlider(), snap = UISwitch()
    private var scale: CGFloat = 0.04
    private var signature = ""
    private var canvasHeight: CGFloat = 240
    private var lastFollowedCue: String?
    private var dragInProgress = false
    private var imageButtons: [String: UIButton] = [:]
    private var timingDrivers: [ImageTimelineManipulationDriver] = []
    private let expanded: Bool
    init(store: WorkspaceStore, expanded: Bool = false) { self.expanded = expanded; super.init(store: store, scopeToProject: false) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Layers"; view.backgroundColor = .clear
        zoom.minimumValue = 0.3; zoom.maximumValue = 2.5; zoom.value = 1; zoom.accessibilityLabel = "Timeline zoom"; zoom.widthAnchor.constraint(equalToConstant: 85).isActive = true
        zoom.addAction(UIAction { [weak self] _ in self?.signature = ""; self?.storeDidChange() }, for: .valueChanged)
        snap.isOn = true; snap.accessibilityLabel = "Snap to words"; snap.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        let audio = ImageUI.button("Audio", symbol: "waveform") { [weak self] in self?.show(.audio) }
        let titleRow = ImageUI.row([ImageUI.label("Layers", size: 17, weight: .semibold), audio, ImageUI.spacer(), ImageUI.label("Snap", size: 10), snap, zoom], spacing: 4)
        if !expanded { titleRow.addArrangedSubview(ImageUI.button("Expand", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in guard let self else { return }; let controller = LayerTimelineViewController(store: self.store, expanded: true); ImageUI.closeButton(controller); ImageUI.present(controller, from: self, size: CGSize(width: 1100, height: 570)) }) }
        scroll.delegate = self; scroll.alwaysBounceHorizontal = true; scroll.alwaysBounceVertical = true; scroll.backgroundColor = ScrivUIKitTheme.inset.withAlphaComponent(0.5); scroll.layer.cornerRadius = 10
        scroll.addSubview(canvas); playhead.backgroundColor = ImageUI.accent; playhead.isUserInteractionEnabled = false
        overview.minimumValue = 0; overview.maximumValue = 1; overview.accessibilityLabel = "Scene overview position"
        overview.addAction(UIAction { [weak self] _ in guard let self else { return }; self.store.seek(toMs: Double(self.overview.value) * Double(self.store.sceneDurationMs)) }, for: .valueChanged)
        let help = ImageUI.label("Drag a picture to offset within its source. Lower right edge: coverage. Upper cut grip: shared cut. Shift: no snap. Change source: picture menu.", size: 10, secondary: true)
        let stack = ImageUI.stack([titleRow, scroll, overview, help], spacing: 7); ImageUI.pinToSafeArea(stack, in: self)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let seek = UITapGestureRecognizer(target: self, action: #selector(seekCanvas(_:))); seek.cancelsTouchesInView = false; canvas.addGestureRecognizer(seek)
        storeDidChange()
    }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        if timingDrivers.contains(where: { $0.isActive && !$0.sourceIsCurrent }) { timingDrivers.forEach { $0.cancel() }; return }
        scale = min(0.04 * CGFloat(zoom.value), 30_000 / CGFloat(max(1, store.sceneDurationMs)))
        let next = "\(store.navigationContext)|\(store.selectedSceneID)|\(store.project.revision)|\(store.sceneCues)|\(store.sceneEntries)|\(store.project.audioClips)|\(store.project.audioAssets)|\(store.project.images)|\(scale)|\(store.scriptZoom)|\(store.peerTransferStatus)"
        if signature != next, !dragInProgress { signature = next; rebuild() }
        for (id, button) in imageButtons {
            button.layer.borderColor = ImageUI.accent.cgColor
            button.layer.borderWidth = id == store.selectedCueID ? 2.5 : id == store.currentCue?.id ? 1 : 0
            button.accessibilityTraits = id == store.selectedCueID ? [.button, .selected] : .button
        }
        playhead.frame = CGRect(x: 70 + CGFloat(store.playheadMs) * scale, y: 22, width: 1.5, height: max(0, canvasHeight - 22))
        if !overview.isTracking { overview.value = Float(store.playheadMs / Double(max(1, store.sceneDurationMs))) }
        let cue = store.isPlaying ? store.currentCue : store.selectedCue
        if cue?.id != lastFollowedCue, (!store.isPlaying || store.followPlayback), !scroll.isDragging, !dragInProgress {
            lastFollowedCue = cue?.id
            if let cue { scroll.scrollRectToVisible(CGRect(x: 70 + CGFloat(cue.startMs) * scale, y: 22, width: max(20, CGFloat(cue.durationMs) * scale), height: 60), animated: !store.isPlaying) }
        }
    }
    private func rebuild() {
        dragDrivers.removeAll(); timingDrivers.removeAll(); imageButtons.removeAll()
        canvas.subviews.forEach { $0.removeFromSuperview() }
        let navigation = store.navigationContext
        let width = max(400, CGFloat(store.sceneDurationMs) * scale) + 80
        let imageRows = UIKitImageContext.imageLanes(store.sceneCues)
        let imageHeight = CGFloat((imageRows.map(\.lane).max() ?? 0) + 1) * 60
        var directionEnds: [Int] = [], directions: [(ScriptEntry, Int)] = []
        for entry in store.sceneEntries where entry.kind == .direction {
            let start = store.project.startMs(of: entry.id), end = start + entry.coverageDurationMs
            let lane = directionEnds.firstIndex { $0 <= start } ?? directionEnds.count
            if lane == directionEnds.count { directionEnds.append(end) } else { directionEnds[lane] = end }; directions.append((entry, lane))
        }
        let dialogueHeight = max(CGFloat(42), store.scriptFontSize * 2.5 + 10)
        let directionHeight = max(CGFloat(48), store.scriptFontSize * 2.5 + 10)
        let wordHeight = max(CGFloat(32), store.scriptFontSize * 1.5 + 8)
        let dialogueY = 26 + imageHeight + 5, directionY = dialogueY + dialogueHeight + 5
        let wordY = directionY + CGFloat(max(1, directionEnds.count)) * (directionHeight + 4) + 5, audioY = wordY + wordHeight + 7
        let audio = AudioTimeline.placements(project: store.project, sceneId: store.selectedSceneID).filter { placement in store.project.audioClips.first { $0.id == placement.clipId }?.entryId == nil }
        var audioEnds: [Int] = [], audioLanes: [(AudioPlacement, Int)] = []
        for item in audio { let lane = audioEnds.firstIndex { $0 <= item.startMs } ?? audioEnds.count; if lane == audioEnds.count { audioEnds.append(item.endMs) } else { audioEnds[lane] = item.endMs }; audioLanes.append((item, lane)) }
        canvasHeight = audioY + CGFloat(audioEnds.count) * 43 + 5
        canvas.frame = CGRect(x: 0, y: 0, width: width, height: canvasHeight); scroll.contentSize = canvas.bounds.size
        for (name, y, height) in [("Images", CGFloat(26), imageHeight), ("Dialogue", dialogueY, dialogueHeight), ("Direction", directionY, CGFloat(max(1, directionEnds.count)) * (directionHeight + 4)), ("Words", wordY, wordHeight), ("Audio", audioY, CGFloat(audioEnds.count) * 43)] where height > 0 {
            let label = ImageUI.label(name, size: 10, weight: .medium); label.textColor = ImageUI.accent; label.frame = CGRect(x: 4, y: y, width: 62, height: height); canvas.addSubview(label)
        }
        let tick = max(1, Int(ceil(50 / max(1, scale * 1000))))
        for second in stride(from: 0, through: max(1, Int(ceil(Double(store.sceneDurationMs) / 1000))), by: tick) {
            let label = ImageUI.label("\(second)s", size: 9, secondary: true); label.frame = CGRect(x: 70 + CGFloat(second * 1000) * scale, y: 0, width: 45, height: 20); canvas.addSubview(label)
        }
        for row in imageRows {
            let cue = row.cue, frame = CGRect(x: 70 + CGFloat(cue.startMs) * scale, y: 26 + CGFloat(row.lane) * 60, width: max(3, CGFloat(cue.durationMs) * scale - 2), height: 55)
            let tile = UIButton(type: .system); tile.frame = frame; tile.clipsToBounds = true; tile.layer.cornerRadius = 6
            let image = UIKitAssetImageView(frame: tile.bounds); image.autoresizingMask = [.flexibleWidth, .flexibleHeight]; image.isUserInteractionEnabled = false
            image.configure(url: store.project.asset(cue.imageId).flatMap { store.assetURL($0) }, title: cue.label, missingText: "No local image"); tile.addSubview(image)
            let label = ImageUI.label(cue.label.isEmpty ? ScrivFormat.duration(cue.durationMs) : cue.label, size: 9, weight: .medium); label.textColor = .white; label.backgroundColor = UIColor.black.withAlphaComponent(0.45); label.frame = CGRect(x: 3, y: 34, width: max(0, frame.width - 6), height: 18); label.numberOfLines = 1; label.autoresizingMask = [.flexibleWidth]; tile.addSubview(label)
            tile.accessibilityLabel = "\(cue.label), \(ScrivFormat.duration(cue.authoredDurationMs ?? cue.durationMs)) authored coverage"; tile.addAction(UIAction { [weak self] _ in guard let self, self.store.navigationContext == navigation else { return }; if self.store.isPlaying { self.store.togglePlayback() }; self.store.seek(toMs: Double(cue.startMs)); self.store.selectedCueID = cue.id }, for: .touchUpInside)
            tile.menu = UIMenu(children: pictureActions(cue)); canvas.addSubview(tile); imageButtons[cue.id] = tile
            let coverageGrip = UIView(frame: CGRect(x: frame.maxX - 13, y: frame.minY + 33, width: 13, height: 20))
            coverageGrip.backgroundColor = ImageUI.accent.withAlphaComponent(0.8); coverageGrip.layer.cornerRadius = 3
            coverageGrip.isAccessibilityElement = true; coverageGrip.accessibilityLabel = "Authored coverage edge for " + cue.label; canvas.addSubview(coverageGrip)
            coverageGrip.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Set precise coverage") { [weak self] _ in guard let self, self.store.navigationContext == navigation else { return false }; ImageUI.present(ImageCoverageViewController(store: self.store, cue: cue), from: self, size: CGSize(width: 430, height: 360)); return true }]
            tile.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Change source or exact offset") { [weak self] _ in guard let self, self.store.navigationContext == navigation else { return false }; self.show(.cueAnchor(cueID: cue.id)); return true }]
            installTimingDrag(surface: tile, tile: tile, cueID: cue.id, mode: .offset, coverageGrip: coverageGrip)
            installTimingDrag(surface: coverageGrip, tile: tile, cueID: cue.id, mode: .coverage)
        }
        for (index, cue) in store.sceneCues.dropLast().enumerated() {
            let next = store.sceneCues[index + 1]
            guard TimingEngine.canMoveBoundary(store.project, leftCueId: cue.id, rightCueId: next.id), store.lockedByOther(cue.id) == nil, store.lockedByOther(next.id) == nil else { continue }
            let lane = imageRows.first { $0.cue.id == cue.id }?.lane ?? 0
            addDragHandle(frame: CGRect(x: 65 + CGFloat(cue.endMs) * scale, y: 29 + CGFloat(lane) * 60, width: 12, height: 20), label: "Move cut after " + cue.label) { [weak self] delta, context in
                guard let self, self.store.navigationContext == context, self.store.project.cues.first(where: { $0.id == cue.id }) == cue, self.store.project.cues.first(where: { $0.id == next.id }) == next else { return }
                self.store.moveBoundary(leftId: cue.id, rightId: next.id, toMs: self.snapped(cue.endMs + Int(delta / self.scale)))
            }
        }
        for entry in store.sceneEntries where entry.kind == .dialogue {
            let start = store.project.startMs(of: entry.id), color = ImageUI.color(store.project.character(entry.characterId)?.color ?? "blue")
            let block = textBlock((store.project.character(entry.characterId)?.name ?? "Dialogue") + "\n" + entry.text, color: color, frame: CGRect(x: 70 + CGFloat(start) * scale, y: dialogueY, width: max(3, CGFloat(entry.ownedDurationMs) * scale - 2), height: dialogueHeight), script: true) { [weak self] in self?.store.selectEntry(entry.id) }
            let clips = store.project.audioClips.filter { $0.entryId == entry.id }
            for placement in AudioTimeline.placements(project: store.project, sceneId: store.selectedSceneID) where clips.contains(where: { $0.id == placement.clipId }) {
                if let asset = store.project.audioAssets.first(where: { $0.id == placement.assetId }) {
                    let wave = ImageTimelineWaveform(peaks: AudioTimeline.waveform(for: placement, asset: asset), color: color); wave.frame = CGRect(x: CGFloat(placement.startMs - start) * scale, y: dialogueHeight - 11, width: CGFloat(placement.durationMs) * scale, height: 10); block.addSubview(wave)
                }
            }
            for word in entry.words {
                let wordFrame = CGRect(x: 70 + CGFloat(start + word.startMs) * scale, y: wordY, width: max(4, CGFloat(word.endMs - word.startMs) * scale - 1), height: wordHeight)
                let wordBlock = textBlock(word.text, color: color, frame: wordFrame, script: true) { [weak self] in guard let self else { return }; self.store.selectedWordIDs = [word.id]; self.store.seek(toMs: Double(start + word.startMs)) }
                wordBlock.menu = UIMenu(children: [ImageUI.guardedAction("Edit word timing…", store: store, context: navigation) { [weak self] in self?.show(.wordTiming(entryID: entry.id, wordIDs: [word.id])) }])
                addPan(to: wordBlock) { [weak self] delta, context in
                    guard let self, self.store.navigationContext == context, self.store.project.entries.first(where: { $0.id == entry.id })?.words == entry.words else { return }
                    _ = self.store.shiftWords(wordIds: [word.id], byMs: Int(delta / self.scale))
                }
                for end in [false, true] {
                    addDragHandle(frame: CGRect(x: (end ? wordFrame.maxX : wordFrame.minX) - 4, y: wordY + 3, width: 8, height: wordHeight - 6), label: "Retime \(word.text) \(end ? "end" : "start")") { [weak self] delta, context in
                        guard let self, self.store.navigationContext == context, self.store.project.entries.first(where: { $0.id == entry.id })?.words == entry.words else { return }
                        let offset = Int(delta / self.scale); _ = self.store.setWordTiming(wordId: word.id, startMs: word.startMs + (end ? 0 : offset), endMs: word.endMs + (end ? offset : 0))
                    }
                }
            }
        }
        for (entry, lane) in directions {
            let start = store.project.startMs(of: entry.id)
            let block = textBlock(entry.text + "\n" + ScrivFormat.duration(entry.ownedDurationMs) + " owned", color: ImageUI.color(entry.color), frame: CGRect(x: 70 + CGFloat(start) * scale, y: directionY + CGFloat(lane) * (directionHeight + 4), width: max(20, CGFloat(entry.coverageDurationMs) * scale - 2), height: directionHeight), script: true) { [weak self] in self?.store.selectEntry(entry.id) }
            block.menu = UIMenu(children: [ImageUI.guardedAction("Owned duration…", store: store, context: navigation) { [weak self] in guard let self else { return }; ImageUI.present(ImageCoverageViewController(store: self.store, entry: entry), from: self, size: CGSize(width: 430, height: 360)) }])
        }
        for (placement, lane) in audioLanes {
            guard let clip = store.project.audioClips.first(where: { $0.id == placement.clipId }), let asset = store.project.audioAssets.first(where: { $0.id == placement.assetId }) else { continue }
            let block = textBlock(asset.originalName, color: clip.isMuted ? .secondaryLabel : .systemTeal, frame: CGRect(x: 70 + CGFloat(placement.startMs) * scale, y: audioY + CGFloat(lane) * 43, width: max(3, CGFloat(placement.durationMs) * scale - 2), height: 38)) { [weak self] in self?.store.seek(toMs: Double(placement.startMs)) }
            let wave = ImageTimelineWaveform(peaks: AudioTimeline.waveform(for: placement, asset: asset), color: .systemTeal); wave.frame = CGRect(x: 0, y: 19, width: block.bounds.width, height: 18); block.addSubview(wave)
            block.menu = UIMenu(children: [ImageUI.guardedAction("Audio trim and timing…", store: store, context: navigation) { [weak self] in guard let self else { return }; let editor = AudioClipEditorController(store: self.store, clip: clip); editor.modalPresentationStyle = .formSheet; self.present(editor, animated: true) }, UIAction(title: clip.isMuted ? "Unmute clip" : "Mute clip") { [weak self] _ in guard let self, self.store.navigationContext == navigation, self.store.project.audioClips.first(where: { $0.id == clip.id }) == clip else { return }; var changed = clip; changed.isMuted.toggle(); _ = self.store.updateAudioClip(changed) }, UIAction(title: "Remove clip", attributes: .destructive) { [weak self] _ in guard let self, self.store.navigationContext == navigation else { return }; self.store.deleteAudioClip(clip.id) }])
            addPan(to: block) { [weak self] delta, context in guard let self, self.store.navigationContext == context, self.store.project.audioClips.first(where: { $0.id == clip.id }) == clip else { return }; var moved = clip; moved.startMs = min(86_400_000, max(0, self.snapped(clip.startMs + Int(delta / self.scale)))); _ = self.store.updateAudioClip(moved) }
        }
        canvas.addSubview(playhead)
    }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelTimingDrag))] }
    @objc private func cancelTimingDrag() { timingDrivers.forEach { $0.cancel() }; dragDrivers.forEach { $0.cancel() } }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); cancelTimingDrag() }
    private func installTimingDrag(surface: UIView, tile: UIView, cueID: String, mode: ImageTimelineDragDraft.Mode, coverageGrip: UIView? = nil) {
        let driver = ImageTimelineManipulationDriver(surface: surface, tile: tile, canvas: canvas, store: store, cueID: cueID, mode: mode, scale: scale, coverageGrip: coverageGrip, snapping: { [weak self] in self?.snap.isOn == true }, onBegin: { [weak self] in
            guard let self else { return }; self.dragInProgress = true; self.scroll.isScrollEnabled = false; self.becomeFirstResponder()
        }, onFinish: { [weak self] in
            guard let self else { return }; self.dragInProgress = false; self.scroll.isScrollEnabled = true
            DispatchQueue.main.async { [weak self] in self?.signature = ""; self?.storeDidChange() }
        })
        timingDrivers.append(driver); scroll.panGestureRecognizer.require(toFail: driver.recognizer)
    }
    private func pictureActions(_ cue: ImageCue) -> [UIMenuElement] {
        let context = store.navigationContext
        var actions: [UIMenuElement] = []
        if let imageID = cue.imageId { actions.append(ImageUI.guardedAction("Inspect image…", store: store, context: context) { [weak self] in self?.show(.imageDetail(imageID: imageID, cueID: cue.id)) }) }
        actions.append(ImageUI.guardedAction("Choose existing image…", store: store, context: context) { [weak self] in guard let self else { return }; ImageUI.present(ImagePickerViewController(store: self.store, cueID: cue.id), from: self) })
        actions.append(ImageUI.guardedAction("Change source / exact offset…", store: store, context: context) { [weak self] in self?.show(.cueAnchor(cueID: cue.id)) })
        actions.append(ImageUI.guardedAction("Authored coverage…", store: store, context: context) { [weak self] in guard let self else { return }; ImageUI.present(ImageCoverageViewController(store: self.store, cue: cue), from: self, size: CGSize(width: 430, height: 360)) })
        actions.append(ImageUI.guardedAction("Import image…", store: store, context: context) { [weak self] in self?.store.importImage(cueId: cue.id) })
        actions.append(ImageUI.guardedAction("Generate image", store: store, context: context) { [weak self] in self?.store.generateImage(cueId: cue.id) })
        actions.append(ImageUI.guardedAction("Split at playhead", store: store, context: context) { [weak self] in self?.store.splitCue(cue.id) }); return actions
    }
    private func textBlock(_ text: String, color: UIColor, frame: CGRect, script: Bool = false, action: @escaping () -> Void) -> UIButton {
        let block = UIButton(type: .system); block.frame = frame; block.layer.cornerRadius = 5; block.clipsToBounds = true; block.backgroundColor = color.withAlphaComponent(0.12)
        block.setTitle(text, for: .normal); block.setTitleColor(color, for: .normal); block.titleLabel?.font = .systemFont(ofSize: script ? store.scriptFontSize : 10); block.titleLabel?.numberOfLines = 3; block.contentHorizontalAlignment = .left
        block.addAction(ImageUI.guardedAction(text, store: store, context: store.navigationContext, handler: action), for: .touchUpInside); block.accessibilityLabel = text; canvas.addSubview(block); return block
    }
    private func addDragHandle(frame: CGRect, label: String, action: @escaping (CGFloat, Int) -> Void) {
        let handle = UIView(frame: frame); handle.backgroundColor = ImageUI.accent.withAlphaComponent(0.6); handle.layer.cornerRadius = 3; handle.accessibilityLabel = label; canvas.addSubview(handle); addPan(to: handle, action: action)
    }
    private func addPan(to view: UIView, action: @escaping (CGFloat, Int) -> Void) {
        let driver = ImageTimelineDragDriver(view: view, begin: { [weak self] in guard let self else { return 0 }; self.dragInProgress = true; if self.store.isPlaying { self.store.togglePlayback() }; return self.store.navigationContext }, finish: { [weak self] delta, context, committed in
            guard let self else { return }; self.dragInProgress = false; if committed { action(delta, context) }; self.signature = ""; self.storeDidChange()
        })
        dragDrivers.append(driver)
    }
    private var dragDrivers: [ImageTimelineDragDriver] = []
    private func snapped(_ ms: Int) -> Int {
        guard snap.isOn else { return ms }; let closest = TimingEngine.absoluteWords(store.project, sceneId: store.selectedSceneID).map(\.startMs).min { abs($0 - ms) < abs($1 - ms) }
        return closest.map { abs($0 - ms) < 300 ? $0 : ms } ?? ms
    }
    @objc private func seekCanvas(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: canvas); guard point.y < 24, point.x >= 70 else { return }; store.seek(toMs: Double((point.x - 70) / scale))
    }
}

@MainActor private final class ImageTimelineDragDriver: NSObject {
    private weak var view: UIView?
    private let begin: () -> Int
    private let finish: (CGFloat, Int, Bool) -> Void
    private var context = 0
    private var recognizer: UIPanGestureRecognizer!
    init(view: UIView, begin: @escaping () -> Int, finish: @escaping (CGFloat, Int, Bool) -> Void) {
        self.view = view; self.begin = begin; self.finish = finish; super.init(); recognizer = UIPanGestureRecognizer(target: self, action: #selector(pan(_:))); view.addGestureRecognizer(recognizer)
    }
    func cancel() { if recognizer.state == .began || recognizer.state == .changed { recognizer.isEnabled = false; recognizer.isEnabled = true } }
    @objc private func pan(_ sender: UIPanGestureRecognizer) {
        let delta = sender.translation(in: view?.superview).x
        switch sender.state {
        case .began: context = begin()
        case .changed: view?.transform = CGAffineTransform(translationX: delta, y: 0)
        case .ended, .cancelled, .failed: view?.transform = .identity; finish(delta, context, sender.state == .ended)
        default: break
        }
    }
}

@MainActor final class ImageTimelineWaveform: UIView {
    private let peaks: [Float], color: UIColor
    init(peaks: [Float], color: UIColor) { self.peaks = peaks; self.color = color; super.init(frame: .zero); backgroundColor = .clear; isUserInteractionEnabled = false }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(peaks:color:)") }
    override func draw(_ rect: CGRect) {
        guard !peaks.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }; context.setStrokeColor(color.cgColor); context.setLineWidth(max(1, rect.width / CGFloat(peaks.count)))
        for (index, peak) in peaks.enumerated() { let x = rect.width * CGFloat(index) / CGFloat(peaks.count), height = rect.height * CGFloat(min(1, max(0, peak))); context.move(to: CGPoint(x: x, y: (rect.height - height) / 2)); context.addLine(to: CGPoint(x: x, y: (rect.height + height) / 2)) }; context.strokePath()
    }
}
