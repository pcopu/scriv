import Foundation
import ScrivCore

/// Matches picture pills: 20 ms per vertical point. Pointer samples change
/// presentation only; release is one undoable, exact-source-fenced mutation.
struct ScriptDurationScrubDraft {
    let original: ScriptEntry
    let navigation: Int
    private(set) var proposedMilliseconds: Int
    private(set) var finished = false
    init(entry: ScriptEntry, navigation: Int) { original = entry; self.navigation = navigation; proposedMilliseconds = entry.ownedDurationMs }
    mutating func update(translationY: Double) {
        guard !finished, translationY.isFinite else { return }
        let minimum = original.kind == .direction ? 0 : max(1, original.words.count)
        proposedMilliseconds = Int(min(3_600_000, max(Double(minimum), Double(original.ownedDurationMs) - translationY * 20)).rounded())
    }
    mutating func finish(entry: ScriptEntry?, navigation: Int, sceneID: String) -> Int? {
        guard !finished else { return nil }; finished = true
        guard self.navigation == navigation, original.sceneId == sceneID, entry == original,
              entry?.text.utf16.elementsEqual(original.text.utf16) == true,
              proposedMilliseconds != original.ownedDurationMs else { return nil }
        return proposedMilliseconds
    }
    mutating func cancel() { finished = true }
}

