import UIKit
import ScrivCore

/// Form state remains local until Save. Creation never adds a placeholder, and
/// an existing edit holds one lease tied to one immutable project/item request.
@MainActor
final class CharacterEditorController: ScrivScreenController, UITextViewDelegate, UIAdaptivePresentationControllerDelegate {
    let navigationContext: Int
    let isNew: Bool
    private let accountContext: String
    private var draft: ScriptCharacter
    private var original: ScriptCharacter
    private var hasLease = false
    private var openingTask: Task<Void, Never>?
    private var active = true
    private var opened = false
    private var layout: CharacterTeamSheetLayout!
    private let name = CharacterTeamUI.field("Name")
    private let biography = CharacterTeamUI.notes("", title: "Biography")
    private let appearance = CharacterTeamUI.notes("", title: "Appearance & image direction")
    private let displayedName = ScrivUIKitTheme.label("", size: 24, weight: .semibold)
    private let colorDot = UIView()
    private let aliases = CharacterChipWrapView()
    private let palette = CharacterChipWrapView()
    private let issue = ScrivUIKitTheme.label("", size: 14, color: .systemRed)
    private let identity = CharacterTeamUI.row([], spacing: 22)
    private var saveButton: UIButton!

    init(store: WorkspaceStore, character: ScriptCharacter, navigationContext: Int, isNew: Bool = false) {
        draft = character; original = character; self.navigationContext = navigationContext; self.isNew = isNew
        accountContext = store.editorAccountContext
        super.init(store: store); preferredContentSize = CGSize(width: 710, height: 844)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:character:navigationContext:isNew:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        layout = CharacterTeamSheetLayout(title: isNew ? "Add character" : "Edit character") { [weak self] in self?.close() }
        view.addSubview(layout); layout.scrivPinEdges(to: view)
        colorDot.layer.cornerRadius = 10; colorDot.widthAnchor.constraint(equalToConstant: 20).isActive = true; colorDot.heightAnchor.constraint(equalToConstant: 20).isActive = true
        name.autocapitalizationType = .words; name.returnKeyType = .done
        name.addAction(UIAction { [weak self] _ in self?.nameChanged() }, for: .editingChanged)
        name.addAction(UIAction { [weak self] _ in self?.save() }, for: .editingDidEndOnExit)
        biography.delegate = self; appearance.delegate = self
        let fields = ScrivUIKitTheme.stack([CharacterTeamUI.row([colorDot, displayedName]), CharacterTeamUI.labeled("Name", name), CharacterTeamUI.labeled("Also called", aliases), CharacterTeamUI.labeled("Character colour", palette)], spacing: 18)
        identity.alignment = .top
        identity.addArrangedSubview(CharacterTeamUI.portrait(draft, store: store, size: CGSize(width: 205, height: 226)))
        identity.addArrangedSubview(fields)
        layout.content.addArrangedSubview(identity)
        layout.content.addArrangedSubview(ScrivUIKitTheme.notice("", message: "Confirmed links stay attached. Script wording never changes."))
        layout.content.addArrangedSubview(CharacterTeamUI.labeled("Biography", biography))
        layout.content.addArrangedSubview(CharacterTeamUI.labeled("Appearance & image direction", appearance))
        layout.content.addArrangedSubview(issue); issue.isHidden = true
        layout.footer.addArrangedSubview(CharacterTeamUI.button("Cancel") { [weak self] in self?.close() })
        saveButton = CharacterTeamUI.button("Save character", primary: true, size: 16) { [weak self] in self?.save() }
        layout.footer.addArrangedSubview(saveButton)
        loadFields(); setEditable(isNew)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); presentationController?.delegate = self
        guard !opened else { return }; opened = true
        if isNew { name.becomeFirstResponder() }
        else {
            openingTask = Task { [weak self] in
                guard let self else { return }
                let allowed = await self.store.beginEdit(self.draft.id)
                guard self.active, !Task.isCancelled, self.contextValid else {
                    if allowed { self.store.endEdit(self.draft.id, context: self.navigationContext) }; return
                }
                guard allowed else { self.showIssue(self.store.errorMessage ?? "This character is being edited elsewhere. Close and reopen when it is available."); return }
                guard let current = self.store.project.character(self.draft.id) else {
                    self.store.endEdit(self.draft.id, context: self.navigationContext); self.showIssue("This character no longer exists. Your script has not been changed."); return
                }
                self.hasLease = true; self.original = current; self.draft = current; self.loadFields(); self.setEditable(true); self.name.becomeFirstResponder()
            }
        }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); identity.axis = view.bounds.width < 610 ? .vertical : .horizontal }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || presentingViewController == nil { release() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { release() }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        if !contextValid { showIssue("The project or account changed. Close and reopen this form before saving."); setEditable(false) }
        else { saveButton.isEnabled = (isNew || hasLease) && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var contextValid: Bool { contextIsCurrent && store.navigationContext == navigationContext && store.editorAccountContext == accountContext }
    private func loadFields() {
        name.text = draft.name; biography.text = draft.biography; appearance.text = draft.appearance
        displayedName.text = draft.name.isEmpty ? "New character" : draft.name; colorDot.backgroundColor = ScrivUIKitTheme.color(draft.color)
        renderAliases(); renderColors()
    }
    private func nameChanged() {
        draft.name = name.text ?? ""; displayedName.text = draft.name.isEmpty ? "New character" : draft.name
        saveButton.isEnabled = (isNew || hasLease) && contextValid && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        issue.isHidden = true
    }
    func textViewDidChange(_ textView: UITextView) {
        if textView === biography { draft.biography = textView.text } else if textView === appearance { draft.appearance = textView.text }
        issue.isHidden = true
    }
    private func renderAliases() {
        aliases.chips = draft.aliases.enumerated().map { index, value in
            CharacterTeamUI.button(value, symbol: "xmark", size: 14) { [weak self] in
                guard let self, self.draft.aliases.indices.contains(index) else { return }
                self.draft.aliases.remove(at: index); self.renderAliases()
            }
        }
        aliases.chips.enumerated().forEach { index, chip in chip.accessibilityLabel = "Remove alias \(draft.aliases[index])" }
        aliases.chips.append(CharacterTeamUI.button("Add alias", symbol: "plus", size: 14) { [weak self] in self?.addAlias() })
    }
    private func addAlias() {
        let alert = UIAlertController(title: "Add alias", message: "New matches remain suggestions until you confirm them.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Another name for this character"; $0.autocapitalizationType = .words }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self, self.contextValid else { return }
            let value = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            guard value.utf16.count <= 500, self.draft.aliases.count < 100 else { self.showIssue("Use at most 100 aliases of up to 500 characters each."); return }
            if !self.draft.aliases.contains(where: { $0.localizedCaseInsensitiveCompare(value) == .orderedSame }) { self.draft.aliases.append(value) }
            self.renderAliases()
        }); present(alert, animated: true)
    }
    private func renderColors() {
        var colors = ["orange", "green", "teal", "blue", "purple", "coral", "pink"]
        if !colors.contains(draft.color) { colors.insert(draft.color, at: 0) }
        palette.chips = colors.map { color in
            let button = UIButton(type: .custom); let selected = draft.color == color
            button.setImage(UIImage(systemName: selected ? "circle.inset.filled" : "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30)), for: .normal)
            button.tintColor = ScrivUIKitTheme.color(color); button.contentEdgeInsets = UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
            button.accessibilityLabel = "\(color.capitalized) character colour"; button.accessibilityTraits = selected ? [.button, .selected] : [.button]
            button.addAction(UIAction { [weak self] _ in self?.draft.color = color; self?.colorDot.backgroundColor = ScrivUIKitTheme.color(color); self?.renderColors() }, for: .touchUpInside)
            return button
        }
    }
    private func setEditable(_ value: Bool) {
        layout.content.isUserInteractionEnabled = value; saveButton.isEnabled = value && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func showIssue(_ value: String) { issue.text = value; issue.isHidden = false }
    private func save() {
        guard contextValid, isNew || hasLease else { showIssue("Reopen this character in the current project before saving."); return }
        view.endEditing(true)
        draft.name = (name.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        draft.biography = biography.text; draft.appearance = appearance.text
        do {
            try UIKitCharacterFormValidation.validate(draft)
            if !isNew {
                guard let current = store.project.character(draft.id) else { throw ScrivError.conflict("This character was removed while the form was open.") }
                var currentAuthored = current, originalAuthored = original
                currentAuthored.portraitImageId = nil; originalAuthored.portraitImageId = nil
                guard currentAuthored == originalAuthored else { throw ScrivError.conflict("This character changed while you were editing. Your draft is still here; copy any notes before closing and reopening the current profile.") }
                // Portrait is not an editable field in this form; preserve its current identity.
                draft.portraitImageId = current.portraitImageId
            }
            if isNew ? store.createCharacter(draft) : store.updateCharacter(draft) { close() }
            else { showIssue(store.errorMessage ?? "The character could not be saved. Your draft is still here.") }
        } catch { showIssue(error.localizedDescription) }
    }
    private func release() {
        active = false; openingTask?.cancel(); openingTask = nil
        if hasLease { store.endEdit(draft.id, context: navigationContext); hasLease = false }
    }
    private func close() { view.endEditing(true); release(); dismiss(animated: true) }
}

/// Uses the same server bounds without normalizing authored prose or aliases.
enum UIKitCharacterFormValidation {
    static func validate(_ character: ScriptCharacter) throws {
        guard !character.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, character.name.utf16.count <= 200 else { throw ScrivError.invalid("Enter a character name of 1–200 characters.") }
        guard character.aliases.count <= 100, character.aliases.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 500 }) else { throw ScrivError.invalid("Use at most 100 aliases of up to 500 characters each.") }
        guard character.biography.utf16.count <= 20_000, character.appearance.utf16.count <= 20_000 else { throw ScrivError.invalid("Biography and image direction can each contain up to 20,000 characters. Your draft has not been truncated.") }
        let encoder = ScrivJSON.encoder; encoder.outputFormatting.insert(.withoutEscapingSlashes)
        guard try encoder.encode(character).count <= 65_536 else { throw ScrivError.invalid("This character's complete profile exceeds 64 KiB. Shorten its notes before saving; the draft remains here.") }
    }
}
