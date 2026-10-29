import Foundation

public struct CharacterMention: Equatable, Sendable {
    /// UTF-16 range suitable for attributed text and native text editors.
    public let range: NSRange
    public let characterId: String
}

public enum CharacterMentions {
    /// Links annotate the original string; they never replace or normalize wording.
    /// Longer names win. For the same span, an exact profile name outranks aliases;
    /// equally plausible identities stay unlinked instead of opening an arbitrary person.
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
}
