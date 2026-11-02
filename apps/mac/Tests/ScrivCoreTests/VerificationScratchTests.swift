import XCTest
@testable import ScrivCore

final class VerificationScratchTests: XCTestCase {
    func testPrunesOnlyStaleScratchFoldersWithKnownPrefixes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("VerificationScratchTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let old = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        func folder(_ name: String, modified: Date?) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url.appendingPathComponent("Projects"), withIntermediateDirectories: true)
            if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
            return url
        }
        let staleRun = try folder("ScrivVerification-1234", modified: old)
        let staleStartup = try folder("ScrivStartupTests-ABCD", modified: old)
        let liveRun = try folder("ScrivVerification-5678", modified: nil)
        let unrelated = try folder("SomethingElse-1234", modified: old)
        let staleFile = root.appendingPathComponent("ScrivVerification-file")
        try Data("keep".utf8).write(to: staleFile); try fm.setAttributes([.modificationDate: old], ofItemAtPath: staleFile.path)
        let link = root.appendingPathComponent("ScrivVerification-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: unrelated)

        XCTAssertEqual(VerificationScratch.pruneStale(in: root), 2)
        XCTAssertFalse(fm.fileExists(atPath: staleRun.path))
        XCTAssertFalse(fm.fileExists(atPath: staleStartup.path))
        XCTAssertTrue(fm.fileExists(atPath: liveRun.path), "A run active within the last day is kept")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path), "Other folders are never touched")
        XCTAssertTrue(fm.fileExists(atPath: staleFile.path), "Only folders are pruned")
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: link.path), "Links are not followed or removed")
        XCTAssertEqual(VerificationScratch.pruneStale(in: root.appendingPathComponent("missing")), 0)
    }
}
