import Foundation

/// Native Return/Backspace operations. Both work on a copy, validate the entire
/// document and publish once; rejected operations leave the original untouched.
public enum ScriptBoundaryEditing {
    @discardableResult
    public static func split(project: inout ScrivProject, entryID: String, atUTF16Offset offset: Int, expectedText: String) throws -> String {
        var next = project
        guard let index = next.entries.firstIndex(where: { $0.id == entryID }) else { throw ScrivError.invalid("This line no longer exists.") }
        let original = next.entries[index]
        try checkSource(original, expectedText: expectedText)
        guard offset >= 0, offset <= original.text.utf16.count,
              let boundary = Range(NSRange(location: offset, length: 0), in: original.text),
              original.text.indices.contains(boundary.lowerBound) || boundary.lowerBound == original.text.endIndex else {
            throw ScrivError.invalid("Split between complete characters, not inside an emoji or composed character.")
        }
        let leftText = String(original.text[..<boundary.lowerBound]), rightText = String(original.text[boundary.lowerBound...])
        let leftMinimum = original.kind == .dialogue ? max(1, tokens(leftText).count) : 0
        let rightMinimum = original.kind == .dialogue ? max(1, tokens(rightText).count) : 0
        guard original.ownedDurationMs >= leftMinimum + rightMinimum else {
            throw ScrivError.invalid("Increase this line’s duration before splitting; each new spoken line needs time for its words.")
        }
        let proposed = caretTime(in: original, utf16Offset: offset)
        let cut = min(original.ownedDurationMs - rightMinimum, max(leftMinimum, proposed))
        let newID = UUID().uuidString
        var left = original, right = original
        left.text = leftText; left.ownedDurationMs = cut
        right.id = newID; right.text = rightText; right.ownedDurationMs = original.ownedDurationMs - cut
        let links = original.characterLinks ?? CharacterMentions.suggestions(in: original.text, characters: next.characters)
        left.characterLinks = partitionLinks(links, source: original.text, lower: 0, upper: offset)
        right.characterLinks = partitionLinks(links, source: original.text, lower: offset, upper: original.text.utf16.count)
        if original.kind == .dialogue {
            let source = sourceWords(original)
            left.words = try projectedWords(text: leftText, source: source, rangeOffset: 0, timeOffset: 0, scale: 1, duration: left.ownedDurationMs)
            right.words = try projectedWords(text: rightText, source: source, rangeOffset: offset, timeOffset: cut, scale: 1, duration: right.ownedDurationMs)
        } else {
            left.coverageDurationMs = max(left.ownedDurationMs, original.coverageDurationMs)
            right.coverageDurationMs = max(right.ownedDurationMs, original.coverageDurationMs - cut)
        }
        try CueAnchoring.materialize(&next, sceneId: original.sceneId)
        next.entries[index] = left; next.entries.append(right)
        var sequence = project.entries(in: original.sceneId)
        let position = sequence.firstIndex(where: { $0.id == entryID })!
        sequence.insert(right, at: position + 1)
        assignOrder(&next, sequence: sequence, changedID: newID)
        for i in next.cues.indices {
            guard var anchor = next.cues[i].startAnchor, anchor.entryId == entryID, anchor.offsetMs >= cut,
                  right.ownedDurationMs > 0 || original.kind == .direction else { continue }
            anchor.entryId = newID; anchor.offsetMs -= cut; next.cues[i].startAnchor = anchor
        }
        // Clips may span a line boundary. Preserve source trim and bytes exactly;
        // only clips starting in the second part acquire that part's identity.
        for i in next.audioClips.indices where next.audioClips[i].entryId == entryID && next.audioClips[i].startMs >= cut {
            next.audioClips[i].entryId = newID; next.audioClips[i].startMs -= cut
        }
        try CueAnchoring.resolve(&next, sceneId: original.sceneId)
        try TimingEngine.validate(next); project = next
        return newID
    }

    @discardableResult
    public static func mergeIntoPrevious(project: inout ScrivProject, entryID: String, expectedText: String) throws -> (entryID: String, caretUTF16Offset: Int) {
        var next = project
        guard let current = next.entries.first(where: { $0.id == entryID }) else { throw ScrivError.invalid("This line no longer exists.") }
        try checkSource(current, expectedText: expectedText)
        let sequence = next.entries(in: current.sceneId)
        guard let position = sequence.firstIndex(where: { $0.id == entryID }), position > 0 else { throw ScrivError.invalid("There is no previous line in this scene.") }
        let previous = sequence[position - 1]
        guard previous.kind == current.kind else {
            throw ScrivError.invalid("A spoken line and a direction cannot be merged without changing their meaning. Move the text explicitly instead.")
        }
        let caret = previous.text.utf16.count
        var merged = previous; merged.text = previous.text + current.text
        let duration = previous.ownedDurationMs, combined = duration + current.ownedDurationMs
        let scale = combined > 0 ? Double(duration) / Double(combined) : 0
        if previous.kind == .dialogue {
            guard duration >= max(1, tokens(merged.text).count) else {
                throw ScrivError.invalid("The previous line is too short for all these words. Increase its duration before merging.")
            }
            let source = sourceWords(previous) + sourceWords(current, rangeOffset: caret, timeOffset: duration)
            merged.words = try projectedWords(text: merged.text, source: source, rangeOffset: 0, timeOffset: 0, scale: scale, duration: duration)
        }
        let leftLinks = previous.characterLinks ?? CharacterMentions.suggestions(in: previous.text, characters: next.characters)
        let rightLinks = (current.characterLinks ?? CharacterMentions.suggestions(in: current.text, characters: next.characters)).map { link -> CharacterTextLink in var value = link; value.location += caret; return value }
        // Exact source annotations stay attached even if two words now touch.
        // Link IDs are entry-local, so resolve a rare cross-entry ID collision.
        var used = Set<String>()
        merged.characterLinks = (leftLinks + rightLinks).map { link in var value = link; if !used.insert(value.id).inserted { value.id = UUID().uuidString; used.insert(value.id) }; return value }
        try CueAnchoring.materialize(&next, sceneId: current.sceneId)
        let start = next.startMs(of: previous.id), end = start + combined
        func mapped(_ time: Int) -> Int {
            if time <= start { return time }
            if time >= end { return time - current.ownedDurationMs }
            return start + Int((Double(time - start) * scale).rounded())
        }
        for i in next.entries.indices where next.entries[i].sceneId == current.sceneId && next.entries[i].kind == .direction && next.entries[i].id != current.id {
            let old = next.entries[i], source = next.startMs(of: old.id)
            let length = max(old.id == previous.id ? duration : old.ownedDurationMs, mapped(source + old.coverageDurationMs) - mapped(source))
            next.entries[i].coverageDurationMs = length
            if old.id == previous.id { merged.coverageDurationMs = max(length, mapped(next.startMs(of: current.id) + current.coverageDurationMs) - start) }
        }
        next.entries.removeAll { $0.id == current.id }
        next.entries[next.entries.firstIndex(where: { $0.id == previous.id })!] = merged
        for i in next.cues.indices {
            guard var anchor = next.cues[i].startAnchor, anchor.entryId == previous.id || anchor.entryId == current.id else { continue }
            let oldOffset = anchor.offsetMs + (anchor.entryId == current.id ? duration : 0)
            anchor.entryId = previous.id
            anchor.offsetMs = duration == 0 ? 0 : min(duration - 1, max(0, Int((Double(oldOffset) * scale).rounded())))
            // Images retain immutable identity and source-owned forward extent;
            // scene-end clipping is a projection, never asset deletion.
            next.cues[i].startAnchor = anchor
        }
        for i in next.audioClips.indices {
            guard let id = next.audioClips[i].entryId, id == previous.id || id == current.id else { continue }
            let oldOffset = next.audioClips[i].startMs + (id == current.id ? duration : 0)
            next.audioClips[i].entryId = previous.id
            next.audioClips[i].startMs = max(0, mapped(start + oldOffset) - start)
        }
        try CueAnchoring.resolve(&next, sceneId: current.sceneId)
        try TimingEngine.validate(next); project = next
        return (previous.id, caret)
    }

    /// Carets refer to exact source UTF-16, never a guessed character-count ratio.
    /// Whitespace starts at the following word; the line-end caret starts at end.
    public static func caretTime(in entry: ScriptEntry, utf16Offset offset: Int) -> Int {
        let length = entry.text.utf16.count
        guard length > 0 else { return 0 }
        if offset <= 0 { return 0 }; if offset >= length { return entry.ownedDurationMs }
        if entry.kind == .direction { return Int((Double(offset) / Double(length) * Double(entry.ownedDurationMs)).rounded()) }
        for item in sourceWords(entry) {
            if offset < item.range.location { return item.word.startMs }
            if offset < NSMaxRange(item.range) {
                let fraction = Double(offset - item.range.location) / Double(item.range.length)
                return item.word.startMs + Int((fraction * Double(item.word.endMs - item.word.startMs)).rounded())
            }
        }
        return entry.ownedDurationMs
    }
    public static func utf16Range(ofWordID id: String, in entry: ScriptEntry) -> NSRange? {
        sourceWords(entry).first { $0.word.id == id }?.range
    }
    private static func checkSource(_ entry: ScriptEntry, expectedText: String) throws {
        guard entry.text.utf16.elementsEqual(expectedText.utf16) else { throw ScrivError.conflict("This line changed. Review the current text before changing its boundary.") }
    }
    private struct SourceWord { var word: TimedWord; var range: NSRange }
    private static func tokens(_ text: String) -> [(text: String, range: NSRange)] {
        text.split(whereSeparator: { $0.isWhitespace }).map { (String($0), NSRange($0.startIndex..<$0.endIndex, in: text)) }
    }
    private static func sourceWords(_ entry: ScriptEntry, rangeOffset: Int = 0, timeOffset: Int = 0) -> [SourceWord] {
        zip(entry.words, tokens(entry.text)).map { word, token in
            var value = word; value.startMs += timeOffset; value.endMs += timeOffset
            return SourceWord(word: value, range: NSRange(location: token.range.location + rangeOffset, length: token.range.length))
        }
    }
    private static func projectedWords(text: String, source: [SourceWord], rangeOffset: Int, timeOffset: Int, scale: Double, duration: Int) throws -> [TimedWord] {
        let output = tokens(text)
        guard duration >= output.count else { throw ScrivError.invalid("There is not enough time to preserve every word.") }
        var end = 0
        return try output.enumerated().map { index, token in
            let range = NSRange(location: token.range.location + rangeOffset, length: token.range.length)
            let contributors = source.filter { NSIntersectionRange($0.range, range).length > 0 }
            guard let first = contributors.first, let last = contributors.last else { throw ScrivError.invalid("Word timing cannot be mapped to the exact source text.") }
            func endpoint(_ item: SourceWord, offset: Int) -> Double {
                let fraction = Double(min(item.range.length, max(0, offset - item.range.location))) / Double(item.range.length)
                return (Double(item.word.startMs) + fraction * Double(item.word.endMs - item.word.startMs) - Double(timeOffset)) * scale
            }
            let ceiling = duration - (output.count - index - 1)
            let lower = min(ceiling - 1, max(end, Int(endpoint(first, offset: range.location).rounded())))
            let upper = min(ceiling, max(lower + 1, Int(endpoint(last, offset: NSMaxRange(range)).rounded())))
            end = upper
            let identical = contributors.count == 1 && first.range == range && first.word.text.utf16.elementsEqual(token.text.utf16)
            return TimedWord(id: identical ? first.word.id : UUID().uuidString, text: token.text, startMs: lower, endMs: upper, timingSource: contributors.contains { $0.word.timingSource == .authored } ? .authored : nil)
        }
    }
    private static func partitionLinks(_ links: [CharacterTextLink], source: String, lower: Int, upper: Int) -> [CharacterTextLink] {
        links.compactMap { link in
            let begin = max(lower, link.location), end = min(upper, NSMaxRange(link.range))
            guard end > begin else { return nil }
            var result = link
            if begin != link.location { result.id = UUID().uuidString }
            result.location = begin - lower; result.length = end - begin
            result.text = (source as NSString).substring(with: NSRange(location: begin, length: end - begin))
            return result
        }
    }
    private static func assignOrder(_ project: inout ScrivProject, sequence: [ScriptEntry], changedID: String) {
        let position = sequence.firstIndex { $0.id == changedID }!, index = project.entries.firstIndex { $0.id == changedID }!
        let lower = sequence[position - 1].order, upper = position + 1 < sequence.count ? sequence[position + 1].order : nil
        let candidate = upper.map { lower / 2 + $0 / 2 } ?? (lower + 1 > lower ? lower + 1 : lower.nextUp)
        if candidate.isFinite, candidate > lower, upper.map({ candidate < $0 }) ?? true { project.entries[index].order = candidate }
        else { for (order, item) in sequence.enumerated() { project.entries[project.entries.firstIndex { $0.id == item.id }!].order = Double(order) } }
    }
}
