import UIKit
import ScrivCore

/// A picture cut preview; dragging this control never seeks or edits script.
@MainActor final class ImageSplitPreviewController: ScrivScreenController {
    private let original: ImageCue
    private let revision: Int
    private var cutMs: Int
    private let slider = UISlider()
    private let before = ImageUI.label(size: 14, weight: .medium)
    private let after = ImageUI.label(size: 14, weight: .medium)
    private let time = ImageUI.label(size: 18, weight: .semibold)
    private let cutMarker = UIView()
    private let imageContainer = UIView()
    private var markerPosition: NSLayoutConstraint?
    private var apply: UIButton!
    init(store: WorkspaceStore, cue: ImageCue) {
        original = cue; revision = store.project.revision
        let playhead = Int(store.playheadMs)
        cutMs = playhead > cue.startMs && playhead < cue.endMs ? playhead : cue.startMs + cue.durationMs / 2
        super.init(store: store)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:cue:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Split picture"; view.backgroundColor = ScrivUIKitTheme.panel
        preferredContentSize = CGSize(width: 420, height: 620)
        let image = UIKitAssetImageView()
        if let asset = store.project.asset(original.imageId) { image.configure(url: store.assetURL(asset), title: original.label, fill: false, expectedDigest: asset.sha256) }
        image.scrivPinEdges(to: imageContainer); imageContainer.heightAnchor.constraint(equalToConstant: 150).isActive = true
        cutMarker.translatesAutoresizingMaskIntoConstraints = false; cutMarker.backgroundColor = ImageUI.accent; cutMarker.isUserInteractionEnabled = false; imageContainer.addSubview(cutMarker)
        markerPosition = cutMarker.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor)
        NSLayoutConstraint.activate([cutMarker.topAnchor.constraint(equalTo: imageContainer.topAnchor), cutMarker.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor), cutMarker.widthAnchor.constraint(equalToConstant: 2), markerPosition!])
        slider.minimumValue = Float(original.startMs + 1); slider.maximumValue = Float(max(original.startMs + 1, original.endMs - 1)); slider.value = Float(cutMs)
        slider.accessibilityIdentifier = "split-picture-cut-preview"; slider.accessibilityLabel = "Preview picture cut time"
        slider.addTarget(self, action: #selector(moveCut), for: .valueChanged)
        let cancel = ImageUI.button("Cancel") { [weak self] in self?.dismiss(animated: true) }
        apply = ImageUI.button("Split picture", symbol: "scissors", primary: true) { [weak self] in self?.commit() }
        apply.accessibilityIdentifier = "split-picture-commit"
        let beforeCard = halfPreview(before), afterCard = halfPreview(after)
        let halves = ImageUI.row([beforeCard, afterCard], spacing: 10); beforeCard.widthAnchor.constraint(equalTo: afterCard.widthAnchor).isActive = true
        let note = ImageUI.label("Picture only · script stays unchanged. Both halves keep this exact image version.", size: 12)
        note.textColor = ImageUI.accent
        let content = ImageUI.stack([ImageUI.label("Split " + (original.label.isEmpty ? "picture" : original.label), size: 22, weight: .semibold), time, imageContainer, slider, halves, ImageUI.card(note, padding: 10), ImageUI.row([ImageUI.spacer(), cancel, apply])], spacing: 10)
        ImageUI.pinToSafeArea(content, in: self, insets: .init(top: 18, leading: 20, bottom: 18, trailing: 20)); updatePreview()
    }
    private func halfPreview(_ title: UILabel) -> UIView {
        let picture = UIKitAssetImageView()
        if let asset = store.project.asset(original.imageId) { picture.configure(url: store.assetURL(asset), title: original.label, fill: false, expectedDigest: asset.sha256) }
        picture.heightAnchor.constraint(equalToConstant: 74).isActive = true
        return ImageUI.card(ImageUI.stack([title, picture], spacing: 8), padding: 8)
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); updateMarker() }
    private func updateMarker() { markerPosition?.constant = imageContainer.bounds.width * CGFloat(cutMs - original.startMs) / CGFloat(max(1, original.durationMs)) }
    @objc private func moveCut() { cutMs = Int(slider.value.rounded()); updatePreview() }
    private func updatePreview() {
        time.text = ScrivFormat.time(cutMs)
        before.text = "Before · " + ScrivFormat.duration(max(0, cutMs - original.startMs))
        after.text = "After · " + ScrivFormat.duration(max(0, original.endMs - cutMs))
        slider.accessibilityValue = ScrivFormat.time(cutMs)
        updateMarker()
        apply.isEnabled = contextIsCurrent && store.project.revision == revision && store.project.cues.first(where: { $0.id == original.id }) == original && cutMs > original.startMs && cutMs < original.endMs
    }
    override func storeDidChange() { guard isViewLoaded, apply != nil else { return }; updatePreview() }
    private func commit() {
        guard requireCurrentContext(), store.project.revision == revision else { store.errorMessage = "The scene changed. Open a fresh picture cut preview."; return }
        if store.splitCue(original.id, atMs: cutMs, expected: original) { dismiss(animated: true) }
    }
    static func present(store: WorkspaceStore, cue: ImageCue, from owner: UIViewController, anchor: UIView? = nil) {
        guard owner.presentedViewController == nil else { return }
        if store.isPlaying { store.togglePlayback() }
        let controller = ImageSplitPreviewController(store: store, cue: cue)
        if let anchor {
            controller.modalPresentationStyle = .popover
            controller.popoverPresentationController?.sourceView = anchor
            controller.popoverPresentationController?.sourceRect = anchor.bounds
        } else { controller.modalPresentationStyle = .formSheet }
        owner.present(controller, animated: true)
    }
}
