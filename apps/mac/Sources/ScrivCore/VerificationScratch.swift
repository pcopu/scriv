import Foundation

/// Isolated verification runs (`--screenshots`, XCTest hosts) each create a
/// scratch folder in the app's temporary directory and nothing removes it when
/// the process exits. Pruning only folders with these exact prefixes that have
/// not changed for a day never touches any ordinary data. CLI workspaces are
/// always excluded: an idle persistent workspace must survive cold relaunch.
public enum VerificationScratch {
    public static let prefixes = ["ScrivVerification-", "ScrivStartupTests-"]

    @discardableResult
    public static func pruneStale(in directory: URL, olderThan age: TimeInterval = 24 * 60 * 60, now: Date = Date(), fileManager: FileManager = .default) -> Int {
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return 0 }
        var removed = 0
        for item in items where prefixes.contains(where: { item.lastPathComponent.hasPrefix($0) }) {
            // Preserve every exact CLI root, even if its marker is missing or
            // damaged. A broken marker must cause resume rejection, not deletion.
            let name = item.lastPathComponent
            let cliPrefix = "ScrivVerification-CLI-"
            if name.hasPrefix(cliPrefix) {
                let suffix = String(name.dropFirst(cliPrefix.count))
                if suffix.count == 36, let id = UUID(uuidString: suffix), id.uuidString.lowercased() == suffix { continue }
            }
            guard let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > age else { continue }
            if (try? fileManager.removeItem(at: item)) != nil { removed += 1 }
        }
        return removed
    }

    /// Older test runs left one empty preferences file per isolated suite.
    public static let preferencePrefixes = ["ScrivStartupTests.", "ScrivPackageTest."]

    @discardableResult
    public static func pruneStalePreferences(in directory: URL, olderThan age: TimeInterval = 24 * 60 * 60, now: Date = Date(), fileManager: FileManager = .default) -> Int {
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return 0 }
        var removed = 0
        for item in items where item.pathExtension == "plist" && preferencePrefixes.contains(where: { item.lastPathComponent.hasPrefix($0) }) {
            guard let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > age else { continue }
            if (try? fileManager.removeItem(at: item)) != nil { removed += 1 }
        }
        return removed
    }
}


/// Actual-app CLI sessions must never read or overwrite the installed app's
/// preference domain. Normal app and existing verification behavior is unchanged.
public enum ScrivPreferences {
    public static let standard: UserDefaults = {
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--scriv-cli"),
              process.arguments.contains("--screenshots") else { return .standard }
        // A fresh suite isolates all app-specific preference keys while retaining
        // system language/accessibility defaults. Never fall back to production.
        let name = "ScrivStartupTests.CLI." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("Could not create isolated CLI preferences")
        }
        return defaults
    }()
}
