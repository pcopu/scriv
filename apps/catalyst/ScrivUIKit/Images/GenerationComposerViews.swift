import UIKit

/// A genuine empty editable field, not placeholder text persisted as direction.
@MainActor final class GenerationDirectionTextView: UITextView {
    let placeholderLabel = ImageUI.label("For example, a wider shot in soft light", size: 17, secondary: true)
    override var text: String! { didSet { updatePlaceholder() } }
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        font = .systemFont(ofSize: 17); textColor = ScrivUIKitTheme.ink
        backgroundColor = ScrivUIKitTheme.panel; layer.cornerRadius = 8
        layer.borderWidth = 0.75; layer.borderColor = ScrivUIKitTheme.hairline.cgColor
        textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        placeholderLabel.isUserInteractionEnabled = false; placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            placeholderLabel.widthAnchor.constraint(equalTo: widthAnchor, constant: -26)
        ])
        accessibilityLabel = "Image direction, optional, for this picture only"
        accessibilityHint = "Leave blank to follow the script. Clearing removes only this picture’s visual override."
        updatePlaceholder()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(frame:textContainer:)") }
    func updatePlaceholder() { placeholderLabel.isHidden = !(text ?? "").isEmpty }
}

/// Resize in place: preserve the text responder and whole command titles.
@MainActor final class GenerationComposerActionRow: UIStackView {
    private let flexibleSpace = ImageUI.spacer()
    init(review: UIButton, generate: UIButton) {
        super.init(frame: .zero); axis = .horizontal; alignment = .center; spacing = 10
        [review, flexibleSpace, generate].forEach(addArrangedSubview)
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError("Use init(review:generate:)") }
    override func layoutSubviews() {
        let vertical = bounds.width > 0 && bounds.width < 350
        let next: NSLayoutConstraint.Axis = vertical ? .vertical : .horizontal
        if axis != next { axis = next; alignment = vertical ? .fill : .center; flexibleSpace.isHidden = vertical }
        super.layoutSubviews()
    }
}

@MainActor final class PreviewLayersDisclosureView: UIView {
    let button: UIButton
    private let duration = ImageUI.label(size: 15, secondary: true)
    init(action: @escaping () -> Void) {
        button = GenerationReviewUI.button("Layers", symbol: "chevron.right", action: action)
        super.init(frame: .zero)
        button.configuration?.background.strokeWidth = 0
        button.configuration?.background.backgroundColor = .clear
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = "preview-layers-disclosure"
        let row = ImageUI.row([button, ImageUI.spacer(), duration], spacing: 10)
        addSubview(row); row.scrivPinEdges(to: self, insets: .init(top: 0, leading: 2, bottom: 0, trailing: 12))
        backgroundColor = ScrivUIKitTheme.inset.withAlphaComponent(0.45)
        layer.cornerRadius = 9; layer.borderWidth = 0.5; layer.borderColor = ScrivUIKitTheme.hairline.cgColor
        update(expanded: false, duration: "")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(action:)") }
    func update(expanded: Bool, duration: String) {
        button.configuration?.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.right")
        button.accessibilityLabel = expanded ? "Collapse Layers" : "Expand Layers"
        button.accessibilityValue = expanded ? "Expanded" : "Collapsed"
        self.duration.text = duration
    }
}
