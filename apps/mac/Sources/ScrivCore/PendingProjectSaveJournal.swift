import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Private write-ahead context, never part of a project package or cloud item.
public struct PendingProjectSaveScope: Codable, Hashable, Sendable {
    public let packagePath: String
    public let projectID: String
    public let cloudProjectID: String?
    public let server: String
    public let accountID: String?
    public init(packagePath: String, projectID: String, cloudProjectID: String? = nil, server: String = "local", accountID: String? = nil) {
        self.packagePath = URL(fileURLWithPath: packagePath).standardizedFileURL.path
        self.projectID = projectID; self.cloudProjectID = cloudProjectID; self.server = server; self.accountID = accountID
    }
}

/// Immutable accepted mutation. Hashes bind the exact source and target snapshots;
/// the filename binds package+target revision, regardless of account or project ID.
public struct PendingProjectSaveRecord: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let scope: PendingProjectSaveScope
    public let before: ScrivProject?
    public let after: ScrivProject
    public let label: String
    public let beforeHash: String?
    public let afterHash: String
    public var id: String { ScrivDigest.sha256(Data(scope.packagePath.utf8)) + "-" + String(after.revision) }
    fileprivate init(scope: PendingProjectSaveScope, before: ScrivProject?, after: ScrivProject, label: String) throws {
        schemaVersion = 1; self.scope = scope; self.before = before; self.after = after; self.label = label
        beforeHash = try before.map { ScrivDigest.sha256(try ScrivJSON.encoder.encode($0)) }
        afterHash = ScrivDigest.sha256(try ScrivJSON.encoder.encode(after))
    }
}

public struct PendingProjectSaveRecoveryPlan: Equatable, Sendable {
    /// Apply these in order through ProjectRepository.save, acknowledging each
    /// exact record only after its package/history write succeeds.
    public let replay: [PendingProjectSaveRecord]
    /// Proven accepted canonical/history snapshots; safe for exact acknowledgement.
    public let alreadySaved: [PendingProjectSaveRecord]
}

/// Synchronous, private, bounded write-ahead storage. Persist MUST succeed before
/// a mutation is published in memory. Failures retain every existing record.
/// A private flock serializes competing instances; exclusive link installation
/// never overwrites a different record. File and directory sync precede success.
public struct PendingProjectSaveJournal {
    public let root: URL
    public let maximumRecordBytes: Int
    public let maximumTotalBytes: Int
    public let maximumRecords: Int

    public init(root: URL, maximumRecordBytes: Int = 130 * 1024 * 1024,
                maximumTotalBytes: Int = 512 * 1024 * 1024, maximumRecords: Int = 256) throws {
        guard maximumRecordBytes > 0, maximumRecordBytes < Int.max,
              maximumTotalBytes > 0, maximumRecords > 0 else { throw ScrivError.invalid("Pending-save storage limits must be positive and bounded.") }
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: root.path) {
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw ScrivError.invalid("Pending-save storage must be a private directory, not a symbolic link or file.") }
        }
        try DurableDirectory.create(at:root)
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.maximumRecordBytes = maximumRecordBytes; self.maximumTotalBytes = maximumTotalBytes; self.maximumRecords = maximumRecords
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
    }

    @discardableResult
    public func persist(scope: PendingProjectSaveScope, before: ScrivProject?, after: ScrivProject, label: String) throws -> PendingProjectSaveRecord {
        let record = try PendingProjectSaveRecord(scope: scope, before: before, after: after, label: label)
        try validate(record)
        let data = try ScrivJSON.encoder.encode(record)
        guard data.count <= maximumRecordBytes else { throw ScrivError.invalid("This project change exceeds the private pending-save record limit. Existing recovery data was retained; the new change was not accepted.") }
        return try locked { directory in
            let records = try loadAll(directory: directory)
            if let existing = records.first(where: { $0.id == record.id }) {
                guard existing == record else { throw conflict("A different pending change already owns this package revision.") }
                return existing
            }
            let related = records.filter { $0.scope.packagePath == scope.packagePath }
            guard related.allSatisfy({ $0.scope == scope }) else { throw conflict("This package has pending changes from another account or project context.") }
            if let previous = related.first(where: { $0.after.revision == before?.revision }), previous.afterHash != record.beforeHash {
                throw conflict("The pending source revision differs from this change’s reviewed source.")
            }
            if let successor = related.first(where: { $0.before?.revision == after.revision }), successor.beforeHash != record.afterHash {
                throw conflict("A later pending revision follows a different version of this change.")
            }
            try checkCapacity(adding: data.count, directory: directory)
            try install(data, name: record.id + ".json", directory: directory)
            return record
        }
    }

    public func load(package: URL) throws -> [PendingProjectSaveRecord] {
        let path = package.standardizedFileURL.path
        try validateLocation(path)
        return try locked { directory in
            try loadAll(directory: directory).filter { $0.scope.packagePath == path }.sorted { $0.after.revision < $1.after.revision }
        }
    }

    /// Includes packages whose initial project.json never reached disk. It does
    /// not grant permission to open them; callers must restore authorized access.
    public func allPackages() throws -> [URL] {
        try locked { directory in
            Array(Set(try loadAll(directory: directory).map { $0.scope.packagePath })).sorted().map { URL(fileURLWithPath: $0) }
        }
    }

    /// Never delete another revision, a changed record, or a newer pending write.
    @discardableResult
    public func acknowledge(_ record: PendingProjectSaveRecord) throws -> Bool {
        try validate(record)
        return try locked { directory in
            let name = record.id + ".json"
            guard let data = try read(name: name, directory: directory, missingAllowed: true) else { return true }
            let current = try decode(data, name: name)
            guard current == record, data == (try ScrivJSON.encoder.encode(record)) else { return false }
            guard unlinkat(directory, name, 0) == 0 else { throw posixError() }
            try sync(directory)
            return true
        }
    }

    /// A pure replay decision against accepted state. It never writes packages
    /// or clears records. Any fork, scope mismatch or gap fails the entire plan.
    public func planRecovery(scope: PendingProjectSaveScope, canonical: ScrivProject?, acceptedHistory: [ScrivProject] = []) throws -> PendingProjectSaveRecoveryPlan {
        try validateScope(scope)
        return try locked { directory in
            let records = try loadAll(directory: directory).filter { $0.scope.packagePath == scope.packagePath }.sorted { $0.after.revision < $1.after.revision }
            guard records.allSatisfy({ $0.scope == scope }) else { throw conflict("Pending changes belong to another account, server or project context.") }
            var accepted: [Int: String] = [:]
            if let canonical {
                try TimingEngine.validate(canonical)
                guard canonical.id == scope.projectID else { throw conflict("The current package contains a different project.") }
                accepted[canonical.revision] = try hash(canonical)
            } else if !acceptedHistory.isEmpty {
                throw conflict("Historical snapshots cannot be accepted without a current canonical project.")
            }
            for snapshot in acceptedHistory {
                try TimingEngine.validate(snapshot)
                guard let canonical, snapshot.id == scope.projectID, snapshot.revision <= canonical.revision else {
                    throw conflict("Recovery history contains a future or unrelated snapshot.")
                }
                let digest = try hash(snapshot)
                if let existing = accepted[snapshot.revision], existing != digest { throw conflict("Accepted history contains different content for one revision.") }
                accepted[snapshot.revision] = digest
            }
            var cursor = canonical
            var replay: [PendingProjectSaveRecord] = [], alreadySaved: [PendingProjectSaveRecord] = []
            for record in records {
                if let canonical, record.after.revision <= canonical.revision {
                    guard accepted[record.after.revision] == record.afterHash else {
                        throw conflict("An older pending revision is not an exact accepted history snapshot. The current package will not be overwritten.")
                    }
                    if let before = record.before {
                        guard accepted[before.revision] == record.beforeHash else { throw conflict("The source of an accepted pending revision is missing or diverged in history.") }
                    }
                    alreadySaved.append(record)
                    continue
                }
                if let before = record.before {
                    guard let cursor, cursor.id == before.id, cursor.revision == before.revision,
                          try hash(cursor) == record.beforeHash else { throw conflict("Pending changes do not continue from the current accepted project. A missing or diverged revision needs review.") }
                } else {
                    guard cursor == nil, record.after.revision == 0 else { throw conflict("An initial pending project must not overwrite an existing package.") }
                }
                replay.append(record); cursor = record.after
            }
            return PendingProjectSaveRecoveryPlan(replay: replay, alreadySaved: alreadySaved)
        }
    }

    private func validate(_ record: PendingProjectSaveRecord) throws {
        try validateScope(record.scope)
        guard record.schemaVersion == 1, record.label.utf8.count <= 4096,
              record.after.id == record.scope.projectID, record.after.cloudProjectId == record.scope.cloudProjectID else {
            throw ScrivError.invalid("Invalid pending project-save identity. Existing records were retained.")
        }
        try TimingEngine.validate(record.after)
        if let before = record.before {
            try TimingEngine.validate(before)
            guard before.id == record.after.id, before.revision < Int.max - 1,
                  record.after.revision == before.revision + 1, record.beforeHash == (try hash(before)) else {
                throw conflict("Pending project revisions must be an exact, contiguous source-to-target change.")
            }
        } else {
            guard record.after.revision == 0, record.beforeHash == nil else { throw conflict("A project without a saved source must begin at revision zero.") }
        }
        guard record.afterHash == (try hash(record.after)) else { throw ScrivError.invalid("A pending project snapshot failed its content check. It was retained for review.") }
    }
    private func validateScope(_ scope: PendingProjectSaveScope) throws {
        guard scope.packagePath.hasPrefix("/"), scope.packagePath.utf8.count <= 4096, !scope.packagePath.contains("\0"),
              URL(fileURLWithPath: scope.packagePath).standardizedFileURL.path == scope.packagePath,
              !scope.projectID.isEmpty, scope.projectID.utf8.count <= 128,
              scope.accountID.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true else {
            throw ScrivError.invalid("Invalid pending-save scope. Existing records were retained.")
        }
        if scope.server == "local" {
            guard scope.accountID == nil, scope.cloudProjectID == nil else { throw ScrivError.invalid("Local pending-save context must not claim a cloud account.") }
        } else {
            guard scope.server.utf8.count <= 2048, let endpoint = URLComponents(string: scope.server),
                  ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""), endpoint.host != nil,
                  endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
                throw ScrivError.invalid("Pending-save context requires a credential-free server origin.")
            }
        }
        try validateLocation(scope.packagePath)
    }
    private func validateLocation(_ packagePath: String) throws {
        let path = URL(fileURLWithPath: packagePath).resolvingSymlinksInPath().standardizedFileURL.path
        guard root.path != path, !root.path.hasPrefix(path.hasSuffix("/") ? path : path + "/") else {
            throw ScrivError.invalid("Private pending project saves must be stored outside the project package.")
        }
    }
    private func hash(_ project: ScrivProject) throws -> String { ScrivDigest.sha256(try ScrivJSON.encoder.encode(project)) }
    private func conflict(_ message: String) -> ScrivError { .conflict(message + " Pending data was retained; no recovery change was applied.") }
    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    private func loadAll(directory: Int32) throws -> [PendingProjectSaveRecord] {
        var records: [PendingProjectSaveRecord] = []
        for name in try inventory(directory: directory) where name.hasSuffix(".json") {
            guard let data = try read(name: name, directory: directory, missingAllowed: false) else { continue }
            records.append(try decode(data, name: name))
        }
        guard Set(records.map(\.id)).count == records.count else { throw ScrivError.invalid("Duplicate pending package revisions require review. All records were retained.") }
        return records
    }
    private func decode(_ data: Data, name: String) throws -> PendingProjectSaveRecord {
        let record = try ScrivJSON.decoder.decode(PendingProjectSaveRecord.self, from: data)
        try validate(record)
        guard name == record.id + ".json" else { throw ScrivError.invalid("A pending-save filename does not match its immutable identity. It was retained.") }
        return record
    }
    private func read(name: String, directory: Int32, missingAllowed: Bool) throws -> Data? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if missingAllowed, errno == ENOENT { return nil }
            throw posixError()
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_size <= maximumRecordBytes else {
            throw ScrivError.invalid("A pending-save record is unsafe or exceeds its bounded size. It was retained.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while data.count <= maximumRecordBytes {
            guard let chunk = try handle.read(upToCount: min(65_536, maximumRecordBytes + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumRecordBytes else { throw ScrivError.invalid("A pending-save record grew beyond its size limit. It was retained.") }
        return data
    }
    private func checkCapacity(adding bytes: Int, directory: Int32) throws {
        _ = try inventory(directory: directory, additionalBytes: bytes, additionalRecords: 1)
    }
    /// Bound reads as well as writes, including abandoned temporary-file bytes.
    /// Never delete files to make room and never decode an unbounded file list.
    private func inventory(directory: Int32, additionalBytes: Int = 0, additionalRecords: Int = 0) throws -> [String] {
        guard additionalBytes <= maximumTotalBytes else { throw full() }
        var total = additionalBytes, count = additionalRecords
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        for name in names where name != ".journal-lock" {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0 else {
                throw ScrivError.invalid("Unsafe content in private pending-save storage. Existing data was retained.")
            }
            guard info.st_size <= maximumTotalBytes - total else { throw full() }
            total += Int(info.st_size)
            if name.hasSuffix(".json") { count += 1 }
            guard count <= maximumRecords else { throw full() }
        }
        guard count <= maximumRecords else { throw full() }
        return names
    }
    private func full() -> ScrivError { .invalid("Private pending-save storage is full. Complete or review earlier saves before editing; no pending data was evicted.") }
    private func install(_ data: Data, name: String, directory: Int32) throws {
        let temporary = ".pending-" + UUID().uuidString + ".tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor); _ = unlinkat(directory, temporary, 0) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw posixError() }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let amount = write(descriptor, base.advanced(by: written), buffer.count - written)
                if amount < 0 { if errno == EINTR { continue }; throw posixError() }
                guard amount > 0 else { throw ScrivError.unavailable("The pending project change could not be written completely.") }
                written += amount
            }
        }
        try sync(descriptor)
        // Exclusive creation is atomic and cannot replace any existing target,
        // unlike a generic rename/write(.atomic) of an immutable revision.
        guard linkat(directory, temporary, directory, name, 0) == 0 else { throw posixError() }
        guard unlinkat(directory, temporary, 0) == 0 else { throw posixError() }
        try sync(directory)
    }
    private func sync(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 { if errno != EINTR { throw posixError() } }
    }
    private func locked<T>(_ action: (Int32) throws -> T) throws -> T {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw posixError() }
        defer { close(directory) }
        let lock = openat(directory, ".journal-lock", O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard lock >= 0 else { throw posixError() }
        defer { close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { throw ScrivError.invalid("The pending-save lock must be a private regular file.") }
        guard fchmod(lock, mode_t(0o600)) == 0 else { throw posixError() }
        while flock(lock, LOCK_EX) != 0 { if errno != EINTR { throw posixError() } }
        defer { _ = flock(lock, LOCK_UN) }
        return try action(directory)
    }
}
