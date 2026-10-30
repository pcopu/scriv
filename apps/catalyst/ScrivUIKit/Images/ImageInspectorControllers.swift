import UIKit
import ScrivCore

@MainActor final class ImageDetailViewController: ScrivScreenController {
    let imageID: String
    let cueID: String?
    private var content: UIStackView!
    private var signature = ""
    private var promptExpanded = false
    init(store: WorkspaceStore, imageID: String, cueID: String? = nil) {
        self.imageID = imageID; self.cueID = cueID; super.init(store: store)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:imageID:cueID:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); content = ImageUI.scrollStack(in: self); ImageUI.closeButton(self)
        preferredContentSize = CGSize(width: 920, height: 780); storeDidChange()
    }
    override func storeDidChange() {
        guard isViewLoaded, content != nil else { return }
        guard contextIsCurrent else { dismiss(animated: true); return }
        let image = store.project.asset(imageID)
        let cue = UIKitImageContext.placement(imageID: imageID, cueID: cueID, project: store.project)
        let next = "\(String(describing: image))|\(String(describing: cue))|\(image.flatMap { store.assetURL($0) }?.path ?? "")|\(store.project.characters)|\(store.peerTransferStatus)"
        guard next != signature else { return }; signature = next; ImageUI.clear(content)
        guard let image else { title = "Image unavailable"; content.addArrangedSubview(ImageUI.notice("This image is no longer in the project. Close the preview and choose another image.", warning: true)); return }
        let name = UIKitImageContext.title(imageID: image.id, cueID: cueID, project: store.project); title = name
        content.addArrangedSubview(ImageUI.row([ImageUI.label(name, size: 24, weight: .semibold), ImageUI.spacer(), ImageUI.label("Version \(image.version)", size: 12, secondary: true)]))
        if let url = store.assetURL(image) {
            let picture = UIKitAssetImageView(); picture.configure(url: url, title: name, fill: false)
            picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: 9 / 16).isActive = true; content.addArrangedSubview(picture)
        } else { content.addArrangedSubview(missingImageCard(image, title: name, cue: cue)) }
        let tags = ImageUI.stack(spacing: 8)
        for character in store.project.characters where image.characterIds.contains(character.id) {
            let label = ImageUI.label("●  " + character.name, size: 13); label.textColor = ImageUI.color(character.color); tags.addArrangedSubview(label)
        }
        tags.addArrangedSubview(ImageUI.button("Edit tags", symbol: "plus") { [weak self] in guard let self, self.requireCurrentContext() else { return }; ImageUI.present(CharacterTagsViewController(store: self.store, imageID: image.id), from: self, size: CGSize(width: 390, height: 650)) })
        content.addArrangedSubview(tags)
        content.addArrangedSubview(ImageUI.label("Image direction", size: 12, weight: .medium, secondary: true))
        content.addArrangedSubview(ImageUI.text(image.prompt.isEmpty ? "No manual image direction was recorded." : image.prompt, size: 15))
        content.addArrangedSubview(ImageUI.button(promptExpanded ? "Hide captured generation prompt" : "Captured generation prompt", symbol: "text.alignleft") { [weak self] in self?.promptExpanded.toggle(); self?.signature = ""; self?.storeDidChange() })
        if promptExpanded {
            content.addArrangedSubview(ImageUI.text(image.generationPrompt ?? "No exact generation prompt was captured for this imported or older version. Its origin is not inferred from the current script."))
            if image.generationPrompt != nil { content.addArrangedSubview(ImageUI.label("Exact submitted text, separate from the manual image direction above.", size: 11, secondary: true)) }
        }
        content.addArrangedSubview(ImageUI.divider())
        let source = ImageUI.button("Show in script", symbol: "doc.text") { [weak self] in self?.showSource() }; source.isEnabled = cue != nil
        source.accessibilityHint = cue == nil ? "This exact image version has no current script placement." : "Show a placement of this version"
        let discuss = ImageUI.button("Discuss this version", symbol: "bubble.left") { [weak self] in
            guard let self, self.requireCurrentContext() else { return }
            self.dismiss(animated: true) { self.store.loadDiscussion(itemId: image.id); self.store.showDiscussion = true }
        }
        let more = ImageUI.button("More", symbol: "ellipsis") {}; more.showsMenuAsPrimaryAction = true
        var actions: [UIMenuElement] = [UIAction(title: "Copy image direction", attributes: image.prompt.isEmpty ? [.disabled] : []) { _ in UIPasteboard.general.string = image.prompt }]
        if let prompt = image.generationPrompt { actions.append(UIAction(title: "Copy captured generation prompt") { _ in UIPasteboard.general.string = prompt }) }
        if let url = store.assetURL(image) { actions.append(UIAction(title: "Share original image") { [weak self, weak more] _ in guard let self else { return }; let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil); sheet.popoverPresentationController?.sourceView = more ?? self.view; self.present(sheet, animated: true) }) }
        more.menu = UIMenu(children: actions)
        content.addArrangedSubview(ImageUI.row([source, discuss, ImageUI.spacer(), more]))
        content.addArrangedSubview(ImageUI.label("Viewing the original image version.", size: 11, secondary: true))
    }
    private func missingImageCard(_ image: ImageAsset, title: String, cue: ImageCue?) -> UIView {
        let stack = ImageUI.stack([ImageUI.label("Image isn’t on this Mac", size: 22, weight: .semibold), ImageUI.label("\(title) · Version \(image.version)", secondary: true), ImageUI.label("The script and timing are intact. Fetch this image to view it here.")], spacing: 14)
        stack.addArrangedSubview(ImageUI.button("Fetch image", symbol: "arrow.down.circle", primary: true) { [weak self] in guard let self, self.requireCurrentContext() else { return }; self.store.downloadImage(image) })
        if let cue { stack.addArrangedSubview(ImageUI.button("Choose another image…") { [weak self] in guard let self else { return }; ImageUI.present(ImagePickerViewController(store: self.store, cueID: cue.id), from: self) }) }
        stack.addArrangedSubview(ImageUI.label("No verified local copy is available. Fetch uses configured project storage or available peer Macs.", size: 11, secondary: true))
        stack.addArrangedSubview(ImageUI.label("Peer transfer: " + store.peerTransferStatus, size: 11, secondary: true))
        return ImageUI.card(stack, padding: 24)
    }
    private func showSource() {
        guard requireCurrentContext(), let cue = UIKitImageContext.placement(imageID: imageID, cueID: cueID, project: store.project) else { return }
        if store.isPlaying { store.togglePlayback() }
        store.selectScene(cue.sceneId); store.tab = .script; store.seek(toMs: Double(cue.startMs)); store.selectedCueID = cue.id
        if let anchor = cue.startAnchor { store.selectedEntryID = anchor.entryId }; dismiss(animated: true)
    }
}

@MainActor final class CharacterTagsViewController: ScrivScreenController {
    let imageID: String
    private var content: UIStackView!
    private var signature = ""
    init(store: WorkspaceStore, imageID: String) { self.imageID = imageID; super.init(store: store) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:imageID:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Who is pictured?"; ImageUI.closeButton(self); content = ImageUI.scrollStack(in: self, padding: 20); storeDidChange()
    }
    override func storeDidChange() {
        guard isViewLoaded, content != nil else { return }
        guard contextIsCurrent else { dismiss(animated: true); return }
        guard let image = store.project.asset(imageID) else { ImageUI.clear(content); content.addArrangedSubview(ImageUI.notice("This image is no longer in the project.", warning: true)); return }
        let next = "\(image)|\(store.project.characters)|\(store.assetURL(image)?.path ?? "")|\(store.lockedByOther(imageID) ?? "")"
        guard next != signature else { return }; signature = next; ImageUI.clear(content)
        content.addArrangedSubview(ImageUI.label(UIKitImageContext.title(imageID: image.id, project: store.project) + " · Version \(image.version)", secondary: true))
        let picture = UIKitAssetImageView(); picture.configure(url: store.assetURL(image), title: "Image being tagged", fill: false, missingText: "Not on this Mac")
        picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: 9 / 16).isActive = true; content.addArrangedSubview(picture)
        content.addArrangedSubview(ImageUI.label("Tag people visible in this image, not people mentioned in the script.", size: 12, secondary: true))
        for character in store.project.characters {
            let portrait = UIKitAssetImageView(); portrait.layer.cornerRadius = 22
            portrait.configure(url: store.project.asset(character.portraitImageId).flatMap { store.assetURL($0) }, title: character.name, missingText: String(character.name.prefix(1)))
            portrait.widthAnchor.constraint(equalToConstant: 44).isActive = true; portrait.heightAnchor.constraint(equalToConstant: 44).isActive = true
            let name = ImageUI.label("●  " + character.name, size: 15, weight: .medium); name.textColor = ImageUI.color(character.color)
            let toggle = UISwitch(); toggle.isOn = image.characterIds.contains(character.id); toggle.isEnabled = store.lockedByOther(image.id) == nil; toggle.accessibilityLabel = character.name
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle, self.requireCurrentContext(), let current = self.store.project.asset(self.imageID) else { return }
                var tags = current.characterIds
                if toggle.isOn { if !tags.contains(character.id) { tags.append(character.id) } } else { tags.removeAll { $0 == character.id } }
                self.store.setCharacterTags(imageId: current.id, characterIds: tags)
                toggle.isOn = self.store.project.asset(current.id)?.characterIds.contains(character.id) == true
            }, for: .valueChanged)
            content.addArrangedSubview(ImageUI.row([portrait, name, ImageUI.spacer(), toggle])); content.addArrangedSubview(ImageUI.divider())
        }
        if store.project.characters.isEmpty { content.addArrangedSubview(ImageUI.button("Add a character", symbol: "person.badge.plus") { [weak self] in self?.show(.characterEditor(characterID: nil)) }) }
        content.addArrangedSubview(ImageUI.label("✓ Changes save automatically", size: 12, secondary: true))
    }
}

extension ScrivUIKitFeatures {
    @MainActor static func registerImages(in router: ScrivUIKitRouter) {
        router.register(.preview) { _, store in PreviewViewController(store: store) }
        router.register(.storyboard) { _, store in StoryboardViewController(store: store) }
        router.register(.imageDetail) { route, store in
            guard case let .imageDetail(imageID, cueID) = route else { return nil }
            let controller = ImageDetailViewController(store: store, imageID: imageID, cueID: cueID)
            let navigation = UINavigationController(rootViewController: controller); navigation.preferredContentSize = CGSize(width: 920, height: 780); return navigation
        }
        router.register(.cueAnchor) { route, store in
            guard case let .cueAnchor(id) = route, let cue = store.project.cues.first(where: { $0.id == id }) else { return nil }
            let navigation = UINavigationController(rootViewController: CueAnchorViewController(store: store, cue: cue)); navigation.preferredContentSize = CGSize(width: 550, height: 700); return navigation
        }
    }
}
