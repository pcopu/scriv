import Foundation
import Combine
import ScrivCore

/// One UIKit text responder owns one lease and recovery journal. This is not a
/// second editing model: accepted text flows through WorkspaceStore/Core APIs.
@MainActor
final class ScriptDraftSession {
    let store: WorkspaceStore
    let changes = PassthroughSubject<Void, Never>()
    private(set) var record: LocalEditorDraft?
    private(set) var issue: String?
    private(set) var requiresReview = false
    private(set) var acquiring = false
    private(set) var applying = false
    private(set) var active = false
    private(set) var sessionID = UUID()
    private(set) var navigation: Int?
    private var lifecycle = 0
    private var accountContext = ""
    private var acquisitionID: UUID?
    private var acquisitionTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    init(store: WorkspaceStore) { self.store = store }
    var entryID: String? { active ? record?.scope.entryID : nil }
    var text: String { record?.text ?? "" }
    var currentEntry: ScriptEntry? { record.flatMap { draft in store.project.entries.first { $0.id == draft.scope.entryID } } }
    var needsRebase: Bool { guard let record, let currentEntry else { return false }; return record.needsRebase(current: currentEntry, epoch: store.editorDraftEpoch) }
    var pending: Bool { requiresReview || issue != nil || !(text.utf16.elementsEqual(currentEntry?.text.utf16 ?? "".utf16)) }

    func begin(_ entryID: String) {
        guard !(active && self.entryID == entryID), store.lockedByOther(entryID) == nil else { return }
        if active && !finish() { keepForLater() }
        cancelAcquisition()
        let token = UUID(), context = store.navigationContext, projectID = store.project.id
        acquisitionID = token; acquiring = true; issue = nil; changes.send()
        acquisitionTask = Task { [weak self] in
            guard let self else { return }
            let allowed = await store.beginEdit(entryID)
            guard !Task.isCancelled, acquisitionID == token, context == store.navigationContext, projectID == store.project.id else {
                if allowed { store.endEdit(entryID, context: context) }; return
            }
            acquiring = false; acquisitionID = nil
            guard allowed else { issue = store.errorMessage ?? "This line could not be opened for editing."; changes.send(); return }
            do {
                let loaded = try store.editorDraftForEditing(entryID)
                record = loaded.draft; requiresReview = loaded.recovered; navigation = context
                lifecycle = store.editorLifecycleContext; accountContext = store.editorAccountContext
                active = true; sessionID = UUID(); issue = nil; changes.send()
            } catch { store.endEdit(entryID, context: context); issue = error.localizedDescription; changes.send() }
        }
    }

    /// UITextView calls this before modifying its string. Never permit a native
    /// edit unless its exact UTF-16 operation has reached the private journal.
    func accept(_ edit: CharacterTextEdit) -> Bool {
        guard validContext, let previous = record, let range = Range(edit.range, in: previous.text) else { return false }
        var next = previous
        next.replaceText(previous.text.replacingCharacters(in: range, with: edit.replacement), edit: edit)
        do { try store.persistEditorDraft(next, replacing: previous.revisionID); record = next; return true }
        catch { issue = error.localizedDescription; changes.send(); return false }
    }

    /// IME/system changes without a matching delegate operation conservatively
    /// replace source text, which revokes ambiguous links rather than guessing.
    @discardableResult func nativeTextDidChange(_ value: String) -> Bool {
        guard validContext, let previous = record else { return false }
        if !previous.text.utf16.elementsEqual(value.utf16) {
            var next = previous; next.replaceText(value)
            do { try store.persistEditorDraft(next, replacing: previous.revisionID); record = next }
            catch { issue = error.localizedDescription; changes.send(); return false }
        }
        scheduleFlush(); changes.send(); return true
    }
    func selectionDidChange(_ range: NSRange) {
        guard validContext, let entryID else { return }
        store.updatePresence(itemId: entryID, selectionStart: range.location, selectionEnd: range.location + range.length)
    }
    func review() { guard active else { return }; flushTask?.cancel(); flushTask = nil; requiresReview = true; changes.send() }
    func rebase() {
        guard validContext, let record else { return }
        do { self.record = try store.rebaseEditorDraft(record); requiresReview = true; issue = nil }
        catch { issue = error.localizedDescription }
        changes.send()
    }
    func applyReviewed() {
        guard validContext, !applying, !needsRebase, let record else { return }
        applying = true; changes.send()
        let context = navigation, lifecycle = self.lifecycle
        Task { [weak self] in
            guard let self else { return }
            defer { applying = false; changes.send() }
            do {
                try await store.reacquireEditorDraftLease(record)
                guard validContext, navigation == context, self.lifecycle == lifecycle else { return }
                requiresReview = false
                if !finish() { requiresReview = true }
            } catch { issue = error.localizedDescription }
        }
    }
    @discardableResult func finish() -> Bool {
        guard active else { return true }
        flushTask?.cancel(); flushTask = nil
        guard !requiresReview else { issue = "Review this recovered draft before applying it. It remains saved on this Mac."; changes.send(); return false }
        guard apply() else { return false }
        detach(); return true
    }
    func keepForLater() { detach() }
    @discardableResult func discard() -> Bool {
        guard validContext, let record else { return false }
        do { try store.discardEditorDraft(record); detach(); self.record = nil; issue = nil; changes.send(); return true }
        catch { issue = error.localizedDescription; changes.send(); return false }
    }
    func contextDidChange() {
        guard active else { return }
        if !validContext { detach() }
    }
    func cancelAcquisition() { acquisitionID = nil; acquisitionTask?.cancel(); acquisitionTask = nil; acquiring = false }
    func detach() {
        cancelAcquisition(); flushTask?.cancel(); flushTask = nil
        if active, let id = entryID, let navigation { store.endEdit(id, context: navigation) }
        active = false; navigation = nil; changes.send()
    }
    private var validContext: Bool {
        active && navigation == store.navigationContext && lifecycle == store.editorLifecycleContext && accountContext == store.editorAccountContext && currentEntry != nil
    }
    private func scheduleFlush() {
        guard !requiresReview, flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, validContext else { return }
            flushTask = nil; _ = apply()
        }
    }
    @discardableResult private func apply() -> Bool {
        guard validContext, let previous = record, let navigation else { return false }
        do {
            try store.applyEditorDraft(previous, navigation: navigation, lifecycle: lifecycle)
            guard let current = store.project.entries.first(where: { $0.id == previous.scope.entryID }) else { return false }
            var next = previous; next.sourceEntry = current; next.sourceRevision = store.project.revision
            next.sourceEpoch = store.editorDraftEpoch; next.text = current.text; next.edits = []
            record = next; issue = nil; requiresReview = false; changes.send(); return true
        } catch { issue = error.localizedDescription; changes.send(); return false }
    }
}
