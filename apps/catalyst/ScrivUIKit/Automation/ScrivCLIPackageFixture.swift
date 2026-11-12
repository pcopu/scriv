#if SCRIV_CLI_AUTOMATION
import UIKit
import Darwin

/// Finite synthetic package input, not an importer/model setter. Production
/// Projects > Open owns decoding/validation. No caller paths or asset bytes.
@MainActor
enum ScrivCLIPackageFixture {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "Synthetic package fixture is unavailable or invalid." }
    }
    static let token = "image-inspector-invariants-v1"
    static let templateID = "BBFD7B11-2D02-4000-8000-000000000001"
    static let title = "Synthetic image inspector invariants"
    static let reviewToken = "character-review-seeded-v1"
    static let reviewTitle = "Synthetic character review"
    private static var stagedToken: String?
    private static var published = false
    private static var stagedProjectID: String?
    /// Read-only alias exception is bound to this process's one staged package.
    static func permitsImageAlias(projectID: String, assetID: String, fileName: String, sha256: String) -> Bool {
        guard published, [token, reviewToken].contains(stagedToken ?? ""), stagedProjectID == projectID else { return false }
        switch (assetID, fileName, sha256) {
        case ("v1", "one.png", "827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577"),
             ("v2", "two.png", "3fba282698b3df63c76fb40e529943fb6da6d28bafa6ff9e3a75c0c4a0cbb784"): return true
        default: return false
        }
    }

    static func permitsPortrait(projectID: String, assetID: String, fileName: String, sha256: String) -> Bool {
        stagedToken == reviewToken && permitsImageAlias(projectID: projectID, assetID: assetID, fileName: fileName, sha256: sha256)
    }

    static func stage(request: [String: Any], workspace: ScrivWorkspaceController) throws -> [String: Any] {
        do {
            guard Set(request.keys) == Set(["id", "command", "fixture"]),
                  request["command"] as? String == "stage-package-fixture",
                  let fixture = request["fixture"] as? String, [token, reviewToken].contains(fixture), !published else { throw Failure() }
            return try perform(workspace: workspace, fixture: fixture)
        } catch { throw Failure() }
    }
    private static func perform(workspace: ScrivWorkspaceController, fixture: String) throws -> [String: Any] {
        let run = try ScrivCLIRunCapability.requirePrepared()
        let store = workspace.store
        func gate() throws {
            try run.validate()
            guard run.approvedOrigin == nil, store.account == nil, store.cloud.account == nil,
                  store.project.cloudProjectId == nil, store.cloud.projectId == nil,
                  store.codex.jobs.isEmpty, store.codex.sharedJobs.isEmpty,
                  !store.characterAnalysis.isScanning,
                  store.characterAnalysis.availability == "Image analysis is disabled in verification mode.",
                  store.errorMessage == nil, !store.isPlaying, !store.isBootstrapping,
                  workspace.viewIfLoaded?.window?.rootViewController === workspace,
                  workspace.presentedViewController == nil,
                  !workspace.isBeingPresented, !workspace.isBeingDismissed,
                  store.project.id.count == 36, UUID(uuidString: store.project.id) != nil,
                  store.projectURL?.path == run.root.appendingPathComponent("Projects")
                    .appendingPathComponent(store.project.id + ".scriv").path else { throw Failure() }
        }
        try gate()
        // Unlike an import, staging must not finish editing or mutate the model.
        let before = store.project, navigation = store.navigationContext
        let root = run.root.resolvingSymlinksInPath()
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw Failure() }
        defer { close(rootFD) }
        func roots() throws {
            try gate()
            try run.validateRootDescriptor(rootFD)
            var named = stat(), opened = stat()
            guard lstat(root.path, &named) == 0, fstat(rootFD, &opened) == 0,
                  privateDirectory(opened), same(named, opened), root.resolvingSymlinksInPath() == root,
                  store.project == before, store.navigationContext == navigation else { throw Failure() }
        }
        try roots()
        let projects = try directory("Projects", parent: rootFD, privateOnly: false)
        defer { close(projects) }
        let current = try directory(before.id + ".scriv", parent: projects, privateOnly: false)
        defer { close(current) }
        let projectID = UUID().uuidString
        let packageName = projectID + ".scriv", pendingName = ".ScrivCLIPackage-" + UUID().uuidString
        guard mkdirat(projects, pendingName, mode_t(0o700)) == 0 else { throw Failure() }
        let package = try directory(pendingName, parent: projects)
        var publishedHere = false
        var files: [(Int32, String, Int32)] = []
        var assets: Int32 = -1
        defer {
            // No recursive deletion, including on failure. Never delete a
            // published package, unknown member, or replaced inode.
            if !publishedHere {
                for (parent, name, fd) in files.reversed() {
                    if matches(name, parent: parent, fd: fd) { _ = unlinkat(parent, name, 0) }
                }
                if assets >= 0, matches("assets", parent: package, fd: assets) { _ = unlinkat(package, "assets", AT_REMOVEDIR) }
                if matches(pendingName, parent: projects, fd: package) { _ = unlinkat(projects, pendingName, AT_REMOVEDIR) }
            }
            for (_, _, fd) in files { close(fd) }
            if assets >= 0 { close(assets) }; close(package)
        }
        guard mkdirat(package, "assets", mode_t(0o700)) == 0 else { throw Failure() }
        assets = try directory("assets", parent: package)
        // Narrow substitution of an internally generated UUID only. No model
        // construction, JSON decoder, repository save, history or persistent grant.
        let json = Data((fixture == reviewToken ? reviewProjectJSON : projectJSON).replacingOccurrences(of: templateID, with: projectID).utf8)
        let one = try ScrivCLILocalImageFixtures.bytes("coral"), two = try ScrivCLILocalImageFixtures.bytes("blue")
        guard json.count <= 16 * 1024, one.count == 73, two.count == 73 else { throw Failure() }
        for (parent, name, bytes) in [(package, "project.json", json), (assets, "one.png", one), (assets, "two.png", two)] {
            let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw Failure() }
            files.append((parent, name, fd))
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    guard let base = buffer.baseAddress else { throw Failure() }
                    let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw Failure() }; offset += written
                }
            }
            var info = stat()
            guard fstat(fd, &info) == 0, privateFile(info), info.st_size == bytes.count,
                  matches(name, parent: parent, fd: fd), fsync(fd) == 0 else { throw Failure() }
        }
        try roots()
        guard matches("Projects", parent: rootFD, fd: projects),
              matches(before.id + ".scriv", parent: projects, fd: current),
              matches(pendingName, parent: projects, fd: package), matches("assets", parent: package, fd: assets),
              files.allSatisfy({ matches($0.1, parent: $0.0, fd: $0.2) }),
              try exactChildren(package, names: ["assets", "project.json"]),
              try exactChildren(assets, names: ["one.png", "two.png"]),
              fsync(assets) == 0, fsync(package) == 0,
              renameatx_np(projects, pendingName, projects, packageName, UInt32(RENAME_EXCL)) == 0 else { throw Failure() }
        // Publication cannot be rolled back on an uncertain durability failure.
        // Latch immediately so a failed response cannot create a second package.
        publishedHere = true; published = true; stagedProjectID = projectID; stagedToken = fixture
        guard matches(packageName, parent: projects, fd: package), fsync(projects) == 0 else { throw Failure() }
        try roots()
        return ["fixture": fixture, "projectID": projectID, "title": fixture == reviewToken ? reviewTitle : title]
    }
    private static func exactChildren(_ descriptor: Int32, names: Set<String>) throws -> Bool {
        let listing = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard listing >= 0 else { throw Failure() }
        guard let stream = fdopendir(listing) else { close(listing); throw Failure() }
        defer { closedir(stream) }
        var found = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw Failure() }; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard names.contains(name), found.insert(name).inserted else { throw Failure() }
        }
        return found == names
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        (a.st_mode & S_IFMT) == (b.st_mode & S_IFMT) && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
    private static func matches(_ name: String, parent: Int32, fd: Int32) -> Bool {
        var a = stat(), b = stat()
        return fstatat(parent, name, &a, AT_SYMLINK_NOFOLLOW) == 0 && fstat(fd, &b) == 0 && same(a, b)
    }
    private static func privateDirectory(_ s: stat) -> Bool {
        (s.st_mode & S_IFMT) == S_IFDIR && s.st_uid == geteuid() && (s.st_mode & 0o777) == 0o700
    }
    private static func privateFile(_ s: stat) -> Bool {
        (s.st_mode & S_IFMT) == S_IFREG && s.st_uid == geteuid() && s.st_nlink == 1 && (s.st_mode & 0o777) == 0o600
    }
    private static func directory(_ name: String, parent: Int32, privateOnly: Bool = true) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(),
              (info.st_mode & 0o022) == 0,
              !privateOnly || privateDirectory(info), matches(name, parent: parent, fd: fd) else { close(fd); throw Failure() }
        return fd
    }
    // Baseline 4d14b29 ImageInspectorInvariantTests.fixture(). Initializer-created
    // UUIDs/dates are fixed; word timings are the initializer's exact output.
    static let projectJSON = #"""
    {
      "schemaVersion": 1,
      "id": "BBFD7B11-2D02-4000-8000-000000000001",
      "title": "Synthetic image inspector invariants",
      "createdAt": 1700000000000,
      "modifiedAt": 1700000000000,
      "revision": 0,
      "scenes": [
        {
          "id": "scene",
          "title": "Untitled scene",
          "order": 0
        }
      ],
      "entries": [
        {
          "id": "a",
          "sceneId": "scene",
          "order": 0,
          "kind": "dialogue",
          "text": "First source",
          "ownedDurationMs": 1000,
          "coverageDurationMs": 0,
          "color": "purple",
          "words": [
            {
              "id": "a-word-1",
              "text": "First",
              "startMs": 0,
              "endMs": 454
            },
            {
              "id": "a-word-2",
              "text": "source",
              "startMs": 454,
              "endMs": 1000
            }
          ]
        },
        {
          "id": "b",
          "sceneId": "scene",
          "order": 1,
          "kind": "dialogue",
          "text": "Second source",
          "ownedDurationMs": 2000,
          "coverageDurationMs": 0,
          "color": "purple",
          "words": [
            {
              "id": "b-word-1",
              "text": "Second",
              "startMs": 0,
              "endMs": 1000
            },
            {
              "id": "b-word-2",
              "text": "source",
              "startMs": 1000,
              "endMs": 2000
            }
          ]
        }
      ],
      "characters": [],
      "images": [
        {
          "id": "v1",
          "version": 1,
          "fileName": "one.png",
          "sha256": "827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577",
          "mimeType": "image/png",
          "byteCount": 73,
          "characterIds": [],
          "prompt": "Manual direction one",
          "createdAt": 1700000000000,
          "generationPrompt": "Exact submitted prompt one\nSource at generation time."
        },
        {
          "id": "v2",
          "version": 2,
          "fileName": "two.png",
          "sha256": "3fba282698b3df63c76fb40e529943fb6da6d28bafa6ff9e3a75c0c4a0cbb784",
          "mimeType": "image/png",
          "byteCount": 73,
          "characterIds": [],
          "prompt": "Manual direction two",
          "createdAt": 1700000000000,
          "previousVersionId": "v1"
        }
      ],
      "cues": [
        {
          "id": "background",
          "sceneId": "scene",
          "imageId": "v1",
          "label": "Background",
          "startMs": 0,
          "endMs": 3000,
          "prompt": "Current cue direction",
          "startAnchor": {
            "entryId": "a",
            "offsetMs": 0
          },
          "authoredDurationMs": 3000
        },
        {
          "id": "foreground",
          "sceneId": "scene",
          "imageId": "v2",
          "label": "Foreground",
          "startMs": 1000,
          "endMs": 2000,
          "prompt": "",
          "startAnchor": {
            "entryId": "b",
            "offsetMs": 0
          },
          "authoredDurationMs": 1000
        }
      ],
      "audioAssets": [],
      "audioClips": [],
      "audioVolume": 1
    }
    """#
    // Literal saved prior analysis. Never applied to the live store by staging.
    static let reviewProjectJSON = #"""
    {
      "schemaVersion": 1,
      "id": "BBFD7B11-2D02-4000-8000-000000000001",
      "title": "Synthetic character review",
      "createdAt": 1700000000000,
      "modifiedAt": 1700000000000,
      "revision": 0,
      "scenes": [
        {
          "id": "scene",
          "title": "Untitled scene",
          "order": 0
        }
      ],
      "entries": [
        {
          "id": "a",
          "sceneId": "scene",
          "order": 0,
          "kind": "dialogue",
          "text": "First source",
          "ownedDurationMs": 1000,
          "coverageDurationMs": 0,
          "color": "purple",
          "words": [
            {
              "id": "a-word-1",
              "text": "First",
              "startMs": 0,
              "endMs": 454
            },
            {
              "id": "a-word-2",
              "text": "source",
              "startMs": 454,
              "endMs": 1000
            }
          ]
        },
        {
          "id": "b",
          "sceneId": "scene",
          "order": 1,
          "kind": "dialogue",
          "text": "Second source",
          "ownedDurationMs": 2000,
          "coverageDurationMs": 0,
          "color": "purple",
          "words": [
            {
              "id": "b-word-1",
              "text": "Second",
              "startMs": 0,
              "endMs": 1000
            },
            {
              "id": "b-word-2",
              "text": "source",
              "startMs": 1000,
              "endMs": 2000
            }
          ]
        }
      ],
      "characters": [
        {
          "id": "synthetic-existing",
          "name": "Synthetic Avery",
          "aliases": [],
          "biography": "Synthetic review fixture only.",
          "appearance": "",
          "color": "blue"
        }
      ],
      "images": [
        {
          "id": "v1",
          "version": 1,
          "fileName": "one.png",
          "sha256": "827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577",
          "mimeType": "image/png",
          "byteCount": 73,
          "characterIds": [],
          "prompt": "Manual direction one",
          "createdAt": 1700000000000,
          "generationPrompt": "Exact submitted prompt one\nSource at generation time.",
          "characterAnalysis": {
            "imageSHA256": "827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577",
            "imageVersion": 1,
            "providerID": "synthetic-seeded-review",
            "completedAt": 1700000000000,
            "annotations": [
              {
                "id": "synthetic-review-1",
                "region": {
                  "x": 0,
                  "y": 0,
                  "width": 0.5,
                  "height": 0.5
                },
                "portraitRegion": {
                  "x": 0,
                  "y": 0,
                  "width": 0.5,
                  "height": 0.5
                },
                "kind": "face",
                "confidence": 0.5,
                "reason": "Synthetic prior analysis candidate 1.",
                "decision": "needsReview"
              },
              {
                "id": "synthetic-review-2",
                "region": {
                  "x": 0.5,
                  "y": 0,
                  "width": 0.5,
                  "height": 0.5
                },
                "portraitRegion": {
                  "x": 0.5,
                  "y": 0,
                  "width": 0.5,
                  "height": 0.5
                },
                "kind": "face",
                "confidence": 0.5,
                "reason": "Synthetic prior analysis candidate 2.",
                "decision": "needsReview"
              },
              {
                "id": "synthetic-review-3",
                "region": {
                  "x": 0,
                  "y": 0.5,
                  "width": 0.5,
                  "height": 0.5
                },
                "portraitRegion": {
                  "x": 0,
                  "y": 0.5,
                  "width": 0.5,
                  "height": 0.5
                },
                "kind": "face",
                "confidence": 0.5,
                "reason": "Synthetic prior analysis candidate 3.",
                "decision": "needsReview"
              }
            ],
            "excludedCharacterIDs": [],
            "manualCharacterIDs": []
          }
        },
        {
          "id": "v2",
          "version": 2,
          "fileName": "two.png",
          "sha256": "3fba282698b3df63c76fb40e529943fb6da6d28bafa6ff9e3a75c0c4a0cbb784",
          "mimeType": "image/png",
          "byteCount": 73,
          "characterIds": [],
          "prompt": "Manual direction two",
          "createdAt": 1700000000000,
          "previousVersionId": "v1"
        }
      ],
      "cues": [
        {
          "id": "background",
          "sceneId": "scene",
          "imageId": "v1",
          "label": "Background",
          "startMs": 0,
          "endMs": 3000,
          "prompt": "Current cue direction",
          "startAnchor": {
            "entryId": "a",
            "offsetMs": 0
          },
          "authoredDurationMs": 3000
        },
        {
          "id": "foreground",
          "sceneId": "scene",
          "imageId": "v2",
          "label": "Foreground",
          "startMs": 1000,
          "endMs": 2000,
          "prompt": "",
          "startAnchor": {
            "entryId": "b",
            "offsetMs": 0
          },
          "authoredDurationMs": 1000
        }
      ],
      "audioAssets": [],
      "audioClips": [],
      "audioVolume": 1
    }
    """#
}
#endif
