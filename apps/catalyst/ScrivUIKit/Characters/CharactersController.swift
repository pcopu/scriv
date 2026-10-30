import UIKit
import ScrivCore

@MainActor
final class CharactersController: ScrivScreenController, UISearchBarDelegate {
    private let search = UISearchBar()
    private let ribbon = UIScrollView()
    private let ribbonItems = CharacterTeamUI.row([], spacing: 10)
    private let scroll = UIScrollView()
    private let profile = ScrivUIKitTheme.stack(spacing: 16)
    private var searchText = ""
    private var renderedProject: ScrivProject?
    private var renderedSelection: String?
    private var renderedAssets: [String: String] = [:]
    private var creationPending = false

    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ScrivUIKitTheme.inset.withAlphaComponent(0.5); view.layer.cornerRadius = 17
        let add = CharacterTeamUI.button("", symbol: "plus") { [weak self] in self?.openNewCharacter() }
        add.accessibilityLabel = "Add character"
        let title = CharacterTeamUI.row([ScrivUIKitTheme.label("Characters", size: 29, weight: .semibold), CharacterTeamUI.spacer(), add])
        search.placeholder = "Search characters"; search.delegate = self; search.searchBarStyle = .minimal
        search.searchTextField.font = .systemFont(ofSize: 15); search.accessibilityLabel = "Search characters and aliases"
        ribbon.showsHorizontalScrollIndicator = false
        ribbonItems.translatesAutoresizingMaskIntoConstraints = false; ribbon.addSubview(ribbonItems)
        NSLayoutConstraint.activate([
            ribbonItems.leadingAnchor.constraint(equalTo: ribbon.contentLayoutGuide.leadingAnchor), ribbonItems.trailingAnchor.constraint(equalTo: ribbon.contentLayoutGuide.trailingAnchor),
            ribbonItems.topAnchor.constraint(equalTo: ribbon.contentLayoutGuide.topAnchor), ribbonItems.bottomAnchor.constraint(equalTo: ribbon.contentLayoutGuide.bottomAnchor),
            ribbonItems.heightAnchor.constraint(equalTo: ribbon.frameLayoutGuide.heightAnchor), ribbon.heightAnchor.constraint(equalToConstant: 150)
        ])
        profile.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(profile)
        NSLayoutConstraint.activate([
            profile.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), profile.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            profile.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), profile.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            profile.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        let hint = ScrivUIKitTheme.label("Confirmed script names open their character. Review suggestions from a line’s menu.", size: 11, color: ScrivUIKitTheme.secondary)
        let body = ScrivUIKitTheme.stack([title, search, ribbon, scroll, hint], spacing: 12)
        view.addSubview(body); body.scrivPinEdges(to: view, insets: .init(top: 16, leading: 16, bottom: 16, trailing: 16))
        render()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); consumeCreationRequest() }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        if renderedProject?.id != store.project.id {
            searchText = ""; search.text = ""
        } else if renderedSelection != store.selectedCharacterID, let selectedID = store.selectedCharacterID,
                  store.project.characters.contains(where: { $0.id == selectedID }), !characters.contains(where: { $0.id == selectedID }) {
            searchText = ""; search.text = ""
        }
        let availability = Dictionary(uniqueKeysWithValues: store.project.images.map { ($0.id, store.assetURL($0)?.path ?? "") })
        if renderedProject != store.project || renderedSelection != store.selectedCharacterID || renderedAssets != availability {
            renderedAssets = availability; render()
        }
        consumeCreationRequest()
    }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { self.searchText = searchText; render() }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    private var characters: [ScriptCharacter] {
        store.project.characters.filter { searchText.isEmpty || ([$0.name] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(searchText) } }
    }
    private func render() {
        renderedProject = store.project; renderedSelection = store.selectedCharacterID
        let selected = characters.first { $0.id == store.selectedCharacterID } ?? characters.first
        CharacterTeamUI.clear(ribbonItems)
        for character in characters {
            let control = UIButton(type: .custom)
            let portrait = CharacterTeamUI.portrait(character, store: store, size: CGSize(width: 98, height: 98), circular: true)
            portrait.layer.borderColor = selected?.id == character.id ? ScrivUIKitTheme.accent.cgColor : UIColor.clear.cgColor
            portrait.layer.borderWidth = selected?.id == character.id ? 2.5 : 0
            let name = ScrivUIKitTheme.label(character.name, size: 14, weight: .medium, lines: 1); name.textAlignment = .center
            let contents = ScrivUIKitTheme.stack([portrait, name], spacing: 9); contents.alignment = .center
            control.addSubview(contents); contents.scrivPinEdges(to: control, insets: .init(top: 10, leading: 8, bottom: 10, trailing: 8)); contents.isUserInteractionEnabled = false
            control.widthAnchor.constraint(equalToConstant: 156).isActive = true
            control.backgroundColor = selected?.id == character.id ? ScrivUIKitTheme.accent.withAlphaComponent(0.075) : .clear
            control.layer.cornerRadius = 14; control.accessibilityLabel = character.name
            control.accessibilityTraits = selected?.id == character.id ? [.button, .selected] : [.button]
            control.addAction(UIAction { [weak self] _ in self?.store.selectCharacter(character.id) }, for: .touchUpInside)
            ribbonItems.addArrangedSubview(control)
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
        let portrait = CharacterTeamUI.portrait(character, store: store, size: CGSize(width: 132, height: 132))
        let edit = CharacterTeamUI.button("Edit") { [weak self] in self?.show(.characterEditor(characterID: character.id)) }
        edit.isEnabled = store.lockedByOther(character.id) == nil
        let heading = CharacterTeamUI.row([ScrivUIKitTheme.label(character.name, size: 25, weight: .semibold), CharacterTeamUI.spacer(), edit])
        let aliases = CharacterTeamUI.row([ScrivUIKitTheme.label("Also called", size: 12, color: ScrivUIKitTheme.secondary), ScrivUIKitTheme.label(character.aliases.isEmpty ? "No aliases" : character.aliases.joined(separator: ", "), size: 12)], spacing: 18)
        let discuss = CharacterTeamUI.button("Discuss", symbol: "bubble.left", size: 12) { [weak self] in self?.store.loadDiscussion(itemId: character.id) }
        let remove = CharacterTeamUI.button("", symbol: "ellipsis") {}
        remove.accessibilityLabel = "Character actions"
        remove.menu = UIMenu(children: [UIAction(title: "Delete character…", image: UIImage(systemName: "trash"), attributes: store.lockedByOther(character.id) == nil ? .destructive : [.destructive, .disabled]) { [weak self] _ in self?.confirmDelete(character) }])
        remove.showsMenuAsPrimaryAction = true
        let details = ScrivUIKitTheme.stack([heading, ScrivUIKitTheme.label("Character", size: 12, color: ScrivUIKitTheme.secondary), CharacterTeamUI.separator(), aliases, CharacterTeamUI.row([discuss, remove, CharacterTeamUI.spacer()])], spacing: 10)
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
        content.addArrangedSubview(CharacterTeamUI.row([ScrivUIKitTheme.label("Tagged images", size: 17, weight: .semibold), ScrivUIKitTheme.label("\(images.count)", size: 12, color: ScrivUIKitTheme.secondary), CharacterTeamUI.spacer()]))
        if images.isEmpty { content.addArrangedSubview(ScrivUIKitTheme.label("Tag this character in an image to add it here.", size: 14, color: ScrivUIKitTheme.secondary)) }
        for start in stride(from: 0, to: images.count, by: 2) {
            let cells = Array(images[start..<min(images.count, start + 2)]).map { imageCard($0, character: character) }
            let row = CharacterTeamUI.row(cells.count == 2 ? cells : cells + [UIView()], spacing: 15); row.distribution = .fillEqually; row.alignment = .top
            content.addArrangedSubview(row)
        }
        return ScrivUIKitTheme.card(content, padding: 17)
    }
    private func imageCard(_ image: ImageAsset, character: ScriptCharacter) -> UIView {
        let cue = store.project.cues.first { $0.imageId == image.id }
        let title = cue.flatMap { $0.label.isEmpty ? nil : $0.label } ?? "Image"
        let picture = UIKitAssetImageView(); picture.configure(url: store.assetURL(image), title: title, fill: true, missingText: "Image not on this device")
        picture.layer.cornerRadius = 9; picture.clipsToBounds = true
        let open = UIButton(type: .custom); open.addSubview(picture); picture.scrivPinEdges(to: open); picture.isUserInteractionEnabled = false
        open.heightAnchor.constraint(equalTo: open.widthAnchor, multiplier: 0.625).isActive = true
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
        let caption = CharacterTeamUI.row([ScrivUIKitTheme.label(title, size: 12, weight: .medium), CharacterTeamUI.spacer(), ScrivUIKitTheme.label("v\(image.version)", size: 11, color: ScrivUIKitTheme.secondary), actions], spacing: 5)
        let tags = CharacterChipWrapView()
        tags.chips = store.project.characters.filter { image.characterIds.contains($0.id) }.map { person in
            let button = CharacterTeamUI.button(person.name, symbol: "circle.fill", size: 10) { [weak self] in self?.store.selectCharacter(person.id) }
            button.configuration?.image = UIImage(systemName: "circle.fill")?.withTintColor(ScrivUIKitTheme.color(person.color), renderingMode: .alwaysOriginal)
            return button
        }
        tags.chips.append(CharacterTeamUI.button("", symbol: "plus", size: 11) { [weak self] in
            guard let self else { return }
            let controller = UINavigationController(rootViewController: CharacterTagsViewController(store: self.store, imageID: image.id))
            CharacterTeamUI.present(controller, from: self, width: 470, height: 600)
        })
        tags.chips.last?.accessibilityLabel = "Edit character tags"
        return ScrivUIKitTheme.stack([open, caption, tags], spacing: 6)
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
