import UIKit
import UniformTypeIdentifiers
import ScrivCore

@MainActor final class StoryboardViewController: ScrivScreenController, UIGestureRecognizerDelegate {
    private let scroll = UIScrollView()
    private let rows = ImageUI.stack(spacing: 28)
    private let countLabel = ImageUI.label(size: 12, secondary: true)
    private let selectionLabel = ImageUI.label(size: 11, secondary: true)
    private var playback: ScrivPlaybackControlsView!
    private var signature = ""
    private var columns = 3
    private var cards: [String: UIKitStoryboardCard] = [:]
    private var directionBands: [UIKitStoryboardDirectionBand] = []
    private var wordAnchor: String?
    private let marquee = UIView()
    private var marqueeOrigin: CGPoint?
    private var marqueeBase: Set<String> = []
    private var marqueeContext: Int?
    private var backgroundTap: UITapGestureRecognizer!
    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Storyboard"
        let heading = ImageUI.row([ImageUI.stack([ImageUI.label("Storyboard", size: 22, weight: .semibold), countLabel], spacing: 3), ImageUI.spacer(), selectionLabel, ImageUI.button("Deselect") { [weak self] in self?.store.selectedWordIDs = [] }, ImageUI.button("Current moment", symbol: "scope") { [weak self] in self?.scrollToCurrent() }, ImageUI.button("Add placement", symbol: "plus.rectangle") { [weak self] in self?.store.addCue() }, ImageUI.button("Import image", symbol: "photo.badge.plus") { [weak self] in self?.store.importImage() }], spacing: 10)
        scroll.addSubview(rows); rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([rows.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 22), rows.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -22), rows.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 10), rows.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24), rows.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -44)])
        playback = ScrivPlaybackControlsView(store: store)
        let footer = ImageUI.stack([ImageUI.label("Select words or drag a marquee. Drag boundary words between pictures to move the cut. Use word timing or Layers to retime speech separately.", size: 11, secondary: true), playback], spacing: 6)
        let root = ImageUI.stack([heading, scroll, footer], spacing: 12); ImageUI.pinToSafeArea(root, in: self, insets: NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 14, trailing: 20))
        marquee.backgroundColor = ImageUI.accent.withAlphaComponent(0.08); marquee.layer.borderColor = ImageUI.accent.cgColor; marquee.layer.borderWidth = 1; marquee.isHidden = true; marquee.isUserInteractionEnabled = false; scroll.addSubview(marquee)
        let selection = ImageTimingPanRecognizer(target: self, action: #selector(selectMarquee(_:))); selection.delegate = self; selection.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]; scroll.addGestureRecognizer(selection)
        backgroundTap = UITapGestureRecognizer(target: self, action: #selector(clearBackgroundSelection))
        backgroundTap.delegate = self; backgroundTap.cancelsTouchesInView = false; backgroundTap.require(toFail: selection); view.addGestureRecognizer(backgroundTap)
        storeDidChange()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); let desired = view.bounds.width < 1050 ? 2 : 3
        if desired != columns { columns = desired; signature = ""; storeDidChange() }
    }
    override func storeDidChange() {
        guard isViewLoaded, playback != nil else { return }
        countLabel.text = "\(store.sceneCues.count) images · \(ScrivFormat.duration(store.sceneDurationMs))"
        selectionLabel.text = store.selectedWordIDs.isEmpty ? "" : "\(store.selectedWordIDs.count) words selected"
        let next = "\(store.navigationContext)|\(store.selectedSceneID)|\(store.project.revision)|\(store.sceneCues)|\(store.sceneEntries)|\(store.project.images)|\(columns)|\(store.peerTransferStatus)"
        if signature != next, marqueeOrigin == nil { signature = next; rebuild() }
        cards.values.forEach { $0.updateSelection() }; directionBands.forEach { $0.updateFont(store.scriptFontSize) }; playback.update()
    }
    private func rebuild() {
        ImageUI.clear(rows); cards.removeAll(); directionBands.removeAll()
        if store.sceneCues.isEmpty {
            rows.addArrangedSubview(ImageUI.card(ImageUI.stack([ImageUI.label("Build the scene, one image at a time", size: 25, weight: .semibold), ImageUI.label("Start with a script moment, then choose the image that belongs there.", secondary: true), ImageUI.row([ImageUI.button("Write in Script", primary: true) { [weak self] in self?.store.tab = .script }, ImageUI.button("Import image…") { [weak self] in self?.store.importImage() }]), ImageUI.label("Images follow their script sources. Dialogue, direction and imported audio stay intact.", size: 12, secondary: true)]), padding: 32)); return
        }
        let grouped = PresentationGeometry.storyboardRows(cues: store.sceneCues, entryStarts: Set(store.sceneEntries.map { store.project.startMs(of: $0.id) }), columns: columns)
        for cues in grouped {
            let row = ImageUI.stack(axis: .horizontal, spacing: 18); row.alignment = .top; row.distribution = .fillEqually
            for cue in cues {
                let card = UIKitStoryboardCard(store: store, cue: cue, owner: self); cards[cue.id] = card; row.addArrangedSubview(card)
            }
            for _ in cues.count..<columns { row.addArrangedSubview(UIView()) }
            let group = ImageUI.stack([row], spacing: 9)
            if let first = cues.first, let end = cues.map(\.endMs).max() {
                for entry in store.sceneEntries where entry.kind == .direction {
                    let start = store.project.startMs(of: entry.id)
                    guard start < end, start + entry.coverageDurationMs > first.startMs else { continue }
                    let band = UIKitStoryboardDirectionBand(entry: entry, cues: cues, columns: columns, project: store.project) { [weak self] in self?.store.selectEntry(entry.id) }; band.updateFont(store.scriptFontSize); directionBands.append(band); group.addArrangedSubview(band)
                }
            }
            rows.addArrangedSubview(group)
        }
    }
    fileprivate func selectWord(_ word: TimedWord, cue: ImageCue, words: [TimedWord], modifiers: UIKeyModifierFlags) {
        if modifiers.contains(.shift), let wordAnchor, let first = words.firstIndex(where: { $0.id == wordAnchor }), let last = words.firstIndex(where: { $0.id == word.id }) {
            store.selectedWordIDs.formUnion(words[min(first, last)...max(first, last)].map(\.id))
        } else if modifiers.contains(.command) {
            if store.selectedWordIDs.contains(word.id) { store.selectedWordIDs.remove(word.id) } else { store.selectedWordIDs.insert(word.id) }; wordAnchor = word.id
        } else { store.selectedWordIDs = [word.id]; wordAnchor = word.id }
        store.selectedCueID = cue.id
    }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelStoryboardGesture))] }
    @objc private func cancelStoryboardGesture() { cards.values.forEach { $0.cancelDurationGesture() }; store.selectedWordIDs = [] }
    private func scrollToCurrent() {
        let id = store.selectedCueID ?? store.currentCue?.id
        if let id, let card = cards[id] { scroll.scrollRectToVisible(card.convert(card.bounds, to: scroll), animated: true) }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === backgroundTap { return StoryboardBackgroundSelectionPolicy.isBlankTouch(touch.view, within: view) }
        guard StoryboardBackgroundSelectionPolicy.isBlankTouch(touch.view, within: view) else { return false }
        let point = touch.location(in: scroll)
        return !cards.values.contains { $0.convert($0.bounds, to: scroll).contains(point) }
    }
    @objc private func clearBackgroundSelection() {
        guard marqueeOrigin == nil else { return }
        store.selectedWordIDs = [] // Deliberately preserve selectedCueID and playhead.
    }
    fileprivate func prioritizeDurationGesture(_ gesture: UIGestureRecognizer) { scroll.panGestureRecognizer.require(toFail: gesture) }
    @objc private func selectMarquee(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: scroll)
        switch pan.state {
        case .began: marqueeOrigin = point; marqueeContext = store.navigationContext; marqueeBase = (pan as? ImageTimingPanRecognizer)?.modifiers.contains(.shift) == true ? store.selectedWordIDs : []; marquee.isHidden = false; scroll.isScrollEnabled = false
        case .changed:
            guard let origin = marqueeOrigin, marqueeContext == store.navigationContext else { return }
            let rect = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y), width: abs(point.x - origin.x), height: abs(point.y - origin.y)); marquee.frame = rect
            var selected = marqueeBase
            for card in cards.values { for (id, button) in card.wordButtons where button.convert(button.bounds, to: scroll).intersects(rect) { selected.insert(id) } }
            store.selectedWordIDs = selected
        case .ended, .cancelled, .failed: marqueeOrigin = nil; marqueeContext = nil; marquee.isHidden = true; scroll.isScrollEnabled = true; storeDidChange()
        default: break
        }
    }
}

private struct StoryboardWordReference { let word: TimedWord; let entryID: String; let absoluteStart: Int }

@MainActor private final class UIKitStoryboardCard: UIView, UIDropInteractionDelegate {
    let store: WorkspaceStore
    let cue: ImageCue
    weak var owner: StoryboardViewController?
    let navigation: Int
    private var words: [StoryboardWordReference] = []
    fileprivate var wordButtons: [String: StoryboardWordButton] = [:]
    private let picture = UIKitAssetImageView()
    private var dragDelegates: [StoryboardWordDragDelegate] = []
    private var boundaryDriver: StoryboardCutDragDriver?
    private var durationDriver: ImageDurationScrubDriver?
    init(store: WorkspaceStore, cue: ImageCue, owner: StoryboardViewController) {
        self.store = store; self.cue = cue; self.owner = owner; navigation = store.navigationContext; super.init(frame: .zero)
        for entry in store.sceneEntries { let start = store.project.startMs(of: entry.id); words += entry.words.filter { start + $0.startMs >= cue.startMs && start + $0.startMs < cue.endMs }.map { StoryboardWordReference(word: $0, entryID: entry.id, absoluteStart: start + $0.startMs) } }
        let wrapper = UIView(); wrapper.addSubview(picture); picture.scrivPinEdges(to: wrapper); wrapper.heightAnchor.constraint(equalTo: wrapper.widthAnchor, multiplier: 1 / 1.5).isActive = true
        let image = store.project.asset(cue.imageId); picture.configure(url: image.flatMap { store.assetURL($0) }, title: cue.label, missingText: image == nil ? "Add an image" : "Image not on this Mac")
        picture.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(selectPicture)))
        let duration = ImageUI.button(ScrivFormat.duration(cue.authoredDurationMs ?? cue.durationMs)) { [weak self] in guard let self, self.navigation == self.store.navigationContext, let owner = self.owner else { return }; ImageUI.present(ImageCoverageViewController(store: self.store, cue: self.cue), from: owner, size: CGSize(width: 430, height: 360)) }
        duration.configuration?.baseBackgroundColor = UIColor.black.withAlphaComponent(0.62)
        duration.configuration?.baseForegroundColor = .white; duration.configuration?.cornerStyle = .capsule
        duration.configuration?.background.strokeColor = UIColor.white.withAlphaComponent(0.5); duration.configuration?.background.strokeWidth = 1
        durationDriver = ImageDurationScrubDriver(button: duration, store: store, cueID: cue.id)
        if let gesture = durationDriver?.recognizer { owner.prioritizeDurationGesture(gesture) }
        duration.translatesAutoresizingMaskIntoConstraints = false; wrapper.addSubview(duration); NSLayoutConstraint.activate([duration.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 8), duration.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -8)])
        let more = ImageUI.button("", symbol: "ellipsis") {}; more.showsMenuAsPrimaryAction = true; more.menu = UIMenu(children: actions()); more.translatesAutoresizingMaskIntoConstraints = false; wrapper.addSubview(more); NSLayoutConstraint.activate([more.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -8), more.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -8)])
        let stack = ImageUI.stack([wrapper], spacing: 8)
        if !cue.label.isEmpty { stack.addArrangedSubview(ImageUI.label(cue.label, size: 12, weight: .medium)) }
        if cue.durationMs == 0 { stack.addArrangedSubview(ImageUI.label("Dormant · waiting for following script time", size: 11, secondary: true)) }
        if (cue.authoredDurationMs ?? cue.durationMs) != cue.durationMs { stack.addArrangedSubview(ImageUI.label("\(ScrivFormat.duration(cue.durationMs)) in scene · \(ScrivFormat.duration(cue.authoredDurationMs ?? cue.durationMs)) authored", size: 11, secondary: true)) }
        let overlap = store.sceneCues.filter { $0.id != cue.id && $0.startMs < cue.endMs && $0.endMs > cue.startMs }.count
        if overlap > 0 { stack.addArrangedSubview(ImageUI.label("\(overlap) overlapping placement\(overlap == 1 ? "" : "s") · preserved", size: 11, secondary: true)) }
        let flow = StoryboardWordFlowView()
        for item in words {
            let button = StoryboardWordButton(text: item.word.text); button.onSelect = { [weak self] modifiers in guard let self, self.navigation == self.store.navigationContext else { return }; self.owner?.selectWord(item.word, cue: self.cue, words: self.words.map(\.word), modifiers: modifiers) }
            button.menu = UIMenu(children: wordActions(item)); flow.addSubview(button); wordButtons[item.word.id] = button
            let drag = StoryboardWordDragDelegate(card: self, wordID: item.word.id); dragDelegates.append(drag); button.addInteraction(UIDragInteraction(delegate: drag))
        }
        stack.addArrangedSubview(flow); addSubview(stack); stack.scrivPinEdges(to: self); addInteraction(UIDropInteraction(delegate: self))
        if let index = store.sceneCues.firstIndex(where: { $0.id == cue.id }), index + 1 < store.sceneCues.count {
            let next = store.sceneCues[index + 1]
            if TimingEngine.canMoveBoundary(store.project, leftCueId: cue.id, rightCueId: next.id) {
                let handle = UIView(); handle.translatesAutoresizingMaskIntoConstraints = false; handle.backgroundColor = .white; handle.layer.cornerRadius = 3; wrapper.addSubview(handle)
                NSLayoutConstraint.activate([handle.widthAnchor.constraint(equalToConstant: 10), handle.heightAnchor.constraint(equalToConstant: 50), handle.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -3), handle.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor)])
                handle.accessibilityLabel = "Move cut after " + cue.label
                boundaryDriver = StoryboardCutDragDriver(view: handle) { [weak self] delta in
                    guard let self, self.navigation == self.store.navigationContext, self.store.project.cues.first(where: { $0.id == cue.id }) == cue, self.store.project.cues.first(where: { $0.id == next.id }) == next else { return }
                    self.store.moveBoundary(leftId: cue.id, rightId: next.id, toMs: cue.endMs + Int(delta * 20))
                }
            }
        }
        updateSelection()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:cue:owner:)") }
    func cancelDurationGesture() { durationDriver?.cancel() }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { durationDriver?.cancel() } }
    @objc private func selectPicture() { guard navigation == store.navigationContext else { return }; store.selectedWordIDs = []; if store.isPlaying { store.togglePlayback() }; store.seek(toMs: Double(cue.startMs)); store.selectedCueID = cue.id }
    func updateSelection() {
        picture.layer.borderColor = ImageUI.accent.cgColor; picture.layer.borderWidth = cue.id == store.selectedCueID ? 2 : 0
        for (id, button) in wordButtons { button.titleLabel?.font = .systemFont(ofSize: store.scriptFontSize); button.invalidateIntrinsicContentSize(); button.superview?.invalidateIntrinsicContentSize(); button.superview?.setNeedsLayout(); let active = store.selectedWordIDs.contains(id) || store.currentWordID == id; button.backgroundColor = active ? ImageUI.accent : ScrivUIKitTheme.inset; button.setTitleColor(active ? .white : .label, for: .normal); button.accessibilityTraits = store.selectedWordIDs.contains(id) ? [.button, .selected] : .button }
    }
    private func actions() -> [UIMenuElement] {
        var result: [UIMenuElement] = []
        if let imageID = cue.imageId { result.append(UIAction(title: "Inspect image…") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext else { return }; self.owner?.show(.imageDetail(imageID: imageID, cueID: self.cue.id)) }) }
        result.append(UIAction(title: "Picture source…") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext else { return }; self.owner?.show(.cueAnchor(cueID: self.cue.id)) })
        result.append(UIAction(title: "Choose existing image…") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext, let owner = self.owner else { return }; ImageUI.present(ImagePickerViewController(store: self.store, cueID: self.cue.id), from: owner) })
        if let image = store.project.asset(cue.imageId), store.assetURL(image) == nil { result.append(UIAction(title: "Fetch image") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext else { return }; self.store.downloadImage(image) }) }
        result.append(UIAction(title: "Import image…") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext else { return }; self.store.importImage(cueId: self.cue.id) })
        result.append(UIAction(title: "Generate image") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext else { return }; self.store.generateImage(cueId: self.cue.id) })
        result.append(UIAction(title: "Split image in half") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext else { return }; self.store.seek(toMs: Double(self.cue.startMs + self.cue.durationMs / 2)); self.store.splitCue(self.cue.id) })
        result.append(UIAction(title: "Discuss image") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext else { return }; self.store.loadDiscussion(itemId: self.cue.imageId ?? self.cue.id); self.store.showDiscussion = true })
        if let index = store.sceneCues.firstIndex(where: { $0.id == cue.id }), index + 1 < store.sceneCues.count {
            let next = store.sceneCues[index + 1]
            if TimingEngine.canMoveBoundary(store.project, leftCueId: cue.id, rightCueId: next.id) { result.append(UIAction(title: "Merge with next placement") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext else { return }; self.store.mergeCue(self.cue.id, with: next.id) }) }
        }
        result.append(UIAction(title: "Remove placement…", attributes: .destructive) { [weak self] _ in guard let self, self.navigation == self.store.navigationContext, let owner = self.owner else { return }; ImageUI.confirm("Remove this image placement?", message: "The image asset, script, words and their timing are preserved.", destructiveTitle: "Remove placement", from: owner) { [weak self] in guard let self, self.navigation == self.store.navigationContext else { return }; self.store.deleteCue(self.cue.id) } }); return result
    }
    private func wordActions(_ item: StoryboardWordReference) -> [UIMenuElement] {
        var result: [UIMenuElement] = [UIAction(title: "Play word") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext else { return }; self.store.seek(toMs: Double(item.absoluteStart)) }, UIAction(title: "Edit word timing…") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext else { return }; self.owner?.show(.wordTiming(entryID: item.entryID, wordIDs: [item.word.id])) }]
        if let index = store.sceneCues.firstIndex(where: { $0.id == cue.id }) {
            for offset in [-1, 1] where store.sceneCues.indices.contains(index + offset) {
                let other = store.sceneCues[index + offset], left = offset < 0 ? other : cue, right = offset < 0 ? cue : other
                if TimingEngine.canMoveBoundary(store.project, leftCueId: left.id, rightCueId: right.id) { result.append(UIAction(title: offset < 0 ? "Move to previous image" : "Move to next image") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext else { return }; self.store.moveWords([item.word.id], fromCueId: self.cue.id, toCueId: other.id) }) }
            }
        }
        result.append(UIAction(title: "Discuss line") { [weak self] _ in guard let self, self.navigation == self.store.navigationContext else { return }; self.store.loadDiscussion(itemId: item.entryID); self.store.showDiscussion = true }); return result
    }
    fileprivate func transfer(wordID: String) -> StoryboardWordTransfer? {
        guard navigation == store.navigationContext else { return nil }
        let ids = store.selectedWordIDs.contains(wordID) ? store.selectedWordIDs.intersection(Set(words.map { $0.word.id })) : [wordID]
        store.selectedWordIDs = ids
        return StoryboardWordTransfer(projectID: store.project.id, sceneID: cue.sceneId, navigation: navigation, revision: store.project.revision, cueID: cue.id, wordIDs: Array(ids))
    }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool { session.localDragSession != nil && session.canLoadObjects(ofClass: NSString.self) }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal { UIDropProposal(operation: .move) }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) { layer.borderWidth = 2; layer.borderColor = ImageUI.accent.cgColor }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) { layer.borderWidth = 0 }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) { layer.borderWidth = 0 }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let payload = session.items.first?.localObject as? StoryboardWordTransfer, navigation == store.navigationContext, payload.canApply(to: store.project, navigation: navigation, destination: cue) else { store.errorMessage = "The scene changed during the drag. Select the words again before moving this cut."; return }
        store.moveWords(Set(payload.wordIDs), fromCueId: payload.cueID, toCueId: cue.id)
    }
}

@MainActor private final class StoryboardWordButton: UIButton {
    var onSelect: ((UIKeyModifierFlags) -> Void)?
    private var modifiers: UIKeyModifierFlags = []
    init(text: String) { super.init(frame: .zero); setTitle(text, for: .normal); titleLabel?.font = .systemFont(ofSize: 14); titleLabel?.numberOfLines = 0; titleLabel?.lineBreakMode = .byCharWrapping; layer.cornerRadius = 8; contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12); addAction(UIAction { [weak self] _ in guard let self else { return }; self.onSelect?(self.modifiers) }, for: .touchUpInside) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(text:)") }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { modifiers = event?.modifierFlags ?? []; super.touchesEnded(touches, with: event) }
}

@MainActor private final class StoryboardWordFlowView: UIView {
    private var measuredHeight: CGFloat = 0
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: layout(width: max(1, bounds.width > 0 ? bounds.width : 300), apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); let height = layout(width: max(1, bounds.width), apply: true); if abs(height - measuredHeight) > 0.5 { measuredHeight = height; invalidateIntrinsicContentSize() } }
    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let desired: CGSize
            if let button = view as? UIButton, let text = button.title(for: .normal), let font = button.titleLabel?.font {
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byCharWrapping
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
                let measured = (text as NSString).boundingRect(with: CGSize(width: max(1, width - 24), height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
                desired = CGSize(width: min(width, ceil(measured.width) + 24), height: ceil(measured.height) + 14)
            } else { desired = view.sizeThatFits(CGSize(width: width, height: 1000)) }
            let size = CGSize(width: min(width, desired.width), height: max(34, desired.height))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + 6; rowHeight = 0 }
            if apply { view.frame = CGRect(origin: CGPoint(x: x, y: y), size: size) }
            x += size.width + 5; rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight
    }
}

@MainActor private final class StoryboardWordDragDelegate: NSObject, UIDragInteractionDelegate {
    weak var card: UIKitStoryboardCard?
    let wordID: String
    init(card: UIKitStoryboardCard, wordID: String) { self.card = card; self.wordID = wordID }
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let payload = card?.transfer(wordID: wordID), let data = try? JSONEncoder().encode(payload), let text = String(data: data, encoding: .utf8) else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider(object: text as NSString)); item.localObject = payload; return [item]
    }
    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
}

@MainActor private final class StoryboardCutDragDriver: NSObject {
    private weak var view: UIView?
    private let action: (CGFloat) -> Void
    init(view: UIView, action: @escaping (CGFloat) -> Void) { self.view = view; self.action = action; super.init(); view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))) }
    @objc private func pan(_ sender: UIPanGestureRecognizer) { let delta = sender.translation(in: view?.superview).x; if sender.state == .changed { view?.transform = CGAffineTransform(translationX: delta, y: 0) }; if sender.state == .ended || sender.state == .cancelled { view?.transform = .identity; if sender.state == .ended { action(delta) } } }
}

@MainActor private final class UIKitStoryboardDirectionBand: UIView {
    private let entry: ScriptEntry, cues: [ImageCue], columns: Int, project: ScrivProject
    private let button = UIButton(type: .system)
    private var heightConstraint: NSLayoutConstraint!
    init(entry: ScriptEntry, cues: [ImageCue], columns: Int, project: ScrivProject, action: @escaping () -> Void) {
        self.entry = entry; self.cues = cues; self.columns = columns; self.project = project; super.init(frame: .zero)
        heightConstraint = heightAnchor.constraint(equalToConstant: 48); heightConstraint.isActive = true; button.setTitle(entry.text, for: .normal); button.titleLabel?.font = .italicSystemFont(ofSize: 14); button.titleLabel?.numberOfLines = 2; button.backgroundColor = ImageUI.color(entry.color).withAlphaComponent(0.12); button.setTitleColor(ImageUI.color(entry.color), for: .normal); button.layer.cornerRadius = 8; button.addAction(UIAction { _ in action() }, for: .touchUpInside); button.accessibilityLabel = entry.text; addSubview(button)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use source initializer") }
    func updateFont(_ size: CGFloat) { button.titleLabel?.font = .italicSystemFont(ofSize: size); heightConstraint.constant = max(48, size * 2.5 + 10); setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews(); let cardWidth = max(1, (bounds.width - CGFloat(columns - 1) * 18) / CGFloat(columns)), start = project.startMs(of: entry.id), end = start + entry.coverageDurationMs
        let spans = cues.enumerated().compactMap { index, cue -> ClosedRange<CGFloat>? in guard let range = PresentationGeometry.coverageFractions(startMs: start, endMs: end, cueStartMs: cue.startMs, cueEndMs: cue.endMs) else { return nil }; let origin = CGFloat(index) * (cardWidth + 18); return (origin + CGFloat(range.lowerBound) * cardWidth)...(origin + CGFloat(range.upperBound) * cardWidth) }
        let left = spans.first?.lowerBound ?? 0, right = spans.last?.upperBound ?? 0; button.frame = CGRect(x: left, y: 0, width: max(1, right - left), height: bounds.height)
    }
}
