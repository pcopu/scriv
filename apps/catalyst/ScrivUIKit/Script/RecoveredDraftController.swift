import UIKit
import Combine
import ScrivCore

@MainActor
final class RecoveredDraftController: ScrivScreenController, UIAdaptivePresentationControllerDelegate {
    private let session: ScriptDraftSession
    var onEditDraft: (() -> Void)?
    private var returningToEditor = false
    private let reviewedScope: EditorDraftScope?
    private var sessionMatches: Bool { contextIsCurrent && session.active && session.record?.scope == reviewedScope && session.navigation == initialNavigationContext }
    private let currentText = ScriptTextView(), draftText = ScriptTextView()
    private let content = ScrivUIKitTheme.stack([], spacing: 18)
    private let headerLabel = ScrivUIKitTheme.label("Recovered draft", size: 23, weight: .semibold)
    private let lineLabel = ScrivUIKitTheme.label("", size: 14, color: ScrivUIKitTheme.secondary)
    private var applyButton: UIButton!
    private var keepButton: UIButton!
    private var discardButton: UIButton!
    private var explanatoryText: UIView?
    private var explanationExpanded = false

    init(store: WorkspaceStore, session: ScriptDraftSession) {
        self.session = session; reviewedScope = session.record?.scope; super.init(store: store)
        preferredContentSize = CGSize(width: 560, height: 740); isModalInPresentation = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        let heading = ScrivUIKitTheme.stack([headerLabel, lineLabel], spacing: 6)
        let edit = ScrivUIKitTheme.button("Edit draft", symbol: "pencil") { [weak self] in
            guard let self, sessionMatches, !session.applying else { return }
            returningToEditor = true
            dismiss(animated: true) { [weak self] in self?.onEditDraft?() }
        }
        let headingRow = ScrivUIKitTheme.stack([heading, UIView(), edit], axis: .horizontal, spacing: 12); headingRow.alignment = .top
        let header = padded(headingRow, insets: NSDirectionalEdgeInsets(top: 24, leading: 26, bottom: 20, trailing: 26))
        header.backgroundColor = ScrivUIKitTheme.chrome.withAlphaComponent(0.2)
        let scroll = UIScrollView(); scroll.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24), content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24), content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 26), content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -26), content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -52)])
        for text in [currentText, draftText] { text.setScriptStyle(size: 18, direction: false); text.isEditable = false; text.isSelectable = true }
        currentText.accessibilityLabel = "Current saved line"; draftText.accessibilityLabel = "Your local draft"
        applyButton = ScrivUIKitTheme.button("Apply reviewed draft", primary: true) { [weak self] in guard let self, sessionMatches else { return }; session.applyReviewed() }
        keepButton = ScrivUIKitTheme.button("Keep for later") { [weak self] in self?.keep() }
        discardButton = ScrivUIKitTheme.button("Discard draft…") { [weak self] in self?.confirmDiscard() }; discardButton.tintColor = .systemRed
        let footer = ScrivUIKitTheme.stack([keepButton, UIView(), applyButton], axis: .horizontal, spacing: 14)
        let bottom = ScrivUIKitTheme.stack([padded(footer, insets: NSDirectionalEdgeInsets(top: 18, leading: 26, bottom: 18, trailing: 26)), padded(ScrivUIKitTheme.stack([discardButton, UIView()], axis: .horizontal), insets: NSDirectionalEdgeInsets(top: 8, leading: 26, bottom: 8, trailing: 26))], spacing: 0)
        let root = ScrivUIKitTheme.stack([header, scroll, bottom], spacing: 0); view.addSubview(root); root.scrivPinEdges(to: view)
        session.changes.sink { [weak self] in DispatchQueue.main.async { self?.storeDidChange() } }.store(in: &subscriptions)
        storeDidChange()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); presentationController?.delegate = self }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        guard sessionMatches, let record = session.record, let entry = session.currentEntry else { dismiss(animated: true); return }
        for child in content.arrangedSubviews { content.removeArrangedSubview(child); child.removeFromSuperview() }
        let line = (store.project.entries(in: entry.sceneId).firstIndex { $0.id == entry.id } ?? 0) + 1
        lineLabel.text = String(format: "Line %02d", line) + " · " + (entry.kind == .direction ? "Direction" : store.project.character(entry.characterId)?.name ?? "Dialogue")
        let matches = record.text.utf16.elementsEqual(entry.text.utf16)
        content.addArrangedSubview(ScrivUIKitTheme.notice(matches ? "Recovery copy saved on this Mac" : "Saved on this Mac · Not uploaded", message: matches ? "This recovery copy matches the current saved line. It does not undo an autosaved edit." : "This draft copy is only on your Mac until you apply it.", warning: true))
        if !currentText.text.utf16.elementsEqual(entry.text.utf16) { currentText.text = entry.text.isEmpty ? "Empty line" : entry.text; currentText.invalidateIntrinsicContentSize() }
        let value = NSMutableAttributedString(string: record.text.isEmpty ? "Empty line" : record.text, attributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: ScrivUIKitTheme.ink])
        if let range = RecoveredDraftComparison.changedRange(in: record.text, comparedTo: entry.text) { value.addAttribute(.backgroundColor, value: ScrivUIKitTheme.accent.withAlphaComponent(0.17), range: range) }
        draftText.attributedText = value; draftText.invalidateIntrinsicContentSize()
        let compare = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Current saved line", size: 16, weight: .semibold), ScrivUIKitTheme.card(currentText, padding: 14), ScrivUIKitTheme.label("Your local draft", size: 16, weight: .semibold), ScrivUIKitTheme.card(draftText, padding: 14), ScrivUIKitTheme.label("Review the current line before applying. Its owned timing stays unchanged.", size: 13, color: ScrivUIKitTheme.secondary)], spacing: 14)
        content.addArrangedSubview(ScrivUIKitTheme.card(compare, padding: 18))
        if session.needsRebase {
            content.addArrangedSubview(ScrivUIKitTheme.notice("The saved line or timing changed", message: "Use the current saved line as the base before applying. Current timing is kept; character links in replaced text will need review.", warning: true))
            let rebase = ScrivUIKitTheme.button("Use current saved line as base") { [weak self] in guard let self, sessionMatches else { return }; session.rebase() }; rebase.isEnabled = !session.applying; content.addArrangedSubview(rebase)
        }
        if let issue = session.issue { content.addArrangedSubview(ScrivUIKitTheme.notice("Draft not applied", message: issue, warning: true)) }
        let why = ScrivUIKitTheme.button("Why am I seeing this?", symbol: explanationExpanded ? "chevron.down" : "chevron.right") { [weak self] in self?.explanationExpanded.toggle(); self?.storeDidChange() }
        content.addArrangedSubview(why)
        if explanationExpanded { content.addArrangedSubview(ScrivUIKitTheme.label("Scriv keeps a separate local recovery copy when editing is interrupted or a change cannot be applied. This draft began at revision \(record.sourceRevision). Keeping it for later does not apply it; reopen this line to review it again.", size: 13, color: ScrivUIKitTheme.secondary)) }
        applyButton.isEnabled = !session.applying && !session.needsRebase
        keepButton.isEnabled = !session.applying; discardButton.isEnabled = !session.applying; isModalInPresentation = session.applying
    }
    private func keep() { if sessionMatches { session.keepForLater() }; dismiss(animated: true) }
    private func confirmDiscard() {
        let alert = UIAlertController(title: "Discard this local draft?", message: "Only this pending recovery copy is removed. The saved script does not change, and valid autosaved edits are not undone.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard local draft", style: .destructive) { [weak self] _ in guard let self, requireCurrentContext(), sessionMatches else { return }; if session.discard() { dismiss(animated: true) } })
        present(alert, animated: true)
    }
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool { !session.applying }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { if sessionMatches && !returningToEditor { session.keepForLater() } }
    private func padded(_ child: UIView, insets: NSDirectionalEdgeInsets) -> UIView { let container = UIView(); container.addSubview(child); child.scrivPinEdges(to: container, insets: insets); return container }
}
