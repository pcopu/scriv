import UIKit
import ScrivCore

/// Immutable preflight presentation. This never rebuilds a request from labels
/// or changes the core's passage selection, identity order or portrait deduping.
struct GenerationBriefSnapshot {
    let context: GenerationContext
    let localPortraitURLs: [String: URL]

    var exactBrief: String { context.prompt }
    var exactRequest: String { GenerationPrompt.submitted(brief: context.prompt) }
    var pictureTitle: String { context.cueLabel.isEmpty ? "Selected picture" : context.cueLabel }
    var interval: String { "\(ScrivFormat.time(context.startMs)) – \(ScrivFormat.time(context.endMs))" }
    var summary: String {
        "\(pictureTitle) · \(context.passages.count) source \(context.passages.count == 1 ? "passage" : "passages") · \(context.characters.count) \(context.characters.count == 1 ? "character" : "characters")"
    }
    func composerTarget(isPlaying: Bool, playingCue: ImageCue?) -> String {
        guard isPlaying, playingCue?.id != context.cueID else { return summary }
        let playing = playingCue.map { $0.label.isEmpty ? "another placement" : $0.label } ?? "the playhead"
        return "Target: \(summary)\nPreview follows \(playing). Review and Generate still use \(pictureTitle)."
    }
    func referenceNumber(for characterID: String) -> Int? {
        context.portraits.firstIndex { $0.characterIDs.contains(characterID) }.map { $0 + 1 }
    }
    func attachedPortraitURL(for characterID: String) -> URL? {
        guard let portrait = context.portraits.first(where: { $0.characterIDs.contains(characterID) }) else { return nil }
        return localPortraitURLs[portrait.assetID]
    }
    func portraitStatus(for character: ScriptCharacter) -> String {
        if let number = referenceNumber(for: character.id) { return "Reference \(number)" }
        guard let id = character.portraitImageId else { return "Text identity only · no portrait saved" }
        return localPortraitURLs[id] == nil
            ? "Text identity only · no local portrait available"
            : "Text identity only · portrait not attached (five-input limit)"
    }
    /// The header already carries “Text identity only” or the reference number.
    /// Keep availability explicit without repeating that marker in every line.
    func portraitAvailability(for character: ScriptCharacter) -> String {
        if let number = referenceNumber(for: character.id) { return "Attached as reference \(number)" }
        guard let id = character.portraitImageId else { return "No portrait saved" }
        return localPortraitURLs[id] == nil ? "No local portrait available" : "Not attached (five-input limit)"
    }
    func reasons(for characterID: String) -> [String] {
        (context.characterReasons[characterID] ?? []).map { reason in
            switch reason {
            case "speaker in this cue": return "Speaker in this interval"
            case "named in this cue's manual override": return "Named in this picture’s image direction"
            case "tagged in this cue's current image": return "Tagged in the current picture"
            default: return reason.prefix(1).uppercased() + String(reason.dropFirst())
            }
        }
    }
    static let storageDisclosure = "The exact submitted request and this picture’s visual direction are saved separately with the generated image. Copied portraits stay in local generation history; image-file storage follows your project settings."
}

@MainActor enum GenerationReviewUI {
    // Local feature metrics, not a global Catalyst scale override. The outer
    // sheet is invariant across tabs and person disclosures; its body scrolls.
    static let preferredSize = CGSize(width: 720, height: 830)
    static func button(_ title: String, symbol: String? = nil, primary: Bool = false, action: @escaping () -> Void) -> UIButton {
        let button = ImageUI.button(title, symbol: symbol, primary: primary, action: action)
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming; outgoing.font = .systemFont(ofSize: 17, weight: .medium); return outgoing
        }
        button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        button.titleLabel?.numberOfLines = 1
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
    static func body(_ text: String, secondary: Bool = false) -> UILabel { ImageUI.label(text, size: 17, secondary: secondary) }
    static func caption(_ text: String) -> UILabel { ImageUI.label(text, size: 15, secondary: true) }
    static func heading(_ text: String) -> UILabel { ImageUI.label(text, size: 21, weight: .semibold) }
    static func personHeader(_ person: ScriptCharacter, snapshot: GenerationBriefSnapshot, symbol: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        let name = ImageUI.label(person.name, size: 22, weight: .semibold)
        name.accessibilityIdentifier = "generation-person-name-" + person.id
        let marker = snapshot.referenceNumber(for: person.id).map { "Reference \($0)" } ?? "Text identity only"
        let markerLabel = ImageUI.label(marker, size: 14, secondary: true)
        markerLabel.accessibilityIdentifier = "generation-person-reference-" + person.id
        markerLabel.setContentHuggingPriority(.required, for: .horizontal)
        let badge = ImageUI.card(markerLabel, padding: 5)
        badge.backgroundColor = ImageUI.accent.withAlphaComponent(0.07); badge.layer.cornerRadius = 12
        let chevron = UIImageView(image: UIImage(systemName: symbol)); chevron.tintColor = ScrivUIKitTheme.secondary; chevron.contentMode = .scaleAspectFit
        chevron.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let labels = GenerationPersonNameRow(name: name, badge: badge)
        let row = ImageUI.row([labels, chevron], spacing: 12); row.isUserInteractionEnabled = false
        button.addSubview(row); row.scrivPinEdges(to: button, insets: .init(top: 3, leading: 0, bottom: 3, trailing: 0))
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        button.accessibilityLabel = person.name + ", " + marker
        return button
    }
    static func avatar(_ character: ScriptCharacter, snapshot: GenerationBriefSnapshot, size: CGFloat) -> UIView {
        let view: UIView
        if let url = snapshot.attachedPortraitURL(for: character.id) {
            let picture = UIKitAssetImageView(); picture.configure(url: url, title: "Attached identity portrait for " + character.name, fill: false)
            view = picture
        } else {
            let initial = ImageUI.label(String(character.name.prefix(1)).uppercased(), size: size * 0.4, weight: .medium)
            initial.textAlignment = .center; initial.textColor = ImageUI.accent
            initial.backgroundColor = ImageUI.accent.withAlphaComponent(0.10)
            initial.layer.cornerRadius = size / 2; initial.clipsToBounds = true
            initial.accessibilityLabel = character.name + ", text identity only"
            view = initial
        }
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        return view
    }
}

/// A name and its identity marker are one group, rather than opposite ends of
/// the card. At narrow widths the marker moves below the name, never crushing
/// a long name into letters or making the full identity unavailable.
@MainActor private final class GenerationPersonNameRow: UIStackView {
    private let name: UILabel
    private let badge: UIView
    private let flexibleSpace = ImageUI.spacer()
    init(name: UILabel, badge: UIView) {
        self.name = name; self.badge = badge
        super.init(frame: .zero)
        axis = .horizontal; alignment = .center; spacing = 10
        name.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        [name, badge, flexibleSpace].forEach(addArrangedSubview)
        name.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        badge.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError("Use init(name:badge:)") }
    override func layoutSubviews() {
        let naturalWidth = name.intrinsicContentSize.width + badge.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + 10
        let vertical = bounds.width > 0 && bounds.width < naturalWidth
        let next: NSLayoutConstraint.Axis = vertical ? .vertical : .horizontal
        if axis != next {
            axis = next; alignment = vertical ? .leading : .center
            spacing = vertical ? 4 : 10; flexibleSpace.isHidden = vertical
        }
        super.layoutSubviews()
    }
}
