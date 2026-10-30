import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Recovery context is private to this Mac. It is never added to a project,
/// cue, image-generation prompt, CloudCodec item or outbox payload.
public struct CuePromptDraftScope: Codable, Hashable, Sendable {
    public var packagePath: String
    public var projectID: String
    public var cloudProjectID: String?
    public var server: String
    public var accountID: String?
    public var sceneID: String
    public var cueID: String
    public init(packagePath: String, projectID: String, cloudProjectID: String?, server: String, accountID: String?, sceneID: String, cueID: String) {
        self.packagePath = URL(fileURLWithPath: packagePath).standardizedFileURL.path
        self.projectID = projectID; self.cloudProjectID = cloudProjectID
        self.server = server; self.accountID = accountID; self.sceneID = sceneID; self.cueID = cueID
    }
    public var key: String { ScrivDigest.sha256((try? ScrivJSON.encoder.encode(self)) ?? Data()) }
}

public struct LocalCuePromptDraft: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var revisionID: String = UUID().uuidString
    public var scope: CuePromptDraftScope
    public var sourcePrompt: String
    public var sourceEpoch: Int?
    public var text: String
    public var updatedAt: Date = ScrivClock.now
    public init(scope: CuePromptDraftScope, sourcePrompt: String, sourceEpoch: Int?, text: String? = nil) {
        self.scope = scope; self.sourcePrompt = sourcePrompt; self.sourceEpoch = sourceEpoch
        self.text = text ?? sourcePrompt
    }
    public mutating func replaceText(_ value: String) {
        text = value; revisionID = UUID().uuidString; updatedAt = ScrivClock.now
    }
    public func needsRebase(sourcePrompt currentPrompt: String, epoch: Int?) -> Bool {
        !sourcePrompt.utf16.elementsEqual(currentPrompt.utf16) || sourceEpoch != epoch
    }
    /// Only an explicit reviewed retry should establish a newer canonical base.
    /// Preserve the exact pending text; never silently replace it with that base.
    public mutating func rebase(sourcePrompt: String, epoch: Int?) {
        self.sourcePrompt = sourcePrompt; sourceEpoch = epoch
        replaceText(text)
    }
    public func applying(to project: ScrivProject, scope currentScope: CuePromptDraftScope, epoch: Int?) throws -> ScrivProject {
        guard schemaVersion == 1, UUID(uuidString: revisionID) != nil,
              scope == currentScope, scope.key == currentScope.key, project.id == scope.projectID, project.cloudProjectId == scope.cloudProjectID,
              project.scenes.contains(where: { $0.id == scope.sceneID }),
              let index = project.cues.firstIndex(where: { $0.id == scope.cueID && $0.sceneId == scope.sceneID }) else {
            throw ScrivError.conflict("This image-direction draft belongs to another project, account, server, scene or image cue. It remains saved on this Mac.")
        }
        guard !needsRebase(sourcePrompt: project.cues[index].prompt, epoch: epoch) else {
            throw ScrivError.conflict("The saved image direction changed since this draft began. Review it before using it as the draft's new base.")
        }
        guard text.utf16.count <= 30_000 else {
            throw ScrivError.invalid("Image direction exceeds 30,000 UTF-16 characters. Shorten the draft before applying it; the exact draft remains saved on this Mac.")
        }
        var next = project
        next.cues[index].prompt = text
        let encoder = ScrivJSON.encoder
        encoder.outputFormatting.insert(.withoutEscapingSlashes)
        guard try encoder.encode(next.cues[index]).count <= 65_536 else {
            throw ScrivError.invalid("This cue's complete image direction and metadata exceed 64 KiB. Shorten the draft before applying it; the text has not been truncated.")
        }
        try TimingEngine.validate(next)
        return next
    }
}

/// Atomic private local recovery. A strict compare-and-swap cannot overwrite a
/// newer draft or resurrect an explicitly cleared one. Bounds never evict data.
/// The private advisory lock serializes the check and replace across instances
/// and processes; atomic rename keeps readers from seeing a partial JSON file.
public struct CuePromptDraftJournal {
    public let root: URL
    public let maximumRecordBytes: Int
    public let maximumTotalBytes: Int
    public let maximumRecords: Int
    public init(root: URL, maximumRecordBytes: Int = 2 * 1024 * 1024,
                maximumTotalBytes: Int = 64 * 1024 * 1024, maximumRecords: Int = 128) throws {
        guard maximumRecordBytes > 0, maximumTotalBytes > 0, maximumRecords > 0 else {
            throw ScrivError.invalid("Image-direction draft storage limits must be positive.")
        }
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: root.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw ScrivError.invalid("Image-direction draft storage must be a directory, not a symbolic link or file.")
            }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.maximumRecordBytes = maximumRecordBytes; self.maximumTotalBytes = maximumTotalBytes; self.maximumRecords = maximumRecords
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
    }
    public func load(_ scope: CuePromptDraftScope) throws -> LocalCuePromptDraft? {
        try validateLocation(scope)
        return try locked { try loadUnlocked(scope) }
    }
    public func save(_ draft: LocalCuePromptDraft, replacing revisionID: String?) throws {
        try validateLocation(draft.scope)
        try locked {
            try validate(draft)
            let current = try loadUnlocked(draft.scope)
            guard current?.revisionID == revisionID else {
                throw ScrivError.conflict("This local image-direction draft was replaced or discarded. Reopen it before editing; the existing recovery record was not changed.")
            }
            let data = try ScrivJSON.encoder.encode(draft)
            if let current, current.revisionID == draft.revisionID,
               try ScrivJSON.encoder.encode(current) != data {
                throw ScrivError.conflict("Changed draft text requires a new revision. The existing recovery record was retained.")
            }
            guard data.count <= maximumRecordBytes else {
                throw ScrivError.invalid("This image-direction draft reached its local recovery size limit. The previous draft is retained; shorten this edit before continuing.")
            }
            let target = try file(draft.scope)
            guard data.count <= maximumTotalBytes else { throw storageFull() }
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            var count = 0, total = data.count
            for url in files where url.pathExtension == "json" && url.lastPathComponent != target.lastPathComponent {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = (attributes[.size] as? NSNumber)?.intValue, size >= 0 else {
                    throw ScrivError.invalid("Unsafe file in image-direction draft storage. Existing drafts were retained.")
                }
                count += 1
                guard size <= maximumTotalBytes - total else { throw storageFull() }
                total += size
            }
            guard count < maximumRecords else { throw storageFull() }
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }
    /// A late canonical save must not delete newer typing or another editor's recovery.
    @discardableResult
    public func clear(_ draft: LocalCuePromptDraft) throws -> Bool {
        try validateLocation(draft.scope)
        return try locked {
            guard let current = try loadUnlocked(draft.scope) else { return true }
            guard current.revisionID == draft.revisionID else { return false }
            try FileManager.default.removeItem(at: file(draft.scope))
            return true
        }
    }
    private func loadUnlocked(_ scope: CuePromptDraftScope) throws -> LocalCuePromptDraft? {
        let url = try file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
        guard size >= 0, size <= maximumRecordBytes else {
            throw ScrivError.invalid("The saved image-direction draft exceeds its size limit; it has not been removed.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumRecordBytes else { throw ScrivError.invalid("The saved image-direction draft is too large; it has been retained.") }
        let draft = try ScrivJSON.decoder.decode(LocalCuePromptDraft.self, from: data)
        try validate(draft)
        guard draft.scope == scope, draft.scope.key == scope.key else { throw ScrivError.invalid("Image-direction draft identity mismatch. The existing file has been retained.") }
        return draft
    }
    private func file(_ scope: CuePromptDraftScope) throws -> URL {
        let url = root.appendingPathComponent(scope.key + ".json")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ScrivError.invalid("An image-direction draft file must not be a symbolic link or directory.")
            }
        }
        return url
    }
    private func validate(_ draft: LocalCuePromptDraft) throws {
        guard draft.schemaVersion == 1, UUID(uuidString: draft.revisionID) != nil,
              !draft.scope.projectID.isEmpty, !draft.scope.sceneID.isEmpty, !draft.scope.cueID.isEmpty,
              !draft.scope.server.isEmpty, draft.scope.packagePath.hasPrefix("/"),
              draft.sourceEpoch.map({ $0 >= 0 }) ?? true,
              draft.updatedAt.timeIntervalSince1970.isFinite,
              draft.text.utf8.count <= maximumRecordBytes, draft.sourcePrompt.utf8.count <= maximumRecordBytes else {
            throw ScrivError.invalid("Invalid local image-direction draft. The existing file has been retained.")
        }
    }
    private func validateLocation(_ scope: CuePromptDraftScope) throws {
        let packagePath = URL(fileURLWithPath: scope.packagePath).resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = packagePath.hasSuffix("/") ? packagePath : packagePath + "/"
        guard root.path != packagePath, !root.path.hasPrefix(prefix) else {
            throw ScrivError.invalid("Private image-direction drafts must be stored outside the project package.")
        }
    }
    private func storageFull() -> ScrivError {
        .invalid("Local image-direction recovery storage is full. Apply or explicitly discard another draft first; no drafts were evicted.")
    }
    private func locked<T>(_ action: () throws -> T) throws -> T {
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ScrivError.invalid("Image-direction draft storage was replaced by an unsafe path.")
        }
        let descriptor = open(root.appendingPathComponent(".journal-lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ScrivError.invalid("Image-direction draft lock must be a regular private file.")
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try action()
    }
}
