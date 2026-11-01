import UIKit

/// The two approved boards deliberately use different reading densities. Zoom
/// remains one shared user preference; this is presentation, never source timing.
struct ScriptPresentationMetrics: Equatable {
    let isCompact: Bool
    var paneWidth: CGFloat = 715
    // Catalyst retains its existing rendering scale. Expand optical geometry
    // only when the pane has room, rather than changing the entire application.
    var opticalScale: CGFloat { max(1, min(1.3, paneWidth / 715)) }
    var bodySize: CGFloat { (isCompact ? 16 : 22) * opticalScale }
    var gutterWidth: CGFloat { (isCompact ? 64 : 80) * opticalScale }
    var railGap: CGFloat { (isCompact ? 64 : 122) * opticalScale }
    var textInset: CGFloat { gutterWidth + railGap }
    var railX: CGFloat { (isCompact ? 88 : 116) * opticalScale }
    var rowSpacing: CGFloat { (isCompact ? 5 : 23) * opticalScale }
    var rowPadding: CGFloat { (isCompact ? 4 : 10) * opticalScale }
    var textSpacing: CGFloat { (isCompact ? 2 : 6) * opticalScale }
    var anchorOffset: CGFloat { rowPadding + (isCompact ? 12 : 16) * opticalScale }
    var titleSize: CGFloat { (isCompact ? 20 : 25) * opticalScale }
    var subtitleSize: CGFloat { (isCompact ? 14 : 17) * opticalScale }
    func fontSize(zoom: Double) -> CGFloat { bodySize * CGFloat(zoom) }
    static let expanded = ScriptPresentationMetrics(isCompact: false)
    static let compact = ScriptPresentationMetrics(isCompact: true)
}
