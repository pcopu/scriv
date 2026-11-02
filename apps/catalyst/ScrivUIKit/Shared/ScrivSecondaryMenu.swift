import UIKit
import ObjectiveC

/// A context menu opened by secondary click (or Control-click) only. A UIButton
/// `menu` also opens on press-and-hold, which swallows drags that begin with a
/// short pause, so draggable controls carry their menu here instead.
@MainActor
final class ScrivSecondaryMenu: NSObject, UIContextMenuInteractionDelegate {
    private var menu: UIMenu?
    private nonisolated(unsafe) static var key: UInt8 = 0

    /// The menu currently offered by `view`'s secondary click.
    static func menu(of view: UIView) -> UIMenu? { (objc_getAssociatedObject(view, &key) as? ScrivSecondaryMenu)?.menu }

    /// Sets (or, with nil, removes) the menu `view` offers on secondary click.
    static func set(_ menu: UIMenu?, on view: UIView) {
        if let existing = objc_getAssociatedObject(view, &key) as? ScrivSecondaryMenu { existing.menu = menu; return }
        guard let menu else { return }
        let provider = ScrivSecondaryMenu(); provider.menu = menu
        objc_setAssociatedObject(view, &key, provider, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        view.addInteraction(UIContextMenuInteraction(delegate: provider))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}
