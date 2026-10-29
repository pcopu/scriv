import XCTest
@testable import ScrivCore

final class PersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    func testAtomicCurrentAndImmutableHistoryRoundtrip() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root)
        var project = ScrivProject.example()
        let package = await repo.defaultURL(for: project)
        try await repo.save(project, at: package, label: "Initial")
        let initial = try await repo.load(at: package)
        XCTAssertEqual(initial, project)
        project.revision = 1; project.title = "Second revision"
        try await repo.save(project, at: package, label: "Rename")
        try await repo.save(project, at: package, label: "Save again")
        let history = try await repo.history(at: package)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?.label, "Rename")
        XCTAssertEqual(history.last?.snapshot.title, "YAM MAN")
    }
    func testCrashBeforePublicationReplacesOnlyTheUnpublishedHistorySnapshot() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let repo = try ProjectRepository(root:root)
        let accepted = ScrivProject.example()
        let package = await repo.defaultURL(for:accepted)
        try await repo.save(accepted,at:package,label:"Accepted initial revision")
        var interrupted = accepted; interrupted.revision = 1; interrupted.title = "Interrupted save"
        let orphanURL = package.appendingPathComponent("history/000000000001.json")
        // Simulate process death after writing history but before replacing project.json.
        try ScrivJSON.encoder.encode(HistoryEntry(label:"Never published",snapshot:interrupted)).write(to:orphanURL,options:.atomic)
        let reopened = try ProjectRepository(root:root)
        var recovered = try await reopened.load(at:package)
        XCTAssertEqual(recovered,accepted)
        recovered.revision = 1; recovered.title = "New edit after restart"
        try await reopened.save(recovered,at:package,label:"Recovered edit")
        let current = try await reopened.load(at:package), history = try await reopened.history(at:package)
        XCTAssertEqual(current,recovered)
        XCTAssertEqual(history.count,2)
        XCTAssertEqual(history.first?.snapshot,current)
        XCTAssertEqual(history.first?.label,"Recovered edit")
        XCTAssertEqual(history.last?.snapshot,accepted)
    }
    func testAcceptedRevisionCollisionPreservesCurrentAndHistoryBytes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let repo = try ProjectRepository(root:root)
        var accepted = ScrivProject.example()
        let package = await repo.defaultURL(for:accepted)
        try await repo.save(accepted,at:package,label:"Initial")
        accepted.revision = 1; accepted.title = "Accepted revision"
        try await repo.save(accepted,at:package,label:"Accepted edit")
        let currentURL = package.appendingPathComponent("project.json"), historyURL = package.appendingPathComponent("history/000000000001.json")
        let currentBytes = try Data(contentsOf:currentURL), historyBytes = try Data(contentsOf:historyURL)
        var collision = accepted; collision.title = "Different content under the same revision"
        do { try await repo.save(collision,at:package,label:"Collision"); XCTFail("An accepted revision was overwritten") }
        catch { guard case ScrivError.conflict = error else { return XCTFail("Expected an immutable-history conflict, got \(error)") } }
        XCTAssertEqual(try Data(contentsOf:currentURL),currentBytes)
        XCTAssertEqual(try Data(contentsOf:historyURL),historyBytes)
        var later = accepted; later.revision = 2; later.title = "Later accepted revision"
        try await repo.save(later,at:package,label:"Later edit")
        do { try await repo.save(accepted,at:package,label:"Stale writer"); XCTFail("A stale save rolled the published head backward") }
        catch { guard case ScrivError.conflict = error else { return XCTFail("Expected a stale-revision conflict, got \(error)") } }
        let current = try await repo.load(at:package)
        XCTAssertEqual(current,later)
        XCTAssertEqual(try Data(contentsOf:historyURL),historyBytes)
    }
    func testReplicaIsVerifiedAndKeepsRemoteFilename() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root)
        // The signature is enough to test storage; image decoding is the UI/importer's responsibility.
        let data = Data([137,80,78,71,13,10,26,10,1,2,3,4])
        let imported = try await repo.importAsset(data: data, at: root)
        var metadata = imported; metadata.fileName = "remote-version.png"
        try await repo.storeReplica(data, for: metadata, at: root)
        let read = try await repo.assetData(metadata, at: root)
        XCTAssertEqual(read, data)
        do { try await repo.storeReplica(Data([1,2,3]), for: metadata, at: root); XCTFail("Corrupt replica accepted") } catch {}
    }
    func testTraversalAndSymlinkEscapeAreRejected() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ProjectRepository(root: root)
        let data = Data([137,80,78,71,13,10,26,10,1,2,3,4])
        var asset = try await repo.importAsset(data: data, at: root)
        asset.fileName = "../secret.png"
        do { _ = try await repo.assetData(asset, at: root); XCTFail("Traversal accepted") } catch {}
        let outside = root.appendingPathComponent("outside.png"); try data.write(to: outside)
        let link = root.appendingPathComponent("assets/link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        asset.fileName = "link.png"
        do { _ = try await repo.assetData(asset, at: root); XCTFail("Symlink escape accepted") } catch {}
    }
    func testCloudItemsRoundTripAndRejectUnknownKinds() throws {
        let project = ScrivProject.example(), items = try CloudCodec.items(from: ScrivProject.example())
        var restored = try CloudCodec.applying(items, to: project)
        XCTAssertEqual(restored.entries.count, project.entries.count)
        try TimingEngine.validate(restored)
        var bad = items; bad.append(CloudItem(id: "future", kind: "future-type", data: .object([:])))
        XCTAssertThrowsError(try CloudCodec.applying(bad, to: project))
        restored.revision = 5
        let encoded = try ScrivJSON.encoder.encode(restored)
        XCTAssertEqual(try ScrivJSON.decoder.decode(ScrivProject.self, from: encoded), restored)
    }
    func testSHA256KnownVectors() {
        XCTAssertEqual(ScrivDigest.sha256(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(ScrivDigest.sha256(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(ScrivDigest.sha256(Data(repeating: 97, count: 1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }
}
