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
        stack.scrivPinEdges(to: contentView, insets: NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func configure(message: DiscussionMessage, store: WorkspaceStore, focused: Bool, reply: @escaping () -> Void, openAttachment: @escaping (String) -> Void) {
        for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
        let mine = message.userId == store.account?.id || message.authorId == store.account?.id
        let name = message.name ?? "Editor"
        let avatar = ScrivUIKitTheme.label(String(name.prefix(1)).uppercased(), size: 14, weight: .medium, color: .white, lines: 1)
        avatar.backgroundColor = mine ? ScrivUIKitTheme.accent : .systemTeal; avatar.textAlignment = .center; avatar.layer.cornerRadius = 14; avatar.clipsToBounds = true
        avatar.widthAnchor.constraint(equalToConstant: 28).isActive = true; avatar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let date = message.createdAt == nil && message.at == nil ? "" : message.timestamp.formatted(date: .omitted, time: .shortened)
        let header = ScrivUIKitTheme.stack([ScrivUIKitTheme.label(name, size: 12, weight: .semibold), UIView(), ScrivUIKitTheme.label(date, size: 10, color: ScrivUIKitTheme.secondary)], axis: .horizontal, spacing: 6)
        let column = ScrivUIKitTheme.stack([header], spacing: 6)
        if let replyID = message.replyToId {
            let original = store.messages.first { $0.id == replyID }
            let quote = ScrivUIKitTheme.label(original?.body ?? "Reply to an earlier message", size: 10, color: ScrivUIKitTheme.secondary, lines: 2)
            let line = UIView(); line.backgroundColor = ScrivUIKitTheme.hairline; line.widthAnchor.constraint(equalToConstant: 2).isActive = true
            column.addArrangedSubview(ScrivUIKitTheme.stack([line, quote], axis: .horizontal, spacing: 8))
        }
        if !message.mentionedUserIds.isEmpty {
            let flow = DiscussionFlowView()
            for id in Array(Set(message.mentionedUserIds)).sorted() {
                let text = id == store.account?.id ? "@You" : "@" + store.discussionMemberName(id)
                let chip = ScrivUIKitTheme.label(text, size: 10, weight: .medium, color: id == store.account?.id ? .white : ScrivUIKitTheme.accent, lines: 1)
                chip.backgroundColor = id == store.account?.id ? ScrivUIKitTheme.accent : ScrivUIKitTheme.inset; chip.layer.cornerRadius = 5; chip.clipsToBounds = true
                chip.accessibilityLabel = id == store.account?.id ? "You were mentioned" : "Mentioned " + store.discussionMemberName(id); flow.addChip(chip)
            }
            column.addArrangedSubview(flow)
        }
        let body = DiscussionReadOnlyTextView()
        body.text = message.body; column.addArrangedSubview(body)
        for attachment in message.attachments ?? [] {
            if let image = UIKitDiscussionPresentation.attachmentImage(attachment, project: store.project) {
                let thumbnail = UIKitAssetImageView(); thumbnail.configure(url: store.assetURL(image), title: UIKitDiscussionPresentation.imageLabel(image, project: store.project), missingText: "Image unavailable")
                thumbnail.widthAnchor.constraint(equalToConstant: 80).isActive = true; thumbnail.heightAnchor.constraint(equalToConstant: 53).isActive = true; thumbnail.clipsToBounds = true
                let label = ScrivUIKitTheme.label(UIKitDiscussionPresentation.imageLabel(image, project: store.project), size: 11, color: ScrivUIKitTheme.secondary)
                let attachmentRow = ScrivUIKitTheme.stack([thumbnail, label, UIView()], axis: .horizontal, spacing: 8); attachmentRow.alignment = .center
                let button = UIButton(type: .system); button.addAction(UIAction { _ in openAttachment(image.id) }, for: .touchUpInside)
                button.addSubview(attachmentRow); attachmentRow.isUserInteractionEnabled = false; attachmentRow.scrivPinEdges(to: button, insets: NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)); button.backgroundColor = ScrivUIKitTheme.inset; button.layer.cornerRadius = 7
                button.accessibilityLabel = "Open attached " + UIKitDiscussionPresentation.imageLabel(image, project: store.project); column.addArrangedSubview(button)
            } else if attachment["imageVersionId"]?.string != nil {
                column.addArrangedSubview(ScrivUIKitTheme.label("Attached image version is unavailable", size: 10, color: ScrivUIKitTheme.secondary))
            } else if let id = attachment["itemId"]?.string {
                column.addArrangedSubview(ScrivUIKitTheme.button(UIKitDiscussionPresentation.itemLabel(id, project: store.project), symbol: UIKitDiscussionPresentation.symbol(id, project: store.project)) { openAttachment(id) })
            }
        }
        let replyButton = ScrivUIKitTheme.button("Reply", action: reply); replyButton.configuration?.contentInsets = .zero; replyButton.contentHorizontalAlignment = .leading
        column.addArrangedSubview(ScrivUIKitTheme.stack([replyButton, UIView()], axis: .horizontal, spacing: 0))
        let row = ScrivUIKitTheme.stack([avatar, column], axis: .horizontal, spacing: 10); row.alignment = .top; stack.addArrangedSubview(row)
        let divider = UIView(); divider.backgroundColor = ScrivUIKitTheme.hairline; divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true; stack.addArrangedSubview(divider)
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
        font = .systemFont(ofSize: 12); textColor = ScrivUIKitTheme.ink
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: ceil(sizeThatFits(CGSize(width: max(1, bounds.width), height: .greatestFiniteMagnitude)).height)) }
    override func layoutSubviews() { super.layoutSubviews(); if abs(measuredWidth - bounds.width) > 0.5 { measuredWidth = bounds.width; invalidateIntrinsicContentSize() } }
}
