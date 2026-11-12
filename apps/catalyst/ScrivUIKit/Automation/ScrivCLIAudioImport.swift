#if SCRIV_CLI_AUTOMATION
import UIKit
import Darwin

/// A bounded synthetic-input boundary to the real post-picker audio importer.
/// This is not picker automation, microphone access, a decoder, or a model setter.
@MainActor
enum ScrivCLIAudioImport {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Synthetic audio import is unavailable or invalid." }
    }
    private static let byteLimit = 44 + 16_000 * 2 * 4
    private static var importing = false

    static func importWAV(base64: String, attachment: String, workspace: ScrivWorkspaceController) async throws -> [String: Any] {
        guard !importing else { throw Failure() }
        importing = true
        defer { importing = false }
        // Do not expose filesystem paths or decoder errors through this boundary.
        do { return try await perform(base64: base64, attachment: attachment, workspace: workspace) }
        catch { throw Failure() }
    }

    private static func perform(base64: String, attachment: String, workspace: ScrivWorkspaceController) async throws -> [String: Any] {
        guard attachment == "scene" || attachment == "selected-dialogue",
              !base64.isEmpty, base64.utf8.count <= ((byteLimit + 2) / 3) * 4,
              let bytes = Data(base64Encoded: base64), bytes.base64EncodedString() == base64,
              isBoundedPCM(bytes) else { throw Failure() }
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains("--scriv-cli"), CommandLine.arguments.contains("--screenshots"),
              let runID = env["SCRIV_CLI_RUN_ID"], runID.count == 36, UUID(uuidString: runID) != nil,
              let configured = env["SCRIV_VERIFICATION_ROOT"] else { throw Failure() }
        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrivVerification-CLI-" + runID.lowercased()).standardizedFileURL
        guard URL(fileURLWithPath: configured).standardizedFileURL.path == expected.path else { throw Failure() }
        // Resolve only the trusted system temporary prefix. No run-owned path
        // component may resolve through a symlink, including the package.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(expected.lastPathComponent)
        guard root.standardizedFileURL == root, root.resolvingSymlinksInPath() == root else { throw Failure() }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure() }
        defer { close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == geteuid(), (rootInfo.st_mode & 0o777) == 0o700,
              rootMatches(root, descriptor: rootFD) else { throw Failure() }
        let store = workspace.store
        let projectID = store.project.id
        guard UUID(uuidString: projectID) != nil,
              store.projectURL?.standardizedFileURL.path == expected
                .appendingPathComponent("Projects").appendingPathComponent(projectID + ".scriv").path,
              workspace.viewIfLoaded?.window != nil, workspace.presentedViewController == nil,
              store.errorMessage == nil, !store.isPlaying else { throw Failure() }
        let projectsFD = try childDirectory("Projects", parent: rootFD)
        defer { close(projectsFD) }
        let packageName = projectID + ".scriv"
        let packageFD = try childDirectory(packageName, parent: projectsFD)
        defer { close(packageFD) }

        // Finish the current draft through the ordinary presentation boundary.
        // All subsequent validation/import/persistence belongs to production code.
        UIKitPresentation.finishEditing(in: store)
        guard store.project.id == projectID, store.errorMessage == nil, !store.isPlaying,
              workspace.presentedViewController == nil,
              store.project.scenes.contains(where: { $0.id == store.selectedSceneID }) else { throw Failure() }
        let packageURL = store.projectURL
        let sceneID = store.selectedSceneID
        let selectedEntryID = store.selectedEntryID
        let navigation = store.navigationContext
        let entryID: String?
        if attachment == "selected-dialogue" {
            guard let entry = store.selectedEntry, entry.sceneId == store.selectedSceneID,
                  entry.kind == .dialogue else { throw Failure() }
            entryID = entry.id
        } else { entryID = nil }

        let importName = "ScrivCLIAudioImport-" + UUID().uuidString
        guard mkdirat(rootFD, importName, mode_t(0o700)) == 0 else { throw Failure() }
        let importFD = try childDirectory(importName, parent: rootFD)
        defer {
            if childMatches(importName, parent: rootFD, descriptor: importFD) {
                _ = unlinkat(rootFD, importName, AT_REMOVEDIR)
            }
            close(importFD)
        }
        // A fixed name is display metadata only. No caller-supplied path/name,
        // original recording, network address, or external destination is read.
        let name = "Synthetic.wav"
        let fileFD = openat(importFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fileFD >= 0 else { throw Failure() }
        defer { close(fileFD) }
        var created = stat()
        guard fstat(fileFD, &created) == 0, (created.st_mode & S_IFMT) == S_IFREG,
              created.st_uid == geteuid(), created.st_nlink == 1,
              (created.st_mode & 0o777) == 0o600 else { throw Failure() }
        defer {
            // Never recursively remove a directory, replacement, or package.
            if childMatches(name, parent: importFD, descriptor: fileFD) {
                _ = unlinkat(importFD, name, 0)
            }
        }
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

        // Keep the owned source alive until AVAudioFile analysis and the normal
        // store import finish. The store itself guards project/scene changes
        // across suspension; we do not retry or install a clip ourselves.
        let imported = await store.importAudio(from: root.appendingPathComponent(importName).appendingPathComponent(name), entryId: entryID)
        let removedFile = childMatches(name, parent: importFD, descriptor: fileFD)
            && unlinkat(importFD, name, 0) == 0
        let removedDirectory = removedFile && childMatches(importName, parent: rootFD, descriptor: importFD)
            && unlinkat(rootFD, importName, AT_REMOVEDIR) == 0
        var remaining = stat()
        let cleanupVerified = removedDirectory
            && fstatat(rootFD, importName, &remaining, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
        guard store.project.id == projectID, store.projectURL == packageURL,
              store.selectedSceneID == sceneID, store.selectedEntryID == selectedEntryID,
              store.navigationContext == navigation, rootMatches(root, descriptor: rootFD),
              childMatches("Projects", parent: rootFD, descriptor: projectsFD),
              childMatches(packageName, parent: projectsFD, descriptor: packageFD) else { throw Failure() }
        // `imported` is the real store result, not a fabricated save result.
        // Persisted metadata is observed separately by persisted-projects.
        return ["dispatched": true, "imported": imported, "cleanupVerified": cleanupVerified]
    }

    /// Restrict the input envelope to a canonical 44-byte RIFF header and up to
    /// four seconds of mono 16-bit, 16 kHz PCM. This does not decode samples,
    /// calculate duration/peaks, or replace the production AVAudioFile decoder.
    private static func isBoundedPCM(_ data: Data) -> Bool {
        guard data.count >= 46, data.count <= byteLimit, (data.count - 44) % 2 == 0 else { return false }
        let bytes = [UInt8](data)
        func ascii(_ offset: Int, _ expected: String) -> Bool {
            Array(bytes[offset..<(offset + 4)]) == Array(expected.utf8)
        }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) }
        func u32(_ offset: Int) -> Int {
            Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) |
                (Int(bytes[offset + 2]) << 16) | (Int(bytes[offset + 3]) << 24)
        }
        return ascii(0, "RIFF") && u32(4) == bytes.count - 8 && ascii(8, "WAVE") &&
            ascii(12, "fmt ") && u32(16) == 16 && u16(20) == 1 && u16(22) == 1 &&
            u32(24) == 16_000 && u32(28) == 32_000 && u16(32) == 2 && u16(34) == 16 &&
            ascii(36, "data") && u32(40) == bytes.count - 44
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
