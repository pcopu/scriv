import UIKit

/// Script geometry and type. Zoom remains one shared user preference; this is
/// presentation, never source timing.
struct ScriptPresentationMetrics: Equatable {
    // One presentation everywhere the script appears (Script and Characters
    // tabs): the same text size, spacing and rails, so switching tabs keeps
    // the same zoom and the same place in the script.
    var paneWidth: CGFloat = 715
    // Catalyst retains its existing rendering scale. Expand optical geometry
    // only when the pane has room, rather than changing the entire application.
    var opticalScale: CGFloat { max(1, min(1.3, paneWidth / 715)) }
    var bodySize: CGFloat { 22 * opticalScale }
    var gutterWidth: CGFloat { 80 * opticalScale }
    var railGap: CGFloat { 122 * opticalScale }
    var textInset: CGFloat { gutterWidth + railGap }
    var railX: CGFloat { 116 * opticalScale }
    var rowSpacing: CGFloat { 23 * opticalScale }
    var rowPadding: CGFloat { 10 * opticalScale }
    var textSpacing: CGFloat { 6 * opticalScale }
    var anchorOffset: CGFloat { rowPadding + 16 * opticalScale }
    var titleSize: CGFloat { 25 * opticalScale }
    var subtitleSize: CGFloat { 17 * opticalScale }
    func fontSize(zoom: Double) -> CGFloat { bodySize * CGFloat(zoom) }
    static let expanded = ScriptPresentationMetrics()
}
