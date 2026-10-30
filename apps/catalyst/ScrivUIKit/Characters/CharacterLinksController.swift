import UIKit
import ScrivCore

/// The request is one immutable entry/context snapshot. Confirm/correct/unlink
/// update only source annotations; source spelling and UTF-16 offsets stay exact.
@MainActor
final class CharacterLinksController: ScrivScreenController, UIAdaptivePresentationControllerDelegate {
    let entry: ScriptEntry
    let navigationContext: Int
    private let accountContext: String
    private var links: [CharacterTextLink]
    private var choices: [String: String] = [:]
    private var hasLease = false
    private var active = true
    private var opening = false
    private var requiresReopening = false
    private var openingTask: Task<Void, Never>?
    private var layout: CharacterTeamSheetLayout!
    private let source = UITextView()
    private let rows = ScrivUIKitTheme.stack(spacing: 14)
    private let phrase = CharacterTeamUI.field("Exact words from this line")
    private let occurrenceRows = ScrivUIKitTheme.stack(spacing: 12)
    private let otherBody = ScrivUIKitTheme.stack(spacing: 14)
    private let issue = ScrivUIKitTheme.label("", size: 14, color: .systemRed)
    private let pending = ScrivUIKitTheme.label("Confirm your selected character changes before saving, or keep those words unlinked.", size: 14, color: ScrivUIKitTheme.secondary)
    private var retry: UIButton!
    private var saveButton: UIButton!
    private var reviewLimit = 40
    private var occurrenceLimit = 20
    private var previousWidth: CGFloat = 0

    init(store: WorkspaceStore, entry: ScriptEntry, navigationContext: Int) {
        self.entry = entry; self.navigationContext = navigationContext; accountContext = store.editorAccountContext
        links = entry.characterLinks ?? CharacterMentions.suggestions(in: entry.text, characters: store.project.characters)
        super.init(store: store); preferredContentSize = CGSize(width: 710, height: 844)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:entry:navigationContext:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        layout = CharacterTeamSheetLayout(title: "Review character links") { [weak self] in self?.close() }
        view.addSubview(layout); layout.scrivPinEdges(to: view)
        let scene = store.project.orderedScenes.firstIndex { $0.id == entry.sceneId }.map { "Scene \($0 + 1)" } ?? "Scene"
        layout.subtitle.text = "\(scene) · \(entry.kind == .direction ? "Direction" : "Dialogue")"; layout.subtitle.isHidden = false
        source.isEditable = false; source.isSelectable = true; source.isScrollEnabled = false
        source.backgroundColor = ScrivUIKitTheme.panel; source.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        source.layer.cornerRadius = 10; source.layer.borderWidth = 1; source.layer.borderColor = ScrivUIKitTheme.hairline.cgColor
        source.heightAnchor.constraint(greaterThanOrEqualToConstant: 102).isActive = true
        source.accessibilityLabel = "Source line, unchanged"
        let toggle = CharacterTeamUI.button("Link other wording", symbol: "chevron.down", size: 17) { [weak self] in self?.otherBody.isHidden.toggle() }
        phrase.autocapitalizationType = .none; phrase.autocorrectionType = .no; phrase.spellCheckingType = .no
        phrase.addAction(UIAction { [weak self] _ in self?.occurrenceLimit = 20; self?.renderOccurrences() }, for: .editingChanged)
        otherBody.addArrangedSubview(CharacterTeamUI.labeled("Exact words from this line", phrase)); otherBody.addArrangedSubview(occurrenceRows)
        retry = CharacterTeamUI.button("Try opening again") { [weak self] in self?.openReview() }; retry.isHidden = true
        [source, rows, CharacterTeamUI.separator(), toggle, otherBody,
         ScrivUIKitTheme.notice("", message: "Suggestions are guesses. Confirm only the right character."), pending, issue, retry].forEach(layout.content.addArrangedSubview)
        issue.isHidden = true; pending.isHidden = true
        layout.footer.addArrangedSubview(CharacterTeamUI.button("Cancel") { [weak self] in self?.close() })
        saveButton = CharacterTeamUI.button("Save links", primary: true, size: 16) { [weak self] in self?.save() }
        layout.footer.addArrangedSubview(saveButton)
        renderLinks(); setEnabled(false)
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); presentationController?.delegate = self; if !hasLease, !requiresReopening { openReview() } }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if (previousWidth < 640) != (view.bounds.width < 640) { previousWidth = view.bounds.width; renderLinks() }
        else { previousWidth = view.bounds.width }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || presentingViewController == nil { release() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { release() }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        if !contextValid { showIssue("The project or account changed. Close and reopen this review before saving."); setEnabled(false) }
    }
    private var contextValid: Bool { contextIsCurrent && store.navigationContext == navigationContext && store.editorAccountContext == accountContext }
    private func setEnabled(_ value: Bool) { rows.isUserInteractionEnabled = value; otherBody.isUserInteractionEnabled = value; saveButton.isEnabled = value && choices.isEmpty }
    private func openReview() {
        guard active, contextValid, !opening, !hasLease, !requiresReopening else { return }
        opening = true; retry.isHidden = true; issue.text = "Opening line…"; issue.textColor = ScrivUIKitTheme.secondary; issue.isHidden = false
        openingTask = Task { [weak self] in
            guard let self else { return }
            let allowed = await self.store.beginEdit(self.entry.id)
            self.opening = false
            guard self.active, self.contextValid, !Task.isCancelled else {
                if allowed { self.store.endEdit(self.entry.id, context: self.navigationContext) }; return
            }
            guard allowed else { self.showIssue(self.store.errorMessage ?? "The line could not be opened for editing."); self.retry.isHidden = false; return }
            guard let current = self.store.project.entries.first(where: { $0.id == self.entry.id }),
                  current.text.utf16.elementsEqual(self.entry.text.utf16), current.characterLinks == self.entry.characterLinks else {
                self.store.endEdit(self.entry.id, context: self.navigationContext); self.requiresReopening = true
                self.showIssue("This line changed before the review opened. Close and reopen it to review the current wording and links."); return
            }
            self.hasLease = true; self.issue.isHidden = true; self.setEnabled(true)
        }
    }
    private func renderLinks() {
        guard isViewLoaded else { return }
        source.attributedText = UIKitCharacterLinkPresentation.highlighted(entry.text, links: links, characters: store.project.characters, fontSize: 20)
        CharacterTeamUI.clear(rows)
        let suggestions = links.filter { !$0.isConfirmed }, confirmed = links.filter(\.isConfirmed)
        for (title, group) in [("Suggested links", suggestions), ("Reviewed links", confirmed)] where !group.isEmpty {
            rows.addArrangedSubview(ScrivUIKitTheme.label(title, size: 17, weight: .semibold, color: ScrivUIKitTheme.secondary))
            group.prefix(reviewLimit).forEach { rows.addArrangedSubview(linkRow($0)) }
            if group.count > reviewLimit { rows.addArrangedSubview(CharacterTeamUI.button("Show more links (\(group.count - reviewLimit) remaining)") { [weak self] in self?.reviewLimit += 40; self?.renderLinks() }) }
        }
        if links.isEmpty { rows.addArrangedSubview(ScrivUIKitTheme.label("No character links in this line yet.", size: 16, color: ScrivUIKitTheme.secondary)) }
        rows.addArrangedSubview(CharacterTeamUI.button("Find more name suggestions", size: 14) { [weak self] in
            guard let self, self.hasLease else { return }
            self.links += CharacterMentions.suggestions(in: self.entry.text, characters: self.store.project.characters, excluding: self.links)
            self.links.sort { $0.location < $1.location }; self.renderLinks()
        })
        pending.isHidden = choices.isEmpty; saveButton?.isEnabled = hasLease && contextValid && choices.isEmpty
    }
    private func linkRow(_ link: CharacterTextLink) -> UIView {
        let selectedID = choices[link.id] ?? link.characterId
        let character = selectedID.flatMap { store.project.character($0) }
        let explanation = ScrivUIKitTheme.stack([
            ScrivUIKitTheme.label("“\(link.text)”", size: 18, weight: .medium),
            ScrivUIKitTheme.label(link.isConfirmed ? (link.characterId == nil ? "Kept unlinked" : "Confirmed link") : "Suggested match", size: 14, color: ScrivUIKitTheme.secondary)
        ], spacing: 5)
        let choices = store.project.characters.map { person in UIAction(title: person.name, state: person.id == selectedID ? .on : .off) { [weak self] _ in
            guard let self, self.hasLease else { return }
            if person.id == link.characterId { self.choices.removeValue(forKey: link.id) } else { self.choices[link.id] = person.id }
            self.renderLinks()
        } }
        let menu = CharacterTeamUI.menu(character?.name ?? (link.characterId == nil ? "Choose character" : "Missing character"), actions: choices)
        menu.widthAnchor.constraint(equalToConstant: 208).isActive = true; menu.isEnabled = !store.project.characters.isEmpty
        menu.accessibilityLabel = "Character for \(link.text)"
        var controls: [UIView] = []
        if let character { controls.append(CharacterTeamUI.portrait(character, store: store, size: CGSize(width: 56, height: 58))) }
        controls.append(menu)
        if !link.isConfirmed || self.choices[link.id] != nil {
            let confirm = CharacterTeamUI.button(link.isConfirmed ? "Correct" : "Confirm", primary: true) { [weak self] in if let selectedID { self?.assign(link.range, characterID: selectedID) } }
            confirm.isEnabled = character != nil; controls.append(confirm)
        } else { controls.append(CharacterTeamUI.symbol("checkmark.circle.fill", color: ScrivUIKitTheme.accent)) }
        let chosen = CharacterTeamUI.row(controls, spacing: 12)
        let main: UIStackView
        if view.bounds.width > 0 && view.bounds.width < 640 { main = ScrivUIKitTheme.stack([explanation, chosen], spacing: 14) }
        else { main = CharacterTeamUI.row([explanation, CharacterTeamUI.symbol("arrow.right"), chosen], spacing: 12) }
        let content = ScrivUIKitTheme.stack([main], spacing: 12)
        if link.characterId != nil || self.choices[link.id] != nil {
            let unlink = CharacterTeamUI.button(link.isConfirmed ? "Unlink" : "Keep unlinked", size: 14) { [weak self] in self?.assign(link.range, characterID: nil) }
            content.addArrangedSubview(CharacterTeamUI.row([CharacterTeamUI.spacer(), unlink]))
        }
        return ScrivUIKitTheme.card(content, padding: 20)
    }
    private func renderOccurrences() {
        CharacterTeamUI.clear(occurrenceRows)
        let phrase = self.phrase.text ?? ""
        let ranges = UIKitCharacterLinkPresentation.occurrences(of: phrase, in: entry.text)
        if !phrase.isEmpty && ranges.isEmpty { occurrenceRows.addArrangedSubview(ScrivUIKitTheme.label("Those exact words are not in this line.", size: 14, color: ScrivUIKitTheme.secondary)) }
        for (index, range) in ranges.prefix(occurrenceLimit).enumerated() {
            let caption = ScrivUIKitTheme.label(ranges.count == 1 ? "Occurrence in scene" : "Occurrence \(index + 1) in scene", size: 14, color: ScrivUIKitTheme.secondary)
            let excerpt = UILabel(); excerpt.numberOfLines = 0
            excerpt.attributedText = UIKitCharacterLinkPresentation.highlighted(entry.text, focusedRange: range, fontSize: 16)
            let existing = links.first { $0.range == range && $0.isConfirmed }
            let menu = CharacterTeamUI.menu(existing?.characterId.flatMap { store.project.character($0)?.name } ?? "Choose character", actions: store.project.characters.map { person in
                UIAction(title: "Link to \(person.name)") { [weak self] _ in self?.assign(range, characterID: person.id) }
            }); menu.isEnabled = !store.project.characters.isEmpty
            let unlink = CharacterTeamUI.button(existing != nil && existing?.characterId == nil ? "Kept unlinked" : "Keep unlinked", size: 14) { [weak self] in self?.assign(range, characterID: nil) }
            let content = ScrivUIKitTheme.stack([caption, excerpt, ScrivUIKitTheme.label("Choose a character for these words, or keep unlinked.", size: 14, color: ScrivUIKitTheme.secondary), CharacterTeamUI.row([menu, CharacterTeamUI.spacer(), unlink])], spacing: 10)
            let card = ScrivUIKitTheme.card(content, padding: 18); card.backgroundColor = ScrivUIKitTheme.inset
            occurrenceRows.addArrangedSubview(card)
        }
        if ranges.count > occurrenceLimit {
            occurrenceRows.addArrangedSubview(CharacterTeamUI.button("Show more occurrences (\(ranges.count - occurrenceLimit) remaining)") { [weak self] in self?.occurrenceLimit += 20; self?.renderOccurrences() })
        }
    }
    private func assign(_ range: NSRange, characterID: String?) {
        guard hasLease, contextValid else { return }
        var copy = entry; copy.characterLinks = links
        do {
            try CharacterMentions.assign(&copy, range: range, characterId: characterID, characters: store.project.characters)
            let replaced = Set(links.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.id))
            choices = choices.filter { !replaced.contains($0.key) }; links = copy.characterLinks ?? []
            issue.isHidden = true; renderLinks(); renderOccurrences()
        } catch { showIssue(error.localizedDescription) }
    }
    private func save() {
        guard contextValid, hasLease, choices.isEmpty else { return }
        guard let current = store.project.entries.first(where: { $0.id == entry.id }), current.characterLinks == entry.characterLinks,
              current.text.utf16.elementsEqual(entry.text.utf16) else {
            showIssue("This line or its reviewed links changed while the sheet was open. Close and reopen the review; the newer saved links have not been overwritten."); return
        }
        if store.saveCharacterLinks(entry.id, expectedText: entry.text, links: links) { close() }
        else { showIssue(store.errorMessage ?? "These links could not be saved. Your review is still here.") }
    }
    private func showIssue(_ value: String) { issue.text = value; issue.textColor = .systemRed; issue.isHidden = false }
    private func release() { active = false; openingTask?.cancel(); openingTask = nil; if hasLease { store.endEdit(entry.id, context: navigationContext); hasLease = false } }
    private func close() { view.endEditing(true); release(); dismiss(animated: true) }
}

enum UIKitCharacterLinkPresentation {
    static func occurrences(of phrase: String, in text: String) -> [NSRange] {
        guard !phrase.isEmpty else { return [] }
        let source = text as NSString; var result: [NSRange] = [], cursor = 0
        while cursor < source.length {
            let range = source.range(of: phrase, options: .literal, range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if Range(range, in: text) != nil { result.append(range) }; cursor = range.location + range.length
        }
        return result
    }
    @MainActor static func highlighted(_ text: String, links: [CharacterTextLink] = [], characters: [ScriptCharacter] = [], focusedRange: NSRange? = nil, fontSize: CGFloat = 18) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        let result = NSMutableAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: ScrivUIKitTheme.ink, .paragraphStyle: paragraph])
        for link in links where CharacterMentions.matchesSource(link, in: text) {
            guard let person = link.characterId.flatMap({ id in characters.first { $0.id == id } }) else { continue }
            result.addAttribute(.backgroundColor, value: ScrivUIKitTheme.color(person.color).withAlphaComponent(0.24), range: link.range)
        }
        if let focusedRange, focusedRange.location >= 0, focusedRange.length > 0,
           focusedRange.location <= text.utf16.count, focusedRange.length <= text.utf16.count - focusedRange.location,
           Range(focusedRange, in: text) != nil {
            result.addAttribute(.backgroundColor, value: ScrivUIKitTheme.accent.withAlphaComponent(0.22), range: focusedRange)
        }
        return result
    }
}
