import UIKit
import ScrivCore

enum ScrivWorkspaceLayout {
    static let scriptPanelRatio: CGFloat = 1.1
    static let outerInset: CGFloat = 24
    static let panelGap: CGFloat = 16
    static func usesFooterTransport(for tab: WorkspaceTab) -> Bool { true }
    static func stacksWorkPanels(availableWidth: CGFloat, discussionVisible: Bool, tab: WorkspaceTab) -> Bool {
        // Side by side stays readable down to ~430 points per panel; stacking
        // earlier left the Script panel showing a single line beside discussion.
        discussionVisible && tab != .storyboard && availableWidth > 0 && availableWidth < 860
    }
}

/// Presentation only: the controller owns all routes and actions. The navigation
/// is centered on the window, not on whatever space two unequal toolbars leave.
@MainActor
final class ScrivWorkspaceHeader: UIView {
    let titleButton = UIButton(type: .system)
    let tabs = UISegmentedControl(items: WorkspaceTab.allCases.map(\.rawValue))
    let searchButton = ScrivWorkspaceHeader.icon("magnifyingglass", label: "Find in script")
    let shareButton = ScrivWorkspaceHeader.icon("square.and.arrow.up", label: "Teams and sharing")
    let moreButton = ScrivWorkspaceHeader.icon("ellipsis", label: "Workspace actions")
    let accountButton = ScrivUIKitTheme.button("Sign in", symbol: "person.crop.circle") {}
    let codexButton = ScrivUIKitTheme.button("Codex · Local", symbol: "circle.fill") {}
    private let actions = UIStackView()
    private var hasAccount = false
    private var expandedActions = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        var configuration = UIButton.Configuration.plain()
        configuration.subtitle = "Scriv"
        configuration.titleAlignment = .leading
        configuration.titlePadding = 1
        configuration.baseForegroundColor = ScrivUIKitTheme.ink
        configuration.contentInsets = .zero
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming; outgoing.font = .systemFont(ofSize: 23, weight: .semibold); return outgoing
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming; outgoing.font = .systemFont(ofSize: 17)
            outgoing.foregroundColor = ScrivUIKitTheme.secondary; return outgoing
        }
        titleButton.configuration = configuration
        titleButton.contentHorizontalAlignment = .leading
        titleButton.titleLabel?.numberOfLines = 1
        titleButton.accessibilityIdentifier = "workspace-project"
        titleButton.accessibilityHint = "Open the project browser. More project actions are in Workspace actions."
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let glyph = UIImageView(image: UIImage(systemName: "doc.text"))
        glyph.tintColor = ScrivUIKitTheme.secondary
        glyph.contentMode = .center; glyph.backgroundColor = ScrivUIKitTheme.inset
        glyph.layer.cornerRadius = 6; glyph.isAccessibilityElement = false
        glyph.widthAnchor.constraint(equalToConstant: 34).isActive = true
        glyph.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let project = ScrivUIKitTheme.stack([glyph, titleButton], axis: .horizontal, spacing: 14)
        project.alignment = .center

        tabs.backgroundColor = ScrivUIKitTheme.inset
        tabs.selectedSegmentTintColor = ScrivUIKitTheme.panel
        tabs.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 18), .foregroundColor: ScrivUIKitTheme.secondary], for: .normal)
        tabs.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: ScrivUIKitTheme.ink], for: .selected)
        tabs.accessibilityIdentifier = "workspace-tabs"
        actions.axis = .horizontal; actions.alignment = .center; actions.spacing = 12
        [searchButton, shareButton, moreButton].forEach(actions.addArrangedSubview)
        accountButton.isHidden = true; codexButton.isHidden = true
        accountButton.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
        codexButton.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
        accountButton.accessibilityLabel = "Scriv account"
        codexButton.accessibilityLabel = "Codex on this Mac"
        [project, tabs, actions].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        let preferredTabWidth = tabs.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.29)
        preferredTabWidth.priority = .defaultHigh
        // Segments share the width equally; never let the 29% preference shrink
        // them below the widest (selected, semibold) title, which truncated
        // "Storyboard"/"Characters" near the minimum window width.
        let widestTitle = WorkspaceTab.allCases.map { ($0.rawValue as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .semibold)]).width }.max() ?? 0
        let minimumTabWidth = tabs.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(widestTitle + 32) * CGFloat(WorkspaceTab.allCases.count))
        NSLayoutConstraint.activate([
            project.leadingAnchor.constraint(equalTo: leadingAnchor),
            project.centerYAnchor.constraint(equalTo: centerYAnchor),
            project.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            project.trailingAnchor.constraint(lessThanOrEqualTo: tabs.leadingAnchor, constant: -24),
            tabs.centerXAnchor.constraint(equalTo: centerXAnchor),
            tabs.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Auto Layout sizes the alignment rectangle, not the visual frame.
            // The 48-point box draws a 49-point native Catalyst segment (about
            // 38 logical pixels at the unchanged scale). Keep that design target
            // rather than chasing its one-point native alignment outset.
            tabs.heightAnchor.constraint(equalToConstant: 48),
            tabs.widthAnchor.constraint(lessThanOrEqualToConstant: 420), preferredTabWidth, minimumTabWidth,
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: tabs.trailingAnchor, constant: 24),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    private var configured: (title: String, accountName: String?)?
    func configure(title: String, accountName: String?) {
        // Called on every workspace refresh; reassigning a button configuration
        // re-renders and relays out the button even when nothing changed.
        if let configured, configured.title == title, configured.accountName == accountName { return }
        configured = (title, accountName)
        titleButton.configuration?.title = title
        titleButton.accessibilityLabel = title + ", Projects"
        hasAccount = accountName != nil
        accountButton.configuration?.title = accountName.map { "Scriv · " + $0 } ?? "Sign in"
        accountButton.accessibilityValue = accountName
        setNeedsLayout()
    }
    override func layoutSubviews() {
        // The collaboration concept adds account/Codex controls at wide sizes.
        // Smaller windows retain every action in the overflow, without squeezing
        // navigation or wrapping a command title into vertical letters.
        let expanded = hasAccount && bounds.width >= 1_440
        if expanded != expandedActions {
            expandedActions = expanded
            // Do not apply UIStackView's zero-width hiding constraint to the
            // circular controls' required 48-point widths.
            for button in actions.arrangedSubviews { actions.removeArrangedSubview(button); button.removeFromSuperview() }
            accountButton.isHidden = !expanded; codexButton.isHidden = !expanded
            searchButton.isHidden = expanded; shareButton.isHidden = expanded
            let visible = expanded ? [accountButton, codexButton, moreButton] : [searchButton, shareButton, moreButton]
            visible.forEach(actions.addArrangedSubview)
        }
        super.layoutSubviews()
    }
    private static func icon(_ symbol: String, label: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .regular))
        configuration.baseForegroundColor = ScrivUIKitTheme.ink
        configuration.background.backgroundColor = ScrivUIKitTheme.inset.withAlphaComponent(0.7)
        configuration.background.cornerRadius = 24
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 48), button.heightAnchor.constraint(equalToConstant: 48)])
        return button
    }
}
