import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Establish newly created directory entries before a write-ahead record can
/// become the only accepted copy. Existing selected packages need no access to
/// their parent; only a newly created chain and its existing parent are flushed.
enum DurableDirectory {
    static func create(at url: URL) throws {
        let fm = FileManager.default
        var missing: [URL] = [], cursor = url.standardizedFileURL
        while !fm.fileExists(atPath:cursor.path) {
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent != cursor else { break }
            cursor = parent
        }
        try fm.createDirectory(at:url,withIntermediateDirectories:true)
        guard !missing.isEmpty else { return }
        for directory in missing + [cursor] { try flush(directory) }
    }
    static func flush(_ url: URL) throws {
        let descriptor = open(url.resolvingSymlinksInPath().path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ScrivError.unavailable("A new local storage directory could not be opened for durability verification. Recovery was retained.") }
        defer { close(descriptor) }
        while fsync(descriptor) != 0 {
            if errno != EINTR { throw ScrivError.unavailable("A new local storage directory could not be flushed to disk. Recovery was retained.") }
        }
    }
}
