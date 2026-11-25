#if SCRIV_CLI_AUTOMATION
import UIKit

@MainActor
enum ScrivCLIMenuActions {
    static let localScopes = ["audio-library-actions"]
    static let localCommands = ["resolve-audio-removal"] + ScrivCLITimingControls.commands

    static func dispatch(_ request: [String: Any], view: UIView, window: UIWindow,
                         windows: @autoclosure () -> [UIWindow],
                         run: ScrivCLIRunCapability) throws -> [String: Any]? {
        if ScrivCLICharacterPortraitMenu.canHandle(request) {
            return try ScrivCLICharacterPortraitMenu.dispatch(view: view, window: window, windows: windows(), request: request)
        }
        if ScrivCLIStoryboardMerge.canHandle(request) {
            return try ScrivCLIStoryboardMerge.dispatch(view: view, window: window, request: request)
        }
        if ScrivCLISceneMenu.canHandle(request) {
            return try ScrivCLISceneMenu.dispatch(view: view, window: window, request: request)
        }
        if view.accessibilityLabel == "Image version actions"
            || request["action"] as? String == "Show captured generation prompt"
            || request["action"] as? String == "Hide captured generation prompt" {
            return try ScrivCLIInspectorPromptMenu.dispatch(view: view, window: window, windows: windows(), request: request)
        }
        if view.accessibilityIdentifier == "audio-anchor" {
            return try ScrivCLIAudioAnchorMenu.dispatch(view: view, window: window, request: request)
        }
        if request["action"] as? String == "Edit word timing…" {
            return try ScrivCLIWordTimingMenu.dispatch(view: view, window: window, request: request)
        }
        if request["action"] as? String == "Owned duration…" {
            return try ScrivCLIDirectionMenu.dispatch(view: view, window: window, request: request)
        }
        if request["scope"] as? String == "audio-library-actions" {
            return try dispatchAudio(request, view: view, window: window, run: run)
        }
        return nil
    }

    static func complete(_ command: String, request: [String: Any], window: UIWindow,
                         run: ScrivCLIRunCapability) throws -> [String: Bool]? {
        guard command == "resolve-audio-removal" else {
            return try ScrivCLITimingControls.dispatch(command, request: request, window: window, run: run)
        }
        guard Set(request.keys) == ["id", "command", "decision"],
              let decision = request["decision"] as? String, decision == "cancel" || decision == "remove",
              let library = audioLibrary(in: window, run: run),
              library.cliResolveRemoval(confirmed: decision == "remove")
        else { throw Failure(message: "Audio clip removal confirmation is unavailable") }
        return ["dispatched": true]
    }

    private static func dispatchAudio(_ request: [String: Any], view: UIView, window: UIWindow,
                                      run: ScrivCLIRunCapability) throws -> [String: Any] {
        guard Set(request.keys) == ["id", "command", "scope", "target", "action"],
              let title = request["action"] as? String, let button = view as? UIButton,
              request["target"] as? String == button.accessibilityIdentifier,
              let library = audioLibrary(in: window, run: run),
              let content = library.viewIfLoaded, content.window === button.window,
              button.isDescendant(of: content),
              let action = library.cliMenuAction(on: button, title: title)
        else { throw Failure(message: "Audio Library menu action is unavailable") }
        button.sendAction(action)
        var result: [String: Any] = ["dispatched": true, "coverage": "semantic-menu-action"]
        if button.accessibilityIdentifier == "audio-import-menu" {
            result["nativePickerPresented"] = library.presentedViewController is UIDocumentPickerViewController
        }
        return result
    }

    private static func audioLibrary(in window: UIWindow, run: ScrivCLIRunCapability) -> AudioLibraryController? {
        guard run.approvedOrigin == nil, let workspace = window.rootViewController as? ScrivWorkspaceController,
              window === workspace.viewIfLoaded?.window,
              let library = workspace.presentedViewController as? AudioLibraryController,
              library.presentingViewController === workspace, library.store === workspace.store,
              library.modalPresentationStyle == .formSheet, library.viewIfLoaded?.window != nil,
              !library.isBeingPresented, !library.isBeingDismissed else { return nil }
        let store = workspace.store
        let id = store.project.id
        guard store.errorMessage == nil, !store.isPlaying, !store.isBootstrapping,
              store.account == nil, store.cloud.account == nil,
              store.project.cloudProjectId == nil, store.cloud.projectId == nil,
              UUID(uuidString: id) != nil, let package = store.projectURL else { return nil }
        let relative = "Projects/" + id + ".scriv"
        let expected = run.root.appendingPathComponent(relative)
        let resolved = run.root.resolvingSymlinksInPath().appendingPathComponent(relative)
        guard package.standardizedFileURL.path == expected.path,
              package.resolvingSymlinksInPath().path == resolved.path,
              (try? package.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return library
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
#endif
