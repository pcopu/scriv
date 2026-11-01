import XCTest
@testable import ScrivCore

/// `changedItemIDs` must agree exactly with diffing the encoded cloud items.
final class CloudChangedItemsTests: XCTestCase {
    private func encodedDiff(_ before: ScrivProject, _ after: ScrivProject) throws -> Set<String> {
        let old = Dictionary(uniqueKeysWithValues: try CloudCodec.items(from: before).map { ($0.id, $0.data) })
        let new = Dictionary(uniqueKeysWithValues: try CloudCodec.items(from: after).map { ($0.id, $0.data) })
        return Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
    }

    func testMatchesEncodedDiffAcrossEditKinds() throws {
        let base = ScrivProject.example()
        let dialogue = try XCTUnwrap(base.entries.first { $0.kind == .dialogue })
        var edits: [(String, (inout ScrivProject) throws -> Void)] = [
            ("no change", { _ in }),
            ("entry text", { try TimingEngine.updateText(&$0, entryId: dialogue.id, text: dialogue.text + " more") }),
            ("entry duration", { try TimingEngine.setOwnedDuration(&$0, entryId: dialogue.id, durationMs: dialogue.ownedDurationMs + 500) }),
            ("character rename", { $0.characters[0].name += " Jr." }),
            ("scene title", { $0.scenes[0].title = "EXT. FIELD — NIGHT" }),
            ("cue prompt", { $0.cues[0].prompt = "wide shot" }),
            ("remove entry", { try ProjectEditing.deleteEntry(&$0, entryId: dialogue.id) }),
            ("revision only", { $0.revision += 1; $0.modifiedAt = Date(timeIntervalSince1970: 1) }),
        ]
        if !base.images.isEmpty { edits.append(("image tags", { $0.images[0].characterIds = [] })) }
        for (name, edit) in edits {
            var after = base; try edit(&after)
            XCTAssertEqual(CloudCodec.changedItemIDs(from: base, to: after), try encodedDiff(base, after), name)
        }
    }

    func testAddedItemIsReported() throws {
        let base = ScrivProject.example()
        var after = base
        after.characters.append(ScriptCharacter(id: "new-person", name: "New Person"))
        XCTAssertEqual(CloudCodec.changedItemIDs(from: base, to: after), ["new-person"])
        XCTAssertEqual(CloudCodec.changedItemIDs(from: base, to: after), try encodedDiff(base, after))
    }
}
