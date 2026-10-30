import UIKit
import Combine
import ScrivCore

@MainActor
final class ScriptScreenController: ScrivScreenController, UITextFieldDelegate {
    private let scroll = UIScrollView()
    private let content = UIView()
    private let rowsStack = ScrivUIKitTheme.stack([], spacing: 23)
    private let searchField = UISearchTextField()
    private let searchRow = ScrivUIKitTheme.stack([], axis: .horizontal, spacing: 7)
    private let matchLabel = ScrivUIKitTheme.label("", size: 11, color: ScrivUIKitTheme.secondary, lines: 1)
    private let sceneButton = UIButton(type: .system)
    private let presence = ScrivUIKitTheme.stack([], axis: .horizontal, spacing: -5)
    private let footerLabel = ScrivUIKitTheme.label("", size: 11, color: ScrivUIKitTheme.secondary, lines: 1)
    private let statusDot = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    private let followSwitch = UISwitch()
    private let zoomButton = UIButton(type: .system)
    private var rows: [String: ScriptEntryRow] = [:]
    private var renderedIDs: [String] = []
    private var searchIndex = 0
    private var previousScene = ""
    private var previousSelected: String?
    private var recovery: RecoveredDraftController?
    private var lastRecoverySessionID: UUID?
    private let session: ScriptDraftSession
    private let rails: ScriptDirectionRails
    private var sessionRefreshQueued = false
    private var finishObserver: NSObjectProtocol?
    private var addBar: UIView!
    private var emptyState: UIView!
    private var pendingCaret: (entryID: String, offset: Int, navigation: Int, afterWordID: String?)?
    private var rememberedCaret: [String: Int] = [:]
    private var playbackCaret: (entryID: String, offset: Int, navigation: Int)?
    private var playbackContext: (navigation: Int, sceneID: String)?
    private var boundaryPending: String?
    private var boundaryTask: Task<Void, Never>?
    private var scrubbers: [String: ScriptDurationScrubDriver] = [:]
    override var canBecomeFirstResponder: Bool { true }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(scrivToggleScriptEditing(_:)) { return viewIfLoaded?.window != nil && presentedViewController == nil && (session.active || store.selectedEntryID != nil) }
        return super.canPerformAction(action, withSender: sender)
    }
    @objc func scrivToggleScriptEditing(_ sender: Any?) {
        guard presentedViewController == nil, boundaryPending == nil else { return }
        if session.active { if session.finish() { view.endEditing(true); becomeFirstResponder() } }
        else if let id = store.selectedEntryID { beginEditing(id, caret: rememberedCaret[id] ?? 0) }
    }
    private func beginEditing(_ id: String, caret: Int, preservingPlayhead: Bool = false, afterWordID: String? = nil) {
        guard boundaryPending == nil else { return }
        pendingCaret = (id, caret, store.navigationContext, afterWordID)
        playbackCaret = (id, caret, store.navigationContext)
        let playhead = store.playheadMs
        store.selectEntry(id)
        if preservingPlayhead { store.seek(toMs: playhead) }
        session.begin(id); storeDidChange()
    }
    /// A child remains attached to its window beneath a sheet presented by the
    /// workspace. Playback stays global, but obscured script must not seek or
    /// reclaim the text responder behind that unrelated modal.
    private var scriptPlaybackSurfaceIsVisible: Bool {
        guard [.script, .characters].contains(store.tab),
              let view = viewIfLoaded, !view.isHidden,
              let root = view.window?.rootViewController,
              root.presentedViewController == nil else { return false }
        var controller: UIViewController? = self
        while let current = controller {
            guard current.presentedViewController == nil, !current.isBeingDismissed else { return false }
            controller = current.parent
        }
        return true
    }
    private func preparePlayback() -> Bool {
        guard scriptPlaybackSurfaceIsVisible else { playbackContext = nil; return true }
        guard boundaryPending == nil, session.finish() else { return false }
        playbackContext = (store.navigationContext, store.selectedSceneID)
        guard let caret = playbackCaret, caret.navigation == store.navigationContext,
              caret.entryID == store.selectedEntryID,
              let entry = store.project.entries.first(where: { $0.id == caret.entryID && $0.sceneId == store.selectedSceneID }) else { return true }
        let target = entry.words.first { word in
            guard let range = ScriptBoundaryEditing.utf16Range(ofWordID: word.id, in: entry) else { return false }
            return NSMaxRange(range) > caret.offset
        }
        // Stable word identity chooses the spoken word. Directions have no word
        // track; their exact source caret maps only within their own action slot.
        let offset = target?.startMs ?? ScriptBoundaryEditing.caretTime(in: entry, utf16Offset: caret.offset)
        store.seek(toMs: Double(store.project.startMs(of: entry.id) + offset))
        return true
    }
    private func restorePausedCaret() {
        guard scriptPlaybackSurfaceIsVisible else { playbackContext = nil; return }
        guard let context = playbackContext,
              context.navigation == store.navigationContext, context.sceneID == store.selectedSceneID else { return }
        let time = Int(store.playheadMs), words = TimingEngine.absoluteWords(store.project, sceneId: context.sceneID)
        let actual = words.first { $0.startMs <= time && time < $0.endMs } ?? words.last { $0.endMs <= time }
        guard let word = actual, let entry = store.sceneEntries.first(where: { $0.words.contains { $0.id == word.id } }),
              let range = ScriptBoundaryEditing.utf16Range(ofWordID: word.id, in: entry) else { return }
        beginEditing(entry.id, caret: NSMaxRange(range), preservingPlayhead: true, afterWordID: word.id)
        scrollTo(entry.id, animated: true)
    }
    private func splitEntry(_ id: String, offset: Int) { changeBoundary(id, splitOffset: offset) }
    private func mergeEntry(_ id: String) { changeBoundary(id, splitOffset: nil) }
    private func changeBoundary(_ id: String, splitOffset: Int?) {
        guard boundaryPending == nil, session.entryID == id, rows[id]?.editor.markedTextRange == nil else { return }
        let text = session.text, navigation = store.navigationContext, scene = store.selectedSceneID
        guard session.finish(), navigation == store.navigationContext,
              let original = store.project.entries.first(where: { $0.id == id }) else { return }
        let sequence = store.sceneEntries
        let position = sequence.firstIndex { $0.id == id }
        let previous = splitOffset == nil ? position.flatMap { $0 > 0 ? sequence[$0 - 1] : nil } : nil
        boundaryPending = id; storeDidChange()
        boundaryTask = Task { [weak self] in
            guard let self else { return }
            var acquired: [String] = []
            defer { acquired.forEach { store.endEdit($0, context: navigation) }; boundaryPending = nil; queueSessionRefresh() }
            for target in [id, previous?.id].compactMap({ $0 }) {
                guard !Task.isCancelled, navigation == store.navigationContext, scene == store.selectedSceneID else { return }
                guard await store.beginEdit(target) else { return }; acquired.append(target)
            }
            guard !Task.isCancelled, navigation == store.navigationContext, scene == store.selectedSceneID,
                  let current = store.project.entries.first(where: { $0.id == id }), current == original,
                  current.text.utf16.elementsEqual(text.utf16), previous.map({ old in store.project.entries.contains { $0 == old && $0.text.utf16.elementsEqual(old.text.utf16) } }) ?? true else {
                if navigation == store.navigationContext { store.errorMessage = "These lines changed while acquiring editing access. No boundary was changed." }
                return
            }
            let result: (entryID: String, caret: Int)?
            if let offset = splitOffset {
                result = store.splitScriptEntry(entryID: id, atUTF16Offset: offset, expectedText: text).map { ($0, 0) }
            } else { result = store.mergeScriptEntryIntoPrevious(entryID: id, expectedText: text).map { ($0.entryID, $0.caretUTF16Offset) } }
            acquired.forEach { store.endEdit($0, context: navigation) }; acquired = []
            boundaryPending = nil; store.requestedEntryEditingID = nil
            if let result { beginEditing(result.entryID, caret: result.caret) }
            else { beginEditing(id, caret: splitOffset ?? 0) }
        }
    }

    init(store: WorkspaceStore) {
        session = ScriptDraftSession(store: store); rails = ScriptDirectionRails(store: store)
        super.init(store: store, scopeToProject: false)
        title = "Script"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    deinit { if let finishObserver { NotificationCenter.default.removeObserver(finishObserver) } }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.layer.cornerRadius = 17; view.clipsToBounds = true
        let icon = UIImageView(image: UIImage(systemName: "doc.text")); icon.tintColor = ScrivUIKitTheme.accent; icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 34).isActive = true; icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        sceneButton.titleLabel?.font = .systemFont(ofSize: 12); sceneButton.contentHorizontalAlignment = .leading; sceneButton.showsMenuAsPrimaryAction = true
        let titleLine = ScrivUIKitTheme.stack([ScrivUIKitTheme.label("Script", size: 23, weight: .semibold), presence], axis: .horizontal, spacing: 10); titleLine.alignment = .center
        let titleStack = ScrivUIKitTheme.stack([titleLine, sceneButton], spacing: 3)
        let search = ScrivUIKitTheme.button("Find", symbol: "magnifyingglass") { [weak self] in self?.toggleSearch() }
        let history = ScrivUIKitTheme.button("History", symbol: "clock.arrow.circlepath") { [weak self] in self?.show(.history) }
        let header = ScrivUIKitTheme.stack([icon, titleStack, UIView(), search, history], axis: .horizontal, spacing: 12); header.alignment = .top
        searchField.placeholder = "Find in script"; searchField.delegate = self; searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        searchRow.addArrangedSubview(searchField); searchRow.addArrangedSubview(matchLabel)
        searchRow.addArrangedSubview(ScrivUIKitTheme.button("Previous", symbol: "chevron.up") { [weak self] in self?.advanceSearch(-1) })
        searchRow.addArrangedSubview(ScrivUIKitTheme.button("Next", symbol: "chevron.down") { [weak self] in self?.advanceSearch(1) })
        searchRow.addArrangedSubview(ScrivUIKitTheme.button("Close", symbol: "xmark") { [weak self] in self?.toggleSearch() })
        searchRow.isHidden = true
        let top = ScrivUIKitTheme.stack([header, searchRow], spacing: 12)
        let topContainer = UIView(); topContainer.addSubview(top); top.scrivPinEdges(to: topContainer, insets: NSDirectionalEdgeInsets(top: 17, leading: 18, bottom: 12, trailing: 18))
        let footer = makeFooter()
        let root = ScrivUIKitTheme.stack([topContainer, separator(), scroll, footer], spacing: 0)
        view.addSubview(root); root.scrivPinEdges(to: view)
        scroll.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        content.addSubview(rowsStack); rowsStack.scrivPinEdges(to: content, insets: NSDirectionalEdgeInsets(top: 20, leading: 14, bottom: 20, trailing: 14))
        content.addSubview(rails); rails.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([rails.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), rails.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), rails.topAnchor.constraint(equalTo: content.topAnchor), rails.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        scroll.keyboardDismissMode = .interactive; scroll.delaysContentTouches = false
        addBar = makeAddBar(); emptyState = makeEmptyState()
        store.prepareScriptPlayback = { [weak self] in self?.preparePlayback() ?? true }
        store.didPauseScriptPlayback = { [weak self] in self?.restorePausedCaret() }
        session.changes.sink { [weak self] in self?.queueSessionRefresh() }.store(in: &subscriptions)
        finishObserver = NotificationCenter.default.addObserver(forName: .scrivFinishEditing, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.session.finish(); self?.view.endEditing(true) }
        }
        storeDidChange()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        var frames: [String: CGRect] = [:]
        for (id, row) in rows { var frame = row.convert(row.bounds, to: content); frame.origin.x -= 14; frames[id] = frame }
        rails.update(entries: store.sceneEntries, frames: frames)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || isMovingFromParent { if !session.finish() { session.keepForLater() }; session.cancelAcquisition(); boundaryTask?.cancel(); scrubbers.values.forEach { $0.cancel() } }
    }
    override func storeDidChange() {
        guard isViewLoaded else { return }
        session.contextDidChange()
        let entries = store.sceneEntries, ids = entries.map(\.id)
        if ids != renderedIDs {
            for id in Array(rows.keys) where !ids.contains(id) { rows.removeValue(forKey: id)?.removeFromSuperview(); scrubbers.removeValue(forKey: id)?.cancel() }
            for entry in entries where rows[entry.id] == nil { rows[entry.id] = makeRow(entry.id) }
            for child in rowsStack.arrangedSubviews { rowsStack.removeArrangedSubview(child); child.removeFromSuperview() }
            if entries.isEmpty { rowsStack.addArrangedSubview(emptyState) }
            else { for id in ids { if let row = rows[id] { rowsStack.addArrangedSubview(row) } }; rowsStack.addArrangedSubview(addBar) }
            renderedIDs = ids
        } else if rowsStack.arrangedSubviews.isEmpty { rowsStack.addArrangedSubview(emptyState) }
        let search = searchField.text ?? ""
        for entry in entries {
            guard let row = rows[entry.id] else { continue }
            let selected = store.selectedEntryID == entry.id
            let start = store.project.startMs(of: entry.id)
            let active = store.isPlaying && Int(store.playheadMs) >= start && Int(store.playheadMs) < start + entry.ownedDurationMs
            row.configure(entry: entry, project: store.project, selected: selected, active: active, search: search, currentWordID: store.currentWordID, peers: store.peers.filter { $0.itemId == entry.id }, locked: store.lockedByOther(entry.id) != nil, speakerMenu: speakerMenu(entry), fontSize: store.scriptFontSize)
            let request = pendingCaret.flatMap { $0.entryID == entry.id && $0.navigation == store.navigationContext && session.entryID == entry.id ? $0 : nil }
            let caret = request.flatMap { request -> Int? in
                if let wordID = request.afterWordID { return ScriptBoundaryEditing.utf16Range(ofWordID: wordID, in: entry).map(NSMaxRange) }
                return request.offset
            }
            row.setEditing(session.entryID == entry.id, text: session.text, focus: !session.requiresReview && scriptPlaybackSurfaceIsVisible && (request?.afterWordID == nil || caret != nil), caret: caret)
            if request != nil { pendingCaret = nil }
            scrubbers[entry.id]?.refreshPreview()
            configureDetails(row, entry: entry, selected: selected)
        }
        sceneButton.setTitle((store.project.scenes.first { $0.id == store.selectedSceneID }?.title ?? "No scene") + " ⌄", for: .normal)
        sceneButton.menu = sceneMenu()
        for child in presence.arrangedSubviews { presence.removeArrangedSubview(child); child.removeFromSuperview() }
        for (index, peer) in store.peers.prefix(4).enumerated() {
            let avatar = ScrivUIKitTheme.label(String(peer.name.prefix(1)).uppercased(), size: 10, weight: .semibold, color: .white, lines: 1)
            avatar.textAlignment = .center; avatar.backgroundColor = [UIColor.systemBlue, .systemGreen, .systemPurple, .systemOrange][index % 4]; avatar.layer.cornerRadius = 11; avatar.clipsToBounds = true
            avatar.widthAnchor.constraint(equalToConstant: 22).isActive = true; avatar.heightAnchor.constraint(equalToConstant: 22).isActive = true; avatar.accessibilityLabel = peer.name; presence.addArrangedSubview(avatar)
        }
        presence.isHidden = store.peers.isEmpty
        footerLabel.text = "\(store.project.authoredEntryCount(in: store.selectedSceneID)) entries · \(ScrivFormat.duration(store.sceneDurationMs))"
        followSwitch.isOn = store.followPlayback
        zoomButton.setTitle("\(Int((store.scriptZoom * 100).rounded()))% ⌄", for: .normal)
        zoomButton.accessibilityLabel = "Shared script zoom, \(Int((store.scriptZoom * 100).rounded())) percent"
        zoomButton.menu = UIMenu(title: "Script text size · shared across views", children: [0.7, 0.85, 1.0, 1.15, 1.3, 1.5, 2.0].map { zoom in
            UIAction(title: "\(Int((zoom * 100).rounded()))%" + (zoom == 1 ? " · Default" : ""), state: abs(store.scriptZoom - zoom) < 0.001 ? .on : .off) { [weak self] _ in self?.store.setScriptZoom(zoom) }
        })
        statusDot.tintColor = store.statusMessage == "Save failed" ? .systemRed : store.hasConflicts ? .systemOrange : .systemGreen
        statusDot.accessibilityLabel = store.statusMessage + (store.hasConflicts ? " · Cloud changes need review" : "")
        updateMatchLabel()
        view.setNeedsLayout()
        if previousScene != store.selectedSceneID {
            previousScene = store.selectedSceneID
            DispatchQueue.main.async { [weak self] in if let id = self?.store.selectedEntryID { self?.scrollTo(id, animated: false) } }
        } else if previousSelected != store.selectedEntryID, store.isPlaying, store.followPlayback, let id = store.selectedEntryID { scrollTo(id, animated: true) }
        previousSelected = store.selectedEntryID
        if let id = store.requestedEntryEditingID, rows[id] != nil {
            store.requestedEntryEditingID = nil; beginEditing(id, caret: 0); scrollTo(id, animated: true)
        }
        if session.requiresReview, session.active, session.record != nil, lastRecoverySessionID != session.sessionID, presentedViewController == nil {
            lastRecoverySessionID = session.sessionID
            let controller = RecoveredDraftController(store: store, session: session)
            controller.onEditDraft = { [weak self] in guard let self, let id = session.entryID else { return }; rows[id]?.editor.becomeFirstResponder() }
            recovery = controller; controller.modalPresentationStyle = .formSheet; present(controller, animated: true)
        }
    }
    private func queueSessionRefresh() {
        guard !sessionRefreshQueued else { return }; sessionRefreshQueued = true
        DispatchQueue.main.async { [weak self] in guard let self else { return }; sessionRefreshQueued = false; storeDidChange() }
    }
    private func makeRow(_ id: String) -> ScriptEntryRow {
        let row = ScriptEntryRow(entryID: id)
        row.onSelect = { [weak self] in self?.store.selectEntry(id) }
        row.onEdit = { [weak self] offset in self?.beginEditing(id, caret: offset) }
        row.onSplit = { [weak self] offset in self?.splitEntry(id, offset: offset) }
        row.editor.mergeAtStart = { [weak self] in self?.mergeEntry(id) }
        scrubbers[id] = ScriptDurationScrubDriver(button: row.durationButton, store: store, entryID: id, finishEditing: { [weak self] in guard let self else { return false }; playbackContext = nil; return session.finish() })
        row.onDuration = { [weak self] in self?.editDuration(id) }
        row.onCharacter = { [weak self] id in self?.store.selectCharacter(id) }
        row.onTextEdit = { [weak self] edit in guard let self, session.entryID == id else { return false }; return session.accept(edit) }
        row.onTextChange = { [weak self] text in guard let self, session.entryID == id else { return false }; return session.nativeTextDidChange(text) }
        row.onSelection = { [weak self] range in
            guard let self, session.entryID == id else { return }; rememberedCaret[id] = range.location
            playbackCaret = (id, range.location, store.navigationContext); session.selectionDidChange(range)
        }
        row.editor.finishEditing = { [weak self] in guard let self else { return }; if session.finish() { view.endEditing(true); becomeFirstResponder() } }
        row.editor.sizeChanged = { [weak self] in self?.view.setNeedsLayout() }
        row.menuProvider = { [weak self] in self?.entryMenu(id) ?? UIMenu(children: []) }
        return row
    }
    private func configureDetails(_ row: ScriptEntryRow, entry: ScriptEntry, selected: Bool) {
        for view in row.details.arrangedSubviews { row.details.removeArrangedSubview(view); view.removeFromSuperview() }
        if boundaryPending == entry.id { row.details.addArrangedSubview(ScrivUIKitTheme.label("Changing line boundary…", size: 11, color: ScrivUIKitTheme.secondary)) }
        if session.entryID == entry.id {
            if let issue = session.issue { row.details.addArrangedSubview(ScrivUIKitTheme.notice("Draft not applied", message: issue, warning: true)) }
            if session.requiresReview {
                row.details.addArrangedSubview(ScrivUIKitTheme.notice(session.text.utf16.elementsEqual(entry.text.utf16) ? "Recovery copy saved on this Mac" : "Recovered draft · Not uploaded", message: "Review the current saved line beside your local draft before applying it.", warning: true))
            }
            let review = ScrivUIKitTheme.button("Review draft…") { [weak self] in self?.lastRecoverySessionID = nil; self?.session.review() }
            let finish = ScrivUIKitTheme.button(session.requiresReview || session.issue != nil ? "Keep for later" : "Finish") { [weak self] in
                guard let self else { return }; if session.requiresReview || session.issue != nil { session.keepForLater() } else { _ = session.finish() }
            }
            let controls = ScrivUIKitTheme.stack(session.pending ? [review, finish, UIView()] : [finish, UIView()], axis: .horizontal, spacing: 8)
            row.details.addArrangedSubview(controls)
        } else if selected {
            let suggestions = (entry.characterLinks ?? CharacterMentions.suggestions(in: entry.text, characters: store.project.characters)).filter { !$0.isConfirmed }.count
            if suggestions > 0 {
                row.details.addArrangedSubview(ScrivUIKitTheme.button("Review \(suggestions) character suggestion\(suggestions == 1 ? "" : "s")") { [weak self] in self?.reviewLinks(entry.id) })
            }
        }
        if selected && entry.kind == .direction { row.details.addArrangedSubview(ScrivUIKitTheme.label("Applies through \(ScrivFormat.time(store.project.startMs(of: entry.id) + entry.coverageDurationMs))", size: 11, color: ScrivUIKitTheme.color(entry.color))) }
        if let lock = store.lockedByOther(entry.id) { row.details.addArrangedSubview(ScrivUIKitTheme.label("\(lock) is editing", size: 11, color: ScrivUIKitTheme.accent)) }
        row.details.isHidden = row.details.arrangedSubviews.isEmpty
    }
    private func entryMenu(_ id: String) -> UIMenu {
        guard let entry = store.project.entries.first(where: { $0.id == id }) else { return UIMenu(children: []) }
        let locked = store.lockedByOther(id) != nil, context = store.navigationContext
        func action(_ title: String, _ symbol: String, edit: Bool = false, destructive: Bool = false, _ body: @escaping () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol), attributes: edit && locked ? [.disabled] : destructive ? [.destructive] : []) { [weak self] _ in guard let self, store.navigationContext == context else { return }; body() }
        }
        var actions: [UIMenuElement] = [
            action("Edit text", "pencil", edit: true) { [weak self] in self?.beginEditing(id, caret: self?.rememberedCaret[id] ?? 0) },
            action("Review character links…", "person.crop.rectangle", edit: true) { [weak self] in self?.reviewLinks(id) },
            action("Discuss this line", "bubble.left") { [weak self] in self?.store.loadDiscussion(itemId: id); self?.store.showDiscussion = true },
            action("Play from here", "play") { [weak self] in guard let self else { return }; playbackCaret = (id, 0, store.navigationContext); store.seek(toMs: Double(store.project.startMs(of: id))); if !store.isPlaying { store.togglePlayback() } }
        ]
        if entry.kind == .dialogue {
            actions.append(action("Import audio for this dialogue…", "waveform.badge.plus") { [weak self] in self?.store.importAudio(entryId: id) })
            actions.append(action("Review word timing…", "clock", edit: true) { [weak self] in self?.show(.wordTiming(entryID: id, wordIDs: [])) })
        }
        actions.append(UIMenu(options: .displayInline, children: [
            action("Move up", "arrow.up", edit: true) { [weak self] in self?.store.moveEntry(id, offset: -1) },
            action("Move down", "arrow.down", edit: true) { [weak self] in self?.store.moveEntry(id, offset: 1) },
            action("Delete entry", "trash", edit: true, destructive: true) { [weak self] in self?.confirmDeleteEntry(id) }
        ]))
        return UIMenu(children: actions)
    }
    private func reviewLinks(_ id: String) {
        guard session.finish(), let entry = store.project.entries.first(where: { $0.id == id }) else { return }
        let context = store.navigationContext
        let controller = CharacterLinksController(store: store, entry: entry, navigationContext: context)
        controller.modalPresentationStyle = .formSheet; present(controller, animated: true)
    }
    private func speakerMenu(_ entry: ScriptEntry) -> UIMenu {
        let context = store.navigationContext
        let choices = [UIAction(title: "No speaker", state: entry.characterId == nil ? .on : .off) { [weak self] _ in guard let self, store.navigationContext == context else { return }; store.setEntryCharacter(entry.id, characterId: nil) }] + store.project.characters.map { character in
            UIAction(title: character.name, state: entry.characterId == character.id ? .on : .off) { [weak self] _ in guard let self, store.navigationContext == context else { return }; store.setEntryCharacter(entry.id, characterId: character.id) }
        }
        return UIMenu(title: "Speaker", children: choices)
    }
    private func sceneMenu() -> UIMenu {
        let context = store.navigationContext
        let scenes = store.project.orderedScenes.map { scene in
            UIAction(title: scene.title, state: scene.id == store.selectedSceneID ? .on : .off) { [weak self] _ in guard let self, store.navigationContext == context else { return }; if !session.finish() { session.keepForLater() }; store.selectScene(scene.id) }
        }
        return UIMenu(children: scenes + [
            UIAction(title: "New scene", image: UIImage(systemName: "plus")) { [weak self] _ in guard let self, store.navigationContext == context else { return }; store.addScene() },
            UIAction(title: "Rename scene…") { [weak self] _ in guard let self, store.navigationContext == context else { return }; renameScene() },
            UIAction(title: "Delete scene…", attributes: .destructive) { [weak self] _ in guard let self, store.navigationContext == context else { return }; deleteScene() }
        ])
    }
    private func editDuration(_ id: String) {
        guard let entry = store.project.entries.first(where: { $0.id == id }), store.lockedByOther(id) == nil else { return }
        let context = store.navigationContext
        let alert = UIAlertController(title: "Owned duration", message: entry.kind == .direction ? "Adds time to this direction’s action slot. Coverage remains a separate source-owned extent." : "Sets this line’s owned time. Its words must fit within the duration.", preferredStyle: .alert)
        alert.addTextField { $0.text = String(format: "%.3f", Double(entry.ownedDurationMs) / 1000); $0.keyboardType = .decimalPad; $0.placeholder = "Seconds" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Apply", style: .default) { [weak self, weak alert] _ in
            guard let self, store.navigationContext == context, store.project.entries.first(where: { $0.id == id }) == entry else { self?.store.errorMessage = "The line changed. Reopen duration to review its current timing."; return }
            guard let number = Double(alert?.textFields?.first?.text ?? ""), number.isFinite, number >= 0, number <= 3600 else { store.errorMessage = "Enter a duration from zero to 3,600 seconds."; return }
            store.setDuration(id, seconds: number)
        })
        present(alert, animated: true)
    }
    private func confirmDeleteEntry(_ id: String) {
        let context = store.navigationContext
        confirm("Delete this entry?", message: "Its text and timing are removed as a new revision. Existing history remains available.") { [weak self] in guard let self, store.navigationContext == context else { return }; store.deleteEntry(id) }
    }
    private func renameScene() {
        guard let scene = store.project.scenes.first(where: { $0.id == store.selectedSceneID }) else { return }
        let context = store.navigationContext, alert = UIAlertController(title: "Rename scene", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = scene.title }; alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in guard let self, store.navigationContext == context, store.selectedSceneID == scene.id else { return }; store.updateSceneTitle(alert?.textFields?.first?.text ?? scene.title) })
        present(alert, animated: true)
    }
    private func deleteScene() {
        let id = store.selectedSceneID, context = store.navigationContext
        confirm("Delete this scene?", message: "The scene’s script and image placements are removed. Image assets and character profiles are kept.") { [weak self] in guard let self, store.navigationContext == context else { return }; store.deleteScene(id) }
    }
    private func confirm(_ title: String, message: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in action() }); present(alert, animated: true)
    }
    private func makeAddBar() -> UIView {
        let bar = ScrivUIKitTheme.stack([ScrivUIKitTheme.button("Dialogue", symbol: "plus") { [weak self] in self?.store.addEntry(kind: .dialogue) }, ScrivUIKitTheme.button("Direction", symbol: "arrow.turn.down.right") { [weak self] in self?.store.addEntry(kind: .direction) }, UIView()], axis: .horizontal, spacing: 12)
        let container = UIView(); container.addSubview(bar); bar.scrivPinEdges(to: container, insets: NSDirectionalEdgeInsets(top: 8, leading: 158, bottom: 0, trailing: 0)); return container
    }
    private func makeEmptyState() -> UIView {
        let title = ScrivUIKitTheme.label("Your story starts here", size: 27, weight: .semibold); title.textAlignment = .center
        let message = ScrivUIKitTheme.label("Write a first line, or bring in a script.", size: 17, color: ScrivUIKitTheme.secondary); message.textAlignment = .center
        let icon = UIImageView(image: UIImage(systemName: "doc.text")); icon.contentMode = .scaleAspectFit; icon.tintColor = ScrivUIKitTheme.secondary; icon.heightAnchor.constraint(equalToConstant: 66).isActive = true
        let buttons = ScrivUIKitTheme.stack([ScrivUIKitTheme.button("Add dialogue", primary: true) { [weak self] in self?.store.addEntry(kind: .dialogue) }, ScrivUIKitTheme.button("Add direction") { [weak self] in self?.store.addEntry(kind: .direction) }, ScrivUIKitTheme.button("Import script…") { [weak self] in self?.store.importScript() }], axis: .horizontal, spacing: 10)
        let hint = ScrivUIKitTheme.label("Fountain or plain text", size: 13, color: ScrivUIKitTheme.secondary); hint.textAlignment = .center
        let stack = ScrivUIKitTheme.stack([icon, title, message, buttons, hint], spacing: 24)
        let container = UIView(); container.addSubview(stack); stack.scrivPinEdges(to: container, insets: NSDirectionalEdgeInsets(top: 90, leading: 26, bottom: 90, trailing: 26)); return container
    }
    private func makeFooter() -> UIView {
        statusDot.contentMode = .scaleAspectFit; statusDot.widthAnchor.constraint(equalToConstant: 13).isActive = true
        followSwitch.transform = CGAffineTransform(scaleX: 0.7, y: 0.7); followSwitch.addTarget(self, action: #selector(followChanged), for: .valueChanged)
        zoomButton.titleLabel?.font = .systemFont(ofSize: 11); zoomButton.showsMenuAsPrimaryAction = true
        let row = ScrivUIKitTheme.stack([statusDot, footerLabel, UIView(), zoomButton, ScrivUIKitTheme.label("Follow playback", size: 12, color: ScrivUIKitTheme.secondary), followSwitch], axis: .horizontal, spacing: 10); row.alignment = .center
        let container = UIView(); container.addSubview(row); row.scrivPinEdges(to: container, insets: NSDirectionalEdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 12)); return container
    }
    @objc private func followChanged() { store.followPlayback = followSwitch.isOn }
    private func separator() -> UIView { let view = UIView(); view.backgroundColor = ScrivUIKitTheme.hairline; view.heightAnchor.constraint(equalToConstant: 0.5).isActive = true; return view }
    private var matches: [ScriptEntry] {
        let query = searchField.text ?? ""; guard !query.isEmpty else { return [] }
        return store.sceneEntries.filter { entry in entry.text.localizedCaseInsensitiveContains(query) || store.project.character(entry.characterId).map { ([$0.name] + $0.aliases).contains { $0.localizedCaseInsensitiveContains(query) } } == true }
    }
    private func toggleSearch() { searchRow.isHidden.toggle(); if searchRow.isHidden { searchField.text = ""; searchField.resignFirstResponder() } else { searchField.becomeFirstResponder() }; searchChanged() }
    @objc private func searchChanged() { searchIndex = 0; storeDidChange(); if let id = matches.first?.id { scrollTo(id, animated: true) } }
    private func advanceSearch(_ offset: Int) { let results = matches; guard !results.isEmpty else { return }; searchIndex = (searchIndex + offset + results.count) % results.count; updateMatchLabel(); scrollTo(results[searchIndex].id, animated: true) }
    private func updateMatchLabel() { let count = matches.count; matchLabel.text = (searchField.text ?? "").isEmpty ? "" : count == 0 ? "0 results" : "\(min(searchIndex + 1, count)) / \(count)" }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { advanceSearch(1); return false }
    private func scrollTo(_ id: String, animated: Bool) { guard let row = rows[id] else { return }; view.layoutIfNeeded(); scroll.scrollRectToVisible(row.convert(row.bounds, to: content).insetBy(dx: 0, dy: -35), animated: animated) }
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input: "f", modifierFlags: .command, action: #selector(findCommand)), UIKeyCommand(input: "g", modifierFlags: .command, action: #selector(nextCommand)), UIKeyCommand(input: "g", modifierFlags: [.command, .shift], action: #selector(previousCommand))] }
    @objc private func findCommand() { if searchRow.isHidden { toggleSearch() } else { searchField.becomeFirstResponder() } }
    @objc private func nextCommand() { advanceSearch(1) }
    @objc private func previousCommand() { advanceSearch(-1) }
}

extension ScrivUIKitFeatures {
    static func registerScriptAndProjects(in router: ScrivUIKitRouter) {
        router.register(.script) { _, store in ScriptScreenController(store: store) }
        router.register(.projects) { _, store in ProjectBrowserController(store: store) }
        router.register(.history) { _, store in HistoryController(store: store) }
    }
}
