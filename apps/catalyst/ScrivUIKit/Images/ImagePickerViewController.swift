import UIKit
import ScrivCore

@MainActor final class ImagePickerViewController: ScrivScreenController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate {
    private let cueID: String
    private let versionsOf: String?
    private var chosenID: String?
    private var query = ""
    private var images: [ImageAsset] = []
    private let search = UISearchBar()
    private let subtitle = ImageUI.label(secondary: true)
    private let collection: UICollectionView
    private let emptyLabel = ImageUI.label("No project images yet. Import or generate an image, then reuse it here.", size: 15, secondary: true)
    private var useButton: UIButton!
    private var dataSignature: [AnyHashable] = []
    private var collectionWidth: CGFloat = 0

    init(store: WorkspaceStore, cueID: String, versionsOf: String? = nil) {
        self.cueID = cueID; self.versionsOf = versionsOf; chosenID = store.project.cues.first { $0.id == cueID }?.imageId
        let layout = UICollectionViewFlowLayout(); layout.minimumInteritemSpacing = 14; layout.minimumLineSpacing = 14
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout); super.init(store: store)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:cueID:versionsOf:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = versionsOf == nil ? "Choose an image" : "Image versions"; navigationController?.setNavigationBarHidden(true, animated: false); view.backgroundColor = ScrivUIKitTheme.panel
        preferredContentSize = CGSize(width: 720, height: 720)
        search.placeholder = "Character, alias or image direction"; search.searchBarStyle = .minimal; search.delegate = self
        search.searchTextField.font = .systemFont(ofSize: 13); search.searchTextField.backgroundColor = ScrivUIKitTheme.panel; search.searchTextField.layer.borderColor = ScrivUIKitTheme.hairline.cgColor; search.searchTextField.layer.borderWidth = 0.75; search.searchTextField.layer.cornerRadius = 8
        collection.backgroundColor = .clear; collection.dataSource = self; collection.delegate = self
        collection.register(ImageChoiceCollectionCell.self, forCellWithReuseIdentifier: "image")
        emptyLabel.textAlignment = .center; collection.backgroundView = emptyLabel
        let cancel = ImageUI.button("Cancel") { [weak self] in self?.dismiss(animated: true) }
        useButton = ImageUI.button(versionsOf == nil ? "Use image" : "Use version", primary: true) { [weak self] in self?.useSelection() }
        useButton.accessibilityIdentifier = "image-picker-use-selection"
        ImagePickerSelectionAppearance.install(on: useButton)
        let footer = ImageUI.row([ImageUI.label("ⓘ  Only this placement changes. Other uses and discussions stay intact.", size: 11, secondary: true), ImageUI.spacer(), cancel, useButton], spacing: 12)
        let heading = ImageUI.stack([ImageUI.label(title ?? "Choose an image", size: 24, weight: .semibold), subtitle], spacing: 4)
        let stack = ImageUI.stack([heading, search, collection, ImageUI.divider(), footer], spacing: 14)
        ImageUI.pinToSafeArea(stack, in: self, insets: NSDirectionalEdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        storeDidChange()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); if abs(collection.bounds.width - collectionWidth) > 0.5 { collectionWidth = collection.bounds.width; collection.collectionViewLayout.invalidateLayout() } }
    override func storeDidChange() {
        guard isViewLoaded, useButton != nil else { return }; guard contextIsCurrent else { dismiss(animated: true); return }
        let cue = store.project.cues.first { $0.id == cueID }
        subtitle.text = cue.map { "For " + ($0.label.isEmpty ? "this picture placement" : $0.label) } ?? "This placement no longer exists."
        useButton.isEnabled = chosenID.flatMap { store.project.asset($0) } != nil && cue != nil && store.lockedByOther(cueID) == nil
        let next: [AnyHashable] = [store.project.images, store.project.characters, store.project.cues, query, store.peerTransferStatus, store.statusMessage]
        guard next != dataSignature else { return }; dataSignature = next
        let available = versionsOf.map { ProjectEditing.imageVersions(in: store.project, imageId: $0) } ?? store.project.images.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        images = available.filter { image in
            term.isEmpty || image.prompt.localizedCaseInsensitiveContains(term) || UIKitImageContext.title(imageID: image.id, project: store.project).localizedCaseInsensitiveContains(term)
                || store.project.characters.contains { image.characterIds.contains($0.id) && ([$0.name] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(term) } }
        }
        emptyLabel.isHidden = !images.isEmpty; emptyLabel.text = query.isEmpty ? "No project images yet. Import or generate an image, then reuse it here." : "No matching images. Try a character, alias or image direction."
        collection.reloadData()
    }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { query = searchText; storeDidChange() }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { images.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "image", for: indexPath) as! ImageChoiceCollectionCell
        let image = images[indexPath.item]; cell.configure(image: image, store: store, selected: chosenID == image.id); return cell
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        chosenID = images[indexPath.item].id; collectionView.reloadData(); useButton.isEnabled = store.lockedByOther(cueID) == nil
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = max(150, (collectionView.bounds.width - 14) / 2)
        return CGSize(width: width, height: ImageChoiceCollectionCell.height(image: images[indexPath.item], project: store.project, width: width, local: store.assetURL(images[indexPath.item]) != nil))
    }
    private func useSelection() {
        guard requireCurrentContext(), let chosenID, store.project.asset(chosenID) != nil, store.project.cues.contains(where: { $0.id == cueID }) else { return }
        store.setCueImage(cueID, imageId: chosenID)
        if store.project.cues.first(where: { $0.id == cueID })?.imageId == chosenID { dismiss(animated: true) }
    }
}


/// Scoped to Use image / Use version. The shared image-button factory pins an
/// accent background, so UIKit's disabled title alone leaves an active-looking
/// blue action. Keep the existing configuration and action; vary only paint.
@MainActor enum ImagePickerSelectionAppearance {
    static func install(on button: UIButton) {
        button.configurationUpdateHandler = { button in
            guard var configuration = button.configuration else { return }
            let background = button.isEnabled ? ImageUI.accent : ScrivUIKitTheme.inset
            let foreground = button.isEnabled ? UIColor.white : ScrivUIKitTheme.secondary
            configuration.baseBackgroundColor = background
            configuration.background.backgroundColor = background
            // Keep the disabled surface neutral even when UIKit applies a
            // state transform. Enabled controls retain native pressed feedback.
            configuration.background.backgroundColorTransformer = button.isEnabled ? nil : UIConfigurationColorTransformer { _ in background }
            configuration.baseForegroundColor = foreground
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 13, weight: .medium)
                outgoing.foregroundColor = foreground
                return outgoing
            }
            button.configuration = configuration
        }
        button.setNeedsUpdateConfiguration()
    }
}

@MainActor private final class ImageChoiceCollectionCell: UICollectionViewCell {
    private let picture = UIKitAssetImageView()
    private let titleLabel = ImageUI.label(size: 14, weight: .semibold)
    private let versionLabel = ImageUI.label(size: 11, secondary: true)
    private let availabilityLabel = ImageUI.label("Not on this Mac", size: 10, secondary: true)
    private let tags = UIView()
    private let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    override init(frame: CGRect) {
        super.init(frame: frame); contentView.backgroundColor = ScrivUIKitTheme.panel; contentView.layer.cornerRadius = 9
        picture.layer.cornerRadius = 7
        versionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        let details = ImageUI.stack([titleLabel, ImageUI.row([tags, ImageUI.spacer(), versionLabel], spacing: 8), availabilityLabel], spacing: 5)
        let padded = UIView(); details.scrivPinEdges(to: padded, insets: NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 8, trailing: 10))
        let stack = ImageUI.stack([picture, padded], spacing: 7); contentView.addSubview(stack); stack.scrivPinEdges(to: contentView, insets: NSDirectionalEdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3))
        picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: 0.5).isActive = true
        check.tintColor = ImageUI.accent; check.backgroundColor = .white; check.layer.cornerRadius = 12; check.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(check)
        NSLayoutConstraint.activate([check.topAnchor.constraint(equalTo: picture.topAnchor, constant: 9), check.trailingAnchor.constraint(equalTo: picture.trailingAnchor, constant: -9), check.widthAnchor.constraint(equalToConstant: 25), check.heightAnchor.constraint(equalToConstant: 25)])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    static func caption(image: ImageAsset, project: ScrivProject, local: Bool) -> String {
        let names = project.characters.filter { image.characterIds.contains($0.id) }.map(\.name).joined(separator: " · ")
        return UIKitImageContext.title(imageID: image.id, project: project) + "\nVersion \(image.version)" + (local ? "" : " · Not on this Mac") + (names.isEmpty ? "" : "\n" + names)
    }
    static func height(image: ImageAsset, project: ScrivProject, width: CGFloat, local: Bool) -> CGFloat {
        let title = UIKitImageContext.title(imageID: image.id, project: project)
        let titleHeight = (title as NSString).boundingRect(with: CGSize(width: max(1, width - 26), height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: UIFont.systemFont(ofSize: 14, weight: .semibold)], context: nil).height
        let names = project.characters.filter { image.characterIds.contains($0.id) }.map(\.name).joined(separator: " · ")
        let tagsHeight = (names as NSString).boundingRect(with: CGSize(width: max(1, width - 110), height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: UIFont.systemFont(ofSize: 11)], context: nil).height
        return ceil((width - 6) * 0.5 + titleHeight + max(17, tagsHeight) + (local ? 0 : 18) + 34)
    }
    func configure(image: ImageAsset, store: WorkspaceStore, selected: Bool) {
        let url = store.assetURL(image); picture.configure(url: url, title: UIKitImageContext.title(imageID: image.id, project: store.project), missingText: "Not on this Mac")
        titleLabel.text = UIKitImageContext.title(imageID: image.id, project: store.project)
        versionLabel.text = "Version \(image.version)"; availabilityLabel.isHidden = url != nil
        tags.subviews.forEach { $0.removeFromSuperview() }
        let names = store.project.characters.filter { image.characterIds.contains($0.id) }
        if !names.isEmpty {
            let label = ImageUI.label(names.map(\.name).joined(separator: " · "), size: 11)
            label.textColor = ScrivUIKitTheme.ink; label.backgroundColor = ImageUI.color(names[0].color).withAlphaComponent(0.18); label.layer.cornerRadius = 5; label.clipsToBounds = true
            label.scrivPinEdges(to: tags)
        }
        tags.isHidden = names.isEmpty
        contentView.layer.borderColor = (selected ? ImageUI.accent : ScrivUIKitTheme.hairline).cgColor; contentView.layer.borderWidth = selected ? 2 : 0.5; check.isHidden = !selected
        accessibilityLabel = Self.caption(image: image, project: store.project, local: url != nil); accessibilityTraits = selected ? [.button, .selected] : [.button]
    }
}
