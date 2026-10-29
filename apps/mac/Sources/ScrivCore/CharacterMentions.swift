import Foundation

public struct CharacterMention: Equatable, Sendable {
    /// UTF-16 range suitable for attributed text and native text editors.
    public let range: NSRange
    public let characterId: String
}

/// A source annotation, never a replacement for the author's words. A nil identity
/// records an explicit unlink; an unconfirmed identity is a suggestion, not a link.
public struct CharacterTextLink: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var characterId: String?
    public var location: Int
    public var length: Int
    public var text: String
    public var isConfirmed: Bool
    public var range: NSRange { NSRange(location: location, length: length) }
    public init(id: String = UUID().uuidString, characterId: String?, location: Int, length: Int, text: String, isConfirmed: Bool = true) {
        self.id = id; self.characterId = characterId; self.location = location; self.length = length; self.text = text; self.isConfirmed = isConfirmed
    }
}

/// Exact native edit events disambiguate deleting one of two identical names.
public struct CharacterTextEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String
    public init(range: NSRange, replacement: String) { self.range = range; self.replacement = replacement }
}

public enum CharacterMentions {
    /// Name matching proposes identities only. Display and generation use resolved
    /// annotations instead, so renames and reused aliases cannot rebind old words.
    /// Longer names win; canonical names outrank aliases; ties stay unassigned.
    public static func find(in text: String, characters: [ScriptCharacter]) -> [CharacterMention] {
        struct Candidate { let characterId: String; let canonical: Bool }
        var matches: [NSRange:[Candidate]] = [:]
        for character in characters {
            for (index, name) in ([character.name] + character.aliases).enumerated() where !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                let pattern = "(?<![\\p{L}\\p{M}\\p{N}_])" + NSRegularExpression.escapedPattern(for:name) + "(?![\\p{L}\\p{M}\\p{N}_])"
                guard let regex = try? NSRegularExpression(pattern:pattern,options:.caseInsensitive) else { continue }
                for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)) { matches[match.range,default:[]].append(Candidate(characterId:character.id,canonical:index == 0)) }
            }
        }
        let ranges = matches.keys.sorted { $0.length == $1.length ? $0.location < $1.location : $0.length > $1.length }
        var occupied: [NSRange] = [], result: [CharacterMention] = []
        for range in ranges {
            guard !occupied.contains(where: { NSIntersectionRange($0,range).length > 0 }), let candidates = matches[range] else { continue }
            occupied.append(range)
            let canonical = candidates.filter(\.canonical)
            let ids = Set((canonical.isEmpty ? candidates : canonical).map(\.characterId))
            if ids.count == 1, let id = ids.first { result.append(CharacterMention(range:range,characterId:id)) }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    public static func suggestions(in text: String, characters: [ScriptCharacter], excluding links: [CharacterTextLink] = []) -> [CharacterTextLink] {
        find(in: text, characters: characters).filter { mention in
            !links.contains { NSIntersectionRange($0.range, mention.range).length > 0 }
        }.map { CharacterTextLink(characterId: $0.characterId, location: $0.range.location, length: $0.range.length, text: (text as NSString).substring(with: $0.range), isConfirmed: false) }
    }

    public static func resolved(in entry: ScriptEntry) -> [CharacterMention] {
        resolved(in: entry.text, links: entry.characterLinks ?? [])
    }
    public static func resolved(in text: String, links: [CharacterTextLink]) -> [CharacterMention] {
        links.compactMap { link in
            guard link.isConfirmed, let id = link.characterId, matchesSource(link, in: text) else { return nil }
            return CharacterMention(range: link.range, characterId: id)
        }
    }

    /// Freeze current suggestions BEFORE changing the character catalog. Existing
    /// confirmed/unlinked annotations are untouched, including their exact wording.
    public static func bootstrap(_ project: inout ScrivProject) {
        for index in project.entries.indices where project.entries[index].characterLinks == nil {
            project.entries[index].characterLinks = suggestions(in: project.entries[index].text, characters: project.characters)
        }
    }

    public static func validate(entry: ScriptEntry, characterIDs: Set<String>) throws {
        guard let links = entry.characterLinks else { return } // Compatible with old packages and cloud records.
        var ids = Set<String>(), end = 0
        for link in links {
            guard !link.id.isEmpty, link.id.utf8.count <= 128, ids.insert(link.id).inserted,
                  link.location >= end, matchesSource(link, in: entry.text),
                  link.characterId.map(characterIDs.contains) ?? link.isConfirmed else {
                throw ScrivError.invalid("Character links must preserve exact, non-overlapping script ranges and refer to existing characters.")
            }
            end = link.location + link.length
        }
    }

    public static func matchesSource(_ link: CharacterTextLink, in text: String) -> Bool {
        guard validRange(link.range, in: text), link.length > 0 else { return false }
        return (text as NSString).substring(with: link.range).utf16.elementsEqual(link.text.utf16)
    }

    /// Keep untouched identities and adjust their UTF-16 offsets, never re-run
    /// name matching over old prose. Only newly authored text gets new suggestions.
    /// Without exact edit events, ambiguous repeated text is conservatively revoked
    /// for review rather than retaining the wrong occurrence's identity.
    public static func reconcile(entry: ScriptEntry, editedText: String, characters: [ScriptCharacter], edits: [CharacterTextEdit]? = nil) -> [CharacterTextLink] {
        let initial = entry.characterLinks ?? suggestions(in: entry.text, characters: characters)
        if let edits, !edits.isEmpty {
            var text = entry.text, links = initial
            var valid = true
            for edit in edits {
                guard validRange(edit.range, in: text) else { valid = false; break }
                let next = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
                links = transform(links, from: text, to: next, removed: edit.range,
                                  inserted: NSRange(location: edit.range.location, length: (edit.replacement as NSString).length), characters: characters)
                text = next
            }
            if valid, text.utf16.elementsEqual(editedText.utf16) { return links }
        }
        guard !entry.text.utf16.elementsEqual(editedText.utf16) else { return initial }
        let old = Array(entry.text.utf16), new = Array(editedText.utf16)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        while suffix < min(old.count, new.count), old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let kept = min(prefix + suffix, min(old.count, new.count))
        var first = max(0, kept - suffix), lastOld = min(prefix, kept) + old.count - kept
        var lastNew = min(prefix, kept) + new.count - kept
        // Expand through surrogate pairs rather than handing a split scalar to NSString.
        while first > 0 && (splitsScalar(old, at: first) || splitsScalar(new, at: first)) { first -= 1 }
        while lastOld < old.count && splitsScalar(old, at: lastOld) { lastOld += 1 }
        while lastNew < new.count && splitsScalar(new, at: lastNew) { lastNew += 1 }
        return transform(initial, from: entry.text, to: editedText,
                         removed: NSRange(location: first, length: lastOld - first),
                         inserted: NSRange(location: first, length: lastNew - first), characters: characters)
    }

    /// Explicit correction/rejection for an exact source range. Existing overlap
    /// is replaced as one operation; source text is never edited.
    public static func assign(_ entry: inout ScriptEntry, range: NSRange, characterId: String?, characters: [ScriptCharacter]) throws {
        guard validRange(range, in: entry.text), range.length > 0,
              characterId == nil || characters.contains(where: { $0.id == characterId }) else {
            throw ScrivError.invalid("Select existing script words and an available character.")
        }
        var links = entry.characterLinks ?? suggestions(in: entry.text, characters: characters)
        let priorID = links.first { $0.range == range }?.id
        links.removeAll { NSIntersectionRange($0.range, range).length > 0 }
        links.append(CharacterTextLink(id: priorID ?? UUID().uuidString, characterId: characterId, location: range.location, length: range.length, text: (entry.text as NSString).substring(with: range)))
        entry.characterLinks = links.sorted { $0.location < $1.location }
    }

    private static func transform(_ links: [CharacterTextLink], from old: String, to new: String, removed: NSRange, inserted: NSRange, characters: [ScriptCharacter]) -> [CharacterTextLink] {
        let delta = (new as NSString).length - (old as NSString).length
        var preserved = links.compactMap { link -> CharacterTextLink? in
            guard matchesSource(link, in: old) else { return nil }
            var next = link
            if link.location + link.length <= removed.location { /* Before edit. */ }
            else if link.location >= removed.location + removed.length { next.location += delta }
            else { return nil }
            guard matchesSource(next, in: new) else { return nil }
            // Adding/deleting letters next to a name changes that token too.
            if hasWordBoundary(link.range, in: old) && !hasWordBoundary(next.range, in: new) { return nil }
            return next
        }
        let proposed = suggestions(in: new, characters: characters, excluding: preserved).filter {
            NSIntersectionRange($0.range, inserted).length > 0 ||
                (inserted.length == 0 && $0.location <= inserted.location && $0.location + $0.length >= inserted.location)
        }
        preserved += proposed
        return preserved.sorted { $0.location < $1.location }
    }
    private static func validRange(_ range: NSRange, in text: String) -> Bool {
        let count = (text as NSString).length
        guard range.location >= 0, range.length >= 0, range.location <= count, range.length <= count - range.location else { return false }
        return Range(range, in: text) != nil
    }
    private static func splitsScalar(_ units: [UInt16], at index: Int) -> Bool {
        index > 0 && index < units.count && (0xD800...0xDBFF).contains(units[index - 1]) && (0xDC00...0xDFFF).contains(units[index])
    }
    private static func hasWordBoundary(_ range: NSRange, in text: String) -> Bool {
        guard validRange(range, in: text), range.length > 0 else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: (text as NSString).substring(with: range))
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{M}\\p{N}_])" + escaped + "(?![\\p{L}\\p{M}\\p{N}_])") else { return false }
        return regex.firstMatch(in: text, options: .withTransparentBounds, range: range)?.range == range
    }
}
