#if SCRIV_CLI_AUTOMATION
import UIKit
import Darwin
import ScrivCore

/// Read-only encoding of the actual loaded Swift model, never a package read or
/// a decoder/setter. Available only for this process's private synthetic run.
@MainActor
enum ScrivCLILoadedProject {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Synthetic loaded-project observation is unavailable or invalid." }
    }
    static func observe(workspace: ScrivWorkspaceController) throws -> [String: Any] {
        do { return try perform(workspace: workspace) }
        catch { throw Failure() }
    }
    private static func perform(workspace: ScrivWorkspaceController) throws -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains("--scriv-cli"), CommandLine.arguments.contains("--screenshots"),
              let runID = env["SCRIV_CLI_RUN_ID"], runID.count == 36, UUID(uuidString: runID) != nil,
              let configured = env["SCRIV_VERIFICATION_ROOT"] else { throw Failure() }
        let expected = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrivVerification-CLI-" + runID.lowercased()).standardizedFileURL
        guard URL(fileURLWithPath: configured).standardizedFileURL.path == expected.path else { throw Failure() }
        // Resolve only the trusted system temp prefix, never a run component.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(expected.lastPathComponent)
        guard root.standardizedFileURL == root, root.resolvingSymlinksInPath() == root else { throw Failure() }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure() }
        defer { close(rootFD) }
        var info = stat()
        guard fstat(rootFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o077) == 0,
              rootMatches(root, descriptor: rootFD) else { throw Failure() }
        let store = workspace.store
        let id = store.project.id
        guard id.count == 36, UUID(uuidString: id) != nil,
              store.projectURL?.standardizedFileURL.path == expected
                .appendingPathComponent("Projects").appendingPathComponent(id + ".scriv").path,
              workspace.viewIfLoaded?.window != nil else { throw Failure() }
        // Read-only observations may sample an ordinary error or the existing
        // navigation-wrapped owned-duration sheet, including its terminal error.
        // This never permits an action on a covered control or relaxes isolation.
        if let presented = workspace.presentedViewController {
            if let alert = presented as? UIAlertController {
                guard alert.preferredStyle == .alert,
                      alert.presentedViewController == nil else { throw Failure() }
            } else if presented is AudioLibraryController {
                // Only the exact library -> real trim editor chain is allowed.
                // Identity, rather than clip-value equality, lets this read-only
                // witness expose accidental changes during a pending draft.
                guard ScrivCLIAudioAnchorMenu.editor(in: workspace, requiresUnchangedClip: false) != nil
                else { throw Failure() }
            } else if presented is WordTimingEditorController {
                guard ScrivCLIWordTimingMenu.editor(in: workspace) != nil else { throw Failure() }
            } else {
                guard let navigation = presented as? UINavigationController,
                      navigation.modalPresentationStyle == .formSheet,
                      navigation.viewControllers.count == 1, navigation.children.count == 1,
                      let coverage = navigation.viewControllers.first as? ImageCoverageViewController,
                      navigation.children.first === coverage,
                      navigation.topViewController === coverage,
                      coverage.navigationController === navigation,
                      coverage.store === store, coverage.scopeToProject,
                      coverage.initialNavigationContext == store.navigationContext,
                      coverage.viewIfLoaded?.window != nil,
                      coverage.title == "Owned duration" else { throw Failure() }
                // The entry/cue snapshot and item ID are private. Store/context
                // and displayed mode bound this observation, not entry identity;
                // the audited UI route and journey must establish that identity.
                // UIKit may report the same presented alert on both controllers.
                var terminals: [UIViewController] = []
                for candidate in [navigation.presentedViewController, coverage.presentedViewController].compactMap({ $0 }) {
                    if !terminals.contains(where: { $0 === candidate }) { terminals.append(candidate) }
                }
                guard terminals.count <= 1 else { throw Failure() }
                if let terminal = terminals.first {
                    guard let alert = terminal as? UIAlertController, alert.preferredStyle == .alert,
                          alert.presentedViewController == nil,
                          navigation.visibleViewController === coverage || navigation.visibleViewController === alert
                    else { throw Failure() }
                } else {
                    guard navigation.visibleViewController === coverage else { throw Failure() }
                }
            }
        }
        let projectsFD = try childDirectory("Projects", parent: rootFD)
        defer { close(projectsFD) }
        let packageName = id + ".scriv"
        let packageFD = try childDirectory(packageName, parent: projectsFD)
        defer { close(packageFD) }
        // Match production file date encoding. No fields are selected, stripped,
        // normalized or reconstructed. Normal save/open owns validation.
        let bytes = try ScrivJSON.encoder.encode(store.project)
        guard bytes.count <= 4 * 1024 * 1024,
              rootMatches(root, descriptor: rootFD),
              childMatches("Projects", parent: rootFD, descriptor: projectsFD),
              childMatches(packageName, parent: projectsFD, descriptor: packageFD),
              let project = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { throw Failure() }
        // JSON's date strategy can hide sub-millisecond precision changes.
        // Preserve exact Date storage witnesses without normalizing either side.
        let dateBits: [String: Any] = [
            "createdAt": String(store.project.createdAt.timeIntervalSinceReferenceDate.bitPattern),
            "modifiedAt": String(store.project.modifiedAt.timeIntervalSinceReferenceDate.bitPattern),
            "images": store.project.images.map { image in
                ["id": image.id, "createdAt": String(image.createdAt.timeIntervalSinceReferenceDate.bitPattern)]
            }
        ]
        let result: [String: Any] = ["project": project, "dateReferenceTimeBits": dateBits]
        guard try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).count <= 4 * 1024 * 1024 else { throw Failure() }
        return result
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
