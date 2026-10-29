import Foundation

/// Geometry, not editorial time: zero-second notes occupy space in the script
/// without advancing playback. Keeping both axes explicit makes rail dragging
/// invertible through variable-height rows and the gaps between them.
public struct ScriptRailRow: Equatable {
    public let startMs: Int
    public let durationMs: Int
    public let anchorY: Double
    public let bottomY: Double
    public init(startMs: Int, durationMs: Int, anchorY: Double, bottomY: Double) {
        self.startMs = startMs; self.durationMs = durationMs
        self.anchorY = anchorY; self.bottomY = bottomY
    }
}

public enum PresentationGeometry {
    /// At a shared instant use its first authored row, so an owned action ends
    /// before a following zero-time note rather than skipping that note's space.
    public static func railPosition(at timeMs: Int, rows: [ScriptRailRow]) -> Double {
        guard let first = rows.first, let last = rows.last else { return 0 }
        if timeMs <= first.startMs { return first.anchorY }
        for (index, row) in rows.enumerated() {
            if timeMs <= row.startMs { return row.anchorY }
            let end = row.startMs + max(0, row.durationMs)
            guard row.durationMs > 0, timeMs <= end else { continue }
            let bottom = index + 1 < rows.count ? rows[index + 1].anchorY : row.bottomY
            let fraction = Double(timeMs - row.startMs) / Double(row.durationMs)
            return row.anchorY + fraction * max(0, bottom - row.anchorY)
        }
        return last.bottomY
    }

    /// A zero-owned row (including its following gap) maps to one instant.
    /// Quantization is optional, allowing precise round-trip tests and 0.1s drags.
    public static func railTime(at y: Double, rows: [ScriptRailRow], quantumMs: Int = 100) -> Int {
        guard let first = rows.first, let last = rows.last, y.isFinite else { return 0 }
        if y <= first.anchorY { return first.startMs }
        for (index, row) in rows.enumerated() {
            let bottom = index + 1 < rows.count ? rows[index + 1].anchorY : row.bottomY
            guard y <= bottom else { continue }
            let fraction = min(1, max(0, (y - row.anchorY) / max(1, bottom - row.anchorY)))
            let raw = Double(row.startMs) + fraction * Double(max(0, row.durationMs))
            let quantum = Double(max(1, quantumMs))
            return min(row.startMs + max(0, row.durationMs), max(row.startMs, Int((raw / quantum).rounded()) * max(1, quantumMs)))
        }
        return last.startMs + max(0, last.durationMs)
    }

    /// Coverage occupies only its intersection with an image, and touching a
    /// cut is not overlap. Fractions preserve cuts even when cards have equal
    /// visual widths but different durations.
    public static func coverageFractions(startMs: Int, endMs: Int, cueStartMs: Int, cueEndMs: Int) -> ClosedRange<Double>? {
        guard endMs > startMs, cueEndMs > cueStartMs else { return nil }
        let lower = max(startMs, cueStartMs), upper = min(endMs, cueEndMs)
        guard upper > lower else { return nil }
        let duration = Double(cueEndMs - cueStartMs)
        return (Double(lower - cueStartMs) / duration)...(Double(upper - cueStartMs) / duration)
    }

    /// Keep a multi-shot script item together when it fills a whole board row.
    /// Short neighboring entries still share rows; no cue is hidden or reordered.
    public static func storyboardRows(cues: [ImageCue], entryStarts: Set<Int>, columns: Int) -> [[ImageCue]] {
        let columns = max(1, columns)
        var result: [[ImageCue]] = [], pending: [ImageCue] = []
        for (index, cue) in cues.enumerated() {
            if entryStarts.contains(cue.startMs), !pending.isEmpty {
                let nextStart = entryStarts.filter { $0 > cue.startMs }.min() ?? Int.max
                let sameEntryCount = cues[index...].prefix { $0.startMs < nextStart && $0.endMs <= nextStart }.count
                if sameEntryCount >= columns { result.append(pending); pending = [] }
            }
            pending.append(cue)
            if pending.count == columns { result.append(pending); pending = [] }
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }

    /// A dragged cut transfers time; neither adjacent image may disappear.
    public static func clampedCueDuration(proposed: Int, current: Int, neighbor: Int?) -> Int {
        guard let neighbor else { return max(1, current) }
        let (total, overflow) = current.addingReportingOverflow(neighbor)
        guard !overflow, total > 1 else { return max(1, current) }
        return min(total - 1, max(1, proposed))
    }

    /// End handles that visually collide must remain selectable independently.
    public static func coincidentHandles(selectedID: String, positions: [String: Double], tolerance: Double = 14) -> [String] {
        guard let y = positions[selectedID] else { return [] }
        return positions.filter { abs($0.value - y) <= max(0, tolerance) }.map(\.key).sorted()
    }
}
