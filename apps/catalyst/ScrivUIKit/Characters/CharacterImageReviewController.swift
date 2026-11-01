import UIKit
import ScrivCore

@MainActor
final class CharacterCropImageView: UIView {
    private let picture = UIImageView()
    private let placeholder = ScrivUIKitTheme.label("Portrait unavailable",size:12,color:ScrivUIKitTheme.secondary)
    private var load: Task<Void,Never>?
    init(source: URL?, sha256: String, region: NormalizedCharacterRegion, title: String) {
        super.init(frame:.zero)
        backgroundColor = ScrivUIKitTheme.inset; clipsToBounds = true; layer.cornerRadius = 10
        picture.contentMode = .scaleAspectFill; addSubview(picture); picture.scrivPinEdges(to:self)
        placeholder.textAlignment = .center; addSubview(placeholder); placeholder.scrivPinEdges(to:self,insets:.init(top:4,leading:4,bottom:4,trailing:4))
        accessibilityLabel = title; isAccessibilityElement = true
        guard let source else { return }
        load = Task { [weak self] in
            do {
                let url = try await CharacterPortraitCache.thumbnail(source:source,sha256:sha256,region:region)
                guard !Task.isCancelled, let self else { return }
                self.picture.image = UIImage(contentsOfFile:url.path); self.placeholder.isHidden = self.picture.image != nil
            } catch { self?.placeholder.text = "Crop unavailable" }
        }
    }
    deinit { load?.cancel() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(source:sha256:region:title:)") }
}

@MainActor
private final class CharacterReviewImageView: UIView {
    private let picture = UIImageView()
    private let annotations: [CharacterImageAnnotation]
    private let names: [String:String]
    private var regions: [UIView] = []
    private var load: Task<Void,Never>?
    init(image: ImageAsset, store: WorkspaceStore) {
        annotations = image.characterAnalysis?.annotations.filter { $0.decision != .ignored } ?? []
        names = Dictionary(uniqueKeysWithValues:store.project.characters.map { ($0.id,$0.name) })
        super.init(frame:.zero)
        layer.cornerRadius = 10; clipsToBounds = true; backgroundColor = ScrivUIKitTheme.inset
        picture.contentMode = .scaleAspectFit; addSubview(picture); picture.scrivPinEdges(to:self)
        for annotation in annotations {
            let region = UIView(); region.layer.borderWidth = 2
            let color: UIColor = annotation.decision == .needsReview ? .systemOrange : ScrivUIKitTheme.accent
            region.layer.borderColor = color.cgColor
            let label = ScrivUIKitTheme.label(annotation.characterID.flatMap { names[$0] } ?? "Unknown character",size:12,weight:.semibold,color:annotation.decision == .needsReview ? ScrivUIKitTheme.ink : .white)
            label.backgroundColor = color; label.tag = 1; region.addSubview(label)
            region.accessibilityLabel = label.text; region.isAccessibilityElement = true
            addSubview(region); regions.append(region)
        }
        if let url = store.assetURL(image) {
            load = Task { [weak self] in
                let data = try? await Task.detached(priority:.utility) { try Data(contentsOf:url,options:.mappedIfSafe) }.value
                guard !Task.isCancelled, let self, let data else { return }
                self.picture.image = UIImage(data:data); self.setNeedsLayout()
            }
        }
    }
    deinit { load?.cancel() }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(image:store:)") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = picture.image?.size, size.width > 0, size.height > 0 else { regions.forEach { $0.isHidden = true }; return }
        let scale = min(bounds.width / size.width,bounds.height / size.height)
        let imageBounds = CGRect(x:(bounds.width-size.width*scale)/2,y:(bounds.height-size.height*scale)/2,width:size.width*scale,height:size.height*scale)
        for (index,region) in regions.enumerated() {
            let box = annotations[index].region; region.isHidden = false
            region.frame = CGRect(x:imageBounds.minX + CGFloat(box.x)*imageBounds.width,y:imageBounds.minY + CGFloat(box.y)*imageBounds.height,width:CGFloat(box.width)*imageBounds.width,height:CGFloat(box.height)*imageBounds.height)
            if let label = region.viewWithTag(1) as? UILabel {
                let size = label.sizeThatFits(CGSize(width:bounds.width,height:25)); label.frame = CGRect(x:0,y:region.frame.minY >= 25 ? -25 : 0,width:min(max(80,size.width+12),bounds.width-region.frame.minX),height:25)
            }
        }
    }
}

/// No canonical edit is performed by selecting, dismissing, or skipping a crop.
/// Save and Ignore both fence the exact image version and original project scope.
@MainActor
final class CharacterImageReviewController: ScrivScreenController, UISearchBarDelegate {
    private let content = ScrivUIKitTheme.stack(spacing:14)
    private let search = UISearchBar()
    private let choices = CharacterTeamUI.row([],spacing:10)
    private let save = CharacterTeamUI.button("Save tag & next",primary:true) {}
    private var currentID: String?
    private var selectedCharacterID: String?
    private var newName: String?
    private var searchText = ""
    private var skipped: Set<String> = []
    private var isSaving = false
    private var renderedProject: ScrivProject?
    init(store: WorkspaceStore, itemID: String? = nil) { currentID = itemID; super.init(store:store) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:itemID:)") }
    private var items: [CharacterImageReviewItem] { store.characterAnalysis.reviewItems.filter { !skipped.contains($0.id) } }
    private var current: CharacterImageReviewItem? { items.first { $0.id == currentID } ?? items.first }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Who is in this image?"
        navigationController?.setNavigationBarHidden(true,animated:false)
        let scroll = UIScrollView(); scroll.keyboardDismissMode = .interactive; view.addSubview(scroll); scroll.scrivPinEdges(to:view)
        scroll.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo:scroll.contentLayoutGuide.topAnchor,constant:22),content.bottomAnchor.constraint(equalTo:scroll.contentLayoutGuide.bottomAnchor,constant:-22),
            content.leadingAnchor.constraint(equalTo:scroll.contentLayoutGuide.leadingAnchor,constant:24),content.trailingAnchor.constraint(equalTo:scroll.contentLayoutGuide.trailingAnchor,constant:-24),content.widthAnchor.constraint(equalTo:scroll.frameLayoutGuide.widthAnchor,constant:-48)
        ])
        search.placeholder = "Find a character"; search.searchBarStyle = .minimal; search.delegate = self
        search.accessibilityLabel = "Find a character for this image region"
        save.accessibilityIdentifier = "character-review-save"
        save.addAction(UIAction { [weak self] _ in self?.submit() },for:.touchUpInside)
        render()
    }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        guard contextIsCurrent else { dismiss(animated:true); return }
        if renderedProject != store.project, !isSaving { render() }
    }
    func searchBar(_ searchBar: UISearchBar,textDidChange searchText: String) { self.searchText = searchText; renderChoices() }
    private func render() {
        renderedProject = store.project
        CharacterTeamUI.clear(content)
        let done = CharacterTeamUI.button("Done",size:16) { [weak self] in self?.dismiss(animated:true) }
        done.isEnabled = !isSaving
        let heading = CharacterTeamUI.row([ScrivUIKitTheme.label("Who is in this image?",size:29,weight:.semibold),CharacterTeamUI.spacer(),done])
        content.addArrangedSubview(heading)
        guard let item = current else {
            let message = skipped.isEmpty ? "Every character candidate has been reviewed." : "Skipped candidates remain in Characters, ready when you are."
            content.addArrangedSubview(ScrivUIKitTheme.notice("Nothing else to review",message:message)); return
        }
        if currentID != item.id { selectedCharacterID = nil; newName = nil; currentID = item.id }
        let cue = store.project.cues.first { $0.imageId == item.image.id }
        let name = cue?.label.isEmpty == false ? cue!.label : "Image"
        content.addArrangedSubview(ScrivUIKitTheme.label("\(items.count) to review · \(name) · v\(item.image.version)",size:15,color:ScrivUIKitTheme.secondary))
        let image = CharacterReviewImageView(image:item.image,store:store)
        image.heightAnchor.constraint(equalTo:image.widthAnchor,multiplier:0.49).isActive = true; content.addArrangedSubview(image)
        let crops = CharacterTeamUI.row([],spacing:12); crops.alignment = .top
        let cropScroll = UIScrollView(); cropScroll.showsHorizontalScrollIndicator = false; cropScroll.addSubview(crops); crops.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([crops.leadingAnchor.constraint(equalTo:cropScroll.contentLayoutGuide.leadingAnchor),crops.trailingAnchor.constraint(equalTo:cropScroll.contentLayoutGuide.trailingAnchor),crops.topAnchor.constraint(equalTo:cropScroll.contentLayoutGuide.topAnchor),crops.bottomAnchor.constraint(equalTo:cropScroll.contentLayoutGuide.bottomAnchor),crops.heightAnchor.constraint(equalTo:cropScroll.frameLayoutGuide.heightAnchor),cropScroll.heightAnchor.constraint(equalToConstant:140)])
        for annotation in item.image.characterAnalysis?.annotations ?? [] where annotation.decision != .ignored {
            let crop = CharacterCropImageView(source:store.assetURL(item.image),sha256:item.image.sha256,region:annotation.portraitRegion,title:annotation.characterID.flatMap { store.project.character($0)?.name } ?? "Unknown character")
            let button = UIButton(type:.custom); button.addSubview(crop); crop.scrivPinEdges(to:button); crop.isUserInteractionEnabled = false
            button.widthAnchor.constraint(equalToConstant:160).isActive = true; button.heightAnchor.constraint(equalToConstant:130).isActive = true
            button.layer.cornerRadius = 10; button.layer.borderColor = (annotation.decision == .needsReview ? UIColor.systemOrange : ScrivUIKitTheme.accent).cgColor; button.layer.borderWidth = annotation.id == item.annotation.id ? 3 : 1
            button.accessibilityLabel = annotation.decision == .needsReview ? "Review unknown character" : "Already tagged character"
            button.isEnabled = annotation.decision == .needsReview
            button.addAction(UIAction { [weak self] _ in self?.currentID = item.image.id + ":" + annotation.id; self?.selectedCharacterID = nil; self?.newName = nil; self?.render() },for:.touchUpInside)
            crops.addArrangedSubview(button)
        }
        content.addArrangedSubview(cropScroll)
        let reason = item.annotation.reason.isEmpty ? "This character needs your help." : item.annotation.reason
        content.addArrangedSubview(ScrivUIKitTheme.label(reason,size:13,color:ScrivUIKitTheme.secondary))
        content.addArrangedSubview(CharacterTeamUI.separator())
        content.addArrangedSubview(ScrivUIKitTheme.label("Choose a character, or give this character a name.",size:16))
        content.addArrangedSubview(search)
        let choiceScroll = UIScrollView(); choiceScroll.showsHorizontalScrollIndicator = false
        choices.removeFromSuperview(); choiceScroll.addSubview(choices); choices.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([choices.leadingAnchor.constraint(equalTo:choiceScroll.contentLayoutGuide.leadingAnchor),choices.trailingAnchor.constraint(equalTo:choiceScroll.contentLayoutGuide.trailingAnchor),choices.topAnchor.constraint(equalTo:choiceScroll.contentLayoutGuide.topAnchor),choices.bottomAnchor.constraint(equalTo:choiceScroll.contentLayoutGuide.bottomAnchor),choices.heightAnchor.constraint(equalTo:choiceScroll.frameLayoutGuide.heightAnchor),choiceScroll.heightAnchor.constraint(equalToConstant:65)])
        content.addArrangedSubview(choiceScroll); renderChoices()
        save.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive = true; content.addArrangedSubview(save)
        let ignore = CharacterTeamUI.button("Not a character") { [weak self] in self?.submit(ignore:true) }; ignore.accessibilityIdentifier = "character-review-ignore"
        let skip = CharacterTeamUI.button("Skip for now") { [weak self] in guard let self, let item = self.current else { return }; self.skipped.insert(item.id); self.currentID = nil; self.render() }
        for button in [ignore,skip] { button.backgroundColor = ScrivUIKitTheme.panel; button.layer.borderColor = ScrivUIKitTheme.hairline.cgColor; button.layer.borderWidth = 1; button.layer.cornerRadius = 10; button.heightAnchor.constraint(equalToConstant:44).isActive = true }
        let actions = CharacterTeamUI.row([ignore,skip]); actions.distribution = .fillEqually; content.addArrangedSubview(actions)
        content.addArrangedSubview(CharacterTeamUI.characterNotice("Tags and portrait crops update automatically. Original images stay unchanged."))
        setSaving(isSaving)
    }
    private func renderChoices() {
        CharacterTeamUI.clear(choices)
        for character in store.project.characters where searchText.isEmpty || ([character.name] + character.aliases).contains(where: { $0.localizedCaseInsensitiveContains(searchText) }) {
            let button = UIButton(type:.custom)
            let portrait = CharacterTeamUI.portrait(character,store:store,size:CGSize(width:48,height:48),circular:true)
            let contents = CharacterTeamUI.row([portrait,ScrivUIKitTheme.label(character.name,size:14,weight:.medium)],spacing:9)
            contents.isUserInteractionEnabled = false; button.addSubview(contents); contents.scrivPinEdges(to:button,insets:.init(top:7,leading:9,bottom:7,trailing:14))
            button.widthAnchor.constraint(greaterThanOrEqualToConstant:136).isActive = true
            button.backgroundColor = selectedCharacterID == character.id ? ScrivUIKitTheme.accent.withAlphaComponent(0.1) : ScrivUIKitTheme.inset
            button.layer.cornerRadius = 10; button.layer.borderWidth = selectedCharacterID == character.id ? 2 : 1
            button.layer.borderColor = (selectedCharacterID == character.id ? ScrivUIKitTheme.accent : ScrivUIKitTheme.hairline).cgColor
            button.accessibilityLabel = character.name; button.accessibilityTraits = selectedCharacterID == character.id ? [.button,.selected] : [.button]
            button.addAction(UIAction { [weak self] _ in self?.selectedCharacterID = character.id; self?.newName = nil; self?.renderChoices() },for:.touchUpInside)
            choices.addArrangedSubview(button)
        }
        let add = CharacterTeamUI.button(newName ?? "New character",symbol:"plus") { [weak self] in self?.nameCharacter() }
        add.layer.cornerRadius = 10; add.layer.borderColor = ScrivUIKitTheme.accent.cgColor; add.layer.borderWidth = 1
        add.widthAnchor.constraint(greaterThanOrEqualToConstant:170).isActive = true; add.heightAnchor.constraint(equalToConstant:63).isActive = true
        choices.addArrangedSubview(add)
        save.isEnabled = !isSaving && (selectedCharacterID != nil || newName != nil)
    }
    private func nameCharacter() {
        let alert = UIAlertController(title:"Name this character",message:"Use an existing character's name to keep one canonical identity.",preferredStyle:.alert)
        alert.addTextField { field in field.placeholder = "Character name"; field.text = self.newName }
        alert.addAction(UIAlertAction(title:"Cancel",style:.cancel))
        alert.addAction(UIAlertAction(title:"Use name",style:.default) { [weak self, weak alert] _ in
            guard let self else { return }; let name = alert?.textFields?.first?.text?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, name.count <= 200 else { return }; self.newName = name; self.selectedCharacterID = nil; self.renderChoices()
        }); present(alert,animated:true)
    }
    private func setSaving(_ value: Bool) { isSaving = value; content.isUserInteractionEnabled = !value; save.isEnabled = !value && (selectedCharacterID != nil || newName != nil); navigationItem.rightBarButtonItem?.isEnabled = !value; isModalInPresentation = value }
    private func submit(ignore: Bool = false) {
        guard !isSaving, requireCurrentContext(), let item = current else { return }
        let characterID = selectedCharacterID, name = newName
        setSaving(true)
        Task { [weak self] in
            guard let self else { return }
            let accepted = await self.store.resolveCharacterImage(item,characterID:characterID,newName:name,ignore:ignore,navigation:self.initialNavigationContext)
            self.setSaving(false)
            if accepted { self.currentID = nil; self.selectedCharacterID = nil; self.newName = nil; self.render() }
        }
    }
}
