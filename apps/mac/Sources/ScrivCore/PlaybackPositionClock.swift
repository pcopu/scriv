import Foundation

/// Monotonic visual-playback clock, independent of frame rate and audio synthesis.
/// Seeking while running rebases the anchor instead of snapping back on the next tick.
public struct PlaybackPositionClock: Sendable {
    private var offsetMs: Double = 0
    private var anchorMs: Double?
    public init() {}
    public mutating func start(fromMs: Double, nowMs: Double) {
        guard fromMs.isFinite, nowMs.isFinite else { return }
        offsetMs = max(0,fromMs); anchorMs = nowMs
    }
    public mutating func seek(toMs: Double, nowMs: Double) {
        guard toMs.isFinite, nowMs.isFinite else { return }
        offsetMs = max(0,toMs)
        if anchorMs != nil { anchorMs = nowMs }
    }
    public func position(nowMs: Double, durationMs: Int) -> Double {
        let elapsed = anchorMs.map { nowMs.isFinite ? max(0,nowMs - $0) : 0 } ?? 0
        return min(max(0,offsetMs + elapsed),Double(max(0,durationMs)))
    }
    public mutating func pause(nowMs: Double, durationMs: Int) -> Double {
        offsetMs = position(nowMs:nowMs,durationMs:durationMs); anchorMs = nil; return offsetMs
    }
}
