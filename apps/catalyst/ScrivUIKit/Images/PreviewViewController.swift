import UIKit
import Combine
import ScrivCore

@MainActor final class PreviewViewController: ScrivScreenController {
    private var content: UIStackView!
    private let subtitle = ImageUI.label(size: 13, secondary: true)
    private let state = ImageUI.label(size: 11, weight: .medium, secondary: true)
    private let media = ImageUI.stack()
    private let metadata = ImageUI.stack(spacing: 8)
    private var mediaSignature = ""
    private var metadataSignature = ""
    private var playback: ScrivPlaybackControlsView!
    private var timeline: LayerTimelineViewController!
    private var generation: GenerationPanelViewController!
    private var cue: ImageCue? { store.isPlaying ? store.currentCue : store.selectedCue ?? store.currentCue }
    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Preview"; content = ImageUI.scrollStack(in: self, spacing: 12, padding: 14)
        let expand = ImageUI.button("Inspect", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in guard let self, let imageID = self.cue?.imageId else { return }; self.show(.imageDetail(imageID: imageID, cueID: self.cue?.id)) }
        content.addArrangedSubview(ImageUI.row([ImageUI.label("Preview", size: 27, weight: .semibold), ImageUI.spacer(), ImageUI.label("16:9", size: 11, secondary: true), expand]))
        content.addArrangedSubview(subtitle); content.addArrangedSubview(media); content.addArrangedSubview(state); content.addArrangedSubview(metadata)
        playback = ScrivPlaybackControlsView(store: store); content.addArrangedSubview(playback)
        timeline = LayerTimelineViewController(store: store); addChild(timeline); content.addArrangedSubview(timeline.view); timeline.view.heightAnchor.constraint(equalToConstant: 330).isActive = true; timeline.didMove(toParent: self)
        generation = GenerationPanelViewController(store: store); addChild(generation); content.addArrangedSubview(generation.view); generation.didMove(toParent: self)
        storeDidChange()
    }
    override func storeDidChange() {
        guard isViewLoaded, content != nil else { return }
        let navigation = store.navigationContext
        let cue = self.cue, image = store.project.asset(cue?.imageId), url = image.flatMap { store.assetURL($0) }
        subtitle.text = cue.map { ($0.label.isEmpty ? "Picture at " + ScrivFormat.time($0.startMs) : $0.label) + (image.map { " · Version \($0.version)" } ?? " · No image chosen") } ?? "Select a script moment or image"
        let inspecting = !store.isPlaying && cue != nil && cue?.id != store.currentCue?.id
        state.text = inspecting ? "Inspecting selected image" : "Following playhead"; state.textColor = inspecting ? ImageUI.accent : .secondaryLabel
        let nextMedia = "\(store.navigationContext)|\(cue?.id ?? "")|\(image?.id ?? "")|\(url?.path ?? "")"
        if nextMedia != mediaSignature {
            mediaSignature = nextMedia; ImageUI.clear(media)
            if let image, let url {
                let picture = UIKitAssetImageView(); picture.configure(url: url, title: cue?.label ?? "Scene preview")
                picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: 9 / 16).isActive = true; media.addArrangedSubview(picture)
            } else if let image {
                let missing = ImageUI.stack([ImageUI.label("Image isn’t on this Mac", size: 20, weight: .semibold), ImageUI.label("The script and timing are intact. Fetch this image to view it here.", size: 13, secondary: true)], spacing: 12)
                missing.addArrangedSubview(ImageUI.row([ImageUI.button("Fetch image", primary: true) { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; self.store.downloadImage(image) }, ImageUI.button("Choose another image…") { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; self.chooseImage(cueID: cue?.id) }]))
                missing.addArrangedSubview(ImageUI.button("Details") { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; self.show(.imageDetail(imageID: image.id, cueID: cue?.id)) }); media.addArrangedSubview(ImageUI.card(missing, padding: 24))
            } else {
                media.addArrangedSubview(ImageUI.card(ImageUI.stack([ImageUI.label("Images appear as you build the scene.", size: 19, weight: .medium), ImageUI.label("Select a script moment, then import or generate an image.", secondary: true), ImageUI.button("Import image…", symbol: "photo.badge.plus") { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; self.store.importImage(cueId: cue?.id) }]), padding: 24))
            }
        }
        let overlaps = store.sceneCues.filter { $0.startMs <= Int(store.playheadMs) && $0.endMs > Int(store.playheadMs) }
        let nextMetadata = "\(String(describing: cue))|\(String(describing: image))|\(inspecting)|\(overlaps.map(\.id))|\(store.project.characters)|\(store.project.entries)|\(store.scriptZoom)|\(store.lockedByOther(cue?.id ?? "") ?? "")"
        if metadataSignature != nextMetadata {
            metadataSignature = nextMetadata; ImageUI.clear(metadata)
            if inspecting { metadata.addArrangedSubview(ImageUI.button("Follow playhead", symbol: "play.circle") { [weak self] in guard let self else { return }; self.store.selectedCueID = self.store.currentCue?.id }) }
            if overlaps.count > 1 {
                let pick = ImageUI.button("\(overlaps.count) overlapping pictures", symbol: "square.3.layers.3d") {}; pick.showsMenuAsPrimaryAction = true
                pick.menu = UIMenu(children: overlaps.reversed().map { item in UIAction(title: item.label.isEmpty ? "Picture at " + ScrivFormat.time(item.startMs) : item.label, state: item.id == cue?.id ? .on : .off) { [weak self] _ in guard let self, self.store.navigationContext == navigation else { return }; if self.store.isPlaying { self.store.togglePlayback() }; self.store.selectedCueID = item.id } })
                metadata.addArrangedSubview(pick); metadata.addArrangedSubview(ImageUI.label("Playback uses the latest-starting active picture. Other placements remain intact.", size: 11, secondary: true))
            }
            if let cue {
                metadata.addArrangedSubview(ImageUI.label("\(ScrivFormat.duration(cue.authoredDurationMs ?? cue.durationMs)) authored · \(ScrivFormat.duration(cue.durationMs)) in scene", size: 11, secondary: true))
                if cue.durationMs == 0 { metadata.addArrangedSubview(ImageUI.label("Dormant · waiting for following script time", size: 11, secondary: true)) }
                let sourceText = cue.startAnchor.flatMap { anchor in store.project.entries.first { $0.id == anchor.entryId } }.map { CueAnchorViewController.entryLabel($0, project: store.project) } ?? "Choose picture source…"
                let sourceButton = ImageUI.button("Source: " + sourceText, symbol: "link") { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; if self.store.isPlaying { self.store.togglePlayback() }; self.show(.cueAnchor(cueID: cue.id)) }
                ImageUI.scriptFont(sourceButton, size: store.scriptFontSize); metadata.addArrangedSubview(sourceButton)
                let menu = ImageUI.button("Picture actions", symbol: "ellipsis") {}; menu.showsMenuAsPrimaryAction = true; menu.menu = imageMenu(cue)
                if let image {
                    let tags = store.project.characters.filter { image.characterIds.contains($0.id) }.map(\.name).joined(separator: " · ")
                    if !tags.isEmpty { metadata.addArrangedSubview(ImageUI.label(tags, size: 12)) }
                    let editTags = ImageUI.button("Edit tags", symbol: "plus") { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; ImageUI.present(CharacterTagsViewController(store: self.store, imageID: image.id), from: self, size: CGSize(width: 390, height: 650)) }
                    let versions = ImageUI.button("Version \(image.version)", symbol: "chevron.down") { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; ImageUI.present(ImagePickerViewController(store: self.store, cueID: cue.id, versionsOf: image.id), from: self) }
                    metadata.addArrangedSubview(ImageUI.row([editTags, ImageUI.spacer(), versions, menu]))
                } else { metadata.addArrangedSubview(menu) }
            }
        }
        playback.update()
    }
    private func chooseImage(cueID: String? = nil) { guard let target = cueID ?? cue?.id, store.project.cues.contains(where: { $0.id == target }) else { return }; ImageUI.present(ImagePickerViewController(store: store, cueID: target), from: self) }
    private func imageMenu(_ cue: ImageCue) -> UIMenu {
        let navigation = store.navigationContext
        return UIMenu(children: [
            ImageUI.guardedAction("Choose existing image…", store: store, context: navigation) { [weak self] in self?.chooseImage(cueID: cue.id) },
            ImageUI.guardedAction("Import image…", store: store, context: navigation) { [weak self] in self?.store.importImage(cueId: cue.id) },
            ImageUI.guardedAction("Generate image", store: store, context: navigation) { [weak self] in self?.store.generateImage(cueId: cue.id) },
            ImageUI.guardedAction("Split at playhead", store: store, context: navigation) { [weak self] in self?.store.splitCue(cue.id) },
            ImageUI.guardedAction("Authored image coverage…", store: store, context: navigation) { [weak self] in guard let self else { return }; ImageUI.present(ImageCoverageViewController(store: self.store, cue: cue), from: self, size: CGSize(width: 430, height: 360)) },
            ImageUI.guardedAction("Discuss image", store: store, context: navigation) { [weak self] in self?.store.loadDiscussion(itemId: cue.imageId ?? cue.id); self?.store.showDiscussion = true }
        ])
    }
}

@MainActor final class ScrivPlaybackControlsView: UIView {
    private let store: WorkspaceStore
    private let play = UIButton(type: .system), seek = UISlider(), volume = UISlider(), mute = UIButton(type: .system)
    private let clock = ImageUI.label(size: 11, weight: .medium)
    init(store: WorkspaceStore) {
        self.store = store; super.init(frame: .zero)
        let previous = UIButton(type: .system), next = UIButton(type: .system)
        previous.setImage(UIImage(systemName: "backward.end.fill"), for: .normal); previous.accessibilityLabel = "Previous picture"
        next.setImage(UIImage(systemName: "forward.end.fill"), for: .normal); next.accessibilityLabel = "Next picture"
        previous.addAction(UIAction { [weak self] _ in guard let self else { return }; self.store.seek(toMs: Double(self.store.sceneCues.map(\.startMs).last { Double($0) < self.store.playheadMs - 100 } ?? 0)) }, for: .touchUpInside)
        next.addAction(UIAction { [weak self] _ in guard let self else { return }; self.store.seek(toMs: Double(self.store.sceneCues.first { Double($0.startMs) > self.store.playheadMs + 100 }?.startMs ?? self.store.sceneDurationMs)) }, for: .touchUpInside)
        play.addAction(UIAction { [weak self] _ in self?.store.togglePlayback() }, for: .touchUpInside)
        seek.accessibilityLabel = "Playback position"; seek.addAction(UIAction { [weak self] _ in guard let self else { return }; self.store.seek(toMs: Double(self.seek.value)) }, for: .valueChanged)
        volume.minimumValue = 0; volume.maximumValue = 1; volume.widthAnchor.constraint(equalToConstant: 58).isActive = true
        volume.accessibilityLabel = "Local audio volume"; volume.addAction(UIAction { [weak self] _ in guard let self else { return }; self.store.setAudioVolume(Double(self.volume.value)) }, for: .valueChanged)
        mute.addAction(UIAction { [weak self] _ in self?.store.toggleAudioMute() }, for: .touchUpInside)
        [previous, play, next, mute].forEach { $0.widthAnchor.constraint(equalToConstant: 28).isActive = true; $0.heightAnchor.constraint(equalToConstant: 34).isActive = true }
        let row = ImageUI.row([previous, play, next, clock, seek, mute, volume], spacing: 6); addSubview(row); row.scrivPinEdges(to: self, insets: NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        backgroundColor = ScrivUIKitTheme.inset; layer.cornerRadius = 11; update()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    func update() {
        play.setImage(UIImage(systemName: store.isPlaying ? "pause.fill" : "play.fill"), for: .normal); play.accessibilityLabel = store.isPlaying ? "Pause" : "Play"
        clock.text = "\(ScrivFormat.time(Int(store.playheadMs))) / \(ScrivFormat.time(store.sceneDurationMs))"
        seek.maximumValue = Float(max(1, store.sceneDurationMs)); if !seek.isTracking { seek.value = Float(store.playheadMs) }
        if !volume.isTracking { volume.value = Float(store.project.audioVolume) }; volume.isEnabled = !store.project.audioClips.isEmpty; mute.isEnabled = volume.isEnabled
        mute.setImage(UIImage(systemName: store.project.audioVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"), for: .normal); mute.accessibilityLabel = store.project.audioVolume == 0 ? "Unmute local audio" : "Mute local audio"
    }
}

@MainActor final class GenerationPanelViewController: ScrivScreenController, UITextViewDelegate {
    private let prompt = UITextView()
    private let target = ImageUI.label(size: 11, weight: .medium, secondary: true)
    private let status = ImageUI.label(size: 11, secondary: true)
    private let recovery = ImageUI.stack(spacing: 8)
    private let brief = ImageUI.text("")
    private var generate: UIButton!
    private var progress: ScrivGenerationProgressView!
    private var promptHeight: NSLayoutConstraint!
    private var scope = ""
    private var editingScope: String?
    private var rejectedDrafts: [String: String] = [:]
    private var unacceptedText: String? {
        get { rejectedDrafts[scope] }
        set { rejectedDrafts[scope] = newValue }
    }
    private var displayedCueID: String?
    private var expanded = false
    private var recoverySignature = ""
    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); prompt.delegate = self; prompt.font = .systemFont(ofSize: 13); prompt.backgroundColor = ScrivUIKitTheme.panel; prompt.layer.cornerRadius = 8
        prompt.accessibilityLabel = "Visual override for this picture"; prompt.textContainer.lineBreakMode = .byWordWrapping
        promptHeight = prompt.heightAnchor.constraint(equalToConstant: 62); promptHeight.isActive = true
        generate = ImageUI.button("Generate image", symbol: "sparkles", primary: true) { [weak self] in guard let self, self.scope == self.store.generationPromptScopeKey else { return }; self.view.endEditing(true); self.store.generateImage(cueId: self.displayedCueID) }
        progress = ScrivGenerationProgressView(controller: store.codex); progress.isHidden = true
        let review = ImageUI.button("Review source, identities and exact brief", symbol: "text.alignleft") { [weak self] in guard let self else { return }; self.expanded.toggle(); self.brief.isHidden = !self.expanded }
        let body = ImageUI.stack([target, prompt, generate, progress, recovery, status, review, brief, ImageUI.label("Exact submitted prompts and manual directions are saved separately. Copied portraits stay in local generation history; image-file storage follows project settings.", size: 10, secondary: true)], spacing: 8)
        view.addSubview(body); body.scrivPinEdges(to: view, insets: NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)); view.layer.cornerRadius = 12; view.backgroundColor = ScrivUIKitTheme.inset
        store.codex.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.storeDidChange() } }.store(in: &subscriptions)
        storeDidChange()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); resizePrompt() }
    override func storeDidChange() {
        guard isViewLoaded, generate != nil else { return }
        if scope != store.generationPromptScopeKey {
            prompt.resignFirstResponder(); editingScope = nil; scope = store.generationPromptScopeKey; store.prepareGenerationPrompt(); prompt.text = store.generationPrompt
        } else if !prompt.isFirstResponder && unacceptedText == nil { prompt.text = store.generationPrompt }
        let context = store.selectedImageGenerationContext; displayedCueID = context?.cueID
        target.text = context.map { "Generation target: \($0.cueLabel.isEmpty ? "Selected picture" : $0.cueLabel) · \($0.passages.count) source passages · \($0.portraits.count) portraits" } ?? "Select an image placement to generate its picture."
        prompt.isEditable = context != nil; generate.isEnabled = context?.hasContent == true && !store.codex.isGenerating && !store.generationPromptNeedsReview && unacceptedText == nil
        generate.configuration?.title = store.codex.isGenerating ? "Generating…" : "Generate image"; progress.isHidden = !store.codex.isGenerating
        status.text = store.generationPromptDraftStatus
        brief.text = context?.prompt ?? ""; brief.isHidden = !expanded; resizePrompt()
        let next = "\(scope)|\(store.generationPromptIssue ?? "")|\(store.generationPromptNeedsReview)|\(store.generationPrompt)|\((store.selectedCue ?? store.currentCue)?.prompt ?? "")|\(unacceptedText ?? "")"
        guard next != recoverySignature else { return }; recoverySignature = next; ImageUI.clear(recovery)
        let expectedScope = scope, expectedDraft = store.generationPrompt, expectedReview = store.generationPromptNeedsReview
        if let unacceptedText {
            recovery.addArrangedSubview(ImageUI.notice("The latest edit could not be written to recovery, so it was not accepted into the field. The attempted text is retained below in memory only. Retry before closing the app.", warning: true))
            recovery.addArrangedSubview(ImageUI.text(unacceptedText))
            recovery.addArrangedSubview(ImageUI.button("Retry retaining this text") { [weak self] in guard let self, self.scope == expectedScope, self.store.generationPromptScopeKey == expectedScope, self.unacceptedText == unacceptedText else { return }; self.store.generationPrompt = unacceptedText; if self.store.generationPrompt.utf16.elementsEqual(unacceptedText.utf16) { self.unacceptedText = nil; self.prompt.text = unacceptedText }; self.storeDidChange() })
        }
        if store.generationPromptNeedsReview || store.generationPromptIssue != nil {
            recovery.addArrangedSubview(ImageUI.notice(store.generationPromptIssue ?? "Recovered visual direction: compare it with the saved direction before using it with the current source.", warning: true))
            if store.generationPromptNeedsReview {
                recovery.addArrangedSubview(ImageUI.label("Saved direction", size: 11, weight: .semibold)); recovery.addArrangedSubview(ImageUI.text((store.selectedCue ?? store.currentCue)?.prompt ?? ""))
                recovery.addArrangedSubview(ImageUI.label("Draft on this Mac", size: 11, weight: .semibold)); recovery.addArrangedSubview(ImageUI.text(store.generationPrompt))
            }
            let retry = ImageUI.button(store.generationPromptNeedsReview ? "Use this draft" : "Retry save", primary: true) { [weak self] in guard let self, self.scope == expectedScope, self.store.generationPromptScopeKey == expectedScope, self.store.generationPrompt.utf16.elementsEqual(expectedDraft.utf16), self.store.generationPromptNeedsReview == expectedReview else { return }; if expectedReview { self.store.rebaseGenerationPrompt() } else { self.store.retryGenerationPrompt() } }
            let discard = ImageUI.button("Discard draft…") { [weak self] in guard let self, self.scope == expectedScope, self.store.generationPromptScopeKey == expectedScope else { return }; let expected = expectedScope; ImageUI.confirm("Discard this local visual direction draft?", message: "The saved picture direction stays unchanged.", destructiveTitle: "Discard local draft", from: self) { [weak self] in guard let self, self.scope == expected, self.store.generationPromptScopeKey == expected, self.store.generationPrompt.utf16.elementsEqual(expectedDraft.utf16) else { return }; self.store.discardGenerationPrompt(); self.unacceptedText = nil; self.prompt.text = self.store.generationPrompt } }
            recovery.addArrangedSubview(ImageUI.row([retry, discard]))
        }
    }
    func textViewDidBeginEditing(_ textView: UITextView) { if store.isPlaying { store.togglePlayback() }; editingScope = scope }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard editingScope == store.generationPromptScopeKey, let sourceRange = Range(range, in: textView.text ?? "") else { return false }
        let candidate = (textView.text ?? "").replacingCharacters(in: sourceRange, with: text)
        // Durable cue-scoped journaling precedes UIKit accepting the mutation.
        store.generationPrompt = candidate
        let accepted = store.generationPrompt.utf16.elementsEqual(candidate.utf16)
        unacceptedText = accepted ? nil : candidate
        if !accepted { storeDidChange() }
        return accepted
    }
    func textViewDidChange(_ textView: UITextView) {
        guard editingScope == store.generationPromptScopeKey else { textView.resignFirstResponder(); storeDidChange(); return }
        let text = textView.text ?? ""; if !store.generationPrompt.utf16.elementsEqual(text.utf16) { store.generationPrompt = text }
        unacceptedText = store.generationPrompt.utf16.elementsEqual(text.utf16) ? nil : text
        resizePrompt(); storeDidChange()
    }
    func textViewDidEndEditing(_ textView: UITextView) { editingScope = nil }
    private func resizePrompt() { guard promptHeight != nil else { return }; let height = prompt.sizeThatFits(CGSize(width: max(100, prompt.bounds.width), height: .greatestFiniteMagnitude)).height; promptHeight.constant = min(180, max(62, height)); prompt.isScrollEnabled = height > 180 }
}
