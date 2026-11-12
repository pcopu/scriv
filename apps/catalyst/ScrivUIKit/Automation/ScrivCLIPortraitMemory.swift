#if SCRIV_CLI_AUTOMATION
import UIKit
import ImageIO
import Darwin
import ScrivCore

/// The seeded review can decode only its two published synthetic assets. No
/// caller paths, disk cache, model injection, provider, or command dispatcher.
@MainActor
enum ScrivCLIPortraitMemory {
    private struct Failure: Error {}
    @MainActor
    struct Prepared {
        fileprivate let run: ScrivCLIRunCapability
        fileprivate weak var workspace: ScrivWorkspaceController?
        fileprivate weak var workspaceWindow: UIWindow?
        fileprivate let projectID: String
        fileprivate let navigation: Int
        fileprivate let asset: ImageAsset
        fileprivate let source: URL
        fileprivate let bytes: Data
        fileprivate let region: NormalizedCharacterRegion?

        func validate(store: WorkspaceStore, view: UIView) throws {
            try ScrivCLIPortraitMemory.validate(run: run, store: store, projectID: projectID,
                                              navigation: navigation, asset: asset, source: source)
            guard let workspace, let workspaceWindow,
                  workspace.store === store,
                  workspace.viewIfLoaded?.window === workspaceWindow,
                  workspaceWindow.rootViewController === workspace,
                  !workspace.isBeingDismissed,
                  let window = view.window, view.superview != nil else { throw Failure() }
            // Bind the exact mounted view to its owning screen. A sheet may be
            // hosted in a different Catalyst window, but not an unrelated one.
            var responder: UIResponder? = view.next
            while let current = responder, !(current is UIViewController) { responder = current.next }
            guard let owner = responder as? ScrivScreenController,
                  owner.store === store, owner.contextIsCurrent,
                  let ownerView = owner.viewIfLoaded, ownerView.window === window,
                  view.isDescendant(of: ownerView), !owner.isBeingDismissed else { throw Failure() }
            if let review = owner as? CharacterImageReviewController {
                guard let navigationController = review.navigationController,
                      let presenter = navigationController.presentingViewController as? ScrivScreenController,
                      presenter.store === store, presenter.contextIsCurrent,
                      presenter.presentedViewController === navigationController,
                      workspace.presentedViewController == nil || workspace.presentedViewController === navigationController,
                      !navigationController.isBeingDismissed,
                      navigationController.viewControllers.count == 1,
                      navigationController.children.count == 1,
                      review.scopeToProject, review.initialNavigationContext == navigation,
                      navigationController.viewControllers.first === review,
                      navigationController.children.first === review,
                      navigationController.topViewController === review,
                      navigationController.visibleViewController === review,
                      review.navigationController === navigationController,
                      navigationController.presentedViewController == nil,
                      review.presentedViewController == nil,
                      navigationController.viewIfLoaded?.window === window else { throw Failure() }
                if presenter !== workspace {
                    guard presenter is CharactersController,
                          let presenterView = presenter.viewIfLoaded,
                          let workspaceView = workspace.viewIfLoaded,
                          presenterView.window === workspaceWindow,
                          presenterView.isDescendant(of: workspaceView),
                          !presenter.isBeingDismissed else { throw Failure() }
                    var ancestor = presenter.parent
                    while let current = ancestor, current !== workspace { ancestor = current.parent }
                    guard ancestor === workspace else { throw Failure() }
                }
            } else {
                guard workspace.presentedViewController == nil,
                      owner.presentedViewController == nil,
                      window === workspaceWindow,
                      let workspaceView = workspace.viewIfLoaded,
                      view.isDescendant(of: workspaceView) else { throw Failure() }
            }
        }
        func image() async throws -> UIImage {
            // Only immutable verified bytes/finite crop cross the actor boundary.
            let bytes = bytes, region = region
            let cgImage = try await Task.detached(priority: .utility) {
                try ScrivCLIPortraitMemory.decode(bytes, region: region)
            }.value
            return UIImage(cgImage: cgImage)
        }
    }

    static func prepare(store: WorkspaceStore, asset: ImageAsset, source: URL,
                        region: NormalizedCharacterRegion?) throws -> Prepared {
        let run = try ScrivCLIRunCapability.requirePrepared()
        // Capture the unique originating workspace before async decoding. Store
        // identity is explicit; no current-project singleton or window guessing.
        let workspaces = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.compactMap { $0.rootViewController as? ScrivWorkspaceController }
            .filter { $0.store === store && $0.viewIfLoaded?.window?.rootViewController === $0 }
        guard workspaces.count == 1, let workspace = workspaces.first,
              let workspaceWindow = workspace.viewIfLoaded?.window else { throw Failure() }
        let projectID = store.project.id, navigation = store.navigationContext
        try validate(run: run, store: store, projectID: projectID, navigation: navigation, asset: asset, source: source)
        if let region {
            let allowed = [NormalizedCharacterRegion(x: 0, y: 0, width: 0.5, height: 0.5),
                           NormalizedCharacterRegion(x: 0.5, y: 0, width: 0.5, height: 0.5),
                           NormalizedCharacterRegion(x: 0, y: 0.5, width: 0.5, height: 0.5)]
            guard region.isValid, allowed.contains(region) else { throw Failure() }
        }
        let root = run.root.resolvingSymlinksInPath()
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure() }
        defer { close(rootFD) }
        try run.validateRootDescriptor(rootFD)
        var rootNamed = stat(), rootOpened = stat()
        guard lstat(root.path, &rootNamed) == 0, fstat(rootFD, &rootOpened) == 0,
              same(rootNamed, rootOpened), (rootOpened.st_mode & S_IFMT) == S_IFDIR,
              rootOpened.st_uid == geteuid(), (rootOpened.st_mode & 0o777) == 0o700 else { throw Failure() }
        try run.validate()
        let projects = try directory("Projects", parent: rootFD)
        defer { close(projects) }
        let packageName = projectID + ".scriv"
        let package = try directory(packageName, parent: projects)
        defer { close(package) }
        let assets = try directory("assets", parent: package)
        defer { close(assets) }
        let fd = openat(assets, asset.fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure() }
        defer { close(fd) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, validFile(initial), matches(asset.fileName, parent: assets, fd: fd) else { throw Failure() }
        var bytes = Data(count: 74)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == 73 else { throw Failure() }
        bytes.removeLast()
        let expected = try ScrivCLILocalImageFixtures.bytes(asset.id == "v1" ? "coral" : "blue")
        guard bytes == expected, ScrivDigest.sha256(bytes) == asset.sha256 else { throw Failure() }
        var final = stat(), namedRoot = stat(), openedRoot = stat()
        guard fstat(fd, &final) == 0, validFile(final), same(initial, final),
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
              initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
              initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec,
              matches(asset.fileName, parent: assets, fd: fd),
              matches("assets", parent: package, fd: assets),
              matches(packageName, parent: projects, fd: package),
              matches("Projects", parent: rootFD, fd: projects),
              lstat(root.path, &namedRoot) == 0, fstat(rootFD, &openedRoot) == 0,
              same(namedRoot, openedRoot), openedRoot.st_uid == geteuid(),
              (openedRoot.st_mode & 0o777) == 0o700 else { throw Failure() }
        try validate(run: run, store: store, projectID: projectID, navigation: navigation, asset: asset, source: source)
        try run.validateRootDescriptor(rootFD)
        return Prepared(run: run, workspace: workspace, workspaceWindow: workspaceWindow, projectID: projectID, navigation: navigation, asset: asset,
                        source: source, bytes: bytes, region: region)
    }

    private static func validate(run: ScrivCLIRunCapability, store: WorkspaceStore, projectID: String,
                                 navigation: Int, asset: ImageAsset, source: URL) throws {
        try run.validate()
        guard run.approvedOrigin == nil, store.account == nil, store.cloud.account == nil,
              store.project.cloudProjectId == nil, store.cloud.projectId == nil,
              store.codex.jobs.isEmpty, store.codex.sharedJobs.isEmpty,
              !store.characterAnalysis.isScanning,
              store.characterAnalysis.availability == "Image analysis is disabled in verification mode.",
              store.project.id == projectID, UUID(uuidString: projectID) != nil,
              store.navigationContext == navigation, store.project.asset(asset.id) == asset,
              asset.mimeType == "image/png", asset.byteCount == 73,
              (asset.id == "v1" && asset.version == 1 || asset.id == "v2" && asset.version == 2),
              ScrivCLIPackageFixture.permitsPortrait(projectID: projectID, assetID: asset.id,
                                                    fileName: asset.fileName, sha256: asset.sha256) else { throw Failure() }
        let package = run.root.appendingPathComponent("Projects").appendingPathComponent(projectID + ".scriv")
        guard store.projectURL?.path == package.path,
              source.path == run.root.resolvingSymlinksInPath().appendingPathComponent("Projects")
                .appendingPathComponent(projectID + ".scriv").appendingPathComponent("assets").appendingPathComponent(asset.fileName).path,
              store.assetURL(asset)?.path == source.path else { throw Failure() }
    }

    nonisolated private static func decode(_ bytes: Data, region: NormalizedCharacterRegion?) throws -> CGImage {
        guard let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil),
              let type = CGImageSourceGetType(imageSource), type as String == "public.png",
              CGImageSourceGetCount(imageSource) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 2,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 2,
              let oriented = CGImageSourceCreateThumbnailAtIndex(imageSource,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:2048] as CFDictionary),
              oriented.width == 2, oriented.height == 2 else { throw Failure() }
        guard let region else { return oriented }
        // Identical production orientation and integral/intersection crop math.
        guard region.isValid else { throw Failure() }
        let bounds = CGRect(x:region.x * Double(oriented.width),y:region.y * Double(oriented.height),width:region.width * Double(oriented.width),height:region.height * Double(oriented.height)).integral.intersection(CGRect(x:0,y:0,width:CGFloat(oriented.width),height:CGFloat(oriented.height)))
        guard !bounds.isEmpty, let cropped = oriented.cropping(to:bounds) else { throw Failure() }
        return cropped
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        (a.st_mode & S_IFMT) == (b.st_mode & S_IFMT) && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
    private static func validFile(_ s: stat) -> Bool {
        (s.st_mode & S_IFMT) == S_IFREG && s.st_uid == geteuid() && s.st_nlink == 1 && s.st_size == 73 && (s.st_mode & 0o022) == 0
    }
    private static func matches(_ name: String, parent: Int32, fd: Int32) -> Bool {
        var named = stat(), opened = stat()
        return fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && fstat(fd, &opened) == 0 && same(named, opened)
            && opened.st_uid == geteuid() && (opened.st_mode & 0o022) == 0
    }
    private static func directory(_ name: String, parent: Int32) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), (info.st_mode & 0o022) == 0,
              matches(name, parent: parent, fd: fd) else { close(fd); throw Failure() }
        return fd
    }
}
#endif
