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
    private var dataSignature = ""
    private var collectionWidth: CGFloat = 0

    init(store: WorkspaceStore, cueID: String, versionsOf: String? = nil) {
        self.cueID = cueID; self.versionsOf = versionsOf; chosenID = store.project.cues.first { $0.id == cueID }?.imageId
        let layout = UICollectionViewFlowLayout(); layout.minimumInteritemSpacing = 14; layout.minimumLineSpacing = 14
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout); super.init(store: store)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:cueID:versionsOf:)") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = versionsOf == nil ? "Choose an image" : "Image versions"
        preferredContentSize = CGSize(width: 720, height: 720)
        search.placeholder = "Character, alias or image direction"; search.searchBarStyle = .minimal; search.delegate = self
        collection.backgroundColor = .clear; collection.dataSource = self; collection.delegate = self
        collection.register(ImageChoiceCollectionCell.self, forCellWithReuseIdentifier: "image")
        emptyLabel.textAlignment = .center; collection.backgroundView = emptyLabel
        let cancel = ImageUI.button("Cancel") { [weak self] in self?.dismiss(animated: true) }
        useButton = ImageUI.button(versionsOf == nil ? "Use image" : "Use version", primary: true) { [weak self] in self?.useSelection() }
        let footer = ImageUI.stack([ImageUI.label("Only this placement changes. Other uses and discussions stay intact.", size: 11, secondary: true), ImageUI.row([ImageUI.spacer(), cancel, useButton])], spacing: 10)
        let stack = ImageUI.stack([subtitle, search, collection, ImageUI.divider(), footer], spacing: 14)
        ImageUI.pinToSafeArea(stack, in: self, insets: NSDirectionalEdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        storeDidChange()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); if abs(collection.bounds.width - collectionWidth) > 0.5 { collectionWidth = collection.bounds.width; collection.collectionViewLayout.invalidateLayout() } }
    override func storeDidChange() {
        guard isViewLoaded, useButton != nil else { return }; guard contextIsCurrent else { dismiss(animated: true); return }
        let cue = store.project.cues.first { $0.id == cueID }
        subtitle.text = cue.map { "For " + ($0.label.isEmpty ? "this picture placement" : $0.label) } ?? "This placement no longer exists."
        useButton.isEnabled = chosenID.flatMap { store.project.asset($0) } != nil && cue != nil && store.lockedByOther(cueID) == nil
        let next = "\(store.project.images)|\(store.project.characters)|\(store.project.cues)|\(query)|\(store.peerTransferStatus)|\(store.statusMessage)"
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
        let caption = ImageChoiceCollectionCell.caption(image: images[indexPath.item], project: store.project, local: store.assetURL(images[indexPath.item]) != nil)
        let size = (caption as NSString).boundingRect(with: CGSize(width: width - 20, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: UIFont.systemFont(ofSize: 13)], context: nil)
        return CGSize(width: width, height: (width - 12) * 9 / 16 + ceil(size.height) + 26)
    }
    private func useSelection() {
        guard requireCurrentContext(), let chosenID, store.project.asset(chosenID) != nil, store.project.cues.contains(where: { $0.id == cueID }) else { return }
        store.setCueImage(cueID, imageId: chosenID)
        if store.project.cues.first(where: { $0.id == cueID })?.imageId == chosenID { dismiss(animated: true) }
    }
}

@MainActor private final class ImageChoiceCollectionCell: UICollectionViewCell {
    private let picture = UIKitAssetImageView()
    private let captionLabel = ImageUI.label(size: 13)
    private let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    override init(frame: CGRect) {
        super.init(frame: frame); contentView.backgroundColor = ScrivUIKitTheme.panel; contentView.layer.cornerRadius = 12
        let stack = ImageUI.stack([picture, captionLabel], spacing: 8); contentView.addSubview(stack); stack.scrivPinEdges(to: contentView, insets: NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 10, trailing: 6))
        picture.heightAnchor.constraint(equalTo: picture.widthAnchor, multiplier: 9 / 16).isActive = true
        check.tintColor = ImageUI.accent; check.backgroundColor = .white; check.layer.cornerRadius = 12; check.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(check)
        NSLayoutConstraint.activate([check.topAnchor.constraint(equalTo: picture.topAnchor, constant: 8), check.trailingAnchor.constraint(equalTo: picture.trailingAnchor, constant: -8), check.widthAnchor.constraint(equalToConstant: 25), check.heightAnchor.constraint(equalToConstant: 25)])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    static func caption(image: ImageAsset, project: ScrivProject, local: Bool) -> String {
        let names = project.characters.filter { image.characterIds.contains($0.id) }.map(\.name).joined(separator: " · ")
        return UIKitImageContext.title(imageID: image.id, project: project) + "\nVersion \(image.version)" + (local ? "" : " · Not on this Mac") + (names.isEmpty ? "" : "\n" + names)
    }
    func configure(image: ImageAsset, store: WorkspaceStore, selected: Bool) {
        let url = store.assetURL(image); picture.configure(url: url, title: UIKitImageContext.title(imageID: image.id, project: store.project), missingText: "Not on this Mac")
        captionLabel.text = Self.caption(image: image, project: store.project, local: url != nil)
        contentView.layer.borderColor = (selected ? ImageUI.accent : ScrivUIKitTheme.hairline).cgColor; contentView.layer.borderWidth = selected ? 2 : 0.5; check.isHidden = !selected
        accessibilityLabel = captionLabel.text; accessibilityTraits = selected ? [.button, .selected] : [.button]
    }
}
