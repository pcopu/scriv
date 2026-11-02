import UIKit
import ObjectiveC

/// Mac Catalyst clips a form sheet whose preferredContentSize is larger than the
/// window, hiding its footer buttons. Sheets keep their designed size and are
/// shrunk to fit the window (and grow back when the window grows).
@MainActor
enum ScrivSheetFitting {
    /// Space kept between the sheet and the window edges.
    static let margin = CGSize(width: 24, height: 20)
    /// Catalyst draws a form sheet no wider than about 1040 pt but still lays
    /// its content out at the requested width, clipping both edges.
    static let maximumWidth: CGFloat = 1024
    private nonisolated(unsafe) static var designedKey: UInt8 = 0
    private nonisolated(unsafe) static var appliedKey: UInt8 = 0

    /// The size a sheet asks for in a window of `available` size.
    static func fittedSize(designed: CGSize, available: CGSize) -> CGSize {
        CGSize(width: max(320, min(designed.width, maximumWidth, available.width - 2 * margin.width)),
               height: max(320, min(designed.height, available.height - 2 * margin.height)))
    }

    static func fit(_ sheet: UIViewController, in available: CGSize) {
        guard sheet.modalPresentationStyle == .formSheet, available.width > 0, available.height > 0 else { return }
        let current = sheet.preferredContentSize
        let applied = (objc_getAssociatedObject(sheet, &appliedKey) as? NSValue)?.cgSizeValue
        // A sheet that changed its own size since the last fit has a new design.
        if applied != current || objc_getAssociatedObject(sheet, &designedKey) == nil {
            objc_setAssociatedObject(sheet, &designedKey, NSValue(cgSize: current), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        guard let designed = (objc_getAssociatedObject(sheet, &designedKey) as? NSValue)?.cgSizeValue, designed != .zero else { return }
        let target = fittedSize(designed: designed, available: available)
        objc_setAssociatedObject(sheet, &appliedKey, NSValue(cgSize: target), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if current != target { sheet.preferredContentSize = target }
    }

    /// The window area a sheet may use (the title bar is a safe-area inset).
    static func available(in window: UIWindow?) -> CGSize? {
        guard let window else { return nil }
        return window.bounds.inset(by: window.safeAreaInsets).size
    }

    /// Fits a sheet about to be presented from `presenter`.
    static func fit(_ sheet: UIViewController, presentedFrom presenter: UIViewController) {
        if let available = available(in: presenter.view.window) { fit(sheet, in: available) }
    }

    /// Refits the sheet that contains `controller` after it changed its own size,
    /// so a sheet that grows to fit its content still stays inside the window.
    static func refit(containing controller: UIViewController) {
        let sheet = controller.navigationController ?? controller
        if let presenter = sheet.presentingViewController { fit(sheet, presentedFrom: presenter) }
    }

    /// Fits every sheet presented above `root`.
    static func fitPresentedSheets(above root: UIViewController) {
        guard let available = available(in: root.view.window) else { return }
        var presented = root.presentedViewController
        while let sheet = presented { fit(sheet, in: available); presented = sheet.presentedViewController }
    }
}
