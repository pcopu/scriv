import XCTest
import UIKit
import ScrivCore
@testable import ScrivUIKit

@MainActor
final class CharacterTeamTests: XCTestCase {
    func testExactOccurrenceReviewKeepsUTF16AndRepeatedOccurrencesSeparate() {
        let text = "🙂 Franklin and Franklin."
        XCTAssertEqual(UIKitCharacterLinkPresentation.occurrences(of: "Franklin", in: text), [NSRange(location: 3, length: 8), NSRange(location: 16, length: 8)])
        XCTAssertEqual(UIKitCharacterLinkPresentation.occurrences(of: "franklin", in: text), [])
        XCTAssertEqual(UIKitCharacterLinkPresentation.occurrences(of: "", in: text), [])
    }
    func testSourceHighlightDoesNotChangeWordingOrGuessIdentity() {
        let text = "🙂 Franklin and the boys."
        let person = ScriptCharacter(id: "farmer", name: "Farmer Franklin", aliases: ["Franklin"], color: "orange")
        let unreviewed = UIKitCharacterLinkPresentation.highlighted(text, characters: [person])
        XCTAssertEqual(unreviewed.string, text); XCTAssertTrue(highlights(unreviewed).isEmpty)
        let range = (text as NSString).range(of: "Franklin")
        let suggestion = CharacterTextLink(characterId: person.id, location: range.location, length: range.length, text: "Franklin", isConfirmed: false)
        let value = UIKitCharacterLinkPresentation.highlighted(text, links: [suggestion], characters: [person])
        XCTAssertEqual(highlights(value), [range]); XCTAssertFalse(suggestion.isConfirmed)
        XCTAssertTrue(CharacterMentions.resolved(in: text, links: [suggestion]).isEmpty)
        XCTAssertNil(value.attribute(.link, at: range.location, effectiveRange: nil))
    }
    func testManualOccurrenceHighlightTargetsOnlyChosenExactSpan() {
        let text = "🙂 Franklin and Franklin."
        let chosen = NSRange(location: 16, length: 8)
        let value = UIKitCharacterLinkPresentation.highlighted(text, focusedRange: chosen)
        XCTAssertEqual(value.string, text); XCTAssertEqual(highlights(value), [chosen])
        XCTAssertTrue(highlights(UIKitCharacterLinkPresentation.highlighted(text, focusedRange: NSRange(location: Int.max, length: 1))).isEmpty)
    }
    func testUnknownUnlinkedAndStaleIdentityRangesNeverGetInventedHighlights() {
        let text = "Franklin waits.", person = ScriptCharacter(id: "known", name: "Franklin")
        let missing = CharacterTextLink(characterId: "missing", location: 0, length: 8, text: "Franklin")
        let unlinked = CharacterTextLink(characterId: nil, location: 0, length: 8, text: "Franklin")
        let stale = CharacterTextLink(characterId: person.id, location: 0, length: 8, text: "Someone!")
        for link in [missing, unlinked, stale] {
            XCTAssertTrue(highlights(UIKitCharacterLinkPresentation.highlighted(text, links: [link], characters: [person])).isEmpty)
        }
    }
    func testCharacterCreationValidationLeavesOriginalProjectUntouched() throws {
        let project = ScrivProject.example(), before = project
        let draft = ScriptCharacter(name: "")
        XCTAssertThrowsError(try UIKitCharacterFormValidation.validate(draft))
        XCTAssertEqual(project, before); XCTAssertFalse(project.characters.contains { $0.id == draft.id })
        var named = draft; named.name = "New name"
        XCTAssertNoThrow(try UIKitCharacterFormValidation.validate(named))
        XCTAssertEqual(project, before)
    }
    func testCharacterBoundsRetainUnicodeAndDoNotSplitCommaAliases() throws {
        let value = ScriptCharacter(name: "台詞", aliases: ["Papa, Jr.", "🙂"], biography: "  cafe\u{301}\n", appearance: "Warm light")
        XCTAssertNoThrow(try UIKitCharacterFormValidation.validate(value))
        XCTAssertEqual(value.aliases, ["Papa, Jr.", "🙂"])
        XCTAssertTrue(value.biography.utf16.elementsEqual("  cafe\u{301}\n".utf16))
        var invalid = value; invalid.name = String(repeating: "🙂", count: 101)
        XCTAssertThrowsError(try UIKitCharacterFormValidation.validate(invalid))
        invalid = value; invalid.appearance = String(repeating: "x", count: 20_001)
        XCTAssertThrowsError(try UIKitCharacterFormValidation.validate(invalid))
        invalid = value; invalid.biography = String(repeating: "\u{0001}", count: 12_000)
        XCTAssertThrowsError(try UIKitCharacterFormValidation.validate(invalid), "Full encoded metadata must respect 64 KiB even below the field character limit")
    }
    func testRoleMenusNeverOfferOwnerRemovalOrAdminEscalation() {
        for role in ["owner", "admin", "member", "viewer"] { XCTAssertFalse(UIKitTeamPolicy.canEditMember(actorRole: role, targetRole: "owner")) }
        XCTAssertTrue(UIKitTeamPolicy.canEditMember(actorRole: "owner", targetRole: "admin"))
        XCTAssertFalse(UIKitTeamPolicy.canEditMember(actorRole: "admin", targetRole: "admin"))
        XCTAssertTrue(UIKitTeamPolicy.canEditMember(actorRole: "admin", targetRole: "member"))
        XCTAssertTrue(UIKitTeamPolicy.canEditMember(actorRole: "admin", targetRole: "viewer"))
        XCTAssertFalse(UIKitTeamPolicy.canEditMember(actorRole: "member", targetRole: "viewer"))
        XCTAssertFalse(UIKitTeamPolicy.canEditMember(actorRole: nil, targetRole: "member"))
    }
    func testExistingSubscriptionAttentionNeverOffersDuplicateCheckout() throws {
        for status in ["past_due", "unpaid", "incomplete", "paused"] {
            let team = try team(role: "owner", plan: "free", status: status)
            XCTAssertTrue(UIKitTeamPolicy.billingNeedsAttention(team)); XCTAssertFalse(UIKitTeamPolicy.canStartCheckout(team))
        }
        for status in ["free", "canceled", "incomplete_expired"] {
            let team = try team(role: "owner", plan: "free", status: status)
            XCTAssertFalse(UIKitTeamPolicy.billingNeedsAttention(team)); XCTAssertTrue(UIKitTeamPolicy.canStartCheckout(team))
        }
        XCTAssertFalse(UIKitTeamPolicy.canStartCheckout(try team(role: "owner", plan: "team", status: "active")))
        XCTAssertFalse(UIKitTeamPolicy.canStartCheckout(try team(role: "member", plan: "free", status: "free")))
    }
    func testInvitationStatusUsesActualExpiryAndRevocation() {
        let now = Date(timeIntervalSince1970: 1000)
        let active: JSONValue = .object(["expiresAt": .number(1_100_000), "revokedAt": .null])
        let expired: JSONValue = .object(["expiresAt": .number(1_000_000)])
        let revoked: JSONValue = .object(["expiresAt": .number(1_100_000), "revokedAt": .number(999_000)])
        XCTAssertTrue(UIKitTeamPolicy.activeInvitation(active, now: now))
        XCTAssertFalse(UIKitTeamPolicy.activeInvitation(expired, now: now)); XCTAssertEqual(UIKitTeamPolicy.invitationState(expired, now: now), "Expired")
        XCTAssertFalse(UIKitTeamPolicy.activeInvitation(revoked, now: now)); XCTAssertEqual(UIKitTeamPolicy.invitationState(revoked, now: now), "Revoked")
        XCTAssertFalse(UIKitTeamPolicy.activeInvitation(.object([:]), now: now))
    }
    private func highlights(_ text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in if value != nil { ranges.append(range) } }
        return ranges
    }
    private func team(role: String, plan: String, status: String) throws -> CloudTeam {
        try JSONValue.object(["id": .string("team"), "name": .string("Test Studio"), "role": .string(role), "plan": .string(plan), "status": .string(status)]).decoded(CloudTeam.self)
    }
}
