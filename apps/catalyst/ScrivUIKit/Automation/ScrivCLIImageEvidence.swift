#if SCRIV_CLI_AUTOMATION
import UIKit
import ImageIO
import Darwin
import ScrivCore

/// Observation only. Never constructs a journal, repairs storage, or starts work.
@MainActor
enum ScrivCLIImageEvidence {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Image evidence is unavailable or inconsistent." }
    }
    private static let imageLimit = 25 * 1024 * 1024

    static func observe(workspace: ScrivWorkspaceController, windows: [UIWindow]) throws -> [String: Any] {
        // Do not leak Foundation errors containing a path through the CLI reply.
        do { return try collect(workspace: workspace, windows: windows) }
        catch { throw Failure() }
    }

    private static func collect(workspace: ScrivWorkspaceController, windows: [UIWindow]) throws -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains("--scriv-cli"), CommandLine.arguments.contains("--screenshots"),
              let runID = env["SCRIV_CLI_RUN_ID"], runID.count == 36, UUID(uuidString: runID) != nil,
              let configured = env["SCRIV_VERIFICATION_ROOT"] else { throw Failure() }
        let expected = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivVerification-CLI-" + runID.lowercased()).standardizedFileURL
        guard URL(fileURLWithPath: configured).standardizedFileURL.path == expected.path else { throw Failure() }
        // The system's temporary-directory prefix can contain /var -> /private/var.
        // Resolve only that trusted prefix, never any run-owned component.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(expected.lastPathComponent)
        let rootFD = try directory(root)
        defer { close(rootFD) }
        let store = workspace.store
        guard store.codex.jobs.count <= 1000 else { throw Failure() }
        var records: [[String: Any]] = []
        for job in store.codex.jobs {
            guard let context = job.context, UUID(uuidString: context.projectID) != nil else { continue }
            let relative = "Projects/" + context.projectID + ".scriv"
            let package = expected.appendingPathComponent(relative)
            // An exact context match is required, not a suffix or resolved-path match.
            guard context.packagePath == package.path else { continue }
            guard UUID(uuidString: job.id) != nil, safeMetadataID(context.targetCue.id) else { throw Failure() }
            guard records.count < 100 else { throw Failure() }
            let projectData = try read(root: root, relative: relative + "/project.json", limit: 4 * 1024 * 1024)
            let project = try ScrivJSON.decoder.decode(ScrivProject.self, from: projectData)
            guard project.id == context.projectID else { throw Failure() }
            var record: [String: Any] = ["jobID": job.id, "projectID": project.id,
                "cueID": context.targetCue.id, "status": job.status.rawValue,
                "journalVerified": false, "attachmentVerified": false,
                "hasThreadID": !(job.threadID ?? "").isEmpty, "hasTurnID": !(job.turnID ?? "").isEmpty,
                "visiblePreviewCount": 0, "previews": []]
            if let outputID = job.outputImageID {
                guard UUID(uuidString: outputID) != nil else { throw Failure() }
                record["outputImageID"] = outputID
            }
            // No public read-only root accessor exists before an artifact is recorded.
            // Such a job is explicitly incomplete evidence, never a verified result.
            if job.artifactRelativePath == nil && job.artifactSha256 == nil {
                guard job.status != .completed, job.outputImageID == nil else { throw Failure() }
                records.append(record); continue
            }
            let descriptor = try store.codex.artifact(for: job.id)
            guard descriptor.jobID == job.id, descriptor.root.lastPathComponent == "Generation",
                  descriptor.root == descriptor.root.resolvingSymlinksInPath(),
                  descriptor.root == root.appendingPathComponent("Generation") ||
                    descriptor.root.deletingLastPathComponent().lastPathComponent == "Scriv" else { throw Failure() }
            let journalBytes = try read(root: descriptor.root, relative: "Journal/" + job.id + ".json", limit: 2 * 1024 * 1024)
            let persisted = try ScrivJSON.decoder.decode(LocalGenerationJob.self, from: journalBytes)
            guard persisted.id == job.id, persisted.context == job.context, persisted.status == job.status,
                  persisted.outputImageID == job.outputImageID, persisted.artifactRelativePath == descriptor.relativePath,
                  persisted.artifactSha256 == descriptor.sha256, persisted.threadID == job.threadID,
                  persisted.turnID == job.turnID, persisted.ownerInstallationID == job.ownerInstallationID else { throw Failure() }
            record["journalVerified"] = true
            record["storedArtifactSHA256"] = descriptor.sha256
            // Preflight with no-follow regular-file checks before the app validator.
            let safeBytes = try read(root: descriptor.root, relative: job.id + "/" + descriptor.relativePath, limit: imageLimit)
            let contents = try descriptor.validatedContents()
            guard contents.data == safeBytes else { throw Failure() }
            let artifact = try imageEvidence(contents.data)
            record["artifact"] = artifact
            if let outputID = job.outputImageID {
                guard let cue = project.cues.first(where: { $0.id == context.targetCue.id }), cue.imageId == outputID,
                      let asset = project.images.first(where: { $0.id == outputID }),
                      safeComponent(asset.fileName), asset.sha256 == descriptor.sha256 else { throw Failure() }
                let bytes = try read(root: root, relative: relative + "/assets/" + asset.fileName, limit: imageLimit)
                guard bytes.count == asset.byteCount, ScrivDigest.sha256(bytes) == asset.sha256,
                      bytes == contents.data else { throw Failure() }
                let assetEvidence = try imageEvidence(bytes)
                record["assetID"] = asset.id; record["asset"] = assetEvidence
                record["attachmentVerified"] = true
                let selectedCue = store.isPlaying ? store.currentCue : (store.selectedCue ?? store.currentCue)
                if store.project.id == project.id, store.projectURL?.path == context.packagePath,
                   selectedCue?.id == cue.id, selectedCue?.imageId == asset.id {
                    let previews = previewEvidence(windows: windows, digest: asset.sha256,
                        width: assetEvidence["width"] as? Int ?? 0, height: assetEvidence["height"] as? Int ?? 0)
                    record["previews"] = previews; record["visiblePreviewCount"] = previews.count
                }
            }
            records.append(record)
        }
        return ["schemaVersion": 1, "runID": runID.lowercased(), "jobs": records]
    }

    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    // Cue IDs are metadata, not paths; seeded projects use IDs such as cue-01a.
    private static func safeMetadataID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                $0 == 45 || $0 == 95 || $0 == 46
        }
    }

    /// Anchor only at the app-owned run directory or the controller's already
    /// picker-authorized Generation directory. Do not open unrelated ancestors
    /// (especially /) for reading. Ancestor identity/access is trusted to the app
    /// container or existing security-scoped picker grant. Canonical-path checks
    /// reject existing ancestor links, but cannot lock those ancestors against
    /// concurrent replacement. All descendants use no-follow descriptor traversal.
    private static func directory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"),
              url.standardizedFileURL == url, url.resolvingSymlinksInPath() == url else { throw Failure() }
        var before = stat()
        guard lstat(url.path, &before) == 0, (before.st_mode & S_IFMT) == S_IFDIR else { throw Failure() }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure() }
        var after = stat()
        guard fstat(fd, &after) == 0, (after.st_mode & S_IFMT) == S_IFDIR,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              url.resolvingSymlinksInPath() == url else { close(fd); throw Failure() }
        return fd
    }

    private static func read(root: URL, relative: String, limit: Int) throws -> Data {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(safeComponent) else { throw Failure() }
        var fd = try directory(root)
        defer { close(fd) }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure() }
            close(fd); fd = next
        }
        let file = openat(fd, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Failure() }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= Int64(limit) else { throw Failure() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == Int(info.st_size), data.count <= limit else { throw Failure() }
        return data
    }

    private static func imageEvidence(_ data: Data) throws -> [String: Any] {
        guard data.count <= imageLimit,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384,
              width * height <= 40_000_000,
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), decoded.width > 0, decoded.height > 0,
              decoded.width <= 256, decoded.height <= 256 else { throw Failure() }
        return ["sha256": ScrivDigest.sha256(data), "byteCount": data.count,
                "width": width, "height": height, "decodedThumbnailWidth": decoded.width,
                "decodedThumbnailHeight": decoded.height]
    }

    private static func previewEvidence(windows: [UIWindow], digest: String, width: Int, height: Int) -> [[String: Any]] {
        var result: [[String: Any]] = [], seen = Set<ObjectIdentifier>()
        func visit(_ view: UIView, window: UIWindow, index: Int) {
            guard seen.insert(ObjectIdentifier(view)).inserted, !view.isHidden, view.alpha > 0.01 else { return }
            if let picture = view as? UIKitAssetImageView, picture.accessibilityIdentifier == "preview-picture",
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
        for (index, window) in windows.enumerated() where !window.isHidden && window.alpha > 0.01 {
            visit(window, window: window, index: index)
        }
        return result
    }
}
#endif
