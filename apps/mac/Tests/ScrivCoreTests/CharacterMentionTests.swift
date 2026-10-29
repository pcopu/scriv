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
}
