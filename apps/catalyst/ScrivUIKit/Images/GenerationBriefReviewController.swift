import UIKit
import Combine
import ScrivCore

/// Read-only review of one captured cue, source and identity selection. Closing
/// this sheet cannot generate, save, rebase, discard or change a script/tag.
@MainActor final class GenerationBriefReviewController: UIViewController {
    let snapshot: GenerationBriefSnapshot
    private let store: WorkspaceStore?
    private let originalNavigation: Int
    private let originalScope: String
    private let originalSceneID: String
    private let originalCue: ImageCue?
    private let originalImage: ImageAsset?
    private var subscription: AnyCancellable?
    private(set) var reviewView: GenerationBriefReviewView!

    init(store: WorkspaceStore, context: GenerationContext) {
        self.store = store; originalNavigation = store.navigationContext
        var urls: [String: URL] = [:]
        for person in context.characters {
            if let asset = store.project.asset(person.portraitImageId), let url = store.assetURL(asset) { urls[asset.id] = url }
        }
        snapshot = GenerationBriefSnapshot(context: context, localPortraitURLs: urls)
        originalScope = store.generationPromptScopeKey
        originalSceneID = store.selectedSceneID
        let cue = store.project.cues.first { $0.id == context.cueID }
        originalCue = cue; originalImage = store.project.asset(cue?.imageId)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        preferredContentSize = GenerationReviewUI.preferredSize
    }
    /// The same real controller can render an immutable snapshot without a live
    /// workspace, enabling native first-load/layout tests without disk mutation.
    init(snapshot: GenerationBriefSnapshot) {
        self.snapshot = snapshot; store = nil; originalNavigation = 0
        originalScope = ""; originalSceneID = ""; originalCue = nil; originalImage = nil
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet; preferredContentSize = GenerationReviewUI.preferredSize
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(store:context:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        reviewView = GenerationBriefReviewView(snapshot: snapshot, onClose: { [weak self] in self?.dismiss(animated: true) }, onCopy: { [weak self] text in
            guard let self, self.reviewIsCurrent else { self?.reviewView.invalidate(); return }
            UIPasteboard.general.string = text
        })
        view.addSubview(reviewView); reviewView.scrivPinEdges(to: view)
        if let store {
            subscription = store.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.storeDidChange() } }
        }
        storeDidChange()
    }
    var reviewIsCurrent: Bool {
        guard let store else { return true }
        return store.navigationContext == originalNavigation && store.generationPromptScopeKey == originalScope && store.selectedSceneID == originalSceneID &&
        store.project.cues.first(where: { $0.id == snapshot.context.cueID }) == originalCue &&
        store.project.asset(originalCue?.imageId) == originalImage && store.selectedImageGenerationContext == snapshot.context
    }
    func storeDidChange() {
        guard isViewLoaded, reviewView != nil else { return }
        // Never silently turn an open review into a different cue's request, or
        // let stale Copy expose the previous account/project after navigation.
        if !reviewIsCurrent { reviewView.invalidate() }
    }
}

/// The same bounded header/body/footer hierarchy serves all three tabs. No
/// preferred-content-size changes, nested sheet, or inline workspace payload.
@MainActor final class GenerationBriefReviewView: UIView {
    enum Tab: Int, CaseIterable { case source, people, exactRequest }
    let snapshot: GenerationBriefSnapshot
    let header = ImageUI.stack(spacing: 10)
    let tabs = UISegmentedControl(items: ["Source", "People", "Exact request"])
    let scroll = UIScrollView()
    let body = ImageUI.stack(spacing: 18)
    let footer = ImageUI.stack(spacing: 10)
    let done: UIButton
    let exactText = UITextView()
    private let exactContainer = UIView()
    private let pictureLabel = ImageUI.label(size: 20, secondary: true)
    private let sceneLabel = ImageUI.label(size: 15, secondary: true)
    private let unavailable = ImageUI.label("The source or project changed while this review was open. Close it and choose Review brief again.", size: 17, secondary: true)
    private let onCopy: (String) -> Void
    private var expandedPeople = Set<String>()
    private var peopleHeaders: [String: UIButton] = [:]
    private(set) var selectedTab: Tab = .source
    private(set) var isValid = true

    init(snapshot: GenerationBriefSnapshot, onClose: @escaping () -> Void, onCopy: @escaping (String) -> Void) {
        self.snapshot = snapshot; self.onCopy = onCopy
        done = GenerationReviewUI.button("Done", primary: true, action: onClose)
        super.init(frame: .zero)
        expandedPeople = Set(snapshot.context.characters.prefix(1).map(\.id))
        backgroundColor = ScrivUIKitTheme.panel
        accessibilityIdentifier = "generation-brief-review"
        let close = GenerationReviewUI.button("", symbol: "xmark", action: onClose)
        close.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        close.accessibilityLabel = "Close image brief review"
        close.widthAnchor.constraint(equalToConstant: 42).isActive = true
        close.heightAnchor.constraint(equalToConstant: 42).isActive = true
        header.addArrangedSubview(ImageUI.row([ImageUI.label("Review image brief", size: 32, weight: .semibold), ImageUI.spacer(), close]))
        pictureLabel.text = snapshot.pictureTitle + " · Current picture"
        sceneLabel.text = snapshot.context.sceneTitle + " · " + snapshot.interval
        header.addArrangedSubview(pictureLabel); header.addArrangedSubview(sceneLabel)
        tabs.selectedSegmentIndex = Tab.source.rawValue
        tabs.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 17)], for: .normal)
        tabs.selectedSegmentTintColor = ImageUI.accent.withAlphaComponent(0.12)
        tabs.setTitleTextAttributes([.foregroundColor: ImageUI.accent], for: .selected)
        tabs.heightAnchor.constraint(equalToConstant: 42).isActive = true
        tabs.accessibilityIdentifier = "generation-review-tabs"
        tabs.addAction(UIAction { [weak self] _ in guard let self, let tab = Tab(rawValue: self.tabs.selectedSegmentIndex) else { return }; self.select(tab) }, for: .valueChanged)
        header.addArrangedSubview(tabs)
        header.addArrangedSubview(ImageUI.divider())

        done.accessibilityIdentifier = "generation-review-done"
        done.widthAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true
        footer.addArrangedSubview(ImageUI.divider())
        let footerRow = ImageUI.row([GenerationReviewUI.caption("Review only. Your script stays unchanged."), ImageUI.spacer(), done])
        footer.addArrangedSubview(footerRow)
        [header, scroll, exactContainer, unavailable, footer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        body.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(body)
        scroll.alwaysBounceVertical = true; scroll.keyboardDismissMode = .interactive
        scroll.accessibilityIdentifier = "generation-review-scroll"
        let safe = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safe.topAnchor, constant: 22), header.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24), header.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            footer.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24), footer.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24), footer.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12), scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16), body.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24), body.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24), body.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            exactContainer.topAnchor.constraint(equalTo: scroll.topAnchor), exactContainer.bottomAnchor.constraint(equalTo: scroll.bottomAnchor), exactContainer.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24), exactContainer.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24),
            unavailable.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 14), unavailable.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24), unavailable.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -24)
        ])
        buildExactRequest()
        unavailable.isHidden = true
        select(.source)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(snapshot:)") }

    func select(_ tab: Tab) {
        guard isValid else { return }
        selectedTab = tab; tabs.selectedSegmentIndex = tab.rawValue
        exactContainer.isHidden = tab != .exactRequest; scroll.isHidden = tab == .exactRequest
        peopleHeaders.removeAll()
        ImageUI.clear(body)
        switch tab {
        case .source: buildSource()
        case .people: buildPeople()
        case .exactRequest: break
        }
        scroll.setContentOffset(.zero, animated: false)
    }
    func showPerson(_ id: String) {
        guard isValid, snapshot.context.characters.contains(where: { $0.id == id }) else { return }
        let alreadyExpanded = expandedPeople.contains(id)
        expandedPeople.insert(id)
        if selectedTab != .people || !alreadyExpanded { select(.people) }
        guard let target = peopleHeaders[id] else { return }
        // The source link names a particular identity. Finish the new tab's
        // layout before revealing its header, not the bottom of a long profile.
        // Repeated links, tab changes and invalidation retire the old view.
        DispatchQueue.main.async { [weak self, weak target] in
            guard let self, let target, self.isValid, self.selectedTab == .people,
                  self.peopleHeaders[id] === target else { return }
            self.layoutIfNeeded(); self.scroll.layoutIfNeeded()
            let header = target.convert(target.bounds, to: self.scroll)
            guard header.height > 0, self.scroll.bounds.height > 0 else { return }
            let destination = CGRect(x: header.minX, y: max(0, header.minY - 12), width: header.width,
                                     height: min(header.height + 24, self.scroll.bounds.height))
            self.scroll.scrollRectToVisible(destination, animated: false)
        }
    }
    func togglePerson(_ id: String) {
        guard isValid, selectedTab == .people, snapshot.context.characters.contains(where: { $0.id == id }) else { return }
        if !expandedPeople.insert(id).inserted { expandedPeople.remove(id) }
        let offset = scroll.contentOffset
        peopleHeaders.removeAll()
        ImageUI.clear(body); buildPeople(); layoutIfNeeded()
        scroll.setContentOffset(CGPoint(x: 0, y: min(offset.y, max(0, scroll.contentSize.height - scroll.bounds.height))), animated: false)
    }
    func invalidate() {
        guard isValid else { return }; isValid = false
        peopleHeaders.removeAll()
        ImageUI.clear(body); exactText.text = nil
        pictureLabel.text = "Review unavailable"; sceneLabel.text = nil
        scroll.isHidden = true; exactContainer.isHidden = true; unavailable.isHidden = false; tabs.isEnabled = false
    }
    private func buildSource() {
        body.addArrangedSubview(GenerationReviewUI.heading("Script source"))
        if snapshot.context.passages.isEmpty { body.addArrangedSubview(GenerationReviewUI.caption("No authored dialogue or active direction overlaps this picture.")) }
        for passage in snapshot.context.passages {
            let color: UIColor = passage.kind == .direction ? .systemPurple : ImageUI.accent
            let dot = UIView(); dot.backgroundColor = color; dot.layer.cornerRadius = 7
            dot.widthAnchor.constraint(equalToConstant: 14).isActive = true; dot.heightAnchor.constraint(equalToConstant: 14).isActive = true
            let speaker = passage.speakerID.flatMap { id in snapshot.context.characters.first { $0.id == id } }?.name
            let kind = passage.kind == .direction ? "Direction" : speaker.map { "Dialogue · " + $0 } ?? "Dialogue"
            let time = GenerationReviewUI.caption("\(ScrivFormat.time(passage.startMs)) – \(ScrivFormat.time(passage.endMs))")
            let heading = ImageUI.row([dot, GenerationReviewUI.body(kind), ImageUI.spacer(), time], spacing: 8)
            let quote = ImageUI.text(passage.text, size: 18); quote.accessibilityIdentifier = "generation-source-" + passage.entryID
            quote.font = UIFont(name: "Georgia-Italic", size: 20) ?? .italicSystemFont(ofSize: 20)
            let content = ImageUI.stack([heading, quote], spacing: 12)
            if passage.text.isEmpty { content.addArrangedSubview(GenerationReviewUI.caption("No spoken word overlaps this part of the dialogue slot.")) }
            body.addArrangedSubview(ImageUI.card(content, padding: 16))
        }
        body.addArrangedSubview(ImageUI.divider())
        body.addArrangedSubview(GenerationReviewUI.heading("People & references"))
        if snapshot.context.characters.isEmpty { body.addArrangedSubview(GenerationReviewUI.caption("No character identities are resolved for this picture.")) }
        for person in snapshot.context.characters {
            let button = GenerationReviewUI.personHeader(person, snapshot: snapshot, symbol: "chevron.right") { [weak self] in
                self?.showPerson(person.id)
            }
            button.accessibilityIdentifier = "generation-source-person-" + person.id
            let info = ImageUI.stack([button], spacing: 3)
            if snapshot.referenceNumber(for: person.id) == nil { info.addArrangedSubview(GenerationReviewUI.caption(snapshot.portraitAvailability(for: person))) }
            body.addArrangedSubview(ImageUI.card(ImageUI.row([GenerationReviewUI.avatar(person, snapshot: snapshot, size: 52), info]), padding: 12))
            body.addArrangedSubview(GenerationReviewUI.caption("Included because: " + snapshot.reasons(for: person.id).joined(separator: "; ")))
        }
        body.addArrangedSubview(ImageUI.divider())
        body.addArrangedSubview(GenerationReviewUI.heading("Image direction · this picture only"))
        body.addArrangedSubview(ImageUI.card(ImageUI.text(snapshot.context.userDirection.isEmpty ? "Follow the script." : snapshot.context.userDirection, size: 17)))
        body.addArrangedSubview(GenerationReviewUI.caption(snapshot.context.userDirection.isEmpty ? "No visual override. Your script is unchanged." : "A visual override. Your script is unchanged."))
        body.addArrangedSubview(GenerationReviewUI.caption("Current preflight review. The final request is captured when generation starts."))
        body.addArrangedSubview(GenerationReviewUI.caption(GenerationBriefSnapshot.storageDisclosure))
    }
    private func buildPeople() {
        body.addArrangedSubview(ImageUI.notice("Identity references, not a cast list. People need not appear on screen."))
        body.addArrangedSubview(GenerationReviewUI.heading("People included in this request"))
        if snapshot.context.characters.isEmpty { body.addArrangedSubview(GenerationReviewUI.caption("No character identities are resolved for this picture. Unrelated profiles are not included.")) }
        for person in snapshot.context.characters {
            let expanded = expandedPeople.contains(person.id)
            let toggle = GenerationReviewUI.personHeader(person, snapshot: snapshot, symbol: expanded ? "chevron.up" : "chevron.down") { [weak self] in self?.togglePerson(person.id) }
            toggle.accessibilityIdentifier = "generation-person-" + person.id
            toggle.accessibilityValue = expanded ? "Expanded" : "Collapsed"
            peopleHeaders[person.id] = toggle
            toggle.contentHorizontalAlignment = .leading
            let details = ImageUI.stack([toggle], spacing: 5)
            if expanded {
                if snapshot.referenceNumber(for: person.id) == nil { details.addArrangedSubview(GenerationReviewUI.caption(snapshot.portraitAvailability(for: person))) }
                details.addArrangedSubview(GenerationReviewUI.caption("Included because"))
                for reason in snapshot.reasons(for: person.id) { details.addArrangedSubview(GenerationReviewUI.body("• " + reason)) }
            } else {
                var summary = snapshot.reasons(for: person.id)
                if snapshot.referenceNumber(for: person.id) == nil { summary.append(snapshot.portraitAvailability(for: person)) }
                details.addArrangedSubview(GenerationReviewUI.caption(summary.joined(separator: " · ")))
            }
            let top = ImageUI.row([GenerationReviewUI.avatar(person, snapshot: snapshot, size: expanded ? 100 : 58), details], spacing: 16); top.alignment = .top
            let content = ImageUI.stack([top], spacing: 14)
            if expanded {
                content.addArrangedSubview(ImageUI.divider())
                let profile = ImageUI.stack([
                    profileRow("Also called", person.aliases.isEmpty ? "No aliases saved." : person.aliases.joined(separator: ", ")),
                    ImageUI.divider(),
                    profileRow("Appearance", person.appearance.isEmpty ? "No appearance saved." : person.appearance),
                    ImageUI.divider(),
                    profileRow("Background", person.biography.isEmpty ? "No background saved." : person.biography, note: "Identity background, not a new scene event.")
                ], spacing: 0)
                profile.accessibilityIdentifier = "generation-profile-grid-" + person.id
                content.addArrangedSubview(profile)
            }
            body.addArrangedSubview(ImageUI.card(content, padding: expanded ? 16 : 12))
        }
        body.addArrangedSubview(ImageUI.divider())
        body.addArrangedSubview(GenerationReviewUI.heading("Portrait inputs · \(snapshot.context.portraits.count) attached · up to 5"))
        for (index, portrait) in snapshot.context.portraits.enumerated() {
            let people = portrait.characterIDs.compactMap { id in snapshot.context.characters.first { $0.id == id } }
            var row: [UIView] = [GenerationReviewUI.body("\(index + 1)")]
            if let first = people.first { row.append(GenerationReviewUI.avatar(first, snapshot: snapshot, size: 58)) }
            row.append(GenerationReviewUI.body(people.map(\.name).joined(separator: ", ")))
            body.addArrangedSubview(ImageUI.card(ImageUI.row(row), padding: 12))
        }
        if snapshot.context.portraits.isEmpty { body.addArrangedSubview(GenerationReviewUI.caption("No local portrait images are attached. Use text identity only.")) }
        if !snapshot.context.unreferencedCharacters.isEmpty { body.addArrangedSubview(GenerationReviewUI.caption("Without an attached portrait, saved names, aliases and profiles stay included. No substitute image is attached.")) }
        body.addArrangedSubview(GenerationReviewUI.caption("Only available local portraits are attached. Identical image bytes are sent once."))
        body.addArrangedSubview(GenerationReviewUI.button("View exact request…") { [weak self] in self?.select(.exactRequest) })
        body.addArrangedSubview(GenerationReviewUI.caption(GenerationBriefSnapshot.storageDisclosure))
    }
    private func profileRow(_ label: String, _ value: String, note: String? = nil) -> UIView {
        let title = GenerationReviewUI.caption(label); title.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let details = ImageUI.stack([ImageUI.text(value, size: 17)], spacing: 4)
        if let note { details.addArrangedSubview(GenerationReviewUI.caption(note)) }
        let row = ImageUI.row([title, details], spacing: 12); row.alignment = .top
        let padded = UIView(); padded.addSubview(row)
        row.scrivPinEdges(to: padded, insets: .init(top: 4, leading: 0, bottom: 4, trailing: 0))
        return padded
    }
    private func buildExactRequest() {
        exactText.text = snapshot.exactRequest
        exactText.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        exactText.textColor = ScrivUIKitTheme.ink; exactText.backgroundColor = ScrivUIKitTheme.inset
        exactText.layer.cornerRadius = 10; exactText.layer.borderWidth = 0.5; exactText.layer.borderColor = ScrivUIKitTheme.hairline.cgColor
        exactText.textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        exactText.isEditable = false; exactText.isSelectable = true; exactText.isScrollEnabled = true
        exactText.accessibilityIdentifier = "generation-exact-request"
        let copy = GenerationReviewUI.button("Copy full request") { [weak self] in guard let self, self.isValid else { return }; self.onCopy(self.snapshot.exactRequest) }
        copy.accessibilityIdentifier = "generation-copy-full-request"
        exactText.accessibilityHint = "Complete source, identity and technical instructions. Nothing is truncated. Captured historical requests remain in image details and generation history."
        let stack = ImageUI.stack([GenerationReviewUI.heading("Exact request"), GenerationReviewUI.caption("Current preflight request · read-only"), exactText, copy], spacing: 10)
        exactContainer.addSubview(stack); stack.scrivPinEdges(to: exactContainer)
        exactText.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
}
