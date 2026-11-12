#if SCRIV_CLI_AUTOMATION
import UIKit
import ImageIO
import Darwin
import ScrivCore

/// Reads only allowlisted fixture bytes in the current isolated local package.
/// No generation-journal fallback, caller asset identifier, path, or mutation.
@MainActor
enum ScrivCLILocalImageEvidence {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Local image evidence is unavailable or inconsistent." }
    }
    static func observe(workspace: ScrivWorkspaceController, windows: [UIWindow]) throws -> [String: Any] {
        do { return try collect(workspace: workspace, windows: windows) }
        catch { throw Failure() }
    }
    private static func collect(workspace: ScrivWorkspaceController, windows: [UIWindow]) throws -> [String: Any] {
        let run = try ScrivCLIRunCapability.requirePrepared()
        let store = workspace.store
        guard run.approvedOrigin == nil, store.account == nil, store.cloud.account == nil,
              store.project.cloudProjectId == nil, store.cloud.projectId == nil,
              store.codex.jobs.isEmpty, store.codex.sharedJobs.isEmpty,
              !store.characterAnalysis.isScanning,
              store.characterAnalysis.availability == "Image analysis is disabled in verification mode.",
              store.errorMessage == nil, !store.isPlaying, workspace.viewIfLoaded?.window != nil,
              store.project.id.count == 36, UUID(uuidString: store.project.id) != nil,
              store.project.images.count <= 100 else { throw Failure() }
        // Bind evidence to one validated visible surface, never another owned
        // window. Catalyst may host this exact sheet in a second scene window.
        guard let workspaceView = workspace.viewIfLoaded, let workspaceWindow = workspaceView.window,
              workspaceWindow.rootViewController === workspace,
              windows.contains(where: { $0 === workspaceWindow }) else { throw Failure() }
        let surface: UIView
        let surfaceWindow: UIWindow
        if let presented = workspace.presentedViewController {
            guard let navigation = presented as? UINavigationController,
                  navigation.presentingViewController === workspace,
                  !navigation.isBeingDismissed,
                  navigation.viewControllers.count == 1,
                  let inspector = navigation.viewControllers.first as? ImageDetailViewController,
                  navigation.topViewController === inspector, navigation.visibleViewController === inspector,
                  navigation.children.count == 1, navigation.children.first === inspector,
                  inspector.navigationController === navigation,
                  navigation.presentedViewController == nil, inspector.presentedViewController == nil,
                  !inspector.isBeingPresented, !inspector.isBeingDismissed,
                  inspector.store === store, inspector.scopeToProject, inspector.contextIsCurrent,
                  inspector.initialNavigationContext == store.navigationContext,
                  let inspectorView = inspector.viewIfLoaded, let window = inspectorView.window,
                  let navigationView = navigation.viewIfLoaded, navigationView.window === window,
                  !navigationView.isHidden, navigationView.alpha > 0.01,
                  !inspectorView.isHidden, inspectorView.alpha > 0.01,
                  !window.isHidden, window.alpha > 0.01,
                  windows.contains(where: { $0 === window }),
                  store.project.asset(inspector.imageID) != nil else { throw Failure() }
            // Catalyst can retain isBeingPresented on this attached navigation
            // controller and bridge its sheet into another scene. Read-only
            // sampling uses the exact presenter/controller/window links above;
            // neither flag nor scene identity authorizes control activation.
            surface = inspectorView; surfaceWindow = window
        } else {
            guard workspaceWindow.rootViewController === workspace,
                  !workspace.isBeingPresented, !workspace.isBeingDismissed else { throw Failure() }
            surface = workspaceView; surfaceWindow = workspaceWindow
        }
        guard let windowIndex = windows.firstIndex(where: { $0 === surfaceWindow }) else { throw Failure() }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ScrivVerification-CLI-" + run.runID.uuidString.lowercased())
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure() }
        defer { close(rootFD) }
        var info = stat()
        guard fstat(rootFD, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o700, rootMatches(root, descriptor: rootFD) else { throw Failure() }
        let projectID = store.project.id, packageName = projectID + ".scriv"
        guard store.projectURL?.path == run.root.appendingPathComponent("Projects").appendingPathComponent(packageName).path else { throw Failure() }
        let projects = try childDirectory("Projects", parent: rootFD)
        defer { close(projects) }
        let package = try childDirectory(packageName, parent: projects)
        defer { close(package) }
        var records: [[String: Any]] = []
        if !store.project.images.isEmpty {
            let assets = try childDirectory("assets", parent: package)
            defer { close(assets) }
            for asset in store.project.images {
                guard asset.sha256.count == 64, asset.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      (asset.fileName == asset.sha256 + ".png" || ScrivCLIPackageFixture.permitsImageAlias(
                        projectID: projectID, assetID: asset.id, fileName: asset.fileName, sha256: asset.sha256)),
                      asset.byteCount == 73 else { throw Failure() }
                let fd = openat(assets, asset.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw Failure() }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var file = stat()
                guard fstat(fd, &file) == 0, (file.st_mode & S_IFMT) == S_IFREG,
                      file.st_uid == geteuid(), file.st_nlink == 1, file.st_size == 73,
                      childMatches(asset.fileName, parent: assets, descriptor: fd) else { throw Failure() }
                let bytes = try handle.read(upToCount: 129) ?? Data()
                guard bytes.count == asset.byteCount, ScrivDigest.sha256(bytes) == asset.sha256,
                      ScrivCLILocalImageFixtures.matching(bytes),
                      let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let type = CGImageSourceGetType(source), type as String == "public.png",
                      CGImageSourceGetCount(source) == 1,
                      let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      decoded.width == 2, decoded.height == 2,
                      childMatches(asset.fileName, parent: assets, descriptor: fd),
                      childMatches("assets", parent: package, descriptor: assets) else { throw Failure() }
                let previews = previewEvidence(surface: surface, window: surfaceWindow, windowIndex: windowIndex, digest: asset.sha256, width: 2, height: 2)
                records.append(["assetID": asset.id, "sha256": asset.sha256, "byteCount": bytes.count,
                    "width": 2, "height": 2, "decoded": true,
                    "visiblePreviewCount": previews.count, "previews": previews])
            }
        }
        try run.validate()
        guard store.project.id == projectID, rootMatches(root, descriptor: rootFD),
              childMatches("Projects", parent: rootFD, descriptor: projects),
              childMatches(packageName, parent: projects, descriptor: package) else { throw Failure() }
        return ["schemaVersion": 1, "projectID": projectID, "generationJobCount": 0,
                "analysisScanning": false, "assets": records]
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
    private static func previewEvidence(surface: UIView, window: UIWindow, windowIndex: Int, digest: String, width: Int, height: Int) -> [[String: Any]] {
        var result: [[String: Any]] = [], seen = Set<ObjectIdentifier>()
        func visit(_ view: UIView, window: UIWindow, index: Int) {
            guard seen.insert(ObjectIdentifier(view)).inserted, !view.isHidden, view.alpha > 0.01 else { return }
            if let picture = view as? UIKitAssetImageView, 
               picture.loadPhase == .loaded, picture.loadedDigest == digest,
               let imageView = picture.subviews.compactMap({ $0 as? UIImageView }).first(where: { !$0.isHidden && $0.image != nil }),
               let image = imageView.image?.cgImage, image.width == width, image.height == height {
                var rect = imageView.convert(imageView.bounds, to: window).intersection(window.bounds)
                var ancestor: UIView? = imageView
                while let current = ancestor {
                    if current.isHidden || current.alpha <= 0.01 { rect = .null; break }
                    if current.clipsToBounds { rect = rect.intersection(current.convert(current.bounds, to: window)) }
                    ancestor = current.superview
                }
                // Reject preview content behind a presented modal.
                var top = window.rootViewController
                while let presented = top?.presentedViewController { top = presented }
                let active = top?.viewIfLoaded.map { picture.isDescendant(of: $0) } ?? false
                if active, !rect.isNull, !rect.isEmpty, rect.origin.x.isFinite, rect.origin.y.isFinite,
                   rect.width.isFinite, rect.height.isFinite {
                    result.append(["windowIndex": index, "loadedDigest": digest, "width": image.width, "height": image.height,
                        "frame": ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]])
                }
            }
            for child in view.subviews { visit(child, window: window, index: index) }
        }
        if !window.isHidden && window.alpha > 0.01, surface.window === window {
            visit(surface, window: window, index: windowIndex)
        }
        return result
    }
}
#endif
