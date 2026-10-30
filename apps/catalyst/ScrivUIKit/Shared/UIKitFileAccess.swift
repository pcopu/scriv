import UIKit
import UniformTypeIdentifiers
import QuickLook

@MainActor
enum UIKitPresentation {
    static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
    }
    static var presenter: UIViewController? {
        guard var controller = window?.rootViewController else { return nil }
        while let presented = controller.presentedViewController, !presented.isBeingDismissed { controller = presented }
        if let navigation = controller as? UINavigationController { return navigation.visibleViewController ?? navigation }
        return controller
    }
    static func finishEditing() {
        NotificationCenter.default.post(name: .scrivFinishEditing, object: nil)
        window?.endEditing(true)
    }
    static func open(_ url: URL) { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
}

/// User-selected security scopes remain active while queued package saves use
/// their captured URL. One-shot imports release their own scope after awaiting.
@MainActor
final class UIKitFileAccess: NSObject, UIDocumentPickerDelegate {
    static let shared = UIKitFileAccess()
    private var selection: ((URL?) -> Void)?
    private var exportCompletion: (() -> Void)?
    private var retainedScopes: [String:URL] = [:]
    private let bookmarksKey = "ScrivUIKitProjectBookmarks.v1"
    static let projectType = UTType(exportedAs: "app.scriv.project", conformingTo: .package)

    func choose(types: [UTType], directory: URL? = nil, from: UIViewController? = nil, completion: @escaping (URL?) -> Void) {
        guard selection == nil, exportCompletion == nil, let presenter = from ?? UIKitPresentation.presenter else { completion(nil); return }
        selection = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false; picker.delegate = self; picker.directoryURL = directory
        presenter.present(picker, animated: true)
    }
    func export(url: URL, from: UIViewController? = nil, completion: @escaping () -> Void = {}) {
        guard selection == nil, exportCompletion == nil, let presenter = from ?? UIKitPresentation.presenter else { completion(); return }
        exportCompletion = completion
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = self; presenter.present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let selected = selection, exported = exportCompletion
        selection = nil; exportCompletion = nil
        selected?(urls.first); exported?()
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let selected = selection, exported = exportCompletion
        selection = nil; exportCompletion = nil
        selected?(nil); exported?()
    }
    func rememberProject(_ url: URL) throws {
        let key = url.standardizedFileURL.path
        guard retainedScopes[key] == nil else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            var saved = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String:Data] ?? [:]
            saved[key] = data; UserDefaults.standard.set(saved, forKey: bookmarksKey)
            if scoped { retainedScopes[key] = url }
        } catch { if scoped { url.stopAccessingSecurityScopedResource() }; throw error }
    }
    func restoreProjectAccess(_ url: URL) throws -> URL {
        let key = url.standardizedFileURL.path
        if let retained = retainedScopes[key] { return retained }
        let saved = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String:Data] ?? [:]
        guard let data = saved[key] else { return url } // App-container URLs need no bookmark; normal I/O still enforces access.
        var stale = false
        let resolved = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = resolved.startAccessingSecurityScopedResource()
        if stale {
            do {
                let refreshed = try resolved.bookmarkData(options:.minimalBookmark,includingResourceValuesForKeys:nil,relativeTo:nil)
                var bookmarks = saved; bookmarks[key] = refreshed
                UserDefaults.standard.set(bookmarks,forKey:bookmarksKey)
            } catch { if scoped { resolved.stopAccessingSecurityScopedResource() }; throw error }
        }
        if scoped { retainedScopes[key] = resolved }
        return resolved
    }
    func preview(url: URL, from: UIViewController? = nil) {
        guard let presenter = from ?? UIKitPresentation.presenter else { return }
        presenter.present(ScrivQuickLookController(url: url), animated: true)
    }
}

@MainActor
private final class ScrivQuickLookController: QLPreviewController, QLPreviewControllerDataSource {
    private let capturedURL: URL
    init(url: URL) { capturedURL = url; super.init(nibName: nil, bundle: nil); dataSource = self }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(url:)") }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { capturedURL as NSURL }
}

extension Notification.Name {
    static let scrivFinishEditing = Notification.Name("ScrivFinishEditing")
}
