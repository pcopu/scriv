#if SCRIV_CLI_AUTOMATION
import UIKit
import CoreFoundation

@MainActor
enum ScrivCLITimingControls {
    static let commands = ["timing-drag", "timing-tap", "audio-trim-action"]

    static func dispatch(_ command: String, request: [String: Any], window: UIWindow,
                         run: ScrivCLIRunCapability) throws -> [String: Bool]? {
        guard commands.contains(command) else { return nil }
        guard run.approvedOrigin == nil, let workspace = window.rootViewController as? ScrivWorkspaceController,
              (try? ScrivCLILoadedProject.observe(workspace: workspace)) != nil else { throw Failure() }
        let dispatched: Bool
        switch command {
        case "timing-drag":
            guard Set(request.keys) == ["id", "command", "surface", "fromMs", "toMs"],
                  let surface = request["surface"] as? String,
                  let from = milliseconds(request["fromMs"]), let to = milliseconds(request["toMs"])
            else { throw Failure() }
            switch surface {
            case "audio-trim": dispatched = try waveform(in: workspace).cliDrag(from: from, to: to)
            case "word-timing": dispatched = try timeline(in: workspace).cliDrag(from: from, to: to)
            default: throw Failure()
            }
        case "timing-tap":
            guard Set(request.keys) == ["id", "command", "timeMs", "region"],
                  let time = milliseconds(request["timeMs"]), let region = request["region"] as? String,
                  region == "track" || region == "ruler" else { throw Failure() }
            dispatched = try timeline(in: workspace).cliTap(at: time, onTrack: region == "track")
        case "audio-trim-action":
            guard Set(request.keys) == ["id", "command", "action"],
                  let title = request["action"] as? String else { throw Failure() }
            let expected = ["Move source in earlier", "Move source in later", "Move source out earlier", "Move source out later"]
            guard let actions = try waveform(in: workspace).accessibilityCustomActions,
                  actions.map(\.name) == expected,
                  let action = actions.first(where: { $0.name == title }),
                  let handler = action.actionHandler else { throw Failure() }
            dispatched = handler(action)
        default: throw Failure()
        }
        return ["dispatched": dispatched]
    }

    private static func milliseconds(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let count = Int(exactly: number.doubleValue), (0...86_400_000).contains(count) else { return nil }
        return count
    }

    private static func waveform(in workspace: ScrivWorkspaceController) throws -> MeasuredAudioWaveformView {
        guard let waveform = ScrivCLIAudioAnchorMenu.editor(in: workspace, requiresUnchangedClip: true)?.cliWaveform,
              isHittable(waveform) else { throw Failure() }
        return waveform
    }

    private static func timeline(in workspace: ScrivWorkspaceController) throws -> ManualWordTimelineView {
        guard let timeline = ScrivCLIWordTimingMenu.editor(in: workspace)?.cliTimeline,
              isHittable(timeline) else { throw Failure() }
        return timeline
    }

    private static func isHittable(_ view: UIView) -> Bool {
        guard let window = view.window, !window.isHidden else { return false }
        let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
        guard let hit = window.hitTest(center, with: nil) else { return false }
        return hit === view || hit.isDescendant(of: view)
    }

    private struct Failure: LocalizedError {
        var errorDescription: String? { "Timing control is unavailable" }
    }
}

// Samples for the mounted control's existing handlers. These recognizers are
// never attached to a window or installed alongside the normal recognizers.
@MainActor
final class ScrivCLITimingPan: UIPanGestureRecognizer {
    private let point: CGPoint
    private let phase: UIGestureRecognizer.State

    init(point: CGPoint, phase: UIGestureRecognizer.State) {
        self.point = point
        self.phase = phase
        super.init(target: nil, action: nil)
    }

    override var state: UIGestureRecognizer.State {
        get { phase }
        set {}
    }

    override func location(in view: UIView?) -> CGPoint { point }
}

@MainActor
final class ScrivCLITimingTap: UITapGestureRecognizer {
    private let point: CGPoint

    init(point: CGPoint) {
        self.point = point
        super.init(target: nil, action: nil)
    }

    override func location(in view: UIView?) -> CGPoint { point }
}
#endif
