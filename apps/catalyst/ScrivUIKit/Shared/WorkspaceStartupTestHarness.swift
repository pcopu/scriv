#if DEBUG
import Foundation
import UIKit
import ScrivCore

/// Only XCTest can create this capability, and only while the host's ordinary
/// dependencies are already isolated by --screenshots. No root/path parameter,
/// environment override, production flag or Release entry point is added.
@MainActor
final class WorkspaceStartupTestHarness {
    let root: URL
    let defaults: UserDefaults
    let fileAccess: UIKitFileAccess
    let trace: StartupTrace
    var denyMetadataRead = false
    var restoreAccount: () async -> Void = {}
    private init(root: URL, defaults: UserDefaults, trace: StartupTrace) {
        self.root = root; self.defaults = defaults; self.trace = trace
        fileAccess = UIKitFileAccess(defaults: defaults)
    }
    static func make(trace: StartupTrace) throws -> WorkspaceStartupTestHarness {
        guard ProcessInfo.processInfo.arguments.contains("--screenshots"), (NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil) else {
            throw ScrivError.permission("Startup injection requires the isolated XCTest host.")
        }
        let token = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ScrivStartupTests-" + token, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw ScrivError.conflict("Startup test location already exists.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard let defaults = UserDefaults(suiteName: "ScrivStartupTests." + token) else {
            throw ScrivError.unavailable("The isolated startup preferences could not be created.")
        }
        return WorkspaceStartupTestHarness(root: root, defaults: defaults, trace: trace)
    }
    func validatePackage(_ url: URL) throws {
        let canonical = url.standardizedFileURL
        guard canonical == canonical.resolvingSymlinksInPath(), canonical.path.hasPrefix(root.path + "/Projects/"),
              canonical.pathExtension.lowercased() == "scriv" else {
            throw ScrivError.permission("Startup test packages must stay inside their synthetic fixture.")
        }
    }
    func beforeMetadataRead(_ url: URL) throws {
        try validatePackage(url)
        if denyMetadataRead {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 1)])
        }
    }
}
#endif
