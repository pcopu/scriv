import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public actor ProjectRepository {
    public let root: URL
    public init(root: URL) throws { self.root = root; try DurableDirectory.create(at:root) }
    public func defaultURL(for project: ScrivProject) -> URL { root.appendingPathComponent(project.id).appendingPathExtension("scriv") }
    public func save(_ project: ScrivProject, at package: URL, label: String) throws {
        try withPackageWriteLock(package) { try saveLocked(project,at:package,label:label) }
    }
    /// Compare and publish under the same all-writer package lock. Planning a
    /// replay never authorizes overwriting a package changed since planning.
    public func saveRecovering(_ record: PendingProjectSaveRecord, at package: URL) throws {
        guard record.schemaVersion == 1, record.scope.packagePath == package.standardizedFileURL.path,
              record.scope.projectID == record.after.id, record.scope.cloudProjectID == record.after.cloudProjectId,
              record.afterHash == (try digest(record.after)),
              record.beforeHash == (try record.before.map(digest)) else {
            throw ScrivError.invalid("The pending save does not match its package or exact snapshots.")
        }
        try TimingEngine.validate(record.after)
        if let before = record.before {
            try TimingEngine.validate(before)
            guard before.id == record.after.id, before.revision < Int.max - 1,
                  record.after.revision == before.revision + 1 else { throw ScrivError.invalid("Pending recovery revisions are not contiguous.") }
        } else { guard record.after.revision == 0 else { throw ScrivError.invalid("Initial recovery must start at revision zero.") } }
        try withPackageWriteLock(package) {
            let currentURL = try member("project.json",in:package)
            let current = FileManager.default.fileExists(atPath:currentURL.path) ? try load(at:package) : nil
            let currentHash = try current.map(digest)
            if let current, current.id == record.after.id,
               current.revision > record.after.revision || currentHash == record.afterHash {
                let accepted = try history(at:package)
                let acceptedHashes = try Set(accepted.map { try digest($0.snapshot) })
                guard acceptedHashes.contains(try digest(current)), acceptedHashes.contains(record.afterHash),
                      record.beforeHash.map({ acceptedHashes.contains($0) }) ?? true else {
                    throw ScrivError.conflict("The accepted recovery snapshot lacks exact source/history evidence. Nothing was overwritten.")
                }
                // Matching readable bytes may follow a failed fsync. Establish
                // durability again before allowing any old WAL acknowledgement.
                try syncSavedFile(currentURL)
                for revision in Set([current.revision,record.after.revision] + [record.before?.revision].compactMap({ $0 })) {
                    try syncSavedFile(member("history/" + String(format:"%012lld",Int64(revision)) + ".json",in:package))
                }
                try DurableDirectory.flush(member("history",in:package)); try DurableDirectory.flush(package)
                return
            }
            if let before = record.before {
                guard let current, current.id == before.id, current.revision == before.revision,
                      try digest(current) == record.beforeHash else {
                    throw ScrivError.conflict("The project changed after recovery was planned. Pending changes were retained; the current package was not overwritten.")
                }
            } else { guard current == nil else { throw ScrivError.conflict("An initial pending project must not replace an existing package.") } }
            try saveLocked(record.after,at:package,label:record.label)
        }
    }
    private func digest(_ project: ScrivProject) throws -> String { ScrivDigest.sha256(try ScrivJSON.encoder.encode(project)) }
    private func withPackageWriteLock<T>(_ package: URL, _ body: () throws -> T) throws -> T {
        try DurableDirectory.create(at:package)
        let root = package.resolvingSymlinksInPath().standardizedFileURL
        let directory = open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw ScrivError.unavailable("The project package cannot be opened for an atomic save.") }
        defer { close(directory) }
        let descriptor = openat(directory,".scriv-write.lock",O_CREAT | O_RDWR | O_NOFOLLOW,mode_t(0o600))
        guard descriptor >= 0 else { throw ScrivError.unavailable("The project write lock cannot be opened safely.") }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor,&attributes) == 0, attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_nlink == 1, attributes.st_uid == getuid() else { throw ScrivError.invalid("The project write lock is not a private regular file.") }
        guard flock(descriptor,LOCK_EX | LOCK_NB) == 0 else { throw ScrivError.conflict("Another Scriv process is saving this package. Retry after its save completes.") }
        defer { _ = flock(descriptor,LOCK_UN) }
        return try body()
    }
    private func saveLocked(_ project: ScrivProject, at package: URL, label: String) throws {
        try TimingEngine.validate(project)
        let fm = FileManager.default
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try fm.createDirectory(at: try member("assets", in:package), withIntermediateDirectories: true)
        let history = try member("history", in:package)
        try fm.createDirectory(at: history, withIntermediateDirectories: true)
        let data = try ScrivJSON.encoder.encode(project)
        let event = HistoryEntry(label: label, snapshot: project)
        let revisionURL = try member("history/" + String(format: "%012lld", Int64(project.revision)) + ".json", in:package)
        let currentURL = try member("project.json", in:package)
        let published = fm.fileExists(atPath:currentURL.path) ? try load(at:package) : nil
        if let published {
            guard published.id == project.id, project.revision >= published.revision else { throw ScrivError.conflict("This project package already contains a newer revision or a different project. Reopen it before saving.") }
            guard project.revision != published.revision || project == published else { throw ScrivError.conflict("An accepted project revision cannot be replaced with different content. Save the change as a new revision.") }
        }
        // History lands before current-state publication. A failed publication may leave
        // an orphan future snapshot; only that unpublished revision may be replaced.
        var writeHistory = true
        if fm.fileExists(atPath:revisionURL.path) {
            let existing = try ScrivJSON.decoder.decode(HistoryEntry.self,from:Data(contentsOf:revisionURL))
            if existing.snapshot == project { writeHistory = false }
            else {
                if let published, project.revision <= published.revision { throw ScrivError.conflict("The accepted history snapshot differs from this revision. Its original contents have been preserved.") }
            }
        }
        if writeHistory { try ScrivJSON.encoder.encode(event).write(to:revisionURL,options:.atomic) }
        try data.write(to:currentURL,options:.atomic)
        // The write-ahead record may be acknowledged only after these bytes and
        // the atomic replacement directory entries have reached durable storage.
        try syncSavedFile(revisionURL); try syncSavedFile(currentURL)
        try syncSavedFile(history,directory:true); try syncSavedFile(package,directory:true)
    }
    private func syncSavedFile(_ url: URL, directory: Bool = false) throws {
        let flags = O_RDONLY | O_NOFOLLOW | (directory ? O_DIRECTORY : 0)
        let descriptor = open(url.resolvingSymlinksInPath().path,flags)
        guard descriptor >= 0 else { throw ScrivError.unavailable("The saved project could not be opened for a durability check. Recovery was retained.") }
        defer { close(descriptor) }
        while fsync(descriptor) != 0 {
            if errno != EINTR { throw ScrivError.unavailable("The saved project could not be flushed to disk. Recovery was retained.") }
        }
    }
    public func load(at package: URL) throws -> ScrivProject {
        let source = try member("project.json", in:package)
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64*1024*1024 else { throw ScrivError.invalid("Project metadata exceeds the 64 MiB safety limit.") }
        let data = try Data(contentsOf: source)
        guard data.count <= 64*1024*1024 else { throw ScrivError.invalid("Project metadata exceeds the 64 MiB safety limit.") }
        let p = try ScrivJSON.decoder.decode(ScrivProject.self, from: data)
        try TimingEngine.validate(p)
        return p
    }
    public func history(at package: URL, through revision: Int = .max) throws -> [HistoryEntry] {
        let directory = try member("history", in:package)
        guard FileManager.default.fileExists(atPath:directory.path) else { return [] }
        // History is written before the current snapshot. Never offer an unpublished
        // future revision as an accepted restore point after an interrupted save.
        let current = try load(at:package), ceiling = min(revision,current.revision)
        let files = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey])
        var result: [HistoryEntry] = []
        for file in files where file.pathExtension == "json" {
            guard let number = Int(file.deletingPathExtension().lastPathComponent), number >= 0, number <= ceiling else { continue }
            let source = try member("history/" + file.lastPathComponent,in:package)
            let size = try source.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size <= 64*1024*1024 else { throw ScrivError.invalid("A history snapshot exceeds the metadata limit.") }
            let data = try Data(contentsOf:source)
            guard data.count <= 64*1024*1024 else { throw ScrivError.invalid("A history snapshot exceeds the metadata limit.") }
            let event = try ScrivJSON.decoder.decode(HistoryEntry.self,from:data)
            guard event.revision == number, event.snapshot.revision == number, event.snapshot.id == current.id, event.date.timeIntervalSince1970.isFinite else { throw ScrivError.invalid("A history snapshot has a different project identity or revision.") }
            try TimingEngine.validate(event.snapshot)
            result.append(event)
        }
        guard Set(result.map(\.revision)).count == result.count else { throw ScrivError.invalid("History contains duplicate revision numbers.") }
        return result.sorted { $0.revision > $1.revision }
    }
    public func importAsset(data: Data, at package: URL, prompt: String = "", characterIds: [String] = []) throws -> ImageAsset {
        guard !data.isEmpty, data.count <= 25*1024*1024 else { throw ScrivError.invalid("Choose an image smaller than 25 MiB.") }
        let bytes = [UInt8](data.prefix(12)), ext: String, mime: String
        if bytes.starts(with: [137,80,78,71,13,10,26,10]) { ext = "png"; mime = "image/png" }
        else if bytes.starts(with: [255,216,255]) { ext = "jpg"; mime = "image/jpeg" }
        else if bytes.count >= 12 && String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF" && String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { ext = "webp"; mime = "image/webp" }
        else { throw ScrivError.invalid("Only PNG, JPEG, and WebP images are supported.") }
        let hash = ScrivDigest.sha256(data), filename = hash + "." + ext
        let directory = try member("assets",in:package)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try member("assets/" + filename,in:package)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard ScrivDigest.sha256(try Data(contentsOf: destination)) == hash else { throw ScrivError.invalid("A local image failed its integrity check.") }
        } else { try data.write(to: destination, options: .atomic) }
        return ImageAsset(fileName: filename, sha256: hash, mimeType: mime, byteCount: data.count, characterIds: characterIds, prompt: prompt)
    }
    /// Save a peer/hosted replica using its existing immutable metadata and identity.
    public func storeReplica(_ data: Data, for asset: ImageAsset, at package: URL) throws {
        guard data.count == asset.byteCount, data.count <= 25*1024*1024, ScrivDigest.sha256(data) == asset.sha256,
              asset.fileName == URL(fileURLWithPath: asset.fileName).lastPathComponent, !asset.fileName.contains("..") else { throw ScrivError.invalid("The image replica failed its metadata or integrity check.") }
        let bytes = [UInt8](data.prefix(12))
        let actualMIME: String?
        if bytes.starts(with:[137,80,78,71,13,10,26,10]) { actualMIME = "image/png" }
        else if bytes.starts(with:[255,216,255]) { actualMIME = "image/jpeg" }
        else if bytes.count >= 12, String(bytes:bytes[0..<4],encoding:.ascii) == "RIFF", String(bytes:bytes[8..<12],encoding:.ascii) == "WEBP" { actualMIME = "image/webp" }
        else { actualMIME = nil }
        guard actualMIME == asset.mimeType else { throw ScrivError.invalid("The image content does not match its declared format.") }
        let directory = try member("assets",in:package)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let destination = try member("assets/" + asset.fileName,in:package)
        // The downloaded bytes are already size/hash/format verified. Replace even
        // a corrupt existing replica atomically rather than trapping it forever.
        try data.write(to:destination,options:.atomic)
    }

    public func assetData(_ asset: ImageAsset, at package: URL) throws -> Data {
        guard asset.fileName == URL(fileURLWithPath: asset.fileName).lastPathComponent, !asset.fileName.contains("..") else { throw ScrivError.invalid("Invalid asset path.") }
        let directory = try member("assets",in:package).resolvingSymlinksInPath()
        let source = directory.appendingPathComponent(asset.fileName).resolvingSymlinksInPath()
        guard source.deletingLastPathComponent() == directory else { throw ScrivError.invalid("The image path leaves this project package.") }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 25*1024*1024 else { throw ScrivError.invalid("The local image is too large.") }
        let data = try Data(contentsOf: source)
        guard data.count == asset.byteCount, ScrivDigest.sha256(data) == asset.sha256 else { throw ScrivError.invalid("The image failed its integrity check; request another replica.") }
        return data
    }
    public func projects() throws -> [URL] { try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "scriv" } }
    public func checkpoint(at package: URL) throws -> CloudCheckpoint? {
        let file = try member("cloud-sync.json",in:package)
        guard FileManager.default.fileExists(atPath:file.path) else { return nil }
        let size = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 64*1024*1024 else { throw ScrivError.invalid("Cloud checkpoint exceeds the metadata limit.") }
        return try ScrivJSON.decoder.decode(CloudCheckpoint.self,from:Data(contentsOf:file))
    }
    public func saveCheckpoint(_ checkpoint: CloudCheckpoint, at package: URL) throws {
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
        try ScrivJSON.encoder.encode(checkpoint).write(to:try member("cloud-sync.json",in:package),options:.atomic)
    }
    public func copyPackage(from source: URL, to destination: URL) throws {
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedSource != resolvedDestination else { return }
        guard !resolvedDestination.path.hasPrefix(resolvedSource.path + "/") else { throw ScrivError.invalid("Export the project outside its existing package.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ScrivError.invalid("A project already exists at this destination.") }
        _ = try load(at: source)
        // Do not export symlink-backed external files as if they were project assets.
        if let enumerator = FileManager.default.enumerator(at:source,includingPropertiesForKeys:[.isSymbolicLinkKey]) {
            for case let file as URL in enumerator {
                guard try file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink != true else { throw ScrivError.invalid("Project packages cannot contain symbolic links.") }
            }
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
    /// Package-internal members may not redirect reads or writes outside the package.
    /// The package itself may be at a user-selected resolved location.
    private func member(_ relativePath: String, in package: URL) throws -> URL {
        let root = package.resolvingSymlinksInPath().standardizedFileURL
        let expected = root.appendingPathComponent(relativePath).standardizedFileURL
        let actual = expected.resolvingSymlinksInPath().standardizedFileURL
        guard expected == actual, actual.path.hasPrefix(root.path + "/") else { throw ScrivError.invalid("A project member points outside its package or through a symbolic link.") }
        return expected
    }
}
