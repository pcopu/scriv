import UIKit
import ScrivCore

@MainActor
final class CharactersController: ScrivScreenController, UISearchBarDelegate {
    private let search = UISearchBar()
    private let heading = ScrivUIKitTheme.label("Characters", size: 32, weight: .semibold)
    private var ribbonHeight: NSLayoutConstraint?
    private var previousWidth: CGFloat = 0
    private var presentationScale: CGFloat { max(1, min(1.3, view.bounds.width / 650)) }
    private let ribbon = UIScrollView()
    private let ribbonItems = CharacterTeamUI.row([], spacing: 10)
    private let scroll = UIScrollView()
    private let profile = ScrivUIKitTheme.stack(spacing: 16)
    private var searchText = ""
    private var renderedProject: ScrivProject?
    private var renderedSelection: String?
    private var renderedAssets: [String: String] = [:]
    private var creationPending = false
    private let analysisStatus = ScrivUIKitTheme.label("",size:13,color:ScrivUIKitTheme.secondary)
    private let analysisDot = CharacterTeamUI.symbol("circle.fill",size:11)
    private let autoTagToggle = UISwitch()
    private let reviewBanner = CharacterTeamUI.row([],spacing:10)
    private let scanStatus = ScrivUIKitTheme.label("",size:12,color:ScrivUIKitTheme.secondary)
    private let scanButton = CharacterTeamUI.button("Scan again",size:13) {}

    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ScrivUIKitTheme.canvas.withAlphaComponent(0.35); view.layer.cornerRadius = 17
        let add = CharacterTeamUI.button("", symbol: "plus") { [weak self] in self?.openNewCharacter() }
        add.accessibilityLabel = "Add character"
        let title = CharacterTeamUI.row([heading, CharacterTeamUI.spacer(), add])
        search.placeholder = "Search characters"; search.delegate = self; search.searchBarStyle = .minimal
        search.searchTextField.font = .systemFont(ofSize: 16); search.searchTextField.textColor = ScrivUIKitTheme.ink; search.searchTextField.backgroundColor = ScrivUIKitTheme.inset; search.accessibilityLabel = "Search characters and aliases"
        ribbon.showsHorizontalScrollIndicator = false
        ribbonItems.translatesAutoresizingMaskIntoConstraints = false; ribbon.addSubview(ribbonItems)
        ribbonHeight = ribbon.heightAnchor.constraint(equalToConstant: 150); ribbonHeight?.isActive = true
        NSLayoutConstraint.activate([
            ribbonItems.leadingAnchor.constraint(equalTo: ribbon.contentLayoutGuide.leadingAnchor), ribbonItems.trailingAnchor.constraint(equalTo: ribbon.contentLayoutGuide.trailingAnchor),
            ribbonItems.topAnchor.constraint(equalTo: ribbon.contentLayoutGuide.topAnchor), ribbonItems.bottomAnchor.constraint(equalTo: ribbon.contentLayoutGuide.bottomAnchor),
            ribbonItems.heightAnchor.constraint(equalTo: ribbon.frameLayoutGuide.heightAnchor)
        ])
        profile.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(profile)
        NSLayoutConstraint.activate([
            profile.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), profile.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            profile.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), profile.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            profile.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        autoTagToggle.accessibilityLabel = "Auto-tag new images"
        autoTagToggle.addAction(UIAction { [weak self] _ in guard let self else { return }; self.store.characterAnalysis.autoTagEnabled = self.autoTagToggle.isOn; self.renderAnalysis() },for:.valueChanged)
        let analysis = CharacterTeamUI.row([analysisDot,analysisStatus,CharacterTeamUI.spacer(),ScrivUIKitTheme.label("Auto-tag new images",size:12),autoTagToggle],spacing:8)
        let analysisCard = ScrivUIKitTheme.card(analysis,padding:9)
        reviewBanner.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.13); reviewBanner.layer.cornerRadius = 10
        reviewBanner.isLayoutMarginsRelativeArrangement = true; reviewBanner.directionalLayoutMargins = .init(top:9,leading:12,bottom:9,trailing:10)
        let hint = CharacterTeamUI.row([CharacterTeamUI.symbol("info.circle.fill", size: 15), ScrivUIKitTheme.label("New image versions are checked automatically. Your corrections are kept.", size: 12, color: ScrivUIKitTheme.secondary)], spacing: 10)
        scanButton.addAction(UIAction { [weak self] _ in guard let self else { return }; if self.store.characterAnalysis.isScanning { self.store.characterAnalysis.pause() } else { self.store.characterAnalysis.scanAgain() }; self.renderAnalysis() },for:.touchUpInside)
        let footer = CharacterTeamUI.row([scanStatus,CharacterTeamUI.spacer(),scanButton],spacing:8)
        let body = ScrivUIKitTheme.stack([title, analysisCard, reviewBanner, search, ribbon, scroll, hint, CharacterTeamUI.separator(),footer], spacing: 10)
        // The body fills the panel and the profile scrolls inside it; on short
        // windows the profile keeps a usable height and the whole panel scrolls.
        let page = UIScrollView(); page.translatesAutoresizingMaskIntoConstraints = false; page.showsHorizontalScrollIndicator = false
        view.addSubview(page); body.translatesAutoresizingMaskIntoConstraints = false; page.addSubview(body)
        let fill = body.heightAnchor.constraint(equalTo: page.frameLayoutGuide.heightAnchor, constant: -40); fill.priority = .defaultHigh - 1
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor), page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.topAnchor.constraint(equalTo: view.topAnchor), page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: page.contentLayoutGuide.leadingAnchor, constant: 20), body.trailingAnchor.constraint(equalTo: page.contentLayoutGuide.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: page.contentLayoutGuide.topAnchor, constant: 20), body.bottomAnchor.constraint(equalTo: page.contentLayoutGuide.bottomAnchor, constant: -20),
            body.widthAnchor.constraint(equalTo: page.frameLayoutGuide.widthAnchor, constant: -40),
            body.heightAnchor.constraint(greaterThanOrEqualTo: page.frameLayoutGuide.heightAnchor, constant: -40),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220), fill
        ])
        render()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard abs(previousWidth - view.bounds.width) > 1 else { return }
        previousWidth = view.bounds.width
        heading.font = .systemFont(ofSize: 32 * presentationScale, weight: .semibold)
        search.searchTextField.font = .systemFont(ofSize: 16 * presentationScale)
        ribbonHeight?.constant = 150 * presentationScale; ribbonItems.spacing = 10 * presentationScale
        render()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); consumeCreationRequest() }
    private var availability: [String: String] = [:]
    private var availabilityCheckedAt: TimeInterval = 0
    override func storeDidChange() {
        guard isViewLoaded else { return }
        if renderedProject?.id != store.project.id {
            searchText = ""; search.text = ""
        } else if renderedSelection != store.selectedCharacterID, let selectedID = store.selectedCharacterID,
                  store.project.characters.contains(where: { $0.id == selectedID }), !characters.contains(where: { $0.id == selectedID }) {
            searchText = ""; search.text = ""
        }
        // Checking every image file costs several file-system calls each. During
        // playback the store refreshes many times a second, so re-check at most
        // once a second while playing; otherwise check on every refresh.
        let now = ProcessInfo.processInfo.systemUptime
        if !store.isPlaying || now - availabilityCheckedAt >= 1 || renderedProject?.images != store.project.images {
            availabilityCheckedAt = now
            availability = Dictionary(uniqueKeysWithValues: store.project.images.map { ($0.id, store.assetURL($0)?.path ?? "") })
        }
        if renderedProject != store.project || renderedSelection != store.selectedCharacterID || renderedAssets != availability {
            renderedAssets = availability; render()
        }
        renderAnalysis(); consumeCreationRequest()
    }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { self.searchText = searchText; render() }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    private var characters: [ScriptCharacter] {
        store.project.characters.filter { searchText.isEmpty || ([$0.name] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(searchText) } }
    }
    private func render() {
        renderedProject = store.project; renderedSelection = store.selectedCharacterID
        renderAnalysis()
        let selected = characters.first { $0.id == store.selectedCharacterID } ?? characters.first
        CharacterTeamUI.clear(ribbonItems)
        for character in characters {
            let control = UIButton(type: .custom)
            let portrait = CharacterTeamUI.portrait(character, store: store, size: CGSize(width: 100 * presentationScale, height: 100 * presentationScale), circular: true)
            portrait.layer.borderColor = selected?.id == character.id ? ScrivUIKitTheme.accent.cgColor : UIColor.clear.cgColor
            portrait.layer.borderWidth = selected?.id == character.id ? 2.5 : 0
            let name = ScrivUIKitTheme.label(character.name, size: 16 * presentationScale, weight: .medium, lines: 1); name.textAlignment = .center
            let contents = ScrivUIKitTheme.stack([portrait, name], spacing: 9); contents.alignment = .center
            control.addSubview(contents); contents.scrivPinEdges(to: control, insets: .init(top: 10, leading: 8, bottom: 10, trailing: 8)); contents.isUserInteractionEnabled = false
            // The card must share the ribbon's hierarchy before a constraint can
            // refer to its frameLayoutGuide. First load and every search/resize
            // rebuild use this same order; activating before mounting crashes.
            ribbonItems.addArrangedSubview(control)
            let third = control.widthAnchor.constraint(equalTo: ribbon.frameLayoutGuide.widthAnchor, multiplier: 1 / 3, constant: -20 * presentationScale / 3)
            third.priority = .defaultHigh
            NSLayoutConstraint.activate([third, control.widthAnchor.constraint(greaterThanOrEqualToConstant: 142 * presentationScale), control.widthAnchor.constraint(lessThanOrEqualToConstant: 210 * presentationScale)])
            control.backgroundColor = selected?.id == character.id ? ScrivUIKitTheme.accent.withAlphaComponent(0.075) : .clear
            control.layer.cornerRadius = 20; control.accessibilityLabel = character.name
            control.accessibilityIdentifier = "character-ribbon-" + character.id
            control.accessibilityTraits = selected?.id == character.id ? [.button, .selected] : [.button]
            control.addAction(UIAction { [weak self] _ in self?.store.selectCharacter(character.id) }, for: .touchUpInside)
        }
        if searchText.isEmpty {
            for item in store.characterAnalysis.reviewItems {
                let control = UIButton(type:.custom)
                let portrait = CharacterCropImageView(source:store.assetURL(item.image),sha256:item.image.sha256,region:item.annotation.portraitRegion,title:"Character needs a name")
                portrait.widthAnchor.constraint(equalToConstant:100 * presentationScale).isActive = true; portrait.heightAnchor.constraint(equalToConstant:100 * presentationScale).isActive = true; portrait.layer.cornerRadius = 50 * presentationScale
                let label = ScrivUIKitTheme.label("Needs a name",size:13,weight:.medium); label.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.65); label.textAlignment = .center
                let contents = ScrivUIKitTheme.stack([portrait,label],spacing:9); contents.alignment = .center; contents.isUserInteractionEnabled = false
                control.addSubview(contents); contents.scrivPinEdges(to:control,insets:.init(top:10,leading:12,bottom:10,trailing:12)); control.backgroundColor = ScrivUIKitTheme.panel; control.layer.cornerRadius = 20
                ribbonItems.addArrangedSubview(control); control.widthAnchor.constraint(equalToConstant:160 * presentationScale).isActive = true
                control.accessibilityLabel = "Review unnamed character"; control.addAction(UIAction { [weak self] _ in self?.openCharacterReview(itemID:item.id) },for:.touchUpInside)
            }
        }
        // The ribbon shows three cards at a time; bring the selected one (e.g. a
        // character just created at the end) into view.
        if let selected, let card = ribbonItems.arrangedSubviews.first(where: { $0.accessibilityIdentifier == "character-ribbon-" + selected.id }) {
            DispatchQueue.main.async { [weak self, weak card] in
                guard let self, let card, card.superview === self.ribbonItems else { return }
                self.ribbon.layoutIfNeeded()
                self.ribbon.scrollRectToVisible(card.convert(card.bounds, to: self.ribbon).insetBy(dx: -10, dy: 0), animated: false)
            }
        }
        CharacterTeamUI.clear(profile)
        if let selected { profile.addArrangedSubview(profileCard(selected)) }
        else {
            profile.addArrangedSubview(ScrivUIKitTheme.notice(searchText.isEmpty ? "People make the scene" : "No matching characters",
                message: searchText.isEmpty ? "Add characters and aliases. Confirm suggestions from a script line’s review; image tags track who is pictured." : "Try another name or alias."))
            profile.addArrangedSubview(CharacterTeamUI.button(searchText.isEmpty ? "Add character" : "Clear search") { [weak self] in
                guard let self else { return }
                if self.searchText.isEmpty { self.openNewCharacter() }
                else { self.searchText = ""; self.search.text = ""; self.render() }
            })
        }
    }
    private func profileCard(_ character: ScriptCharacter) -> UIView {
        let portrait = CharacterTeamUI.portrait(character, store: store, size: CGSize(width: 136 * presentationScale, height: 136 * presentationScale))
        let edit = CharacterTeamUI.button("Edit", size: 14 * presentationScale) { [weak self] in self?.show(.characterEditor(characterID: character.id)) }
        edit.isEnabled = store.lockedByOther(character.id) == nil
        let aliases = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Also called", size: 14 * presentationScale, color: ScrivUIKitTheme.secondary), ScrivUIKitTheme.label(character.aliases.isEmpty ? "No aliases" : character.aliases.joined(separator: ", "), size: 14 * presentationScale)], spacing: 7)
        let remove = CharacterTeamUI.button("", symbol: "ellipsis") {}
        remove.accessibilityLabel = "Character actions"
        remove.menu = UIMenu(children: [UIAction(title: "Discuss character", image: UIImage(systemName: "bubble.left")) { [weak self] _ in self?.store.loadDiscussion(itemId: character.id) }, UIAction(title: "Delete character…", image: UIImage(systemName: "trash"), attributes: store.lockedByOther(character.id) == nil ? .destructive : [.destructive, .disabled]) { [weak self] _ in self?.confirmDelete(character) }])
        remove.showsMenuAsPrimaryAction = true
        let heading = CharacterTeamUI.row([ScrivUIKitTheme.label(character.name, size: 28 * presentationScale, weight: .semibold), CharacterTeamUI.spacer(), edit, remove], spacing: 6)
        let portraitAsset = store.project.asset(character.portraitImageId)
        let portraitCue = store.project.cues.first { $0.imageId == portraitAsset?.id }
        let portraitSource = character.portraitRegion != nil ? "Portrait cropped from \(portraitCue?.label.isEmpty == false ? portraitCue!.label : "image") · v\(portraitAsset?.version ?? 1)" : "Character"
        let options = CharacterTeamUI.button("Portrait options",size:13) { [weak self] in self?.show(.characterEditor(characterID:character.id)) }
        let details = ScrivUIKitTheme.stack([heading, ScrivUIKitTheme.label(portraitSource, size: 13 * presentationScale, color: ScrivUIKitTheme.secondary), CharacterTeamUI.separator(), aliases,options], spacing: 11)
        let header = CharacterTeamUI.row([portrait, details], spacing: 18); header.alignment = .top
        let content = ScrivUIKitTheme.stack([header], spacing: 16)
        if !character.biography.isEmpty || !character.appearance.isEmpty {
            let notes = ScrivUIKitTheme.stack(spacing: 10); notes.isHidden = true
            if !character.biography.isEmpty { notes.addArrangedSubview(ScrivUIKitTheme.label(character.biography, size: 14)) }
            if !character.appearance.isEmpty { notes.addArrangedSubview(ScrivUIKitTheme.label(character.appearance, size: 13, color: ScrivUIKitTheme.secondary)) }
            let toggle = CharacterTeamUI.button("Character notes & image direction", symbol: "chevron.down", size: 12) { notes.isHidden.toggle() }
            content.addArrangedSubview(toggle); content.addArrangedSubview(notes)
        }
        content.addArrangedSubview(CharacterTeamUI.separator())
        let images = store.project.images.filter { $0.characterIds.contains(character.id) }
        content.addArrangedSubview(CharacterTeamUI.row([ScrivUIKitTheme.label("Tagged images", size: 17 * presentationScale, weight: .semibold), ScrivUIKitTheme.label("\(images.count)", size: 14, color: ScrivUIKitTheme.secondary), CharacterTeamUI.spacer()]))
        if images.isEmpty { content.addArrangedSubview(ScrivUIKitTheme.label("Tag this character in an image to add it here.", size: 14, color: ScrivUIKitTheme.secondary)) }
        for start in stride(from: 0, to: images.count, by: 2) {
            let cells = Array(images[start..<min(images.count, start + 2)]).map { imageCard($0, character: character) }
            let row = CharacterTeamUI.row(cells.count == 2 ? cells : cells + [UIView()], spacing: 15); row.distribution = .fillEqually; row.alignment = .top
            content.addArrangedSubview(row)
        }
        return ScrivUIKitTheme.card(content, padding: 17 * presentationScale)
    }
    private func imageCard(_ image: ImageAsset, character: ScriptCharacter) -> UIView {
        let cue = store.project.cues.first { $0.imageId == image.id }
        let title = cue.flatMap { $0.label.isEmpty ? nil : $0.label } ?? "Image"
        let picture = UIKitAssetImageView(); picture.configure(url: store.assetURL(image), title: title, fill: true, missingText: "Image not on this device")
        picture.layer.cornerRadius = 9; picture.clipsToBounds = true
        let open = UIButton(type: .custom); open.addSubview(picture); picture.scrivPinEdges(to: open); picture.isUserInteractionEnabled = false
        open.heightAnchor.constraint(equalTo: open.widthAnchor, multiplier: 0.54).isActive = true
        open.accessibilityLabel = "Open \(title), version \(image.version)"
        open.addAction(UIAction { [weak self] _ in self?.show(.imageDetail(imageID: image.id, cueID: cue?.id)) }, for: .touchUpInside)
        let actions = CharacterTeamUI.button("", symbol: "ellipsis", size: 11) {}
        var menu: [UIAction] = [UIAction(title: "Discuss this image version") { [weak self] _ in self?.store.loadDiscussion(itemId: image.id) }]
        if let cue { menu.append(UIAction(title: "Show in script") { [weak self] _ in
            self?.store.selectScene(cue.sceneId); self?.store.selectedCueID = cue.id; self?.store.seek(toMs: Double(cue.startMs)); self?.store.tab = .script
        }) }
        if store.assetURL(image) == nil { menu.append(UIAction(title: "Download image") { [weak self] _ in self?.store.downloadImage(image) }) }
        menu.append(UIAction(title: "Use as \(character.name)'s portrait", attributes: store.lockedByOther(character.id) == nil ? [] : .disabled) { [weak self] _ in self?.store.setCharacterPortrait(character.id, imageId: image.id) })
        actions.menu = UIMenu(children: menu); actions.showsMenuAsPrimaryAction = true; actions.accessibilityLabel = "Image actions"
        let caption = CharacterTeamUI.row([ScrivUIKitTheme.label(title, size: 14 * presentationScale, weight: .medium), CharacterTeamUI.spacer(), ScrivUIKitTheme.label("v\(image.version)", size: 11, color: ScrivUIKitTheme.secondary), actions], spacing: 5)
        let tags = CharacterChipWrapView(); tags.minimumChipHeight = 26 * presentationScale
        tags.chips = store.project.characters.filter { image.characterIds.contains($0.id) }.map { person in
            let button = CharacterTeamUI.button(person.name, symbol: "circle.fill", size: 11 * presentationScale) { [weak self] in self?.store.selectCharacter(person.id) }
            button.configuration?.image = UIImage(systemName: "circle.fill")?.withTintColor(ScrivUIKitTheme.color(person.color), renderingMode: .alwaysOriginal)
            button.configuration?.contentInsets = .init(top: 4, leading: 6, bottom: 4, trailing: 6)
            button.configuration?.imagePadding = 4
            return button
        }
        let addTags = CharacterTeamUI.button("", symbol: "plus", size: 11) { [weak self] in
            guard let self else { return }
            let controller = UINavigationController(rootViewController: CharacterTagsViewController(store: self.store, imageID: image.id))
            CharacterTeamUI.present(controller, from: self, width: 470, height: 600)
        }
        addTags.accessibilityLabel = "Edit tags"
        tags.chips.append(addTags)
        tags.chips.last?.accessibilityLabel = "Edit character tags"
        (tags.chips.last as? UIButton)?.configuration?.contentInsets = .init(top: 4, leading: 6, bottom: 4, trailing: 6)
        return ScrivUIKitTheme.stack([open, caption, tags], spacing: 6)
    }
    private var renderedAnalysis: [AnyHashable]?
    private func renderAnalysis() {
        let analysis = store.characterAnalysis
        // Runs on every refresh; rebuild the banner only when its inputs change.
        // Always re-sync the switch, so a refused toggle snaps back.
        if autoTagToggle.isOn != analysis.autoTagEnabled { autoTagToggle.setOn(analysis.autoTagEnabled,animated:false) }
        let key: [AnyHashable] = [analysis.availability, analysis.isScanning, analysis.status, analysis.reviewImageCount]
        guard key != renderedAnalysis else { return }
        renderedAnalysis = key
        analysisDot.tintColor = analysis.availability == nil ? .systemGreen : .systemOrange
        analysisStatus.text = analysis.availability ?? (analysis.isScanning ? "Checking image characters…" : "Image analysis ready")
        scanStatus.text = analysis.status; scanStatus.isHidden = analysis.status == analysis.availability
        scanButton.setTitle(analysis.isScanning ? "Pause" : "Scan again",for:.normal)
        scanButton.isEnabled = analysis.availability == nil
        CharacterTeamUI.clear(reviewBanner)
        reviewBanner.isHidden = analysis.reviewImageCount == 0
        if analysis.reviewImageCount > 0 {
            reviewBanner.addArrangedSubview(CharacterTeamUI.symbol("exclamationmark.triangle.fill",color:.systemOrange,size:18))
            reviewBanner.addArrangedSubview(ScrivUIKitTheme.label("\(analysis.reviewImageCount) images need your help",size:14,weight:.medium))
            reviewBanner.addArrangedSubview(CharacterTeamUI.spacer())
            reviewBanner.addArrangedSubview(CharacterTeamUI.button("Review \(analysis.reviewImageCount)",primary:true,size:13) { [weak self] in self?.openCharacterReview() })
        }
    }
    private func openCharacterReview(itemID: String? = nil) {
        let review = UINavigationController(rootViewController:CharacterImageReviewController(store:store,itemID:itemID))
        CharacterTeamUI.present(review,from:self,width:760,height:930)
    }
    private func openNewCharacter() { show(.characterEditor(characterID: nil)) }
    private func consumeCreationRequest() {
        guard isViewLoaded, view.window != nil, store.characterCreationRequest != nil, presentedViewController == nil, !creationPending else { return }
        creationPending = true; store.characterCreationRequest = nil; openNewCharacter(); creationPending = false
    }
    private func confirmDelete(_ character: ScriptCharacter) {
        let context = store.navigationContext
        let alert = UIAlertController(title: "Delete \(character.name)?", message: "Script wording and images are preserved. Speaker links, inline links and character tags are removed; old words will not link to a reused name.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete character", style: .destructive) { [weak self] _ in
            guard let self, self.store.navigationContext == context else { return }
            self.store.deleteCharacter(character.id)
        }); present(alert, animated: true)
    }
}

extension ScrivUIKitFeatures {
    static func registerCharactersAndTeams(in router: ScrivUIKitRouter) {
        router.register(.characters) { _, store in CharactersController(store: store) }
        router.register(.characterEditor) { route, store in
            guard case .characterEditor(let id) = route else { return nil }
            if let id {
                guard let character = store.project.character(id) else { return nil }
                return CharacterEditorController(store: store, character: character, navigationContext: store.navigationContext, isNew: false)
            }
            return CharacterEditorController(store: store, character: ScriptCharacter(name: ""), navigationContext: store.navigationContext, isNew: true)
        }
        router.register(.characterLinks) { route, store in
            guard case .characterLinks(let id) = route, let entry = store.project.entries.first(where: { $0.id == id }) else { return nil }
            return CharacterLinksController(store: store, entry: entry, navigationContext: store.navigationContext)
        }
        router.register(.teams) { _, store in TeamsController(store: store) }
    }
}
