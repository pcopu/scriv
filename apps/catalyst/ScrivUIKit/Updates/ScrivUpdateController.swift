import UIKit

/// References generated before implementation: update-flow-reference.png and
/// termination-retry-reference.png in design/updates/.
@MainActor
final class ScrivUpdateController: UIViewController {
    var onClose: (() -> Void)?
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let notesLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let primary = UIButton(type: .system)
    private let secondary = UIButton(type: .system)
    private let mark = UIImageView(image: UIImage(systemName: "arrow.down.circle"))
    private var reply: ((String) -> Void)?
    private var phase = "checking"

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        isModalInPresentation = true
        preferredContentSize = CGSize(width: 480, height: 510)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init()") }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }
    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelFromEscape))
        escape.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [escape]
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(cancelFromEscape) { return canCancelFromEscape }
        return super.canPerformAction(action, withSender: sender)
    }
    private var canCancelFromEscape: Bool {
        presentingViewController != nil && viewIfLoaded?.window != nil && presentedViewController == nil
            && !isBeingPresented && !isBeingDismissed
            && !secondary.isHidden && secondary.isEnabled && reply != nil
    }
    @objc private func cancelFromEscape() {
        // Sparkle owns cancellation, including prepared updates. Never dismiss
        // the sheet independently or treat an in-flight install as canceled.
        guard canCancelFromEscape else { return }
        chooseSecondary()
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.985, green: 0.98, blue: 0.97, alpha: 1)
        let accent = ScrivUIKitTheme.accent
        mark.tintColor = accent; mark.contentMode = .scaleAspectFit
        mark.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let eyebrow = UILabel(); eyebrow.text = "SCRIV UPDATE"; eyebrow.font = .systemFont(ofSize: 11, weight: .semibold)
        eyebrow.textColor = .secondaryLabel; eyebrow.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 29, weight: .bold); titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header; titleLabel.numberOfLines = 0
        for label in [detailLabel, notesLabel] { label.font = .systemFont(ofSize: 14); label.numberOfLines = 0; label.textAlignment = .center; label.textColor = .secondaryLabel }
        notesLabel.textAlignment = .left
        progress.progressTintColor = accent; progress.accessibilityLabel = "Update progress"
        var configuration = UIButton.Configuration.filled(); configuration.baseBackgroundColor = accent; configuration.cornerStyle = .medium
        primary.configuration = configuration; primary.accessibilityIdentifier = "scriv.update.primary"
        secondary.configuration = .gray(); secondary.accessibilityIdentifier = "scriv.update.secondary"
        primary.addAction(UIAction { [weak self] _ in self?.choosePrimary() }, for: .touchUpInside)
        secondary.addAction(UIAction { [weak self] _ in self?.chooseSecondary() }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [secondary, primary]); buttons.spacing = 12; buttons.distribution = .fillEqually
        let footer = UILabel(); footer.text = "Your projects stay right where you left them."; footer.font = .systemFont(ofSize: 11); footer.textColor = .tertiaryLabel; footer.textAlignment = .center; footer.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [mark, eyebrow, titleLabel, detailLabel, notesLabel, progress, buttons, footer])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -64)
        ])
        render(["phase": "checking"], reply: nil)
    }
    func render(_ event: [String: Any], reply: ((String) -> Void)?) {
        loadViewIfNeeded()
        let next = event["phase"] as? String ?? "error"
        if next == "progress" { progress.progress = min(1, max(0, (event["progress"] as? NSNumber)?.floatValue ?? 0)); return }
        phase = next; self.reply = reply
        let version = event["version"] as? String ?? ""
        let presentation = ScrivUpdatePresentation(phase: next, version: version)
        titleLabel.text = presentation.title; detailLabel.text = event["message"] as? String ?? presentation.detail
        notesLabel.text = next == "available" ? (event["notes"] as? String) : nil
        notesLabel.isHidden = notesLabel.text?.isEmpty != false
        primary.setTitle(presentation.primary, for: .normal); primary.isHidden = presentation.primary == nil
        secondary.setTitle(presentation.secondary, for: .normal); secondary.isHidden = presentation.secondary == nil
        primary.isEnabled = true; secondary.isEnabled = reply != nil
        progress.isHidden = !presentation.showsProgress; progress.progress = 0
        mark.image = UIImage(systemName: presentation.symbol)
        UIAccessibility.post(notification: .layoutChanged, argument: titleLabel)
    }
    private func choosePrimary() {
        guard primary.isEnabled else { return }
        primary.isEnabled = false; secondary.isEnabled = false
        if phase == "available" || phase == "ready" || phase == "retryQuit" { consume("install") }
        else { consume("close"); closeIfIdle() }
    }
    private func chooseSecondary() {
        guard !secondary.isHidden, secondary.isEnabled, reply != nil else { return }
        primary.isEnabled = false; secondary.isEnabled = false
        consume("cancel")
        // The callback may synchronously show a new phase, including an error.
        // Leave that notice visible and let the plugin own cancellation/dismissal.
    }
    private func consume(_ choice: String) { let callback = reply; reply = nil; callback?(choice) }
    private func closeIfIdle() { dismiss(animated: true); onClose?() }
}
