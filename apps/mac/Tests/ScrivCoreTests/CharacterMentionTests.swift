import XCTest
@testable import ScrivCore

final class CharacterMentionTests: XCTestCase {
    func testCanonicalNamesAliasesAndLongestNamesKeepExactSource() {
        let people = [ScriptCharacter(id:"franklin",name:"Farmer Franklin",aliases:["Franklin"]),ScriptCharacter(id:"farmer",name:"Farmer"),ScriptCharacter(id:"m",name:"Miyazaki")]
        let text = "Franklin turns. Farmer Franklin asks Miyazaki's opinion."
        let result = CharacterMentions.find(in:text,characters:people)
        XCTAssertEqual(result.map(\.characterId),["franklin","franklin","m"])
        XCTAssertEqual(result.map { (text as NSString).substring(with:$0.range) },["Franklin","Farmer Franklin","Miyazaki"])
    }
    func testExactProfileNameWinsAliasAndAmbiguousAliasesStayUnlinked() {
        let a = ScriptCharacter(id:"a",name:"Anna",aliases:["Sam"]), b = ScriptCharacter(id:"b",name:"Bea",aliases:["Sam","Anna"])
        let result = CharacterMentions.find(in:"Anna and Sam",characters:[b,a])
        XCTAssertEqual(result.map(\.characterId),["a"])
        XCTAssertEqual(result[0].range,NSRange(location:0,length:4))
        XCTAssertEqual(CharacterMentions.find(in:"Anna",characters:[a,ScriptCharacter(id:"duplicate",name:"Anna")]),[])
    }
    func testWordBoundariesUnicodeAndRegexCharacters() {
        let people = [ScriptCharacter(id:"ann",name:"Ann"),ScriptCharacter(id:"mei",name:"美"),ScriptCharacter(id:"plus",name:"C++")]
        let text = "🙂 Ann, ANNA, Joanne, 美！ C++? Ann_2."
        let result = CharacterMentions.find(in:text,characters:people)
        XCTAssertEqual(result.map(\.characterId),["ann","mei","plus"])
        XCTAssertEqual(result[0].range.location,3) // Emoji occupies two UTF-16 code units.
        XCTAssertEqual(result.map { (text as NSString).substring(with:$0.range) },["Ann","美","C++"])
    }
    private let randy = ScriptCharacter(id: "randy", name: "Randy", aliases: ["Rand"])
    private func entry(_ text: String) -> ScriptEntry { ScriptEntry(id: "line", sceneId: "scene", order: 0, text: text) }
    private func confirmed(_ text: String, range: NSRange? = nil, character: ScriptCharacter? = nil) throws -> ScriptEntry {
        var value = entry(text)
        try CharacterMentions.assign(&value, range: range ?? (text as NSString).range(of: "Randy"), characterId: (character ?? randy).id, characters: [character ?? randy])
        return value
    }
    func testLegacyBootstrapIsReviewableAndFreezesIdentityBeforeRename() throws {
        var p = ScrivProject(scenes: [ScriptScene(id: "scene")], entries: [entry("Randy turns to Rand.")], characters: [randy])
        XCTAssertEqual(CharacterMentions.resolved(in: p.entries[0]), [])
        CharacterMentions.bootstrap(&p)
        XCTAssertEqual(p.entries[0].characterLinks?.map(\.characterId), ["randy", "randy"])
        XCTAssertTrue(p.entries[0].characterLinks!.allSatisfy { !$0.isConfirmed })
        p.characters[0].name = "Jason"; p.characters[0].aliases = []
        p.characters.append(ScriptCharacter(id: "new", name: "Randy"))
        CharacterMentions.bootstrap(&p)
        XCTAssertEqual(p.entries[0].characterLinks?.map(\.characterId), ["randy", "randy"])
        XCTAssertEqual(p.entries[0].text, "Randy turns to Rand.")
        try TimingEngine.validate(p)
    }
    func testConfirmedNamesSurviveRenameAliasRemovalAndNameReuse() throws {
        var e = try confirmed("Randy calls Rand.")
        try CharacterMentions.assign(&e, range: (e.text as NSString).range(of: "Rand", options: .backwards), characterId: randy.id, characters: [randy])
        let renamed = ScriptCharacter(id: randy.id, name: "Jason")
        let catalog = [renamed, ScriptCharacter(id: "new-randy", name: "Randy", aliases: ["Rand"])]
        let before = e.characterLinks
        e.characterLinks = CharacterMentions.reconcile(entry: e, editedText: e.text, characters: catalog)
        XCTAssertEqual(e.characterLinks, before)
        XCTAssertEqual(CharacterMentions.resolved(in: e).map(\.characterId), ["randy", "randy"])
        XCTAssertEqual(e.text, "Randy calls Rand.")
        try CharacterMentions.validate(entry: e, characterIDs: Set(catalog.map(\.id)))
    }
    func testExplicitCorrectionAndUnlinkDoNotChangeAuthoredWording() throws {
        var e = try confirmed("Randy waits.")
        let other = ScriptCharacter(id: "other", name: "Someone else")
        try CharacterMentions.assign(&e, range: NSRange(location: 0, length: 5), characterId: other.id, characters: [randy, other])
        XCTAssertEqual(CharacterMentions.resolved(in: e).first?.characterId, "other")
        try CharacterMentions.assign(&e, range: NSRange(location: 0, length: 5), characterId: nil, characters: [randy, other])
        XCTAssertEqual(e.text, "Randy waits.")
        XCTAssertEqual(CharacterMentions.resolved(in: e), [])
        XCTAssertTrue(CharacterMentions.suggestions(in: e.text, characters: [randy], excluding: e.characterLinks!).isEmpty)
        let links = CharacterMentions.reconcile(entry: e, editedText: "Randy waits. Still.", characters: [randy])
        XCTAssertEqual(links.first?.characterId, nil)
        XCTAssertEqual(links.first?.isConfirmed, true)
    }
    func testExactNativeDeletionKeepsSecondIdenticalNamesIdentity() throws {
        let a = ScriptCharacter(id: "a", name: "Randy"), b = ScriptCharacter(id: "b", name: "Randy")
        var e = entry("Randy Randy")
        try CharacterMentions.assign(&e, range: NSRange(location: 0, length: 5), characterId: "a", characters: [a,b])
        try CharacterMentions.assign(&e, range: NSRange(location: 6, length: 5), characterId: "b", characters: [a,b])
        let links = CharacterMentions.reconcile(entry: e, editedText: "Randy", characters: [a,b], edits: [CharacterTextEdit(range: NSRange(location: 0, length: 6), replacement: "")])
        XCTAssertEqual(links.map(\.characterId), ["b"])
        XCTAssertEqual(links.map(\.location), [0])
        XCTAssertTrue(links[0].isConfirmed)
        // The same final text alone cannot reveal which occurrence was removed.
        let fallback = CharacterMentions.reconcile(entry: e, editedText: "Randy", characters: [a,b])
        XCTAssertTrue(fallback.isEmpty)
    }
    func testUTF16OffsetsMoveButAnnotationIdentityAndWordingStay() throws {
        let e = try confirmed("Randy waits.")
        let links = CharacterMentions.reconcile(entry: e, editedText: "🙂 Randy waits.", characters: [randy], edits: [CharacterTextEdit(range: NSRange(location: 0, length: 0), replacement: "🙂 ")])
        XCTAssertEqual(links.first?.location, 3)
        XCTAssertEqual(links.first?.id, e.characterLinks?.first?.id)
        XCTAssertEqual(links.first?.text, "Randy")
        XCTAssertEqual(links.first?.isConfirmed, true)
    }
    func testMultipleExactEditsPreserveUntouchedMiddleMention() throws {
        let e = try confirmed("Before Randy after.")
        let links = CharacterMentions.reconcile(entry: e, editedText: "Earlier Randy later.", characters: [randy], edits: [
            CharacterTextEdit(range: NSRange(location: 0, length: 6), replacement: "Earlier"),
            CharacterTextEdit(range: NSRange(location: 14, length: 5), replacement: "later")
        ])
        XCTAssertEqual(links.first?.location, 8)
        XCTAssertEqual(links.first?.id, e.characterLinks?.first?.id)
        XCTAssertEqual(links.first?.isConfirmed, true)
    }
    func testEditingInsideMentionRevokesOldIdentityWithoutSilentReassignment() throws {
        let e = try confirmed("Randy waits.")
        let jason = ScriptCharacter(id: "jason", name: "Jason")
        let links = CharacterMentions.reconcile(entry: e, editedText: "Jason waits.", characters: [randy,jason], edits: [CharacterTextEdit(range: NSRange(location: 0, length: 5), replacement: "Jason")])
        XCTAssertEqual(links.map(\.characterId), ["jason"])
        XCTAssertFalse(links[0].isConfirmed)
        XCTAssertNotEqual(links[0].id, e.characterLinks?.first?.id)
    }
    func testTypingLettersAtBoundaryRevokesLinkButWhitespaceKeepsIt() throws {
        let e = try confirmed("Randy waits.")
        let joined = CharacterMentions.reconcile(entry: e, editedText: "XRandy waits.", characters: [randy], edits: [CharacterTextEdit(range: NSRange(location: 0, length: 0), replacement: "X")])
        XCTAssertTrue(joined.isEmpty)
        let spaced = CharacterMentions.reconcile(entry: e, editedText: " Randy waits.", characters: [randy], edits: [CharacterTextEdit(range: NSRange(location: 0, length: 0), replacement: " ")])
        XCTAssertEqual(spaced.first?.characterId, randy.id)
        XCTAssertEqual(spaced.first?.isConfirmed, true)
    }
    func testBootstrapDoesNotProposeReusedNamesInUntouchedOldText() {
        var p = ScrivProject(entries: [entry("Randy waits.")], characters: [])
        CharacterMentions.bootstrap(&p)
        p.characters = [randy]
        let links = CharacterMentions.reconcile(entry: p.entries[0], editedText: "Randy waits. Randy arrives.", characters: p.characters)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].location, 13)
        XCTAssertFalse(links[0].isConfirmed)
    }
    func testSourceValidationRejectsStaleOverlappingMissingAndInvalidUnicodeRanges() throws {
        var e = try confirmed("Randy waits.")
        XCTAssertNoThrow(try CharacterMentions.validate(entry: e, characterIDs: [randy.id]))
        XCTAssertThrowsError(try CharacterMentions.validate(entry: e, characterIDs: []))
        e.characterLinks![0].text = "Jason"
        XCTAssertThrowsError(try CharacterMentions.validate(entry: e, characterIDs: [randy.id]))
        e = try confirmed("Randy waits."); e.characterLinks!.append(e.characterLinks![0])
        XCTAssertThrowsError(try CharacterMentions.validate(entry: e, characterIDs: [randy.id]))
        e = entry("🙂 Randy"); e.characterLinks = [CharacterTextLink(characterId: randy.id, location: 1, length: 1, text: "x")]
        XCTAssertThrowsError(try CharacterMentions.validate(entry: e, characterIDs: [randy.id]))
        e.characterLinks = [CharacterTextLink(characterId: randy.id, location: Int.max, length: Int.max, text: "Randy")]
        XCTAssertThrowsError(try CharacterMentions.validate(entry: e, characterIDs: [randy.id]))
        e = entry("e\u{301}")
        e.characterLinks = [CharacterTextLink(characterId: randy.id, location: 0, length: 2, text: "é")]
        XCTAssertThrowsError(try CharacterMentions.validate(entry: e, characterIDs: [randy.id])) // Canonical equivalence is not exact source text.
    }
    func testLegacyDecodeAndLocalCloudRoundTripsPreserveAnnotationsAndUnlinks() throws {
        let legacy = entry("Randy waits.")
        let decoded = try ScrivJSON.decoder.decode(ScriptEntry.self, from: ScrivJSON.encoder.encode(legacy))
        XCTAssertNil(decoded.characterLinks)
        var e = try confirmed("Randy waits.")
        try CharacterMentions.assign(&e, range: NSRange(location: 6, length: 5), characterId: nil, characters: [randy])
        let p = ScrivProject(scenes: [ScriptScene(id: "scene")], entries: [e], characters: [randy])
        let roundTrip = try ScrivJSON.decoder.decode(ScrivProject.self, from: ScrivJSON.encoder.encode(p))
        XCTAssertEqual(roundTrip, p)
        let cloud = try CloudCodec.applying(CloudCodec.items(from: p), to: p)
        XCTAssertEqual(cloud.entries, p.entries)
    }
    func testTimingTextUpdateReconcilesLinksAndPreservesSpeaker() throws {
        let e = try confirmed("Randy waits.")
        var p = ScrivProject(scenes: [ScriptScene(id: "scene")], entries: [e], characters: [randy])
        p.entries[0].characterId = randy.id
        try TimingEngine.updateText(&p, entryId: e.id, text: "Now Randy waits.", edits: [CharacterTextEdit(range: NSRange(location: 0, length: 0), replacement: "Now ")])
        XCTAssertEqual(p.entries[0].characterId, randy.id)
        XCTAssertEqual(p.entries[0].characterLinks?.first?.location, 4)
        XCTAssertEqual(CharacterMentions.resolved(in: p.entries[0]).first?.characterId, randy.id)
        XCTAssertEqual(p.entries[0].text, "Now Randy waits.")
        try TimingEngine.validate(p)
    }
}
