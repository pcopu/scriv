import UIKit
import ScrivCore

/// UIKit measures the actual constrained width, not a speculative SwiftUI probe.
/// Keeping one text view alive preserves the native undo stack, marked text and
/// UTF-16 selection while unrelated store state publishes.
final class ScriptTextView: UITextView {
    var finishEditing: (() -> Void)?
    var sizeChanged: (() -> Void)?
    var mergeAtStart: (() -> Void)?
    private var measuredWidth: CGFloat = 0
    var presencePeers: [PresencePeer] = [] { didSet { setNeedsLayout() } }
    private var peerMarkers: [UIView] = []
    private var presenceSignature = ""
    override var intrinsicContentSize: CGSize {
        let width = max(1, bounds.width)
        let size = super.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: max((font?.lineHeight ?? 22) + 3, ceil(size.height)))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(measuredWidth - bounds.width) > 0.5 {
            measuredWidth = bounds.width; invalidateIntrinsicContentSize(); sizeChanged?()
        }
        renderPresence()
    }
    private func renderPresence() {
        let signature = "\(bounds.width):\(bounds.height):\(text.hashValue):\(text.utf16.count):" + presencePeers.map { "\($0.id):\($0.name):\($0.selection?["end"]?.int ?? -1)" }.joined(separator: "|")
        guard signature != presenceSignature else { return }; presenceSignature = signature
        peerMarkers.forEach { $0.removeFromSuperview() }; peerMarkers = []
        guard bounds.width > 1 else { return }
        for (index, peer) in presencePeers.enumerated() {
            guard let offset = peer.selection?["end"]?.int, offset >= 0, offset <= text.utf16.count,
                  Range(NSRange(location: offset, length: 0), in: text) != nil,
                  let position = position(from: beginningOfDocument, offset: offset) else { continue }
            let rect = caretRect(for: position), color = [UIColor.systemBlue, .systemGreen, .systemPurple, .systemOrange][index % 4]
            guard rect.minX.isFinite, rect.minY.isFinite else { continue }
            let marker = UIView(frame: CGRect(x: rect.minX, y: rect.minY, width: 2, height: max(18, rect.height))); marker.backgroundColor = color; marker.isUserInteractionEnabled = false
            let name = UILabel(); name.text = peer.name; name.font = .systemFont(ofSize: 9, weight: .medium); name.textColor = .white; name.backgroundColor = color; name.layer.cornerRadius = 3; name.clipsToBounds = true; name.sizeToFit()
            name.frame = CGRect(x: min(rect.minX, max(0, bounds.width - name.bounds.width - 8)), y: rect.maxY, width: name.bounds.width + 8, height: 15); name.isUserInteractionEnabled = false
            marker.accessibilityLabel = "\(peer.name) is editing here"; addSubview(marker); addSubview(name); peerMarkers += [marker, name]
        }
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(finish))]
    }
    @objc private func finish() { finishEditing?() }
    override func deleteBackward() {
        if isEditable, markedTextRange == nil, selectedRange == NSRange(location: 0, length: 0), let mergeAtStart { mergeAtStart(); return }
        super.deleteBackward()
    }
    func setScriptStyle(size: CGFloat, direction: Bool) {
        backgroundColor = .clear; isScrollEnabled = false
        textContainerInset = .zero; textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true; textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        let base = UIFont.systemFont(ofSize: size)
        font = direction ? UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitItalic) ?? base.fontDescriptor, size: size) : base
        autocorrectionType = .yes; smartQuotesType = .no; smartDashesType = .no; smartInsertDeleteType = .no
        setContentCompressionResistancePriority(.required, for: .vertical)
        accessibilityLabel = direction ? "Direction text" : "Dialogue text"
    }
}

@MainActor
final class ScriptEntryRow: UIView, UITextViewDelegate, UIContextMenuInteractionDelegate {
    let entryID: String
    let durationButton = UIButton(type: .system)
    let timestamp = ScrivUIKitTheme.label("", size: 12, color: ScrivUIKitTheme.secondary, lines: 1)
    let speakerButton = UIButton(type: .system)
    let speakerMenuButton = UIButton(type: .system)
    let display = ScriptTextView()
    let editor = ScriptTextView()
    let details = ScrivUIKitTheme.stack([], spacing: 8)
    let textStack = ScrivUIKitTheme.stack([], spacing: 7)
    let root: UIStackView
    var onSelect: (() -> Void)?
    var onEdit: ((Int) -> Void)?
    var onSplit: ((Int) -> Void)?
    var onDuration: (() -> Void)?
    var onCharacter: ((String) -> Void)?
    var onTextEdit: ((CharacterTextEdit) -> Bool)?
    var onTextChange: ((String) -> Bool)?
    var onSelection: ((NSRange) -> Void)?
    var menuProvider: (() -> UIMenu)?
    private var settingText = false
    private var editing = false
    private var lastEntry: ScriptEntry?

    init(entryID: String) {
        self.entryID = entryID
        let gutter = ScrivUIKitTheme.stack([durationButton, timestamp], spacing: 5)
        gutter.alignment = .center
        root = ScrivUIKitTheme.stack([gutter, UIView(), textStack], axis: .horizontal, spacing: 0)
        super.init(frame: .zero)
        root.alignment = .top
        gutter.widthAnchor.constraint(equalToConstant: 80).isActive = true
        root.arrangedSubviews[1].widthAnchor.constraint(equalToConstant: 78).isActive = true
        let speaker = ScrivUIKitTheme.stack([speakerButton, speakerMenuButton, UIView()], axis: .horizontal, spacing: 6)
        speaker.alignment = .center
        speakerMenuButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        speakerMenuButton.accessibilityLabel = "Change speaker"
        speakerMenuButton.showsMenuAsPrimaryAction = true
        speakerMenuButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        speakerButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        speakerButton.contentEdgeInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        speakerButton.layer.cornerRadius = 5
        textStack.addArrangedSubview(speaker); textStack.addArrangedSubview(display); textStack.addArrangedSubview(editor); textStack.addArrangedSubview(details)
        addSubview(root)
        root.scrivPinEdges(to: self, insets: NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 10))
        display.delegate = self; editor.delegate = self
        display.isEditable = false; display.isSelectable = true; display.dataDetectorTypes = []
        editor.isHidden = true; editor.isEditable = true
        editor.accessibilityIdentifier = "script-editor-" + entryID
        display.accessibilityIdentifier = "script-line-" + entryID
        durationButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        durationButton.backgroundColor = ScrivUIKitTheme.inset; durationButton.layer.cornerRadius = 13
        durationButton.contentEdgeInsets = UIEdgeInsets(top: 5, left: 11, bottom: 5, right: 11)
        durationButton.addAction(UIAction { [weak self] _ in self?.onDuration?() }, for: .touchUpInside)
        durationButton.accessibilityLabel = "Edit owned duration"
        timestamp.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let tap = UITapGestureRecognizer(target: self, action: #selector(editRequested(_:)))
        tap.cancelsTouchesInView = true
        display.addGestureRecognizer(tap)
        addInteraction(UIContextMenuInteraction(delegate: self))
        layer.cornerRadius = 10
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @objc private func editRequested(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: display)
        let raw = display.closestPosition(to: point).map { display.offset(from: display.beginningOfDocument, to: $0) } ?? 0
        onEdit?(min(lastEntry?.text.utf16.count ?? 0, max(0, raw)))
    }
    func configure(entry: ScriptEntry, project: ScrivProject, selected: Bool, active: Bool, search: String, currentWordID: String?, peers: [PresencePeer], locked: Bool, speakerMenu: UIMenu, fontSize: CGFloat) {
        lastEntry = entry
        durationButton.setTitle(ScrivFormat.duration(entry.ownedDurationMs), for: .normal); durationButton.isEnabled = !locked
        timestamp.text = ScrivFormat.time(project.startMs(of: entry.id))
        let direction = entry.kind == .direction
        let color = direction ? ScrivUIKitTheme.color(entry.color) : ScrivUIKitTheme.ink
        let character = project.character(entry.characterId)
        let ordered = project.entries(in: entry.sceneId)
        let previous = ordered.firstIndex(where: { $0.id == entry.id }).flatMap { index in ordered[..<index].last { $0.ownedDurationMs > 0 } }
        let continued = entry.characterId != nil && previous?.kind == .dialogue && previous?.characterId == entry.characterId
        let name = (character?.name.uppercased() ?? "DIALOGUE") + (continued ? " (CONT’D)" : "")
        speakerButton.setTitle(name, for: .normal)
        let speakerColor = character.map { ScrivUIKitTheme.color($0.color) } ?? ScrivUIKitTheme.secondary
        speakerButton.setTitleColor(speakerColor, for: .normal); speakerButton.backgroundColor = speakerColor.withAlphaComponent(0.12)
        speakerButton.removeAction(identifiedBy: UIAction.Identifier("speaker"), for: .touchUpInside)
        speakerButton.addAction(UIAction(identifier: UIAction.Identifier("speaker")) { [weak self] _ in if let id = character?.id { self?.onCharacter?(id) } }, for: .touchUpInside)
        textStack.arrangedSubviews[0].isHidden = direction
        speakerMenuButton.isHidden = !selected; speakerMenuButton.menu = speakerMenu; speakerMenuButton.isEnabled = !locked
        display.setScriptStyle(size: fontSize, direction: direction); editor.setScriptStyle(size: fontSize, direction: direction)
        speakerButton.titleLabel?.font = .systemFont(ofSize: max(11, fontSize * 0.8), weight: .semibold)
        durationButton.titleLabel?.font = .systemFont(ofSize: max(11, fontSize * 0.7), weight: .semibold)
        timestamp.font = .monospacedDigitSystemFont(ofSize: max(10, fontSize * 0.6), weight: .regular)
        editor.textColor = color; display.linkTextAttributes = [.foregroundColor: ScrivUIKitTheme.accent]
        let value = ScriptAttributedText.make(entry: entry, project: project, font: display.font ?? .systemFont(ofSize: fontSize), color: color, currentWordID: currentWordID, peers: peers)
        if display.attributedText != value { display.attributedText = value; display.invalidateIntrinsicContentSize() }
        display.presencePeers = peers
        let matched = !search.isEmpty && (entry.text.localizedCaseInsensitiveContains(search) || character.map { ([$0.name] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(search) } } == true)
        backgroundColor = active ? ScrivUIKitTheme.accent.withAlphaComponent(0.08) : selected ? ScrivUIKitTheme.accent.withAlphaComponent(0.055) : matched ? UIColor.systemYellow.withAlphaComponent(0.12) : .clear
    }
    func setEditing(_ value: Bool, text: String, focus: Bool, caret: Int? = nil) {
        let changed = editing != value; editing = value
        display.isHidden = value; editor.isHidden = !value
        if value && !editor.text.utf16.elementsEqual(text.utf16), editor.markedTextRange == nil {
            let selected = editor.selectedRange
            settingText = true
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3; paragraph.lineBreakMode = .byWordWrapping
            editor.attributedText = NSAttributedString(string: text, attributes: [.font: editor.font ?? UIFont.systemFont(ofSize: 14), .foregroundColor: editor.textColor ?? ScrivUIKitTheme.ink, .paragraphStyle: paragraph])
            settingText = false
            editor.selectedRange = NSRange(location: min(selected.location, text.utf16.count), length: 0)
            editor.invalidateIntrinsicContentSize()
        }
        if value && focus && (changed || caret != nil) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.editing, self.window != nil else { return }
                self.editor.becomeFirstResponder()
                let offset = min(self.editor.text.utf16.count, max(0, caret ?? self.editor.text.utf16.count))
                if Range(NSRange(location: offset, length: 0), in: self.editor.text) != nil { self.editor.selectedRange = NSRange(location: offset, length: 0) }
            }
        } else if !value && editor.isFirstResponder { editor.resignFirstResponder() }
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard textView === editor, !settingText else { return true }
        if (text == "\n" || text == "\r"), editor.markedTextRange == nil, let onSplit {
            // Return changes a boundary, not source characters. A selection is
            // preserved on the new line rather than silently deleted.
            onSplit(range.location); return false
        }
        return onTextEdit?(CharacterTextEdit(range: range, replacement: text)) ?? false
    }
    func textViewDidChange(_ textView: UITextView) {
        guard textView === editor, !settingText else { return }
        _ = onTextChange?(textView.text)
        textView.invalidateIntrinsicContentSize(); editor.sizeChanged?()
    }
    func textViewDidChangeSelection(_ textView: UITextView) {
        if textView === editor, !settingText { onSelection?(textView.selectedRange) }
    }
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        if URL.scheme == "scriv-character", interaction != .invokeDefaultAction { onCharacter?(URL.lastPathComponent); return false }
        return false
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: entryID as NSString, previewProvider: nil) { [weak self] _ in self?.menuProvider?() }
    }
}

enum ScriptAttributedText {
    static func make(entry: ScriptEntry, project: ScrivProject, font: UIFont, color: UIColor, currentWordID: String?, peers: [PresencePeer]) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3; paragraph.lineBreakMode = .byWordWrapping
        let value = NSMutableAttributedString(string: entry.text.isEmpty ? (entry.kind == .direction ? "Describe the action…" : "Write dialogue…") : entry.text,
                                              attributes: [.font: font, .foregroundColor: entry.text.isEmpty ? ScrivUIKitTheme.secondary : color, .paragraphStyle: paragraph])
        guard !entry.text.isEmpty else { return value }
        let links = entry.characterLinks ?? CharacterMentions.suggestions(in: entry.text, characters: project.characters)
        for link in links where !link.isConfirmed && CharacterMentions.matchesSource(link, in: entry.text) {
            value.addAttribute(.backgroundColor, value: UIColor.systemOrange.withAlphaComponent(0.09), range: link.range)
        }
        for mention in CharacterMentions.resolved(in: entry.text, links: links) {
            guard let character = project.character(mention.characterId), let url = URL(string: "scriv-character://open/" + character.id), Range(mention.range, in: entry.text) != nil else { continue }
            value.addAttributes([.link: url, .foregroundColor: ScrivUIKitTheme.accent, .backgroundColor: ScrivUIKitTheme.color(character.color).withAlphaComponent(0.13)], range: mention.range)
        }
        for peer in peers {
            guard let lower = peer.selection?["start"]?.int, let upper = peer.selection?["end"]?.int, lower >= 0, upper > lower, upper <= entry.text.utf16.count else { continue }
            let range = NSRange(location: lower, length: upper - lower)
            guard Range(range, in: entry.text) != nil else { continue }
            value.addAttribute(.backgroundColor, value: ScrivUIKitTheme.accent.withAlphaComponent(0.14), range: range)
        }
        if let index = entry.words.firstIndex(where: { $0.id == currentWordID }), let regex = try? NSRegularExpression(pattern: "\\S+") {
            let words = regex.matches(in: entry.text, range: NSRange(location: 0, length: entry.text.utf16.count))
            if words.indices.contains(index) { value.addAttributes([.backgroundColor: ScrivUIKitTheme.accent, .foregroundColor: UIColor.white], range: words[index].range) }
        }
        return value
    }
}
