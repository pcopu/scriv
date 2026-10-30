import UIKit
import ScrivCore

/// UIKit-only controls shared by the character and team forms. The controls do
/// not own canonical state: edits are applied through WorkspaceStore on action.
@MainActor
enum CharacterTeamUI {
    static func button(_ title: String, symbol: String? = nil, primary: Bool = false, size: CGFloat = 15, action: @escaping () -> Void) -> UIButton {
        let button = ScrivUIKitTheme.button(title, symbol: symbol, primary: primary, action: action)
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes; result.font = .systemFont(ofSize: size, weight: .medium); return result
        }
        return button
    }
    static func field(_ placeholder: String, value: String = "") -> UITextField {
        let field = UITextField(); field.placeholder = placeholder; field.text = value
        field.font = .systemFont(ofSize: 18); field.textColor = ScrivUIKitTheme.ink
        field.backgroundColor = ScrivUIKitTheme.panel; field.layer.cornerRadius = 9
        field.layer.borderColor = ScrivUIKitTheme.hairline.cgColor; field.layer.borderWidth = 1
        let padding = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        field.leftView = padding; field.leftViewMode = .always
        field.rightView = UIView(frame: padding.frame); field.rightViewMode = .always
        field.heightAnchor.constraint(equalToConstant: 46).isActive = true
        field.clearButtonMode = .whileEditing; field.accessibilityLabel = placeholder
        return field
    }
    static func notes(_ value: String, title: String) -> UITextView {
        let view = UITextView(); view.text = value; view.font = .systemFont(ofSize: 18)
        view.textColor = ScrivUIKitTheme.ink; view.backgroundColor = ScrivUIKitTheme.panel
        view.layer.cornerRadius = 9; view.layer.borderWidth = 1; view.layer.borderColor = ScrivUIKitTheme.hairline.cgColor
        view.textContainerInset = UIEdgeInsets(top: 11, left: 11, bottom: 11, right: 11)
        view.heightAnchor.constraint(equalToConstant: 108).isActive = true
        view.accessibilityLabel = title; return view
    }
    static func labeled(_ title: String, _ field: UIView) -> UIStackView {
        ScrivUIKitTheme.stack([ScrivUIKitTheme.label(title, size: 15, weight: .medium, color: ScrivUIKitTheme.secondary), field], spacing: 8)
    }
    static func separator() -> UIView {
        let view = UIView(); view.backgroundColor = ScrivUIKitTheme.hairline
        view.heightAnchor.constraint(equalToConstant: 0.5).isActive = true; return view
    }
    static func spacer() -> UIView {
        let view = UIView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); return view
    }
    static func row(_ views: [UIView], spacing: CGFloat = 12) -> UIStackView {
        let stack = ScrivUIKitTheme.stack(views, axis: .horizontal, spacing: spacing); stack.alignment = .center; return stack
    }
    static func clear(_ stack: UIStackView) { stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() } }
    static func menu(_ title: String, actions: [UIAction]) -> UIButton {
        let view = button(title, symbol: "chevron.down") {}
        view.menu = UIMenu(children: actions); view.showsMenuAsPrimaryAction = true; return view
    }
    static func symbol(_ name: String, color: UIColor = ScrivUIKitTheme.secondary, size: CGFloat = 21) -> UIImageView {
        let view = UIImageView(image: UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size)))
        view.contentMode = .scaleAspectFit; view.tintColor = color
        view.widthAnchor.constraint(equalToConstant: size + 2).isActive = true
        view.heightAnchor.constraint(equalToConstant: size + 2).isActive = true; return view
    }
    static func error(_ message: String, in controller: UIViewController) {
        let alert = UIAlertController(title: "This change needs attention", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); controller.present(alert, animated: true)
    }
    static func present(_ child: UIViewController, from controller: UIViewController, width: CGFloat = 710, height: CGFloat = 820) {
        child.preferredContentSize = CGSize(width: width, height: height); child.modalPresentationStyle = .formSheet
        controller.present(child, animated: true)
    }
    static func portrait(_ character: ScriptCharacter, store: WorkspaceStore, size: CGSize, circular: Bool = false) -> UIView {
        let asset = store.project.asset(character.portraitImageId) ?? store.project.images.first { $0.characterIds.contains(character.id) }
        let view = UIKitAssetImageView()
        view.configure(url: asset.flatMap { store.assetURL($0) }, title: character.name, fill: true, missingText: "No portrait on this device")
        view.backgroundColor = ScrivUIKitTheme.color(character.color).withAlphaComponent(0.12)
        view.layer.cornerRadius = circular ? size.width / 2 : 10; view.clipsToBounds = true
        view.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        view.accessibilityLabel = "Portrait of \(character.name.isEmpty ? "new character" : character.name)"
        return view
    }
}

@MainActor
final class CharacterTeamSheetLayout: UIView {
    let header: UIStackView
    let heading: UILabel
    let subtitle = ScrivUIKitTheme.label("", size: 17, color: ScrivUIKitTheme.secondary)
    let scroll = UIScrollView()
    let content = ScrivUIKitTheme.stack(spacing: 23)
    let footer = CharacterTeamUI.row([CharacterTeamUI.spacer()], spacing: 14)
    let close: UIButton
    init(title: String, onClose: @escaping () -> Void) {
        heading = ScrivUIKitTheme.label(title, size: 25, weight: .semibold)
        close = CharacterTeamUI.button("", symbol: "xmark", action: onClose)
        close.accessibilityLabel = "Close \(title)"
        header = CharacterTeamUI.row([ScrivUIKitTheme.stack([heading, subtitle], spacing: 8), CharacterTeamUI.spacer(), close])
        super.init(frame: .zero)
        backgroundColor = ScrivUIKitTheme.panel; subtitle.isHidden = true
        let topLine = CharacterTeamUI.separator(), bottomLine = CharacterTeamUI.separator()
        [header, topLine, scroll, bottomLine, footer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        content.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(content)
        scroll.keyboardDismissMode = .interactive
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 27), header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -27),
            topLine.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16), topLine.leadingAnchor.constraint(equalTo: leadingAnchor), topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topLine.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 22), content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -22),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 27), content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -27),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -54),
            bottomLine.topAnchor.constraint(equalTo: scroll.bottomAnchor), bottomLine.leadingAnchor.constraint(equalTo: leadingAnchor), bottomLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.topAnchor.constraint(equalTo: bottomLine.bottomAnchor, constant: 13), footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 27), footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -27),
            footer.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor, constant: -13)
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(title:onClose:)") }
}

/// Alias and tag chips wrap without turning long names into a horizontally
/// clipped pseudo-grid. UIKit keeps each real button keyboard/accessibility reachable.
@MainActor
final class CharacterChipWrapView: UIView {
    var chips: [UIView] = [] { didSet { oldValue.forEach { $0.removeFromSuperview() }; chips.forEach(addSubview); invalidateIntrinsicContentSize(); setNeedsLayout() } }
    private var lastWidth: CGFloat = 0
    private func arranged(width: CGFloat, apply: Bool) -> CGFloat {
        let width = max(1, width); var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for chip in chips {
            let measured = chip.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let size = CGSize(width: min(width, max(28, measured.width)), height: max(30, measured.height))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + 8; rowHeight = 0 }
            if apply { chip.frame = CGRect(origin: CGPoint(x: x, y: y), size: size) }
            x += size.width + 8; rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight
    }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: arranged(width: bounds.width > 0 ? bounds.width : 400, apply: false)) }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastWidth { lastWidth = bounds.width; invalidateIntrinsicContentSize() }
        _ = arranged(width: bounds.width, apply: true)
    }
}
