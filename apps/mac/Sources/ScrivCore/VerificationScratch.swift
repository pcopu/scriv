import Foundation

/// Isolated verification runs (`--screenshots`, XCTest hosts) each create a
/// scratch folder in the app's temporary directory and nothing removes it when
/// the process exits. Pruning only folders with these exact prefixes that have
/// not changed for a day never touches a live run or any ordinary data.
public enum VerificationScratch {
    public static let prefixes = ["ScrivVerification-", "ScrivStartupTests-"]

    @discardableResult
    public static func pruneStale(in directory: URL, olderThan age: TimeInterval = 24 * 60 * 60, now: Date = Date(), fileManager: FileManager = .default) -> Int {
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return 0 }
        var removed = 0
        for item in items where prefixes.contains(where: { item.lastPathComponent.hasPrefix($0) }) {
            guard let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, now.timeIntervalSince(modified) > age else { continue }
            if (try? fileManager.removeItem(at: item)) != nil { removed += 1 }
        }
        return removed
    }
}
