import UIKit

/// UIKit-only rendering primitives for the owner-approved Scriv screens.
/// Domain state and actions live in WorkspaceStore, never in these factories.
enum ScrivUIKitTheme {
    static let accent = UIColor(red: 0.02, green: 0.36, blue: 0.98, alpha: 1)
    static let ink = UIColor.label
    static let secondary = UIColor.secondaryLabel
    static let hairline = UIColor.separator.withAlphaComponent(0.45)
    static let canvas = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 1)
            : UIColor(red: 0.91, green: 0.95, blue: 0.98, alpha: 1)
    }
    static let panel = UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemBackground : UIColor(white: 0.998, alpha: 1) }
    static let inset = UIColor { $0.userInterfaceStyle == .dark ? .tertiarySystemBackground : UIColor(red: 0.935, green: 0.950, blue: 0.975, alpha: 1) }
    static let chrome = UIColor { $0.userInterfaceStyle == .dark ? .systemBackground : UIColor(red: 0.90, green: 0.95, blue: 0.985, alpha: 1) }
    static func color(_ hex: String) -> UIColor {
        let names = ["blue": "1768E8", "purple": "A350EA", "coral": "F47A63", "teal": "16B9B7", "orange": "E6A33A", "green": "24A878", "pink": "DD6DB3"]
        let raw = (names[hex.lowercased()] ?? hex).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let value = UInt64(raw, radix: 16), raw.count == 6 else { return accent }
        return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 9

    static func label(_ text: String, size: CGFloat = 13, weight: UIFont.Weight = .regular,
                      color: UIColor = .label, lines: Int = 0) -> UILabel {
        let view = UILabel()
        view.text = text; view.font = .systemFont(ofSize: size, weight: weight)
        view.textColor = color; view.numberOfLines = lines; view.lineBreakMode = .byWordWrapping
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }
    static func stack(_ views: [UIView] = [], axis: NSLayoutConstraint.Axis = .vertical, spacing: CGFloat = 12) -> UIStackView {
        let view = UIStackView(arrangedSubviews: views)
        view.axis = axis; view.spacing = spacing; view.alignment = .fill
        return view
    }
    static func button(_ title: String, symbol: String? = nil, primary: Bool = false,
                       action: @escaping () -> Void) -> UIButton {
        var configuration: UIButton.Configuration = primary ? .filled() : .tinted()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 7
        configuration.baseBackgroundColor = primary ? accent : inset
        configuration.baseForegroundColor = primary ? .white : ink
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = controlRadius
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 15, bottom: 10, trailing: 15)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        button.accessibilityLabel = title
        return button
    }
    static func card(_ content: UIView, padding: CGFloat = 16) -> UIView {
        let view = UIView(); view.backgroundColor = panel
        view.layer.cornerRadius = cardRadius; view.layer.borderWidth = 0.5
        view.layer.borderColor = hairline.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding)
        ])
        return view
    }
    static func notice(_ title: String, message: String, warning: Bool = false) -> UIView {
        let tint: UIColor = warning ? .systemOrange : accent
        let icon = UIImageView(image: UIImage(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle"))
        icon.tintColor = tint; icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let text = stack([label(title, weight: .semibold), label(message, size: 12, color: secondary)], spacing: 4)
        let row = stack([icon, text], axis: .horizontal, spacing: 10); row.alignment = .top
        let view = card(row, padding: 14); view.backgroundColor = tint.withAlphaComponent(0.08)
        return view
    }
}

extension UIView {
    func scrivPinEdges(to container: UIView, insets: NSDirectionalEdgeInsets = .zero) {
        if superview !== container { container.addSubview(self) }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.leading),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.trailing),
            topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom)
        ])
    }
}
