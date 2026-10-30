import UIKit
import ScrivCore

/// Embedded by the workspace shell. Store owns draft text, mentions, replies,
/// attachments and send idempotency; this controller owns only presentation.
@MainActor
final class ScrivDiscussionController: ScrivScreenController, UITableViewDataSource, UITableViewDelegate, UITextViewDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private let scope = UISegmentedControl(items: ["Project", "This item"])
    private let contextButton = UIButton(type: .system)
    private let contextThumbnail = UIKitAssetImageView()
    private let contextSubtitle = ScrivUIKitTheme.label("", size: 11, color: ScrivUIKitTheme.secondary)
    private let placeholder = ScrivUIKitTheme.label("Add a comment…", size: 13, color: ScrivUIKitTheme.secondary)
    private let composer = DiscussionComposerTextView()
    private let composerMetadata = ScrivUIKitTheme.stack([], spacing: 5)
    private let countLabel = ScrivUIKitTheme.label("", size: 10, color: ScrivUIKitTheme.secondary)
    private let draftLabel = ScrivUIKitTheme.label("In-app only · Drafts are not sent", size: 10, color: ScrivUIKitTheme.secondary)
    private let unavailable = ScrivUIKitTheme.stack([], spacing: 12)
    private let resolvedRow = ScrivUIKitTheme.stack([], axis: .horizontal, spacing: 10)
    private var composerContainer: UIView!
    private var sendButton: UIButton!, attachButton: UIButton!, mentionsButton: UIButton!, activityButton: UIButton!, filterButton: UIButton!
    private var composerHeight: NSLayoutConstraint!
    private var onlyMentions = false
    private var visibleMessages: [DiscussionMessage] = []
    private var composerScope = ""
    private var contextSnapshot = 0
    private var updatingComposer = false
    private var memberScope = ""
    private var lastMessageIDs: [String] = []
    private var lastFocusedID: String?
    private var refreshTask: Task<Void, Never>?
    private var scrollAfterReload = false

    init(store: WorkspaceStore) { super.init(store: store, scopeToProject: false); preferredContentSize = CGSize(width: 368, height: 515) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    private var ready: Bool { store.account != nil && store.project.cloudProjectId != nil }
    private var mentionsOfMe: [DiscussionMessage] { guard let id = store.account?.id else { return [] }; return store.messages.filter { $0.mentionedUserIds.contains(id) } }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ScrivUIKitTheme.panel; view.layer.cornerRadius = 18; view.layer.borderWidth = 0.5; view.layer.borderColor = ScrivUIKitTheme.hairline.cgColor
        view.layer.shadowOpacity = 0
        activityButton = iconButton("Project activity", "bell") { [weak self] in self?.openActivity() }
        filterButton = iconButton("Show mentions of you", "at") { [weak self] in self?.onlyMentions.toggle(); self?.renderMessages() }
        let close = iconButton("Close discussion", "xmark") { [weak self] in self?.view.endEditing(true); self?.store.showDiscussion = false }
        let header = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Discussion", size: 15, weight: .semibold, color: ScrivUIKitTheme.accent), UIView(), activityButton, filterButton, close], axis: .horizontal, spacing: 7); header.alignment = .center
        scope.selectedSegmentIndex = store.discussionItemID == nil ? 0 : 1; scope.addTarget(self, action: #selector(scopeChanged), for: .valueChanged)
        contextButton.titleLabel?.font = .systemFont(ofSize: 11, weight: .medium); contextButton.titleLabel?.lineBreakMode = .byTruncatingTail; contextButton.contentHorizontalAlignment = .leading; contextButton.showsMenuAsPrimaryAction = true
        contextButton.backgroundColor = ScrivUIKitTheme.inset.withAlphaComponent(0.6); contextButton.layer.cornerRadius = 7; contextButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 9, bottom: 7, right: 9)
        table.dataSource = self; table.delegate = self; table.separatorStyle = .none; table.backgroundColor = .clear; table.estimatedRowHeight = 110; table.rowHeight = UITableView.automaticDimension
        table.register(DiscussionMessageCell.self, forCellReuseIdentifier: "message"); table.layer.cornerRadius = 11
        let messagesContainer = UIView(); messagesContainer.addSubview(table); table.scrivPinEdges(to: messagesContainer)
        messagesContainer.addSubview(unavailable); unavailable.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([unavailable.leadingAnchor.constraint(equalTo: messagesContainer.leadingAnchor, constant: 12), unavailable.trailingAnchor.constraint(equalTo: messagesContainer.trailingAnchor, constant: -12), unavailable.centerYAnchor.constraint(equalTo: messagesContainer.centerYAnchor)])
        composerContainer = makeComposer()
        contextThumbnail.widthAnchor.constraint(equalToConstant: 65).isActive = true; contextThumbnail.heightAnchor.constraint(equalToConstant: 44).isActive = true
        contextThumbnail.clipsToBounds = true
        let contextRow = ScrivUIKitTheme.stack([contextThumbnail, ScrivUIKitTheme.stack([contextButton, contextSubtitle], spacing: 3)], axis: .horizontal, spacing: 9); contextRow.alignment = .center
        let contextCard = ScrivUIKitTheme.card(contextRow, padding: 10)
        let root = ScrivUIKitTheme.stack([header, scope, contextCard, messagesContainer, resolvedRow, composerContainer], spacing: 10)
        view.addSubview(root); root.scrivPinEdges(to: view, insets: NSDirectionalEdgeInsets(top: 18, leading: 16, bottom: 16, trailing: 16))
        storeDidChange()
    }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        let key = store.discussionDraftKey
        if composerScope != key {
            composer.resignFirstResponder(); composerScope = key; contextSnapshot = store.navigationContext; onlyMentions = false
            if presentedViewController is UIKitDiscussionMentionPicker { presentedViewController?.dismiss(animated: true) }
        }
        if contextSnapshot != store.navigationContext {
            contextSnapshot = store.navigationContext; onlyMentions = false; presentedViewController?.dismiss(animated: true)
        }
        scope.selectedSegmentIndex = store.discussionItemID == nil ? 0 : 1
        let image = store.project.asset(store.discussionItemID)
        let itemKind = image != nil ? "image" : store.project.character(store.discussionItemID) != nil ? "character" : store.project.entries.first(where: { $0.id == store.discussionItemID })?.kind == .direction ? "direction" : "line"
        scope.setTitle(store.discussionItemID == nil ? "This item" : "This " + itemKind, forSegmentAt: 1)
        contextButton.setTitle(store.discussionItemID == nil ? store.project.title : UIKitDiscussionPresentation.itemLabel(store.discussionItemID, project: store.project) + "  ⌄", for: .normal); contextButton.menu = contextMenu()
        contextSubtitle.text = "Comments stay with this " + (store.discussionItemID == nil ? "project." : itemKind + ".")
        contextThumbnail.isHidden = image == nil
        if let image { contextThumbnail.configure(url: store.assetURL(image), title: UIKitDiscussionPresentation.imageLabel(image, project: store.project), missingText: "Image unavailable") }
        preferredContentSize = CGSize(width: 368, height: ready && store.messages.isEmpty ? 410 : 515)
        activityButton.isEnabled = ready; activityButton.setImage(UIImage(systemName: store.unreadDiscussionMentionCount > 0 ? "bell.badge.fill" : "bell"), for: .normal)
        activityButton.accessibilityLabel = "Project activity, \(store.unreadDiscussionMentionCount) unread mentions"
        filterButton.isHidden = mentionsOfMe.isEmpty; filterButton.tintColor = onlyMentions ? ScrivUIKitTheme.accent : ScrivUIKitTheme.secondary
        filterButton.accessibilityLabel = "\(mentionsOfMe.count) messages mention you. " + (onlyMentions ? "Show all messages" : "Filter to your mentions")
        unavailable.isHidden = ready; table.isHidden = !ready; composerContainer.isHidden = !ready; resolvedRow.isHidden = !ready || store.activeThread == nil || store.messages.isEmpty
        if !ready { renderUnavailable() }
        renderMessages(); renderComposer(); renderResolution()
        let currentMemberScope = "\(store.navigationContext):\(store.account?.id ?? ""):\(store.project.cloudProjectId ?? "")"
        if ready && currentMemberScope != memberScope {
            memberScope = currentMemberScope; refreshTask?.cancel()
            refreshTask = Task { [weak self] in guard let self else { return }; do { try await store.refreshDiscussionMembers() } catch is CancellationError { } catch { /* Picker provides actionable retry without interrupting writing. */ } }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); updateComposerHeight()
        if scrollAfterReload { scrollAfterReload = false; scrollToCurrentMessage() }
    }
    private func renderMessages() {
        visibleMessages = onlyMentions ? mentionsOfMe : store.messages
        let ids = visibleMessages.map(\.id)
        scrollAfterReload = ids != lastMessageIDs || store.discussionFocusedMessageID != lastFocusedID
        lastMessageIDs = ids; lastFocusedID = store.discussionFocusedMessageID
        table.reloadData()
        if store.discussionLoading { table.backgroundView = centeredMessage("Loading conversation…") }
        else if visibleMessages.isEmpty { table.backgroundView = emptyConversation() }
        else { table.backgroundView = nil }
        view.setNeedsLayout()
    }
    private func renderResolution() {
        for child in resolvedRow.arrangedSubviews { resolvedRow.removeArrangedSubview(child); child.removeFromSuperview() }
        guard ready, !store.messages.isEmpty, let thread = store.activeThread else { return }
        let key = store.discussionDraftKey, navigation = store.navigationContext
        resolvedRow.addArrangedSubview(ScrivUIKitTheme.button(thread.resolved ? "Reopen conversation" : "Mark resolved", symbol: thread.resolved ? "arrow.uturn.backward" : "checkmark") { [weak self] in
            guard let self, store.navigationContext == navigation, store.discussionDraftKey == key, store.activeThread?.id == thread.id else { return }; store.resolveThread()
        }); resolvedRow.addArrangedSubview(UIView())
        if thread.resolved { resolvedRow.addArrangedSubview(ScrivUIKitTheme.label("Resolved", size: 10, color: .systemGreen)) }
    }
    private func makeComposer() -> UIView {
        composer.delegate = self; composer.font = .systemFont(ofSize: 13); composer.backgroundColor = .clear; composer.textContainerInset = .zero; composer.textContainer.lineFragmentPadding = 0
        composer.addSubview(placeholder); placeholder.translatesAutoresizingMaskIntoConstraints = false; placeholder.isUserInteractionEnabled = false; placeholder.isAccessibilityElement = false
        NSLayoutConstraint.activate([placeholder.leadingAnchor.constraint(equalTo: composer.leadingAnchor), placeholder.topAnchor.constraint(equalTo: composer.topAnchor), placeholder.trailingAnchor.constraint(lessThanOrEqualTo: composer.trailingAnchor)])
        composer.accessibilityLabel = "Discussion draft, not sent"; composer.sendMessage = { [weak self] in self?.send() }
        composerHeight = composer.heightAnchor.constraint(equalToConstant: 42); composerHeight.isActive = true
        attachButton = iconButton("Attach a project item", "paperclip") {}; attachButton.showsMenuAsPrimaryAction = true
        mentionsButton = iconButton("Mention a project member", "at") { [weak self] in self?.openMentions() }
        sendButton = iconButton("Send message", "arrow.up") { [weak self] in self?.send() }; sendButton.tintColor = .white; sendButton.backgroundColor = ScrivUIKitTheme.accent; sendButton.layer.cornerRadius = 14
        let tools = ScrivUIKitTheme.stack([attachButton, mentionsButton, UIView(), sendButton], axis: .horizontal, spacing: 12)
        let card = ScrivUIKitTheme.card(ScrivUIKitTheme.stack([composer, tools], spacing: 8), padding: 12)
        return ScrivUIKitTheme.stack([composerMetadata, card, ScrivUIKitTheme.stack([draftLabel, UIView(), countLabel], axis: .horizontal, spacing: 8)], spacing: 7)
    }
    private func renderComposer() {
        if !composer.text.utf16.elementsEqual(store.discussionDraft.utf16), composer.markedTextRange == nil {
            let range = composer.selectedRange; updatingComposer = true; composer.text = store.discussionDraft; updatingComposer = false
            composer.selectedRange = NSRange(location: min(range.location, composer.text.utf16.count), length: 0)
        }
        composer.accessibilityHint = "Reply to \(store.discussionItemID == nil ? "project" : "this item"). Command–Return sends."
        for child in composerMetadata.arrangedSubviews { composerMetadata.removeArrangedSubview(child); child.removeFromSuperview() }
        let key = store.discussionDraftKey, navigation = store.navigationContext
        if let replyID = store.discussionReplyToID, let message = store.messages.first(where: { $0.id == replyID }) {
            let remove = iconButton("Cancel reply", "xmark") { [weak self] in guard let self, store.discussionDraftKey == key, store.navigationContext == navigation else { return }; store.discussionReplyToID = nil }
            composerMetadata.addArrangedSubview(ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Replying to \(message.name ?? "editor")", size: 10, color: ScrivUIKitTheme.secondary), UIView(), remove], axis: .horizontal, spacing: 8))
        }
        if !store.discussionMentionedUserIDs.isEmpty {
            let chips = DiscussionFlowView()
            for id in store.discussionMentionedUserIDs {
                let chip = ScrivUIKitTheme.button("@" + mentionName(id), symbol: "xmark") { [weak self] in guard let self, store.discussionDraftKey == key, store.navigationContext == navigation else { return }; store.removeDiscussionMention(id) }
                chip.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7); chip.titleLabel?.font = .systemFont(ofSize: 10); chip.accessibilityLabel = "Remove mention of " + mentionName(id); chips.addChip(chip)
            }
            composerMetadata.addArrangedSubview(chips)
        }
        if !store.discussionAttachments.isEmpty {
            let clear = ScrivUIKitTheme.button("Clear") { [weak self] in guard let self, store.discussionDraftKey == key, store.navigationContext == navigation else { return }; store.discussionAttachments = [] }
            composerMetadata.addArrangedSubview(ScrivUIKitTheme.stack([ScrivUIKitTheme.label("\(store.discussionAttachments.count) attached item\(store.discussionAttachments.count == 1 ? "" : "s")", size: 10, color: ScrivUIKitTheme.secondary), UIView(), clear], axis: .horizontal, spacing: 8))
        }
        composerMetadata.isHidden = composerMetadata.arrangedSubviews.isEmpty
        attachButton.menu = attachmentMenu(); attachButton.isEnabled = store.discussionAttachments.count < 8
        placeholder.isHidden = !composer.text.isEmpty
        draftLabel.text = store.discussionDraft.isEmpty ? "In-app only · Drafts are not sent" : "Draft — not sent"
        let length = store.discussionDraft.utf16.count
        countLabel.text = length > 7500 ? "\(length) / 8,000" : ""; countLabel.textColor = length > 8000 ? .systemRed : ScrivUIKitTheme.secondary
        sendButton.isEnabled = ready && !store.isSendingDiscussion && !store.discussionLoading && !store.discussionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && length <= 8000
        sendButton.alpha = sendButton.isEnabled ? 1 : 0.4; updateComposerHeight()
    }
    private func updateComposerHeight() {
        guard composer.bounds.width > 0 else { return }
        let measured = composer.sizeThatFits(CGSize(width: composer.bounds.width, height: .greatestFiniteMagnitude)).height
        let next = min(116, max(42, ceil(measured)))
        if abs(composerHeight.constant - next) > 0.5 { composerHeight.constant = next }
        composer.isScrollEnabled = measured > 116
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !updatingComposer, composerScope == store.discussionDraftKey, contextSnapshot == store.navigationContext, let stringRange = Range(range, in: textView.text) else { return false }
        // Persist to the currently captured Store scope before UIKit accepts it.
        store.discussionDraft = textView.text.replacingCharacters(in: stringRange, with: text); return true
    }
    func textViewDidChange(_ textView: UITextView) {
        guard !updatingComposer else { return }
        guard composerScope == store.discussionDraftKey, contextSnapshot == store.navigationContext else { storeDidChange(); return }
        store.discussionDraft = textView.text; renderComposer()
    }
    private func send() {
        guard ready, composerScope == store.discussionDraftKey, contextSnapshot == store.navigationContext, !store.isSendingDiscussion, !store.discussionLoading else { return }
        let text = store.discussionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 8000 else { return }
        let key = composerScope, navigation = contextSnapshot
        Task { [weak self] in
            guard let self, store.discussionDraftKey == key, store.navigationContext == navigation else { return }
            do { _ = try await store.sendMessage(text) } catch is CancellationError { } catch { store.errorMessage = error.localizedDescription }
        }
    }
    @objc private func scopeChanged() {
        if scope.selectedSegmentIndex == 0 { store.loadDiscussion(itemId: nil) }
        else {
            let item: String?
            switch store.tab { case .characters: item = store.selectedCharacterID; case .storyboard: item = store.selectedCue?.imageId ?? store.selectedCueID; case .script: item = store.selectedEntryID }
            guard let item else { scope.selectedSegmentIndex = 0; return }; store.loadDiscussion(itemId: item)
        }
    }
    private func contextMenu() -> UIMenu {
        let navigation = store.navigationContext
        func action(_ title: String, id: String) -> UIAction { UIAction(title: title) { [weak self] _ in guard let self, store.navigationContext == navigation else { return }; store.loadDiscussion(itemId: id) } }
        return UIMenu(children: [
            UIMenu(title: "Lines and directions", children: store.sceneEntries.map { action(UIKitDiscussionPresentation.itemLabel($0.id, project: store.project) + " · " + String($0.text.prefix(45)), id: $0.id) }),
            UIMenu(title: "Characters", children: store.project.characters.map { action($0.name, id: $0.id) }),
            UIMenu(title: "Images", children: store.project.images.map { action(UIKitDiscussionPresentation.imageLabel($0, project: store.project), id: $0.id) })
        ])
    }
    private func attachmentMenu() -> UIMenu {
        let key = store.discussionDraftKey, navigation = store.navigationContext
        func action(_ title: String, id: String, image: String? = nil) -> UIAction { UIAction(title: title) { [weak self] _ in guard let self, store.navigationContext == navigation, store.discussionDraftKey == key else { return }; store.addDiscussionAttachment(itemId: id, imageVersionId: image) } }
        var actions: [UIAction] = []
        if let id = store.selectedEntryID { actions.append(action("Selected line or direction", id: id)) }
        if let id = store.selectedCharacterID { actions.append(action("Selected character", id: id)) }
        if let image = store.project.asset(store.selectedCue?.imageId ?? store.currentCue?.imageId) { actions.append(action("Current image, version \(image.version)", id: image.id, image: image.id)) }
        return UIMenu(children: actions)
    }
    private func renderUnavailable() {
        for child in unavailable.arrangedSubviews { unavailable.removeArrangedSubview(child); child.removeFromSuperview() }
        let title = ScrivUIKitTheme.label(store.account == nil ? "Sign in to keep the conversation" : "Save this project to Scriv Cloud", size: 15, weight: .semibold); title.textAlignment = .center
        let message = ScrivUIKitTheme.label("Threads attach to lines, directions, characters and images. Shared projects include everyone on your team.", size: 12, color: ScrivUIKitTheme.secondary); message.textAlignment = .center
        unavailable.addArrangedSubview(title); unavailable.addArrangedSubview(message)
        unavailable.addArrangedSubview(ScrivUIKitTheme.button(store.account == nil ? "Sign in to Scriv" : "Save script to cloud", primary: true) { [weak self] in guard let self else { return }; if store.account == nil { show(.signIn) } else { store.syncProject() } })
    }
    private func openMentions() { guard ready else { return }; let controller = UIKitDiscussionMentionPicker(store: store); presentPopover(controller, from: mentionsButton) }
    private func openActivity() { guard ready else { return }; let controller = UIKitDiscussionActivityController(store: store); presentPopover(controller, from: activityButton) }
    private func presentPopover(_ controller: UIViewController, from anchor: UIView) { controller.modalPresentationStyle = .popover; controller.popoverPresentationController?.sourceView = anchor; controller.popoverPresentationController?.sourceRect = anchor.bounds; present(controller, animated: true) }
    private func mentionName(_ id: String) -> String { id == store.account?.id ? store.account?.name ?? "You" : store.discussionMemberName(id) }
    private func scrollToCurrentMessage() {
        let index = visibleMessages.firstIndex { $0.id == store.discussionFocusedMessageID } ?? (visibleMessages.isEmpty ? nil : visibleMessages.count - 1)
        if let index { table.scrollToRow(at: IndexPath(row: index, section: 0), at: store.discussionFocusedMessageID == nil ? .bottom : .middle, animated: true) }
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visibleMessages.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "message", for: indexPath) as! DiscussionMessageCell
        let message = visibleMessages[indexPath.row], key = store.discussionDraftKey, navigation = store.navigationContext
        cell.configure(message: message, store: store, focused: store.discussionFocusedMessageID == message.id,
                       reply: { [weak self] in guard let self, store.discussionDraftKey == key, store.navigationContext == navigation else { return }; store.discussionReplyToID = message.id; composer.becomeFirstResponder() },
                       openAttachment: { [weak self] id in guard let self, store.navigationContext == navigation else { return }; store.loadDiscussion(itemId: id) })
        return cell
    }
    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system); button.setImage(UIImage(systemName: symbol), for: .normal); button.tintColor = ScrivUIKitTheme.accent; button.accessibilityLabel = title
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true; button.heightAnchor.constraint(equalToConstant: 28).isActive = true; button.addAction(UIAction { _ in action() }, for: .touchUpInside); return button
    }
    private func emptyConversation() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "bubble.left")); icon.tintColor = ScrivUIKitTheme.secondary; icon.contentMode = .scaleAspectFit; icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let title = ScrivUIKitTheme.label(onlyMentions ? "No mentions here" : "No comments yet", size: 13, weight: .semibold); title.textAlignment = .center
        let detail = ScrivUIKitTheme.label(onlyMentions ? "Messages mentioning you will appear here." : "Start a conversation about this " + (store.discussionItemID == nil ? "project." : "item."), size: 11, color: ScrivUIKitTheme.secondary); detail.textAlignment = .center
        let stack = ScrivUIKitTheme.stack([icon, title, detail], spacing: 7), container = UIView(); container.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: container.centerYAnchor), stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12)])
        return container
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); refreshTask?.cancel() }
    private func centeredMessage(_ text: String) -> UIView { let label = ScrivUIKitTheme.label(text, size: 12, color: ScrivUIKitTheme.secondary); label.textAlignment = .center; let container = UIView(); container.addSubview(label); label.scrivPinEdges(to: container, insets: NSDirectionalEdgeInsets(top: 20, leading: 14, bottom: 20, trailing: 14)); return container }
}

private final class DiscussionComposerTextView: UITextView {
    var sendMessage: (() -> Void)?
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(send))] }
    @objc private func send() { sendMessage?() }
}
