#if SCRIV_CLI_AUTOMATION
import UIKit

/// A local session for the mounted UIKit delegates. Only the drag delegate can
/// supply items, and the Storyboard drop delegate reads their local transfer.
@MainActor
final class ScrivCLIStoryboardDrag: NSObject, UIDragSession, UIDropSession {
    weak var source: UIView?
    weak var position: UIView?
    weak var window: UIWindow?
    weak var store: WorkspaceStore?
    var items: [UIDragItem] = []
    var localContext: Any?
    var localDragSession: (any UIDragSession)? { self }
    let allowsMoveOperation = true
    let isRestrictedToDraggingApplication = true
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .none
    let progress = Progress(totalUnitCount: 0)

    init(source: UIView, store: WorkspaceStore) {
        self.source = source; position = source; window = source.window; self.store = store
        super.init()
    }
    func location(in view: UIView) -> CGPoint {
        guard let position else { return .zero }
        return position.convert(CGPoint(x: position.bounds.midX, y: position.bounds.midY), to: view)
    }
    func hasItemsConforming(toTypeIdentifiers identifiers: [String]) -> Bool {
        items.contains { item in identifiers.contains { item.itemProvider.hasItemConformingToTypeIdentifier($0) } }
    }
    func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool {
        items.contains { $0.itemProvider.canLoadObject(ofClass: aClass) }
    }
    func loadObjects(ofClass aClass: any NSItemProviderReading.Type,
                     completion: @escaping ([any NSItemProviderReading]) -> Void) -> Progress {
        // This adapter never loads external providers. Storyboard uses localObject.
        completion([])
        return progress
    }
}
#endif
