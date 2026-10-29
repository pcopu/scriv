import Foundation

public actor ProjectRepository {
    public let root: URL
    public init(root: URL) throws { self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    public func defaultURL(for project: ScrivProject) -> URL { root.appendingPathComponent(project.id).appendingPathExtension("scriv") }
    public func save(_ project: ScrivProject, at package: URL, label: String) throws {
        try TimingEngine.validate(project)
        let fm = FileManager.default
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try fm.createDirectory(at: package.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let history = package.appendingPathComponent("history")
        try fm.createDirectory(at: history, withIntermediateDirectories: true)
        let data = try ScrivJSON.encoder.encode(project)
        let event = HistoryEntry(label: label, snapshot: project)
        let revisionURL = history.appendingPathComponent(String(format: "%012d", project.revision)).appendingPathExtension("json")
        let currentURL = package.appendingPathComponent("project.json")
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
    }
    public func load(at package: URL) throws -> ScrivProject {
        let source = package.appendingPathComponent("project.json")
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64*1024*1024 else { throw ScrivError.invalid("Project metadata exceeds the 64 MiB safety limit.") }
        let data = try Data(contentsOf: source)
        guard data.count <= 64*1024*1024 else { throw ScrivError.invalid("Project metadata exceeds the 64 MiB safety limit.") }
        let p = try ScrivJSON.decoder.decode(ScrivProject.self, from: data)
        try TimingEngine.validate(p)
        return p
    }
    public func history(at package: URL, through revision: Int = .max) throws -> [HistoryEntry] {
        let directory = package.appendingPathComponent("history")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.compactMap { url in
            let item = try ScrivJSON.decoder.decode(HistoryEntry.self, from: Data(contentsOf: url)); return item.revision <= revision ? item : nil
        }
    }
    public func importAsset(data: Data, at package: URL, prompt: String = "", characterIds: [String] = []) throws -> ImageAsset {
        guard !data.isEmpty, data.count <= 25*1024*1024 else { throw ScrivError.invalid("Choose an image smaller than 25 MiB.") }
        let bytes = [UInt8](data.prefix(12)), ext: String, mime: String
        if bytes.starts(with: [137,80,78,71,13,10,26,10]) { ext = "png"; mime = "image/png" }
        else if bytes.starts(with: [255,216,255]) { ext = "jpg"; mime = "image/jpeg" }
        else if bytes.count >= 12 && String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF" && String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { ext = "webp"; mime = "image/webp" }
        else { throw ScrivError.invalid("Only PNG, JPEG, and WebP images are supported.") }
        let hash = ScrivDigest.sha256(data), filename = hash + "." + ext
        let directory = package.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard ScrivDigest.sha256(try Data(contentsOf: destination)) == hash else { throw ScrivError.invalid("A local image failed its integrity check.") }
        } else { try data.write(to: destination, options: .atomic) }
        return ImageAsset(fileName: filename, sha256: hash, mimeType: mime, byteCount: data.count, characterIds: characterIds, prompt: prompt)
    }
    /// Save a peer/hosted replica using its existing immutable metadata and identity.
    public func storeReplica(_ data: Data, for asset: ImageAsset, at package: URL) throws {
        guard data.count == asset.byteCount, data.count <= 25*1024*1024, ScrivDigest.sha256(data) == asset.sha256,
              asset.fileName == URL(fileURLWithPath: asset.fileName).lastPathComponent, !asset.fileName.contains("..") else { throw ScrivError.invalid("The image replica failed its metadata or integrity check.") }
        let imported = try importAsset(data: data, at: package)
        guard imported.mimeType == asset.mimeType else { throw ScrivError.invalid("The image content does not match its declared format.") }
        let directory = package.appendingPathComponent("assets")
        let destination = directory.appendingPathComponent(asset.fileName)
        guard destination.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw ScrivError.invalid("Invalid image destination.") }
        if imported.fileName != asset.fileName { try data.write(to: destination, options: .atomic) }
    }
    public func assetData(_ asset: ImageAsset, at package: URL) throws -> Data {
        guard asset.fileName == URL(fileURLWithPath: asset.fileName).lastPathComponent, !asset.fileName.contains("..") else { throw ScrivError.invalid("Invalid asset path.") }
        let directory = package.appendingPathComponent("assets").resolvingSymlinksInPath()
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
        let file = package.appendingPathComponent("cloud-sync.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return nil }
        let size = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 64*1024*1024 else { throw ScrivError.invalid("Cloud checkpoint exceeds the metadata limit.") }
        return try ScrivJSON.decoder.decode(CloudCheckpoint.self,from:Data(contentsOf:file))
    }
    public func saveCheckpoint(_ checkpoint: CloudCheckpoint, at package: URL) throws {
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
        try ScrivJSON.encoder.encode(checkpoint).write(to:package.appendingPathComponent("cloud-sync.json"),options:.atomic)
    }
    public func copyPackage(from source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ScrivError.invalid("A project already exists at this destination.") }
        _ = try load(at: source)
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
