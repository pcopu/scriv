#if SCRIV_CLI_AUTOMATION
import UIKit
import Darwin

/// Explicit semantic import boundary, not document-picker or physical-input
/// automation. Only synthetic text enters the ordinary production importer.
@MainActor
enum ScrivCLIImport {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Synthetic script import is unavailable or invalid." }
    }
    // Keep even a JSON-escaped over-limit probe inside the CLI's 1 MiB envelope.
    private static let textLimit = 64 * 1024

    static func importFountain(text: String, filename: String = "Import.fountain", workspace: ScrivWorkspaceController) throws -> [String: Any] {
        // No filesystem paths or underlying errors are returned to the caller.
        do { return try perform(text: text, filename: filename, fileExtension: "fountain", workspace: workspace) }
        catch { throw Failure() }
    }

    static func importJSON(text: String, workspace: ScrivWorkspaceController) throws -> [String: Any] {
        do { return try perform(text: text, filename: "Import.json", fileExtension: "json", workspace: workspace) }
        catch { throw Failure() }
    }

    private static func perform(text: String, filename: String, fileExtension: String, workspace: ScrivWorkspaceController) throws -> [String: Any] {
        guard text.utf8.count <= textLimit,
              !filename.isEmpty, filename.utf8.count <= 128,
              filename.hasSuffix("." + fileExtension), !filename.hasPrefix("."),
              !filename.contains("/"), !filename.contains("\\"), !filename.contains(":"),
              filename.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw Failure() }
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains("--scriv-cli"), CommandLine.arguments.contains("--screenshots"),
              let runID = env["SCRIV_CLI_RUN_ID"], runID.count == 36, UUID(uuidString: runID) != nil,
              let configured = env["SCRIV_VERIFICATION_ROOT"] else { throw Failure() }
        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrivVerification-CLI-" + runID.lowercased()).standardizedFileURL
        guard URL(fileURLWithPath: configured).standardizedFileURL.path == expected.path else { throw Failure() }
        // Only the trusted system temp prefix may resolve /var -> /private/var.
        // No run-owned component may be a symlink.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(expected.lastPathComponent)
        guard root.standardizedFileURL == root, root.resolvingSymlinksInPath() == root else { throw Failure() }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure() }
        defer { close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == geteuid(), (rootInfo.st_mode & 0o077) == 0,
              rootMatches(root, descriptor: rootFD) else { throw Failure() }

        let store = workspace.store
        let previousID = store.project.id
        guard UUID(uuidString: previousID) != nil,
              store.projectURL?.standardizedFileURL.path == expected
                .appendingPathComponent("Projects").appendingPathComponent(previousID + ".scriv").path,
              workspace.viewIfLoaded?.window != nil, workspace.presentedViewController == nil,
              store.errorMessage == nil else { throw Failure() }
        let projectsFD = try childDirectory("Projects", parent: rootFD)
        defer { close(projectsFD) }
        let packageName = previousID + ".scriv"
        let packageFD = try childDirectory(packageName, parent: projectsFD)
        defer { close(packageFD) }

        // This is the same finish-editing boundary used before the real picker.
        // It commits an active draft normally; no parser/model/store assignment
        // or special test-only save is performed here.
        UIKitPresentation.finishEditing(in: store)
        guard store.project.id == previousID, store.errorMessage == nil,
              workspace.presentedViewController == nil else { throw Failure() }

        // A filename is a bounded display-name component, never a caller path.
        // Each import owns an exclusive private directory, so identical names
        // cannot collide and production fallback-title behavior stays real.
        let importName = "ScrivCLIImport-" + UUID().uuidString
        guard mkdirat(rootFD, importName, mode_t(0o700)) == 0 else { throw Failure() }
        let importFD = try childDirectory(importName, parent: rootFD)
        defer {
            if childMatches(importName, parent: rootFD, descriptor: importFD) {
                _ = unlinkat(rootFD, importName, AT_REMOVEDIR)
            }
            close(importFD)
        }
        let name = filename
        let fileFD = openat(importFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fileFD >= 0 else { throw Failure() }
        defer { close(fileFD) }
        var created = stat()
        guard fstat(fileFD, &created) == 0, (created.st_mode & S_IFMT) == S_IFREG,
              created.st_uid == geteuid(), created.st_nlink == 1 else { throw Failure() }
        defer {
            // Never recursively remove the run, another import, or a replacement.
            var current = stat()
            if fstatat(importFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
               (current.st_mode & S_IFMT) == S_IFREG,
               current.st_dev == created.st_dev, current.st_ino == created.st_ino {
                _ = unlinkat(importFD, name, 0)
            }
        }
        let bytes = Data(text.utf8)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard let base = buffer.baseAddress else { throw Failure() }
                let written = Darwin.write(fileFD, base.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure() }
                offset += written
            }
        }
        var writtenInfo = stat()
        guard fstat(fileFD, &writtenInfo) == 0, writtenInfo.st_size == bytes.count,
              writtenInfo.st_nlink == 1, rootMatches(root, descriptor: rootFD),
              childMatches("Projects", parent: rootFD, descriptor: projectsFD),
              childMatches(packageName, parent: projectsFD, descriptor: packageFD),
              childMatches(importName, parent: rootFD, descriptor: importFD),
              childMatches(name, parent: importFD, descriptor: fileFD) else { throw Failure() }

        // This synchronously reads/parses/validates/installs through exactly the
        // entry point used after the production picker. Normal persistence is
        // observed separately through persisted-projects, never fabricated here.
        store.importScript(from: root.appendingPathComponent(importName).appendingPathComponent(name))
        return ["dispatched": true, "projectChanged": store.project.id != previousID]
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

    private static func rootMatches(_ url: URL, descriptor: Int32) -> Bool {
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
