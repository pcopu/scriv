import UIKit
import Combine
import ScrivCore

@MainActor final class PreviewViewController: ScrivScreenController {
    private var content: UIStackView!
    private let subtitle = ImageUI.label(size: 16, secondary: true)
    private let state = ImageUI.label(size: 11, weight: .medium, secondary: true)
    private let media = ImageUI.stack()
    private let metadata = ImageUI.stack(spacing: 8)
    private var mediaSignature = ""
    private var metadataSignature: [AnyHashable] = []
    private var timeline: LayerTimelineViewController!
    private var timelineHeight: NSLayoutConstraint?
    private var layersDisclosure: PreviewLayersDisclosureView!
    private(set) var layersExpanded = false
    private var generation: GenerationPanelViewController!
    /// Inspect opens the original image; with no image it is disabled rather
    /// than a button that silently does nothing.
    private var expand = UIButton()
    private var cue: ImageCue? { store.isPlaying ? store.currentCue : store.selectedCue ?? store.currentCue }
    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Preview"; content = ImageUI.scrollStack(in: self, spacing: 9, padding: 12); view.backgroundColor = ScrivUIKitTheme.panel
        expand = PreviewChromeUI.inspect { [weak self] in guard let self, let imageID = self.cue?.imageId else { return }; self.show(.imageDetail(imageID: imageID, cueID: self.cue?.id)) }
        expand.accessibilityHint = "Opens the original image when this picture has one."
        // A one-word title must never wrap ("Previe / w") when the panel narrows.
        let heading = ImageUI.label("Preview", size: 30, weight: .semibold)
        heading.numberOfLines = 1; heading.setContentCompressionResistancePriority(.required, for: .horizontal)
        content.addArrangedSubview(ImageUI.row([heading, ImageUI.spacer(), ImageUI.badge("16:9"), expand]))
        content.addArrangedSubview(subtitle); content.addArrangedSubview(media); content.addArrangedSubview(state); content.addArrangedSubview(metadata)
        layersDisclosure = PreviewLayersDisclosureView { [weak self] in guard let self else { return }; self.setLayersExpanded(!self.layersExpanded) }
        content.addArrangedSubview(layersDisclosure)
        timeline = LayerTimelineViewController(store: store); addChild(timeline); timeline.didMove(toParent: self)
        generation = GenerationPanelViewController(store: store); addChild(generation); content.addArrangedSubview(generation.view); generation.didMove(toParent: self)
        storeDidChange()
    }
    override func storeDidChange() {
        if isViewLoaded { expand.isEnabled = cue?.imageId != nil }
        guard isViewLoaded, content != nil else { return }
        let navigation = store.navigationContext
        let cue = self.cue, image = store.project.asset(cue?.imageId), url = image.flatMap { store.assetURL($0) }
        subtitle.text = cue.map { ($0.label.isEmpty ? "Picture at " + ScrivFormat.time($0.startMs) : $0.label) + (image.map { " · Version \($0.version)" } ?? " · No image chosen") } ?? "Select a script moment or image"
        let inspecting = !store.isPlaying && cue != nil && cue?.id != store.currentCue?.id
        state.text = inspecting ? "Inspecting selected image · starts " + ScrivFormat.time(cue?.startMs ?? 0) : "Following playhead"; state.textColor = inspecting ? ImageUI.accent : ScrivUIKitTheme.secondary; state.isHidden = !inspecting
        let nextMedia = "\(store.navigationContext)|\(cue?.id ?? "")|\(image?.id ?? "")|\(url?.path ?? "")"
        if nextMedia != mediaSignature {
            mediaSignature = nextMedia; ImageUI.clear(media)
            if let image, let url {
                let picture = UIKitAssetImageView(); picture.configure(url: url, title: cue?.label ?? "Scene preview", fill: false, expectedDigest: image.sha256)
                picture.accessibilityIdentifier = "preview-picture"
                picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: 9.0 / 16.0).isActive = true; media.addArrangedSubview(picture)
            } else if let image {
                let missing = ImageUI.stack([ImageUI.label("Image isn’t on this Mac", size: 20, weight: .semibold), ImageUI.label("The script and timing are intact. Fetch this image to view it here.", size: 13, secondary: true)], spacing: 12)
                missing.addArrangedSubview(ImageUI.row([ImageUI.button("Fetch image", primary: true) { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; self.store.downloadImage(image) }, ImageUI.button("Choose another image…") { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; self.chooseImage(cueID: cue?.id) }]))
                missing.addArrangedSubview(ImageUI.button("Details") { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; self.show(.imageDetail(imageID: image.id, cueID: cue?.id)) }); media.addArrangedSubview(ImageUI.card(missing, padding: 24))
            } else {
                media.addArrangedSubview(ImageUI.card(ImageUI.stack([ImageUI.label("Images appear as you build the scene.", size: 19, weight: .medium), ImageUI.label("Select a script moment, then import or generate an image.", secondary: true), ImageUI.button("Import image…", symbol: "photo.badge.plus") { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; self.store.importImage(cueId: cue?.id) }]), padding: 24))
            }
        }
        let overlaps = store.sceneCues.filter { $0.startMs <= Int(store.playheadMs) && $0.endMs > Int(store.playheadMs) }
        // Compare values directly; describing whole model arrays as strings was
        // reflection over the entire project on every playback tick.
        let nextMetadata: [AnyHashable] = [cue, image, inspecting, overlaps.map(\.id), store.project.characters, store.project.entries, store.scriptZoom, store.lockedByOther(cue?.id ?? "")]
        if metadataSignature != nextMetadata {
            metadataSignature = nextMetadata; ImageUI.clear(metadata)
            if inspecting { metadata.addArrangedSubview(ImageUI.button("Follow playhead", symbol: "play.circle") { [weak self] in guard let self else { return }; self.store.selectedCueID = self.store.currentCue?.id }) }
            if overlaps.count > 1 {
                let pick = ImageUI.button("\(overlaps.count) overlapping pictures", symbol: "square.3.layers.3d") {}; pick.showsMenuAsPrimaryAction = true
                pick.menu = UIMenu(children: overlaps.reversed().map { item in UIAction(title: item.label.isEmpty ? "Picture at " + ScrivFormat.time(item.startMs) : item.label, state: item.id == cue?.id ? .on : .off) { [weak self] _ in guard let self, self.store.navigationContext == navigation else { return }; if self.store.isPlaying { self.store.togglePlayback() }; self.store.selectedCueID = item.id } })
                metadata.addArrangedSubview(pick); metadata.addArrangedSubview(ImageUI.label("Playback uses the latest-starting active picture. Other placements remain intact.", size: 11, secondary: true))
            }
            if let cue {
                if (cue.authoredDurationMs ?? cue.durationMs) != cue.durationMs {
                    metadata.addArrangedSubview(ImageUI.label("\(ScrivFormat.duration(cue.durationMs)) in scene · \(ScrivFormat.duration(cue.authoredDurationMs ?? cue.durationMs)) authored", size: 11, secondary: true))
                }
                if cue.durationMs == 0 { metadata.addArrangedSubview(ImageUI.label("Dormant · waiting for following script time", size: 11, secondary: true)) }
                let menu = ImageUI.button("", symbol: "ellipsis") {}; menu.accessibilityLabel = "Picture source, coverage and actions"; menu.showsMenuAsPrimaryAction = true; menu.menu = imageMenu(cue); ImageUI.compact(menu)
                if let image {
                    var tags: [UIView] = store.project.characters.filter { image.characterIds.contains($0.id) }.map { ImageUI.tag($0.name, color: ImageUI.color($0.color), compact: true) }
                    let editTags = ImageUI.button("", symbol: "plus") { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; ImageUI.present(CharacterTagsViewController(store: self.store, imageID: image.id), from: self, size: CGSize(width: 390, height: 650)) }
                    editTags.accessibilityLabel = "Edit pictured character tags"; ImageUI.compact(editTags); tags.append(editTags)
                    let versions = PreviewChromeUI.version(image.version) { [weak self] in guard let self, self.store.navigationContext == navigation else { return }; ImageUI.present(ImagePickerViewController(store: self.store, cueID: cue.id, versionsOf: image.id), from: self) }
                    metadata.addArrangedSubview(ImageUI.row([ImageTagFlowView(tags), versions, menu], spacing: 6))
                } else { metadata.addArrangedSubview(ImageUI.row([ImageUI.spacer(), menu])) }
            }
        }
        layersDisclosure.update(expanded: layersExpanded, duration: ScrivFormat.duration(store.sceneDurationMs))
    }
    func setLayersExpanded(_ expanded: Bool) {
        guard layersExpanded != expanded else { return }; layersExpanded = expanded
        if expanded, let index = content.arrangedSubviews.firstIndex(of: layersDisclosure) {
            content.insertArrangedSubview(timeline.view, at: index + 1)
            if timelineHeight == nil { timelineHeight = timeline.view.heightAnchor.constraint(equalToConstant: 276) }
            timelineHeight?.isActive = true
            timeline.beginAppearanceTransition(true, animated: false); timeline.endAppearanceTransition()
        } else if timeline.isViewLoaded {
            timeline.beginAppearanceTransition(false, animated: false)
            content.removeArrangedSubview(timeline.view); timeline.view.removeFromSuperview()
            timeline.endAppearanceTransition()
        }
        layersDisclosure.update(expanded: expanded, duration: ScrivFormat.duration(store.sceneDurationMs))
    }
    private func chooseImage(cueID: String? = nil) { guard let target = cueID ?? cue?.id, store.project.cues.contains(where: { $0.id == target }) else { return }; ImageUI.present(ImagePickerViewController(store: store, cueID: target), from: self) }
    private func imageMenu(_ cue: ImageCue) -> UIMenu {
        let navigation = store.navigationContext
        return UIMenu(children: [
            ImageUI.guardedAction("Picture source…", store: store, context: navigation) { [weak self] in guard let self else { return }; if self.store.isPlaying { self.store.togglePlayback() }; self.show(.cueAnchor(cueID: cue.id)) },
            ImageUI.guardedAction("Choose existing image…", store: store, context: navigation) { [weak self] in self?.chooseImage(cueID: cue.id) },
            ImageUI.guardedAction("Import image…", store: store, context: navigation) { [weak self] in self?.store.importImage(cueId: cue.id) },
            ImageUI.guardedAction("Generate image", store: store, context: navigation) { [weak self] in self?.store.generateImage(cueId: cue.id) },
            ImageUI.guardedAction("Preview picture split…", store: store, context: navigation) { [weak self] in guard let self else { return }; ImageSplitPreviewController.present(store: self.store, cue: cue, from: self) },
            ImageUI.guardedAction("Authored image coverage…", store: store, context: navigation) { [weak self] in guard let self else { return }; ImageUI.present(ImageCoverageViewController(store: self.store, cue: cue), from: self, size: CGSize(width: 430, height: 360)) },
            ImageUI.guardedAction("Discuss image", store: store, context: navigation) { [weak self] in self?.store.loadDiscussion(itemId: cue.imageId ?? cue.id); self?.store.showDiscussion = true }
        ])
    }
}

/// Local Preview chrome, not a review-sheet command. Keep full labels readable
/// without inheriting the sheet's larger command padding or changing shared UI.
@MainActor enum PreviewChromeUI {
    static func inspect(action: @escaping () -> Void) -> UIButton {
        let button = compactButton("Inspect", symbol: "arrow.up.left.and.arrow.down.right", action: action)
        button.accessibilityIdentifier = "preview-inspect"
        button.accessibilityLabel = "Inspect original image"
        return button
    }
    static func version(_ number: Int, action: @escaping () -> Void) -> UIButton {
        let button = compactButton("Version \(number)", symbol: "chevron.down", action: action)
        button.configuration?.imagePlacement = .trailing
        button.accessibilityIdentifier = "preview-version"
        button.accessibilityLabel = "Image version \(number), choose another version"
        return button
    }
    private static func compactButton(_ title: String, symbol: String, action: @escaping () -> Void) -> UIButton {
        let button = ImageUI.button(title, symbol: symbol, action: action)
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming; outgoing.font = .systemFont(ofSize: 15, weight: .medium); return outgoing
        }
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
        button.configuration?.background.backgroundColor = .clear
        button.configuration?.background.strokeWidth = 0
        button.configuration?.titleLineBreakMode = .byWordWrapping
        button.titleLabel?.numberOfLines = 0
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

@MainActor final class ScrivPlaybackControlsView: UIView {
    private let store: WorkspaceStore
    private let play = UIButton(type: .system), seek = UISlider(), volume = UISlider(), mute = UIButton(type: .system)
    private let clock = ImageUI.label(size: 11, weight: .medium)
    init(store: WorkspaceStore, compact: Bool = false) {
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
        [previous, next, mute].forEach { $0.widthAnchor.constraint(equalToConstant: 26).isActive = true; $0.heightAnchor.constraint(equalToConstant: 32).isActive = true; $0.tintColor = ScrivUIKitTheme.ink }
        play.widthAnchor.constraint(equalToConstant: compact ? 26 : 36).isActive = true; play.heightAnchor.constraint(equalToConstant: compact ? 32 : 36).isActive = true
        play.backgroundColor = compact ? .clear : ImageUI.accent; play.tintColor = compact ? ImageUI.accent : .white; play.layer.cornerRadius = compact ? 0 : 18
        if compact { [previous, next, mute].forEach { $0.tintColor = ImageUI.accent } }
        play.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold), forImageIn: .normal)
        clock.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium); clock.numberOfLines = 1
        clock.setContentCompressionResistancePriority(.required, for: .horizontal)
        seek.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = ImageUI.row([previous, play, next, clock, seek, mute, volume], spacing: 6); addSubview(row); row.scrivPinEdges(to: self, insets: NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        backgroundColor = ScrivUIKitTheme.panel; layer.cornerRadius = 11; layer.borderColor = ScrivUIKitTheme.hairline.cgColor; layer.borderWidth = compact ? 0 : 0.5; update()
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
    private let prompt = GenerationDirectionTextView(frame: .zero, textContainer: nil)
    private let target = ImageUI.label(size: 15, weight: .medium, secondary: true)
    private let status = ImageUI.label(size: 14, secondary: true)
    private let recovery = ImageUI.stack(spacing: 8)
    private var generate: UIButton!
    private var review: UIButton!
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
    private var recoverySignature = ""
    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); prompt.delegate = self; prompt.textContainer.lineBreakMode = .byWordWrapping
        prompt.accessibilityIdentifier = "generation-optional-direction"
        promptHeight = prompt.heightAnchor.constraint(equalToConstant: 62); promptHeight.isActive = true
        generate = GenerationReviewUI.button("Generate image", primary: true) { [weak self] in
            guard let self, self.store.generationPromptPresentationIsCurrent, self.scope == self.store.generationPromptScopeKey, let cueID = self.displayedCueID else { return }
            let expectedScope = self.scope; self.view.endEditing(true)
            guard self.store.generationPromptScopeKey == expectedScope, self.displayedCueID == cueID else { return }
            self.store.generateImage(cueId: cueID)
        }
        generate.accessibilityIdentifier = "generation-generate-image"
        progress = ScrivGenerationProgressView(controller: store.codex); progress.isHidden = true
        review = GenerationReviewUI.button("Review brief…") { [weak self] in
            guard let self, self.store.generationPromptPresentationIsCurrent, self.presentedViewController == nil, self.scope == self.store.generationPromptScopeKey else { return }
            self.view.endEditing(true)
            guard let context = self.store.selectedImageGenerationContext, context.cueID == self.displayedCueID else { return }
            let controller = GenerationBriefReviewController(store: self.store, context: context)
            // Fitted like every sheet: inside the window's safe area, refitted as it resizes.
            ScrivSheetFitting.fit(controller, presentedFrom: self)
            self.present(controller, animated: true)
        }
        review.accessibilityLabel = "Review source, people and exact image request"; review.accessibilityIdentifier = "generation-review-brief"
        generate.setContentCompressionResistancePriority(.required, for: .horizontal)
        let body = ImageUI.stack([ImageUI.label("Create image", size: 21, weight: .semibold), target, ImageUI.label("Image direction (optional)", size: 16, secondary: true), prompt, GenerationReviewUI.caption("Leave blank to follow the script."), GenerationComposerActionRow(review: review, generate: generate), progress, recovery, status], spacing: 7)
        view.addSubview(body); body.scrivPinEdges(to: view, insets: NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)); view.layer.cornerRadius = 10; view.backgroundColor = ScrivUIKitTheme.inset
        view.layer.borderWidth = 0.75; view.layer.borderColor = ImageUI.accent.withAlphaComponent(0.16).cgColor
        store.codex.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.storeDidChange() } }.store(in: &subscriptions)
        storeDidChange()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); resizePrompt() }
    override func storeDidChange() {
        guard isViewLoaded, generate != nil else { return }
        if scope != store.generationPromptScopeKey {
            prompt.resignFirstResponder(); editingScope = nil; scope = store.generationPromptScopeKey; store.prepareGenerationPromptForPresentation(force:true); prompt.text = store.generationPrompt
        } else {
            store.prepareGenerationPromptForPresentation()
            if !prompt.isFirstResponder && unacceptedText == nil { let text = store.generationPrompt; if prompt.text != text { prompt.text = text } }
        }
        let context = store.selectedImageGenerationContext; displayedCueID = context?.cueID
        target.text = context.map { GenerationBriefSnapshot(context: $0, localPortraitURLs: [:]).composerTarget(isPlaying: store.isPlaying, playingCue: store.currentCue) } ?? "Select a picture placement in Script or Storyboard."
        generate.accessibilityLabel = context.map { "Generate image for " + ($0.cueLabel.isEmpty ? "selected picture" : $0.cueLabel) } ?? "Generate image"
        review.isEnabled = context != nil && store.generationPromptPresentationIsCurrent
        prompt.isEditable = context != nil && store.generationPromptRecoveryIsReady; generate.isEnabled = store.generationPromptPresentationIsCurrent && context?.hasContent == true && !store.codex.isGenerating && !store.generationPromptNeedsReview && unacceptedText == nil
        let title = store.codex.isGenerating ? "Generating…" : "Generate image"
        if generate.configuration?.title != title { generate.configuration?.title = title }; progress.isHidden = !store.codex.isGenerating
        status.text = store.generationPromptDraftStatus; status.isHidden = status.text == nil
        recovery.isHidden = store.generationPromptIssue == nil && !store.generationPromptNeedsReview && unacceptedText == nil
        prompt.updatePlaceholder(); resizePrompt()
        let next = "\(scope)|\(store.generationPromptIssue ?? "")|\(store.generationPromptNeedsReview)|\(store.generationPrompt)|\((store.selectedCue ?? store.currentCue)?.prompt ?? "")|\(unacceptedText ?? "")"
        guard next != recoverySignature else { return }; recoverySignature = next; ImageUI.clear(recovery)
        let expectedScope = scope, expectedDraft = store.generationPrompt, expectedReview = store.generationPromptNeedsReview
        if let unacceptedText {
            recovery.addArrangedSubview(ImageUI.notice("The latest edit could not be written to recovery, so it was not accepted into the field. The attempted text is retained below in memory only. Retry before closing the app.", warning: true))
            recovery.addArrangedSubview(ImageUI.text(unacceptedText))
            recovery.addArrangedSubview(ImageUI.button("Retry retaining this text") { [weak self] in guard let self, self.store.generationPromptRecoveryIsReady, self.scope == expectedScope, self.store.generationPromptScopeKey == expectedScope, self.unacceptedText == unacceptedText else { return }; self.store.generationPrompt = unacceptedText; if self.store.generationPrompt.utf16.elementsEqual(unacceptedText.utf16) { self.unacceptedText = nil; self.prompt.text = unacceptedText }; self.storeDidChange() })
        }
        if store.generationPromptNeedsReview || store.generationPromptIssue != nil {
            recovery.addArrangedSubview(ImageUI.notice(store.generationPromptIssue ?? "Recovered visual direction: compare it with the saved direction before using it with the current source.", warning: true))
            if store.generationPromptNeedsReview {
                recovery.addArrangedSubview(ImageUI.label("Saved direction", size: 11, weight: .semibold)); recovery.addArrangedSubview(ImageUI.text((store.selectedCue ?? store.currentCue)?.prompt ?? ""))
                recovery.addArrangedSubview(ImageUI.label("Draft on this Mac", size: 11, weight: .semibold)); recovery.addArrangedSubview(ImageUI.text(store.generationPrompt))
            }
            let retry = ImageUI.button(store.generationPromptNeedsReview ? "Use this draft" : "Retry save", primary: true) { [weak self] in guard let self, self.scope == expectedScope, self.store.generationPromptScopeKey == expectedScope, self.store.generationPrompt.utf16.elementsEqual(expectedDraft.utf16), self.store.generationPromptNeedsReview == expectedReview else { return }; if expectedReview { guard self.store.generationPromptRecoveryIsReady else { return }; self.store.rebaseGenerationPrompt() } else { self.store.prepareGenerationPromptForPresentation(force:true) } }
            let discard = ImageUI.button("Discard draft…") { [weak self] in guard let self, self.scope == expectedScope, self.store.generationPromptScopeKey == expectedScope else { return }; let expected = expectedScope; ImageUI.confirm("Discard this local visual direction draft?", message: "The saved picture direction stays unchanged.", destructiveTitle: "Discard local draft", from: self) { [weak self] in guard let self, self.store.generationPromptRecoveryIsReady, self.scope == expected, self.store.generationPromptScopeKey == expected, self.store.generationPrompt.utf16.elementsEqual(expectedDraft.utf16) else { return }; self.store.discardGenerationPrompt(); self.unacceptedText = nil; self.prompt.text = self.store.generationPrompt } }
            recovery.addArrangedSubview(ImageUI.row([retry, discard]))
        }
    }
    func textViewDidBeginEditing(_ textView: UITextView) { if store.isPlaying { store.togglePlayback() }; editingScope = scope }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard store.generationPromptRecoveryIsReady, editingScope == store.generationPromptScopeKey, let sourceRange = Range(range, in: textView.text ?? "") else { return false }
        let candidate = (textView.text ?? "").replacingCharacters(in: sourceRange, with: text)
        // Durable cue-scoped journaling precedes UIKit accepting the mutation.
        store.generationPrompt = candidate
        let accepted = store.generationPrompt.utf16.elementsEqual(candidate.utf16)
        unacceptedText = accepted ? nil : candidate
        if !accepted { storeDidChange() }
        return accepted
    }
    func textViewDidChange(_ textView: UITextView) {
        guard store.generationPromptRecoveryIsReady, editingScope == store.generationPromptScopeKey else { textView.resignFirstResponder(); storeDidChange(); return }
        let text = textView.text ?? ""; if !store.generationPrompt.utf16.elementsEqual(text.utf16) { store.generationPrompt = text }
        unacceptedText = store.generationPrompt.utf16.elementsEqual(text.utf16) ? nil : text
        resizePrompt(); storeDidChange()
    }
    func textViewDidEndEditing(_ textView: UITextView) { editingScope = nil }
    private var promptSizeInput: (text: String, width: CGFloat, editing: Bool)?
    private func resizePrompt() {
        guard promptHeight != nil else { return }
        // Measuring a text view is costly and this runs on every refresh.
        let input = (text: prompt.text ?? "", width: prompt.bounds.width, editing: prompt.isFirstResponder)
        if let promptSizeInput, promptSizeInput.text == input.text, promptSizeInput.width == input.width, promptSizeInput.editing == input.editing { return }
        promptSizeInput = input
        let height = prompt.sizeThatFits(CGSize(width: max(100, prompt.bounds.width), height: CGFloat.greatestFiniteMagnitude)).height; let limit: CGFloat = prompt.isFirstResponder ? 96 : 62; promptHeight.constant = min(limit, max(62, height)); prompt.isScrollEnabled = height > limit; prompt.updatePlaceholder()
    }
}
