import Foundation

/// Local recovery only: never included in project packages, CloudCodec or outbox payloads.
public struct EditorDraftScope: Codable, Hashable, Sendable {
    public var packagePath: String
    public var projectID: String
    public var cloudProjectID: String?
    public var server: String
    public var accountID: String?
    public var entryID: String
    public init(packagePath: String, projectID: String, cloudProjectID: String?, server: String, accountID: String?, entryID: String) {
        self.packagePath = URL(fileURLWithPath: packagePath).standardizedFileURL.path
        self.projectID = projectID; self.cloudProjectID = cloudProjectID
        self.server = server; self.accountID = accountID; self.entryID = entryID
    }
    public var key: String { ScrivDigest.sha256((try? ScrivJSON.encoder.encode(self)) ?? Data()) }
}

public struct LocalEditorDraft: Codable, Equatable, Sendable {
    public struct Edit: Codable, Equatable, Sendable {
        public var location: Int
        public var length: Int
        public var replacement: String
        public init(_ value: CharacterTextEdit) { location = value.range.location; length = value.range.length; replacement = value.replacement }
        public var native: CharacterTextEdit { .init(range: NSRange(location: location, length: length), replacement: replacement) }
    }
    public var schemaVersion = 1
    public var revisionID: String = UUID().uuidString
    public var scope: EditorDraftScope
    public var sourceRevision: Int
    public var sourceEpoch: Int?
    public var sourceEntry: ScriptEntry
    public var text: String
    public var edits: [Edit] = []
    public var updatedAt: Date = ScrivClock.now
    public init(scope: EditorDraftScope, sourceRevision: Int, sourceEpoch: Int?, sourceEntry: ScriptEntry) {
        self.scope = scope; self.sourceRevision = sourceRevision; self.sourceEpoch = sourceEpoch
        self.sourceEntry = sourceEntry; text = sourceEntry.text
    }
    public mutating func replaceText(_ value: String, edit: CharacterTextEdit? = nil) {
        if let edit, Self.validRange(edit.range, in: text),
           (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == value, edits.count < 1024 {
            edits.append(Edit(edit))
        } else {
            // Missing native events or a very long invalid editing session must
            // not guess which repeated name survived: revoke/review all links.
            edits = [Edit(.init(range: NSRange(location: 0, length: sourceEntry.text.utf16.count), replacement: value))]
        }
        text = value; revisionID = UUID().uuidString; updatedAt = ScrivClock.now
    }
    public func needsRebase(current: ScriptEntry, epoch: Int?) -> Bool { sourceEntry != current || sourceEpoch != epoch }
    static func validRange(_ range: NSRange, in text: String) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= text.utf16.count &&
        range.length <= text.utf16.count - range.location && Range(range, in: text) != nil
    }
    /// Explicit user review only. Rebasing replaces text, not current timing or
    /// source identity, and conservatively re-proposes character links.
    public mutating func rebase(on entry: ScriptEntry, revision: Int, epoch: Int?) {
        sourceEntry = entry; sourceRevision = revision; sourceEpoch = epoch
        replaceText(text)
    }
    public func applying(to project: ScrivProject, scope currentScope: EditorDraftScope, epoch: Int?) throws -> ScrivProject {
        guard scope == currentScope, project.id == scope.projectID, project.cloudProjectId == scope.cloudProjectID,
              let entry = project.entries.first(where: { $0.id == scope.entryID }) else {
            throw ScrivError.conflict("This draft belongs to another project, account, server or line. It remains saved on this Mac.")
        }
        guard !needsRebase(current: entry, epoch: epoch) else {
            throw ScrivError.conflict("The saved line or its timing changed since this draft began. Review the current line before using it as the draft's new base.")
        }
        var next = project
        try TimingEngine.updateText(&next, entryId: entry.id, text: text, edits: edits.map(\.native))
        try TimingEngine.validate(next)
        return next
    }
}

/// Synchronous atomic writes happen before a native text edit is accepted.
/// Bounds never evict another unsaved draft; a full/unwritable journal refuses
/// the new edit and leaves the previous recoverable record intact.
public struct EditorDraftJournal {
    public let root: URL
    public let maximumRecordBytes: Int
    public let maximumTotalBytes: Int
    public let maximumRecords: Int
    public init(root: URL, maximumRecordBytes: Int = 2 * 1024 * 1024,
                maximumTotalBytes: Int = 64 * 1024 * 1024, maximumRecords: Int = 128) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path), try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw ScrivError.invalid("Editor draft storage must not be a symbolic link.")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.maximumRecordBytes = maximumRecordBytes; self.maximumTotalBytes = maximumTotalBytes; self.maximumRecords = maximumRecords
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
    }
    public func load(_ scope: EditorDraftScope) throws -> LocalEditorDraft? {
        let url = try file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= maximumRecordBytes else { throw ScrivError.invalid("The saved editor draft exceeds its size limit; it has not been removed.") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumRecordBytes else { throw ScrivError.invalid("The saved editor draft is too large.") }
        let draft = try ScrivJSON.decoder.decode(LocalEditorDraft.self, from: data)
        try validate(draft)
        guard draft.scope == scope else { throw ScrivError.invalid("Editor draft identity mismatch; the existing file has been retained.") }
        return draft
    }
    public func save(_ draft: LocalEditorDraft, replacing revisionID: String?) throws {
        try validate(draft)
        let current = try load(draft.scope)
        guard current == nil || current?.revisionID == revisionID else {
            throw ScrivError.conflict("A newer local editor already saved this draft. Reopen the line to recover it before editing.")
        }
        let data = try ScrivJSON.encoder.encode(draft)
        guard data.count <= maximumRecordBytes else { throw ScrivError.invalid("This draft reached the 2 MiB local recovery limit. The previous draft is retained; shorten this edit before continuing.") }
        let target = try file(draft.scope)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])
        var count = 0, total = data.count
        for url in files where url.pathExtension == "json" && url.lastPathComponent != target.lastPathComponent {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ScrivError.invalid("Unsafe file in local draft storage. Existing drafts were retained.") }
            count += 1
            let bytes = values.fileSize ?? maximumTotalBytes
            guard bytes <= maximumTotalBytes - total else { throw ScrivError.invalid("Local draft recovery storage is full. Apply or explicitly discard another saved draft first.") }
            total += bytes
        }
        guard count < maximumRecords, total <= maximumTotalBytes else { throw ScrivError.invalid("Local draft recovery storage is full. No drafts were evicted.") }
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    /// A late canonical save must never remove newer typing or another editor's draft.
    @discardableResult
    public func clear(_ draft: LocalEditorDraft) throws -> Bool {
        guard let current = try load(draft.scope) else { return true }
        guard current.revisionID == draft.revisionID else { return false }
        try FileManager.default.removeItem(at: file(draft.scope)); return true
    }
    private func file(_ scope: EditorDraftScope) throws -> URL {
        let url = root.appendingPathComponent(scope.key + ".json")
        if FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw ScrivError.invalid("Editor draft file must not be a symbolic link.")
        }
        return url
    }
    private func validate(_ draft: LocalEditorDraft) throws {
        guard draft.schemaVersion == 1, UUID(uuidString: draft.revisionID) != nil,
              draft.scope.entryID == draft.sourceEntry.id, draft.sourceRevision >= 0,
              draft.text.utf8.count <= maximumRecordBytes, draft.edits.count <= 1024,
              draft.edits.allSatisfy({ $0.location >= 0 && $0.length >= 0 && $0.location <= Int.max - $0.length }) else {
            throw ScrivError.invalid("Invalid local editor draft. The existing file has been retained.")
        }
        var replay = draft.sourceEntry.text
        for edit in draft.edits {
            guard LocalEditorDraft.validRange(edit.native.range, in: replay) else { throw ScrivError.invalid("Saved draft edit ranges do not match their source.") }
            replay = (replay as NSString).replacingCharacters(in: edit.native.range, with: edit.replacement)
            guard replay.utf8.count <= maximumRecordBytes else { throw ScrivError.invalid("Saved draft text exceeds its recovery limit.") }
        }
        guard replay.utf16.elementsEqual(draft.text.utf16) else { throw ScrivError.invalid("Saved draft text does not match its edit history.") }
    }
}
