import Foundation

/// Audio is local-only, copied into the project package and exported with it.
/// No external paths or security-scoped bookmarks are persisted in metadata.
public enum AudioFileStore {
    public static func store(_ data: Data, fileExtension: String, at package: URL) throws -> (url: URL, sha256: String, fileName: String) {
        let ext = fileExtension.lowercased()
        guard !data.isEmpty, data.count <= AudioTimeline.maximumFileBytes, AudioTimeline.supportedExtensions.contains(ext) else {
            throw ScrivError.invalid("Choose WAV, AIFF, M4A, MP3, CAF, AAC or FLAC audio no larger than 100 MiB.")
        }
        let hash = ScrivDigest.sha256(data), name = hash + "." + ext
        let destination = try member(name, at: package, create: true)
        // Atomic replacement also repairs a corrupt replica of the same content hash.
        try data.write(to: destination, options: .atomic)
        return (destination, hash, name)
    }
    /// Confines a metadata path; call verifiedData before trusting or playing its bytes.
    public static func url(asset: AudioAsset, package: URL) throws -> URL {
        let ext = URL(fileURLWithPath: asset.fileName).pathExtension.lowercased()
        guard asset.sha256.count == 64, asset.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              AudioTimeline.supportedExtensions.contains(ext), asset.fileName == asset.sha256 + "." + ext else {
            throw ScrivError.invalid("The local audio has invalid file metadata.")
        }
        return try member(asset.fileName, at: package, create: false)
    }
    public static func verifiedData(for asset: AudioAsset, at package: URL) throws -> Data {
        let ext = URL(fileURLWithPath: asset.fileName).pathExtension.lowercased()
        guard asset.sha256.count == 64, asset.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              AudioTimeline.supportedExtensions.contains(ext), asset.fileName == asset.sha256 + "." + ext,
              asset.byteCount > 0, asset.byteCount <= AudioTimeline.maximumFileBytes else {
            throw ScrivError.invalid("The local audio has invalid file metadata.")
        }
        let source = try member(asset.fileName, at: package, create: false)
        let size = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, size.fileSize == asset.byteCount else { throw ScrivError.invalid("The local audio is missing or has changed size.") }
        let data = try Data(contentsOf: source)
        guard data.count == asset.byteCount, ScrivDigest.sha256(data) == asset.sha256 else { throw ScrivError.invalid("The local audio failed its integrity check. Import the original file again.") }
        return data
    }
    private static func member(_ name: String, at package: URL, create: Bool) throws -> URL {
        guard package.isFileURL, name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("..") else { throw ScrivError.invalid("Invalid local audio package path.") }
        let fm = FileManager.default
        if create { try fm.createDirectory(at: package, withIntermediateDirectories: true) }
        let root = package.standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("audio", isDirectory: true)
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else { throw ScrivError.invalid("The audio directory leaves the project package.") }
        if create { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let file = directory.appendingPathComponent(name)
        guard file.resolvingSymlinksInPath().standardizedFileURL.path == file.standardizedFileURL.path else { throw ScrivError.invalid("The audio file leaves the project package.") }
        return file
    }
}
