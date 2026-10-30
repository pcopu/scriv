import UIKit
import ScrivCore

/// UIKit-only surfaces shared by account, settings and local generation recovery.
@MainActor
enum AccountUI {
    static let accent = UIColor(red: 0.02, green: 0.36, blue: 0.98, alpha: 1)
    static let panel = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.15, blue: 0.19, alpha: 1) : .white }
    static let inset = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.18, green: 0.22, blue: 0.28, alpha: 1) : UIColor(red: 0.94, green: 0.96, blue: 0.985, alpha: 1) }
    static func label(_ text: String, size: CGFloat = 14, weight: UIFont.Weight = .regular, color: UIColor = .label, centered: Bool = false) -> UILabel {
        let label = UILabel(); label.text = text; label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color; label.numberOfLines = 0; label.textAlignment = centered ? .center : .left
        label.setContentCompressionResistancePriority(.required, for: .vertical); return label
    }
    static func stack(_ views: [UIView] = [], spacing: CGFloat = 12, horizontal: Bool = false) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views); stack.axis = horizontal ? .horizontal : .vertical
        stack.spacing = spacing; stack.alignment = horizontal ? .center : .fill; return stack
    }
    static func button(_ title: String, symbol: String? = nil, primary: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> UIButton {
        var configuration = primary ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        configuration.title = title; configuration.baseBackgroundColor = primary ? accent : inset
        configuration.baseForegroundColor = primary ? .white : destructive ? .systemRed : accent
        configuration.cornerStyle = .medium; configuration.contentInsets = .init(top: 10, leading: 14, bottom: 10, trailing: 14)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in var result = attributes; result.font = UIFont.systemFont(ofSize: 14, weight: .medium); return result }
        if let symbol { configuration.image = UIImage(systemName: symbol); configuration.imagePadding = 8 }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = title; button.titleLabel?.numberOfLines = 0; return button
    }
    static func link(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> UIButton {
        let button = self.button(title, symbol: symbol, action: action); button.configuration?.baseBackgroundColor = .clear
        button.contentHorizontalAlignment = .leading; return button
    }
    static func divider() -> UIView { let line = UIView(); line.backgroundColor = .separator; line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true; return line }
    static func card(_ content: UIView, padding: CGFloat = 15, selected: Bool = false, tint: UIColor? = nil) -> UIView {
        let box = UIView(); box.backgroundColor = tint ?? panel; box.layer.cornerRadius = 12; box.layer.borderWidth = selected ? 1.5 : 0.5
        box.layer.borderColor = (selected ? accent : UIColor.separator).cgColor; content.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(content)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo: box.topAnchor, constant: padding), content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -padding), content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: padding), content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -padding)])
        return box
    }
    static func notice(_ text: String, warning: Bool = true) -> UIView {
        card(stack([label(warning ? "Needs attention" : "On this Mac", size: 13, weight: .semibold, color: warning ? .systemOrange : accent), label(text, size: 13)]), tint: (warning ? UIColor.systemOrange : accent).withAlphaComponent(0.09))
    }
    static func field(_ placeholder: String) -> UITextField {
        let field = UITextField(); field.placeholder = placeholder; field.font = .systemFont(ofSize: 16); field.borderStyle = .none
        field.backgroundColor = inset.withAlphaComponent(0.65); field.layer.cornerRadius = 9; field.layer.borderWidth = 1; field.layer.borderColor = UIColor.separator.cgColor
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 13, height: 1)); field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 13, height: 1)); field.rightViewMode = .always
        field.heightAnchor.constraint(equalToConstant: 48).isActive = true; field.autocorrectionType = .no; field.spellCheckingType = .no; return field
    }
    static func avatar(_ name: String, size: CGFloat = 48) -> UIView {
        let label = self.label(String(name.prefix(1)).uppercased(), size: size * 0.42, weight: .medium, color: .white, centered: true)
        label.backgroundColor = accent; label.layer.cornerRadius = size / 2; label.clipsToBounds = true
        NSLayoutConstraint.activate([label.widthAnchor.constraint(equalToConstant: size), label.heightAnchor.constraint(equalToConstant: size)]); return label
    }
    static func symbol(_ name: String, size: CGFloat = 64) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)))
        icon.contentMode = .center; icon.tintColor = .secondaryLabel; icon.backgroundColor = inset; icon.layer.cornerRadius = size / 2
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: size), icon.heightAnchor.constraint(equalToConstant: size)]); return icon
    }
    static func installScroll(in controller: UIViewController, content: UIStackView, padding: CGFloat = 24) -> UIScrollView {
        let scroll = UIScrollView(); scroll.keyboardDismissMode = .interactive; scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(content); controller.view.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor), scroll.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor), content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: padding), content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -padding), content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: padding), content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -padding), content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * padding)])
        return scroll
    }
    static func clear(_ stack: UIStackView) { for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() } }
    static func present(_ screen: UIViewController, from parent: UIViewController, size: CGSize) {
        let navigation = UINavigationController(rootViewController: screen); navigation.modalPresentationStyle = .formSheet; navigation.preferredContentSize = size; screen.preferredContentSize = size
        parent.present(navigation, animated: true)
    }
}
