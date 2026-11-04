import UIKit
import ScrivCore

@MainActor
final class DiscussionFlowView: UIView {
    private var chips: [UIView] = []
    private var measuredWidth: CGFloat = 0
    func addChip(_ view: UIView) { chips.append(view); addSubview(view); invalidateIntrinsicContentSize() }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: arrange(width: max(1, bounds.width), apply: false)) }
    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(measuredWidth - bounds.width) > 0.5 { measuredWidth = bounds.width; invalidateIntrinsicContentSize() }
        _ = arrange(width: max(1, bounds.width), apply: true)
    }
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        for chip in chips {
            let desired = chip.sizeThatFits(CGSize(width: width, height: 100)), size = CGSize(width: min(width, max(20, desired.width)), height: max(22, desired.height))
            if x > 0 && x + size.width > width { x = 0; y += height + 5; height = 0 }
            if apply { chip.frame = CGRect(origin: CGPoint(x: x, y: y), size: size) }
            x += size.width + 5; height = max(height, size.height)
        }
        return y + height
    }
}

@MainActor
final class DiscussionMessageCell: UITableViewCell {
    private let stack = ScrivUIKitTheme.stack([], spacing: 7)
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none; backgroundColor = .clear; contentView.addSubview(stack)
        stack.scrivPinEdges(to: contentView, insets: NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 5, trailing: 0))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func configure(message: DiscussionMessage, store: WorkspaceStore, focused: Bool, reply: @escaping () -> Void, openAttachment: @escaping (String) -> Void) {
        for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
        let mine = message.userId == store.account?.id || message.authorId == store.account?.id
        let name = message.name ?? "Editor"
        let avatar = DiscussionAvatarView(name: name, identity: message.userId ?? message.authorId ?? name, mine: mine)
        let date = message.createdAt == nil && message.at == nil ? "" : message.timestamp.formatted(date: .omitted, time: .shortened)
        let header = ScrivUIKitTheme.stack([ScrivUIKitTheme.label(mine ? "You" : name, size: 16, weight: .semibold, color: ScrivUIKitTheme.ink, lines: 1), UIView(), ScrivUIKitTheme.label(date, size: 12, color: ScrivUIKitTheme.secondary)], axis: .horizontal, spacing: 6)
        let column = ScrivUIKitTheme.stack([header], spacing: 6)
        if let replyID = message.replyToId {
            let original = store.messages.first { $0.id == replyID }
            let quote = ScrivUIKitTheme.label(original?.body ?? "Reply to an earlier message", size: 12, color: ScrivUIKitTheme.secondary, lines: 2)
            let line = UIView(); line.backgroundColor = ScrivUIKitTheme.hairline; line.widthAnchor.constraint(equalToConstant: 2).isActive = true
            column.addArrangedSubview(ScrivUIKitTheme.stack([line, quote], axis: .horizontal, spacing: 8))
        }
        if !message.mentionedUserIds.isEmpty {
            let flow = DiscussionFlowView()
            for id in Array(Set(message.mentionedUserIds)).sorted() {
                let text = id == store.account?.id ? "@You" : "@" + store.discussionMemberName(id)
                let chip = ScrivUIKitTheme.label(text, size: 12, weight: .medium, color: id == store.account?.id ? .white : ScrivUIKitTheme.accent, lines: 1)
                chip.backgroundColor = id == store.account?.id ? ScrivUIKitTheme.accent : ScrivUIKitTheme.inset; chip.layer.cornerRadius = 5; chip.clipsToBounds = true
                chip.accessibilityLabel = id == store.account?.id ? "You were mentioned" : "Mentioned " + store.discussionMemberName(id); flow.addChip(chip)
            }
            column.addArrangedSubview(flow)
        }
        let body = DiscussionReadOnlyTextView()
        body.text = message.body; column.addArrangedSubview(body)
        for attachment in message.attachments ?? [] {
            if let image = UIKitDiscussionPresentation.attachmentImage(attachment, project: store.project) {
                let thumbnail = UIKitAssetImageView(); thumbnail.configure(url: store.assetURL(image), title: UIKitDiscussionPresentation.imageLabel(image, project: store.project), missingText: "Image unavailable", expectedDigest: image.sha256)
                thumbnail.widthAnchor.constraint(equalToConstant: 80).isActive = true; thumbnail.heightAnchor.constraint(equalToConstant: 53).isActive = true; thumbnail.clipsToBounds = true
                let label = ScrivUIKitTheme.label(UIKitDiscussionPresentation.imageLabel(image, project: store.project), size: 12, color: ScrivUIKitTheme.secondary)
                let attachmentRow = ScrivUIKitTheme.stack([thumbnail, label, UIView()], axis: .horizontal, spacing: 8); attachmentRow.alignment = .center
                let button = UIButton(type: .system); button.addAction(UIAction { _ in openAttachment(image.id) }, for: .touchUpInside)
                button.addSubview(attachmentRow); attachmentRow.isUserInteractionEnabled = false; attachmentRow.scrivPinEdges(to: button, insets: NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)); button.backgroundColor = ScrivUIKitTheme.inset; button.layer.cornerRadius = 7
                button.accessibilityLabel = "Open attached " + UIKitDiscussionPresentation.imageLabel(image, project: store.project); column.addArrangedSubview(button)
            } else if attachment["imageVersionId"]?.string != nil {
                column.addArrangedSubview(ScrivUIKitTheme.label("Attached image version is unavailable", size: 12, color: ScrivUIKitTheme.secondary))
            } else if let id = attachment["itemId"]?.string {
                column.addArrangedSubview(ScrivUIKitTheme.button(UIKitDiscussionPresentation.itemLabel(id, project: store.project), symbol: UIKitDiscussionPresentation.symbol(id, project: store.project)) { openAttachment(id) })
            }
        }
        var replyStyle = UIButton.Configuration.plain(); replyStyle.title = "Reply"
        replyStyle.baseForegroundColor = ScrivUIKitTheme.accent
        replyStyle.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0)
        replyStyle.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = UIFont.systemFont(ofSize: 16); return attributes
        }
        let replyButton = UIButton(configuration: replyStyle, primaryAction: UIAction { _ in reply() })
        replyButton.contentHorizontalAlignment = .leading; replyButton.accessibilityLabel = "Reply to " + name
        column.addArrangedSubview(ScrivUIKitTheme.stack([replyButton, UIView()], axis: .horizontal, spacing: 0))
        let divider = UIView(); divider.backgroundColor = ScrivUIKitTheme.hairline; divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        column.addArrangedSubview(divider)
        let row = ScrivUIKitTheme.stack([avatar, column], axis: .horizontal, spacing: 12); row.alignment = .top; stack.addArrangedSubview(row)
        contentView.backgroundColor = focused ? ScrivUIKitTheme.accent.withAlphaComponent(0.08) : .clear
        contentView.layer.cornerRadius = 9
    }
}

private final class DiscussionReadOnlyTextView: UITextView {
    private var measuredWidth: CGFloat = 0
    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false; isScrollEnabled = false; isSelectable = true; backgroundColor = .clear
        textContainerInset = .zero; textContainer.lineFragmentPadding = 0
        font = .systemFont(ofSize: 16); textColor = ScrivUIKitTheme.ink
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: ceil(sizeThatFits(CGSize(width: max(1, bounds.width), height: .greatestFiniteMagnitude)).height)) }
    override func layoutSubviews() { super.layoutSubviews(); if abs(measuredWidth - bounds.width) > 0.5 { measuredWidth = bounds.width; invalidateIntrinsicContentSize() } }
}

/// Stable participant colors and a readable initial, shared by messages and
/// mention selection. Identity is presentation-only: never a recipient lookup.
@MainActor
final class DiscussionAvatarView: UIView {
    private let gradient = CAGradientLayer()
    init(name: String, identity: String, mine: Bool = false, diameter: CGFloat = 48) {
        super.init(frame: .zero)
        let colors: [UIColor] = [.systemGreen, .systemPink, .systemTeal, .systemPurple, .systemOrange]
        let index = identity.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % colors.count }
        let color = mine ? ScrivUIKitTheme.accent : colors[index]
        gradient.colors = [color.withAlphaComponent(0.75).cgColor, color.cgColor]
        gradient.startPoint = CGPoint(x: 0.25, y: 0); gradient.endPoint = CGPoint(x: 0.75, y: 1)
        layer.addSublayer(gradient); layer.cornerRadius = diameter / 2; clipsToBounds = true
        let initial = ScrivUIKitTheme.label(String(name.prefix(1)).uppercased(), size: diameter * 0.5, weight: .medium, color: .white, lines: 1)
        initial.textAlignment = .center; addSubview(initial); initial.scrivPinEdges(to: self)
        widthAnchor.constraint(equalToConstant: diameter).isActive = true; heightAnchor.constraint(equalToConstant: diameter).isActive = true
        isAccessibilityElement = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); gradient.frame = bounds }
}
