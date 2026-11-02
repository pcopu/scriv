import UIKit
import ScrivCore

@MainActor enum ImageUI {
    static var accent: UIColor { ScrivUIKitTheme.accent }
    static func label(_ text: String = "", size: CGFloat = 13, weight: UIFont.Weight = .regular, secondary: Bool = false) -> UILabel {
        let view = UILabel(); view.text = text; view.numberOfLines = 0
        view.font = .systemFont(ofSize: size, weight: weight); view.textColor = secondary ? ScrivUIKitTheme.secondary : ScrivUIKitTheme.ink
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }
    static func text(_ text: String, size: CGFloat = 13) -> UITextView {
        let view = UITextView(); view.text = text; view.font = .systemFont(ofSize: size); view.textColor = ScrivUIKitTheme.ink
        view.backgroundColor = .clear; view.isEditable = false; view.isScrollEnabled = false
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }
    static func button(_ title: String, symbol: String? = nil, primary: Bool = false, action: @escaping () -> Void) -> UIButton {
        var config = primary ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        config.title = title; config.titleLineBreakMode = .byTruncatingTail; config.cornerStyle = .fixed
        config.baseBackgroundColor = primary ? accent : ScrivUIKitTheme.panel
        config.baseForegroundColor = primary ? .white : ScrivUIKitTheme.ink
        config.background.backgroundColor = primary ? accent : ScrivUIKitTheme.panel
        config.background.cornerRadius = 8
        config.background.strokeColor = primary ? .clear : ScrivUIKitTheme.hairline
        config.background.strokeWidth = primary ? 0 : 0.75
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming; outgoing.font = UIFont.systemFont(ofSize: 13, weight: .medium); return outgoing
        }
        if let symbol { config.image = UIImage(systemName: symbol); config.imagePadding = 7; config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium) }
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = title; button.titleLabel?.numberOfLines = 1
        button.setContentCompressionResistancePriority(UILayoutPriority(751), for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        return button
    }
    static func stack(_ views: [UIView] = [], axis: NSLayoutConstraint.Axis = .vertical, spacing: CGFloat = 12) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views); stack.axis = axis; stack.spacing = spacing; stack.alignment = .fill
        return stack
    }
    static func row(_ views: [UIView], spacing: CGFloat = 10) -> UIStackView {
        let stack = self.stack(views, axis: .horizontal, spacing: spacing); stack.alignment = .center; return stack
    }
    static func spacer() -> UIView { let view = UIView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view }
    static func divider() -> UIView { let line = UIView(); line.backgroundColor = ScrivUIKitTheme.hairline; line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true; return line }
    static func card(_ content: UIView, padding: CGFloat = 14) -> UIView {
        let card = UIView(); card.backgroundColor = ScrivUIKitTheme.panel; card.layer.cornerRadius = 12
        card.layer.borderColor = ScrivUIKitTheme.hairline.cgColor; card.layer.borderWidth = 0.5
        content.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: padding), content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -padding), content.topAnchor.constraint(equalTo: card.topAnchor, constant: padding), content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -padding)])
        return card
    }
    static func notice(_ message: String, warning: Bool = false) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")); icon.tintColor = warning ? .systemOrange : accent
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true; icon.contentMode = .scaleAspectFit
        let row = row([icon, label(message, size: 12)], spacing: 10); row.alignment = .top
        let result = card(row); result.backgroundColor = (warning ? UIColor.systemOrange : accent).withAlphaComponent(0.08); return result
    }
    static func badge(_ text: String) -> UIView {
        let label = self.label(text, size: 12, weight: .medium, secondary: true)
        let result = card(label, padding: 6); result.backgroundColor = ScrivUIKitTheme.inset; result.layer.cornerRadius = 8
        return result
    }
    static func tag(_ name: String, color: UIColor, compact: Bool = false) -> UIView {
        let dot = UIView(); dot.backgroundColor = color; dot.layer.cornerRadius = compact ? 4 : 5
        dot.widthAnchor.constraint(equalToConstant: compact ? 8 : 10).isActive = true
        dot.heightAnchor.constraint(equalTo: dot.widthAnchor).isActive = true
        let body = row([dot, label(name, size: compact ? 12 : 15)], spacing: 7)
        let result = card(body, padding: compact ? 5 : 7); result.backgroundColor = ScrivUIKitTheme.inset.withAlphaComponent(0.5); result.layer.cornerRadius = 9
        result.isAccessibilityElement = true; result.accessibilityLabel = name
        return result
    }
    static func heading(_ title: String, badge: String? = nil, close: (() -> Void)? = nil) -> UIView {
        var views: [UIView] = [label(title, size: 23, weight: .semibold)]
        if let badge { views.append(self.badge(badge)) }
        views.append(spacer())
        if let close { views.append(button("Done", primary: true, action: close)) }
        return row(views, spacing: 12)
    }
    static func compact(_ button: UIButton) {
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming; outgoing.font = UIFont.systemFont(ofSize: 11, weight: .medium); return outgoing
        }
    }
    static func scrollStack(in controller: UIViewController, spacing: CGFloat = 16, padding: CGFloat = 22) -> UIStackView {
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.keyboardDismissMode = .interactive
        controller.view.addSubview(scroll)
        let stack = self.stack(spacing: spacing); stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: padding), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: padding), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -padding),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * padding)
        ]); return stack
    }
    static func pinToSafeArea(_ content: UIView, in controller: UIViewController, insets: NSDirectionalEdgeInsets = .zero) {
        content.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(content)
        let guide = controller.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: insets.leading), content.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -insets.trailing), content.topAnchor.constraint(equalTo: guide.topAnchor, constant: insets.top), content.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -insets.bottom)])
    }
    static func guardedAction(_ title: String, store: WorkspaceStore, context: Int, handler: @escaping () -> Void) -> UIAction {
        UIAction(title: title) { _ in
            guard store.navigationContext == context else { store.errorMessage = "The project changed while this action was open. Reopen the action in the current project."; return }
            handler()
        }
    }
    static func clear(_ stack: UIStackView) { stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() } }
    static func scriptFont(_ button: UIButton, size: CGFloat) {
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming; outgoing.font = UIFont.systemFont(ofSize: size); return outgoing
        }
        button.titleLabel?.font = .systemFont(ofSize: size)
    }
    static func field(_ value: String = "", placeholder: String? = nil) -> UITextField {
        let field = UITextField(); field.text = value; field.placeholder = placeholder; field.borderStyle = .roundedRect
        field.font = .systemFont(ofSize: 14); field.textColor = ScrivUIKitTheme.ink; field.backgroundColor = ScrivUIKitTheme.panel; field.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        return field
    }
    static func present(_ controller: UIViewController, from parent: UIViewController, size: CGSize = CGSize(width: 720, height: 720)) {
        let navigation = UINavigationController(rootViewController: controller); navigation.modalPresentationStyle = .formSheet
        navigation.preferredContentSize = size; controller.preferredContentSize = size
        ScrivSheetFitting.fit(navigation, presentedFrom: parent); parent.present(navigation, animated: true)
    }
    static func closeButton(_ controller: UIViewController, title: String = "Done") {
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(title: title, primaryAction: UIAction { [weak controller] _ in controller?.dismiss(animated: true) })
    }
    static func alert(_ title: String, message: String, from controller: UIViewController) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); controller.present(alert, animated: true)
    }
    static func confirm(_ title: String, message: String, destructiveTitle: String, from controller: UIViewController, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: destructiveTitle, style: .destructive) { _ in action() }); controller.present(alert, animated: true)
    }
    static func color(_ name: String) -> UIColor { ScrivUIKitTheme.color(name) }
}


/// Content-sized chips wrap rather than squeezing names or making a vertical
/// form out of the image's compact metadata strip.
@MainActor final class ImageTagFlowView: UIView {
    private var measuredHeight: CGFloat = 0
    var spacing: CGFloat = 7
    init(_ items: [UIView]) { super.init(frame: .zero); items.forEach(addSubview) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(items:)") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: arrange(width: max(1, bounds.width > 0 ? bounds.width : 400), apply: false)) }
    override func layoutSubviews() {
        super.layoutSubviews(); let height = arrange(width: max(1, bounds.width), apply: true)
        if abs(height - measuredHeight) > 0.5 { measuredHeight = height; invalidateIntrinsicContentSize() }
    }
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for item in subviews {
            let fitted = item.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .fittingSizeLevel, verticalFittingPriority: .fittingSizeLevel)
            let itemWidth = min(width, ceil(fitted.width))
            let constrained = item.systemLayoutSizeFitting(CGSize(width: itemWidth, height: UIView.layoutFittingCompressedSize.height), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            let size = CGSize(width: itemWidth, height: max(27, ceil(constrained.height)))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            if apply { item.frame = CGRect(origin: CGPoint(x: x, y: y), size: size) }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight
    }
}
