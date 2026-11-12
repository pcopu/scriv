#if SCRIV_CLI_AUTOMATION
import UIKit
import Darwin

/// Captures the actual application's synchronous Fountain-file handoff. It
/// does not call a serializer, choose an external destination or copy a file.
@MainActor
enum ScrivCLIExport {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Synthetic Fountain export is unavailable or invalid." }
    }
    private static let byteLimit = 64 * 1024

    static func exportFountain(workspace: ScrivWorkspaceController) throws -> [String: Any] {
        do { return try perform(workspace: workspace) }
        catch { throw Failure() } // Never return underlying errors or local paths.
    }

    private static func perform(workspace: ScrivWorkspaceController) throws -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains("--scriv-cli"), CommandLine.arguments.contains("--screenshots"),
              let runID = env["SCRIV_CLI_RUN_ID"], runID.count == 36, UUID(uuidString: runID) != nil,
              let configured = env["SCRIV_VERIFICATION_ROOT"] else { throw Failure() }
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        let expected = temporary.appendingPathComponent("ScrivVerification-CLI-" + runID.lowercased()).standardizedFileURL
        guard URL(fileURLWithPath: configured).standardizedFileURL.path == expected.path else { throw Failure() }
        // Resolve only the trusted system temp prefix, never a run/export child.
        let canonicalTemp = temporary.resolvingSymlinksInPath()
        let root = canonicalTemp.appendingPathComponent(expected.lastPathComponent)
        let rootFD = try directory(root)
        defer { close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, (rootInfo.st_mode & 0o077) == 0 else { throw Failure() }
        let projectsFD = try childDirectory("Projects", parent: rootFD)
        defer { close(projectsFD) }
        let store = workspace.store
        let projectID = store.project.id
        guard UUID(uuidString: projectID) != nil else { throw Failure() }
        let packageName = projectID + ".scriv"
        let expectedPackage = expected.appendingPathComponent("Projects").appendingPathComponent(packageName)
        let packageFD = try childDirectory(packageName, parent: projectsFD)
        defer { close(packageFD) }

        func validateContext() throws {
            guard store.project.id == projectID,
                  store.projectURL?.standardizedFileURL.path == expectedPackage.path,
                  workspace.viewIfLoaded?.window != nil, workspace.presentedViewController == nil,
                  store.errorMessage == nil, directoryMatches(root, descriptor: rootFD),
                  childMatches("Projects", parent: rootFD, descriptor: projectsFD),
                  childMatches(packageName, parent: projectsFD, descriptor: packageFD) else { throw Failure() }
        }
        try validateContext()
        var result: [String: Any]?
        var generatedDirectory: URL?
        try UIKitFileAccess.shared.captureExportForCLI({
            // The real operation finishes editing, serializes, writes UTF-8,
            // and provides its own cleanup closure at the file-export handoff.
            store.exportScript()
        }, observe: { url in
            try validateContext()
            guard result == nil, url.isFileURL, url.standardizedFileURL == url,
                  url.lastPathComponent == "Script.fountain" else { throw Failure() }
            let directoryURL = url.deletingLastPathComponent()
            let directoryName = directoryURL.lastPathComponent
            let prefix = "ScrivExport-"
            guard directoryName.hasPrefix(prefix) else { throw Failure() }
            let suffix = String(directoryName.dropFirst(prefix.count))
            guard suffix.count == 36, UUID(uuidString: suffix) != nil,
                  directoryURL.deletingLastPathComponent().standardizedFileURL.path == temporary.path else { throw Failure() }
            let canonicalDirectory = canonicalTemp.appendingPathComponent(directoryName)
            let exportFD = try directory(canonicalDirectory)
            defer { close(exportFD) }
            let descriptor = openat(exportFD, "Script.fountain", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure() }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var before = stat()
            guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
                  before.st_uid == geteuid(), before.st_nlink == 1,
                  before.st_size >= 0, before.st_size <= byteLimit,
                  childMatches("Script.fountain", parent: exportFD, descriptor: descriptor) else { throw Failure() }
            let bytes = try handle.read(upToCount: byteLimit + 1) ?? Data()
            var after = stat()
            guard bytes.count == before.st_size, bytes.count <= byteLimit,
                  let text = String(data: bytes, encoding: .utf8),
                  fstat(descriptor, &after) == 0, after.st_size == before.st_size,
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  directoryMatches(canonicalDirectory, descriptor: exportFD),
                  childMatches("Script.fountain", parent: exportFD, descriptor: descriptor) else { throw Failure() }
            generatedDirectory = canonicalDirectory
            result = ["dispatched": true, "text": text, "byteCount": bytes.count]
        })
        try validateContext()
        guard var result, let generatedDirectory else { throw Failure() }
        // The production completion swallows deletion errors. Observe absence
        // rather than confusing 'cleanup invoked' with successful cleanup.
        var remaining = stat()
        guard lstat(generatedDirectory.path, &remaining) == -1, errno == ENOENT else { throw Failure() }
        result["cleanupVerified"] = true
        return result
    }

    private static func directory(_ url: URL) throws -> Int32 {
        guard url.standardizedFileURL == url, url.resolvingSymlinksInPath() == url else { throw Failure() }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), directoryMatches(url, descriptor: descriptor) else {
            close(descriptor); throw Failure()
        }
        return descriptor
    }

    private static func childDirectory(_ name: String, parent: Int32) throws -> Int32 {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), childMatches(name, parent: parent, descriptor: descriptor) else {
            close(descriptor); throw Failure()
        }
        return descriptor
    }

    private static func directoryMatches(_ url: URL, descriptor: Int32) -> Bool {
        var named = stat(), opened = stat()
        return lstat(url.path, &named) == 0 && fstat(descriptor, &opened) == 0 &&
            (named.st_mode & S_IFMT) == S_IFDIR && named.st_dev == opened.st_dev &&
            named.st_ino == opened.st_ino && url.resolvingSymlinksInPath() == url
    }

    private static func childMatches(_ name: String, parent: Int32, descriptor: Int32) -> Bool {
        var named = stat(), opened = stat()
        return fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
            fstat(descriptor, &opened) == 0 && (named.st_mode & S_IFMT) == (opened.st_mode & S_IFMT) &&
            named.st_dev == opened.st_dev && named.st_ino == opened.st_ino
    }
}
#endif
