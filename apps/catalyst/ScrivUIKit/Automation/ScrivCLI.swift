#if SCRIV_CLI_AUTOMATION
import UIKit
import Darwin
import CoreFoundation

@MainActor protocol ScrivCLIPictureTimingDriver: AnyObject {
    var cliGestureInFlight: Bool { get }
    var cliAcceptsSample: Bool { get }
    func cliBeginGesture()
    func cliSampleGesture(_ translation: Double, shift: Bool, releasing: Bool)
    func cancel()
}

@MainActor protocol ScrivCLIScriptDurationDriver: AnyObject {
    var cliGestureInFlight: Bool { get }
    var cliAcceptsSample: Bool { get }
    func cliBeginGesture(on button: UIButton)
    func cliSampleGesture(_ translation: Double, on button: UIButton, releasing: Bool)
    func cancel()
}

/// Must run before UIApplicationMain and WorkspaceStore's stored CloudClient.
func prepareScrivCLIEnvironment() throws { try ScrivCLIRunCapability.prepare() }

/// Test-build-only stdio adapter. Commands invoke the same UIKit controls as a
/// person; no parallel domain model, network listener, or production backdoor.
@MainActor
final class ScrivCLI {
    static let shared = ScrivCLI()
    private weak var window: UIWindow?
    private weak var pictureTimingGesture: (any ScrivCLIPictureTimingDriver)?
    private weak var scriptDurationGesture: (any ScrivCLIScriptDurationDriver)?
    private weak var scriptDurationTarget: UIButton?
    private var started = false
    private var asynchronousCommandInProgress = false
    private var nativeAccessibility: ScrivCLIAccessibility?
    private var rejectedJSONImport: (projectID: String, message: String)?

    // During a synchronous synthetic stroke, the owned CLI route determines
    // the keyboard scope. Catalyst can put an auxiliary window ahead of it.
    private(set) var shortcutWindow: UIWindow?
    private(set) var shortcutResponder: UIResponder?
    private func withShortcutScope<Result>(_ action: () throws -> Result) rethrows -> Result {
        let active = ownedWindows().first(where: { $0.isKeyWindow }) ?? window
        if let active, active === window, active.rootViewController is ScrivWorkspaceController,
           !ownedPresentedAlerts().contains(where: { $0.viewIfLoaded?.window != nil }) {
            shortcutWindow = active
            shortcutResponder = ScrivKeyboardTextContext.firstResponder() ?? views().first(where: { $0.1.isFirstResponder })?.1
        }
        defer { shortcutWindow = nil; shortcutResponder = nil }
        return try action()
    }

    func start(window: UIWindow) {
        guard !started, ProcessInfo.processInfo.arguments.contains("--scriv-cli") else { return }
        guard (try? ScrivCLIRunCapability.requirePrepared()) != nil else {
            fatalError("Isolated CLI setup is invalid")
        }
        started = true; self.window = window
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = readLine() {
                guard line.utf8.count <= 1_048_576 else { continue }
                let bytes = Data(line.utf8)
                DispatchQueue.main.async { self.receive(bytes) }
            }
        }
    }

    private func receive(_ data: Data) {
        var id: Any = NSNull()
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = request["command"] as? String else { throw Failure("Expected a JSON command") }
            id = request["id"] ?? NSNull()
            _ = try ScrivCLIRunCapability.requirePrepared()
            guard !asynchronousCommandInProgress else { throw Failure("An isolated asynchronous command is still running") }
            if command == "import-audio" {
                guard Set(request.keys).isSubset(of: ["id", "command", "base64", "attachment"]),
                      let base64 = request["base64"] as? String,
                      let attachment = request["attachment"] as? String,
                      let workspace = window?.rootViewController as? ScrivWorkspaceController else {
                    throw Failure("Synthetic audio import is unavailable or invalid")
                }
                asynchronousCommandInProgress = true
                let responseID = id
                Task { @MainActor in
                    defer { self.asynchronousCommandInProgress = false }
                    do {
                        let result = try await ScrivCLIAudioImport.importWAV(base64: base64, attachment: attachment, workspace: workspace)
                        self.reply(["id": responseID, "ok": true, "result": result])
                    } catch {
                        self.reply(["id": responseID, "ok": false, "error": "Synthetic audio import is unavailable or invalid"])
                    }
                }
                return
            }
            if command == "import-local-image" {
                guard Set(request.keys).isSubset(of: ["id", "command", "fixture"]),
                      let fixture = request["fixture"] as? String,
                      let workspace = window?.rootViewController as? ScrivWorkspaceController else {
                    throw Failure("Synthetic image import is unavailable or invalid")
                }
                asynchronousCommandInProgress = true
                let responseID = id
                Task { @MainActor in
                    defer { self.asynchronousCommandInProgress = false }
                    do {
                        let result = try await ScrivCLILocalImageImport.importPNG(fixture: fixture, workspace: workspace)
                        self.reply(["id": responseID, "ok": true, "result": result])
                    } catch {
                        self.reply(["id": responseID, "ok": false, "error": "Synthetic image import is unavailable or invalid"])
                    }
                }
                return
            }
            if command == "stage-package-fixture" {
                guard let workspace = window?.rootViewController as? ScrivWorkspaceController else {
                    throw Failure("Synthetic package fixture is unavailable or invalid")
                }
                let result = try ScrivCLIPackageFixture.stage(request: request, workspace: workspace)
                reply(["id": id, "ok": true, "result": result])
                return
            }
            if command == "export-project" {
                let message = "Synthetic project export is unavailable or invalid"
                guard Set(request.keys).isSubset(of: ["id", "command"]),
                      let workspace = window?.rootViewController as? ScrivWorkspaceController else { throw Failure(message) }
                asynchronousCommandInProgress = true
                let responseID = id
                Task { @MainActor in
                    defer { self.asynchronousCommandInProgress = false }
                    do {
                        let result = try await ScrivCLIExport.exportProject(workspace: workspace)
                        self.reply(["id": responseID, "ok": true, "result": result])
                    } catch { self.reply(["id": responseID, "ok": false, "error": message]) }
                }
                return
            }
            let result = try execute(command, request)
            reply(["id": id, "ok": true, "result": result])
        } catch { reply(["id": id, "ok": false, "error": error.localizedDescription]) }
    }
    private func reply(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(Data("SCRIV_CLI ".utf8) + data + Data([10]))
    }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    private func nativeAccessibilityAdapter() throws -> ScrivCLIAccessibility {
        if let nativeAccessibility { return nativeAccessibility }
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("ScrivCLIAccessibility.bundle"),
              let bundle = Bundle(url: url) else { throw Failure("Native accessibility adapter is unavailable") }
        do { try bundle.loadAndReturnError() } catch { throw Failure("Native accessibility adapter could not load") }
        guard let type = bundle.principalClass as? ScrivCLIAccessibility.Type else {
            throw Failure("Native accessibility adapter has no supported interface")
        }
        let adapter = type.init()
        nativeAccessibility = adapter
        return adapter
    }
    private func ownedWindows() -> [UIWindow] {
        guard let window else { return [] }
        var result = [window]
        func add(_ candidate: UIWindow) {
            if !result.contains(where: { $0 === candidate }) { result.append(candidate) }
        }
        // Catalyst form sheets may use a separate native-backed UIWindow.
        for candidate in window.windowScene?.windows ?? [] { add(candidate) }
        var controller = window.rootViewController
        while let current = controller {
            if let presentedWindow = current.viewIfLoaded?.window { add(presentedWindow) }
            controller = current.presentedViewController
        }
        if let workspace = window.rootViewController as? ScrivWorkspaceController {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                if scene.windows.contains(where: { ($0.rootViewController as? ScrivSettingsPanelController)?.store === workspace.store }) {
                    scene.windows.forEach { add($0) }
                    // Settings sheets can own native-backed windows outside scene.windows.
                    for settings in scene.windows.compactMap({ $0.rootViewController as? ScrivSettingsPanelController }) where settings.store === workspace.store {
                        var controller: UIViewController? = settings
                        while let current = controller {
                            if let presentedWindow = current.viewIfLoaded?.window { add(presentedWindow) }
                            controller = current.presentedViewController
                        }
                    }
                }
            }
        }
        return result
    }
    private func views() -> [(String, UIView)] {
        var result: [(String, UIView)] = []
        func visit(_ view: UIView, _ path: String) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            result.append((path, view))
            for (index, child) in view.subviews.enumerated() { visit(child, path + "." + String(index)) }
        }
        for (index, window) in ownedWindows().enumerated() { visit(window, String(index)) }
        return result
    }
    private func isSensitiveInput(_ view: UIView) -> Bool {
        if let field = view as? UITextField { return field.isSecureTextEntry || field.textContentType == .oneTimeCode }
        if let text = view as? UITextView { return text.isSecureTextEntry || text.textContentType == .oneTimeCode }
        return false
    }
    private func isSensitiveSubtree(_ view: UIView) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            if isSensitiveInput(current) { return true }
            ancestor = current.superview
        }
        return false
    }
    private func sensitiveInputs() -> [UIView] {
        // Include hidden inputs: native/public accessibility containers can expose
        // text independently of UIView visibility and may aggregate descendants.
        var inputs: [UIView] = []
        func visit(_ view: UIView) {
            if isSensitiveInput(view) { inputs.append(view) }
            view.subviews.forEach { visit($0) }
        }
        ownedWindows().forEach { visit($0) }
        return inputs
    }
    private func requireNonsensitiveAccessibility() throws {
        guard sensitiveInputs().isEmpty else { throw Failure("Accessibility observation is unavailable while sensitive input is present") }
    }
    private func ownedPresentedAlerts() -> [UIAlertController] {
        var alerts: [UIAlertController] = [], seen = Set<ObjectIdentifier>()
        func visit(_ controller: UIViewController) {
            guard seen.insert(ObjectIdentifier(controller)).inserted else { return }
            if let alert = controller as? UIAlertController, alert.presentingViewController != nil {
                alerts.append(alert)
            }
            controller.children.forEach { visit($0) }
            if let presented = controller.presentedViewController { visit(presented) }
        }
        ownedWindows().compactMap(\.rootViewController).forEach { visit($0) }
        return alerts
    }
    private func isInActivePresentation(_ view: UIView) -> Bool {
        guard let root = view.window?.rootViewController ?? window?.rootViewController else { return false }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        if let ownedWindow = view.window, ownedWindow === window,
           ownedPresentedAlerts().contains(where: { alert in
               guard let alertWindow = alert.viewIfLoaded?.window else { return false }
               return alertWindow !== ownedWindow
           }) {
            // The same workspace's Catalyst alert can live in its own native
            // window without appearing in the covered window's direct chain.
            return false
        }
        guard top !== root, let content = top.viewIfLoaded else { return true }
        return view === content || view.isDescendant(of: content)
    }
    private func isHittable(_ view: UIView) -> Bool {
        guard let window = view.window, ownedWindows().contains(where: { $0 === window }), isInActivePresentation(view) else { return false }
        var rect = view.convert(view.bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0.01, current.isUserInteractionEnabled else { return false }
            if current.clipsToBounds { rect = rect.intersection(current.convert(current.bounds, to: window)) }
            ancestor = current.superview
        }
        guard !rect.isNull, !rect.isEmpty, rect.midX.isFinite, rect.midY.isFinite,
              let hit = window.hitTest(CGPoint(x: rect.midX, y: rect.midY), with: nil) else { return false }
        return hit === view || hit.isDescendant(of: view)
    }
    private func pictureTimingSample(_ request: [String: Any], at view: UIView) throws -> [String: Bool] {
        let keys = Set(request.keys)
        let required: Set<String> = ["id", "command", "target", "phase"]
        guard let phase = request["phase"] as? String, !isSensitiveSubtree(view) else { throw Failure("Invalid picture timing sample") }
        let drivers = (view.gestureRecognizers ?? []).compactMap { recognizer in
            recognizer.isEnabled ? recognizer.delegate as? ScrivCLIPictureTimingDriver : nil
        }
        guard drivers.count == 1, let driver = drivers.first else { throw Failure("Target has no picture timing gesture") }
        switch phase {
        case "begin":
            guard keys == required else { throw Failure("Invalid picture timing sample") }
            guard pictureTimingGesture?.cliGestureInFlight != true, scriptDurationGesture?.cliGestureInFlight != true,
                  !driver.cliGestureInFlight else { throw Failure("An active picture timing gesture already owns input") }
            guard isHittable(view), (view as? UIControl)?.isEnabled != false else { throw Failure("Picture timing control is unavailable") }
            driver.cliBeginGesture()
            guard driver.cliGestureInFlight else { throw Failure("Picture timing control is unavailable") }
            pictureTimingGesture = driver
        case "change", "end":
            guard keys == required.union(["translation", "shift"]),
                  let displacement = request["translation"] as? NSNumber, CFGetTypeID(displacement) != CFBooleanGetTypeID(),
                  let shift = request["shift"] as? NSNumber, CFGetTypeID(shift) == CFBooleanGetTypeID(),
                  abs(displacement.doubleValue) <= 32_768 else { throw Failure("Invalid picture timing sample") }
            guard pictureTimingGesture === driver, driver.cliAcceptsSample else { throw Failure("Target has no active picture timing gesture") }
            driver.cliSampleGesture(displacement.doubleValue, shift: shift.boolValue, releasing: phase == "end")
        case "cancel":
            guard keys == required else { throw Failure("Invalid picture timing sample") }
            guard pictureTimingGesture === driver, driver.cliAcceptsSample else { throw Failure("Target has no active picture timing gesture") }
            driver.cancel()
        default: throw Failure("Invalid picture timing sample")
        }
        return ["dispatched": true]
    }
    private func scriptDurationSample(_ request: [String: Any], at view: UIView) throws -> [String: Bool] {
        let keys = Set(request.keys)
        let required: Set<String> = ["id", "command", "target", "phase"]
        guard let phase = request["phase"] as? String, !isSensitiveSubtree(view) else { throw Failure("Invalid script duration sample") }
        let drivers = (view.gestureRecognizers ?? []).compactMap { recognizer -> (any ScrivCLIScriptDurationDriver)? in
            guard recognizer.isEnabled else { return nil }
            if let hold = recognizer as? ScriptDurationHoldRecognizer { return hold.driver }
            return (recognizer as? ScriptDirectionCoveragePanRecognizer)?.driver
        }
        guard drivers.count == 1, let driver = drivers.first, let button = view as? UIButton else { throw Failure("Target has no script duration gesture") }
        switch phase {
        case "begin":
            guard keys == required else { throw Failure("Invalid script duration sample") }
            guard scriptDurationGesture?.cliGestureInFlight != true, pictureTimingGesture?.cliGestureInFlight != true,
                  !driver.cliGestureInFlight else { throw Failure("An active script duration gesture already owns input") }
            guard isHittable(button), button.isEnabled else { throw Failure("Script duration control is unavailable") }
            driver.cliBeginGesture(on: button)
            guard driver.cliGestureInFlight else { throw Failure("Script duration control is unavailable") }
            scriptDurationGesture = driver
            scriptDurationTarget = button
        case "change", "end":
            guard keys == required.union(["translation"]), let displacement = request["translation"] as? NSNumber,
                  CFGetTypeID(displacement) != CFBooleanGetTypeID(), abs(displacement.doubleValue) <= 32_768 else {
                throw Failure("Invalid script duration sample")
            }
            guard scriptDurationGesture === driver, scriptDurationTarget === button, driver.cliAcceptsSample else { throw Failure("Target has no active script duration gesture") }
            driver.cliSampleGesture(displacement.doubleValue, on: button, releasing: phase == "end")
        case "cancel":
            guard keys == required else { throw Failure("Invalid script duration sample") }
            guard scriptDurationGesture === driver, scriptDurationTarget === button, driver.cliAcceptsSample else { throw Failure("Target has no active script duration gesture") }
            driver.cancel()
        default: throw Failure("Invalid script duration sample")
        }
        return ["dispatched": true]
    }
    private func keyCommands() -> [(UIResponder, UIKeyCommand)] {
        guard let window else { return [] }
        var top = (ownedWindows().first(where: { $0.isKeyWindow }) ?? window).rootViewController
        while let presented = top?.presentedViewController { top = presented }
        let focused: UIResponder? = ScrivKeyboardTextContext.firstResponder() ?? views().first(where: { $0.1.isFirstResponder })?.1
        var responder: UIResponder? = focused ?? top
        var result: [(UIResponder, UIKeyCommand)] = []
        var visited = Set<ObjectIdentifier>()
        while let current = responder, visited.insert(ObjectIdentifier(current)).inserted {
            for command in (current.keyCommands ?? []) + ((current as? ScrivUIKitApplication)?.cliMenuKeyCommands ?? []) {
                guard let action = command.action, current.canPerformAction(action, withSender: command) else { continue }
                result.append((current, command))
            }
            responder = current.next
        }
        return result
    }
    private func modifierNames(_ flags: UIKeyModifierFlags) -> [String] {
        let options: [(String, UIKeyModifierFlags)] = [("command", .command), ("shift", .shift), ("option", .alternate), ("control", .control), ("capsLock", .alphaShift), ("numericPad", .numericPad)]
        return options.filter { flags.contains($0.1) }.map { $0.0 }
    }
    /// Read-only evidence from this run's synthetic persisted packages. No caller
    /// path is accepted, no production repository or in-memory model is exposed.
    private func persistedProjects() throws -> [[String: Any]] {
        let env = ProcessInfo.processInfo.environment
        guard let runID = env["SCRIV_CLI_RUN_ID"], UUID(uuidString: runID) != nil,
              let configured = env["SCRIV_VERIFICATION_ROOT"] else { throw Failure("No isolated run") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScrivVerification-CLI-" + runID.lowercased())
        guard root.standardizedFileURL.path == URL(fileURLWithPath: configured).standardizedFileURL.path else { throw Failure("Root mismatch") }
        let directory = root.appendingPathComponent("Projects", isDirectory: true)
        for location in [root, directory] {
            let values = try location.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure("Invalid synthetic directory") }
        }
        let packages = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard packages.count <= 100 else { throw Failure("Synthetic export limit exceeded") }
        return try packages.filter { $0.pathExtension == "scriv" }.map { package in
            let values = try package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure("Invalid synthetic package") }
            let file = package.appendingPathComponent("project.json")
            let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else {
                // Initial installation journals first; the background repository
                // creates the package before publishing its first project.json.
                // Never return a partial snapshot or retry an import mutation.
                if errno == ENOENT { throw Failure("Synthetic saved-project publication pending") }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size <= 4 * 1024 * 1024 else { throw Failure("Invalid synthetic project file") }
            let bytes = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
            guard bytes.count <= 4 * 1024 * 1024,
                  let project = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure("Invalid synthetic project JSON") }
            return project
        }
    }

    private func execute(_ command: String, _ request: [String: Any]) throws -> Any {
        guard let window else { throw Failure("No workspace window") }
        let run = try ScrivCLIRunCapability.requirePrepared()
#if SCRIV_CLI_COVERAGE
        if ["coverage-snapshot", "coverage-read", "coverage-release"].contains(command) {
            return try ScrivCLICoverage.handle(command: command, request: request)
        }
#endif
        ownedWindows().forEach { $0.layoutIfNeeded() }
        if command == "capabilities" {
            var workspace = ["persistent": run.persistent, "resumed": run.resumed]
            if run.startupRecovery {
                workspace["startupRecovery"] = true
                workspace["bootstrapping"] = (window.rootViewController as? ScrivWorkspaceController)?.store.isBootstrapping ?? true
            }
            if run.freshStartup {
                workspace["freshStartup"] = true
                workspace["bootstrapping"] = (window.rootViewController as? ScrivWorkspaceController)?.store.startupBootstrapComplete != true
            }
            var result: [String: Any] = ["protocol": 1, "driver": "UIKit controls", "completeInterfaceParity": false, "imageEvidenceSchemaVersion": 1,
                    "scriptInteractionCountsSchemaVersion": 1,
                    "cloudIsolation": run.publicStatus,
                    "semanticApplicationCommands": ["import-local-image", "import-audio", "import-fountain", "export-fountain", "export-project", "import-json", "acknowledge-json-import-error"],
                    "semanticGestureCommands": ["picture-timing-gesture", "script-duration-gesture"],
                    "semanticActivationModifiers": ["storyboard-word": ["shift", "command"]],
                    "jsonImportAcknowledgementScope": "owned-presentations",
                    "syntheticFixtureCommands": ["stage-package-fixture"],
                    "publicDelegateCommands": ["return", "script-insert", "script-delete-selection"],
                    "publicTextInputCommands": ["delete-backward"],
                    "semanticMenuActionScopes": ["script-zoom", "layers-direction-duration", "audio-anchor", "layers-word-timing", "image-inspector-prompt-disclosure", "script-scenes", "script-entries"] + ScrivCLIStoryboardMerge.scopes + ["character-portrait-options", "character-delete", "workspace-discussion", "workspace-panels", "codex-model-selection"],
                    "runID": run.runID.uuidString.lowercased(),
                    "sessionID": run.sessionID.uuidString.lowercased(),
                    "workspace": workspace,
                    "verificationRoot": run.root.path,
                    "commands": ["stage-package-fixture", "local-image-evidence", "import-local-image", "import-audio", "presented-alerts", "snapshot", "activate", "text", "select", "scroll", "slider", "keys", "key", "end-editing", "capabilities", "persisted-projects", "loaded-project", "script-interaction-counts", "controller-keys", "type", "selection", "toggle", "image-evidence", "accessibility-activate", "accessibility-snapshot", "native-accessibility-snapshot", "native-accessibility-activate", "return", "script-insert", "script-delete-selection", "delete-backward", "menu", "menu-action", "import-fountain", "export-fountain", "export-project", "import-json", "acknowledge-json-import-error", "picture-timing-gesture", "script-duration-gesture"]] as [String: Any]
            if !ScrivUpdateCoordinator.releaseSigningConfigured {
                for key in ["semanticApplicationCommands", "commands"] {
                    result[key] = (result[key] as? [String] ?? []) + ["check-for-updates"]
                }
            }
            if run.approvedOrigin != nil {
                result["semanticMenuActionScopes"] = (result["semanticMenuActionScopes"] as? [String] ?? []) + ["team-member-actions", "discussion-attachment"]
                for key in ["syntheticFixtureCommands", "commands"] {
                    result[key] = (result[key] as? [String] ?? []) + ["receive-fixture-email-code"]
                }
                for key in ["semanticApplicationCommands", "commands"] {
                    result[key] = (result[key] as? [String] ?? []) + ["acknowledge-cloud-save-error"]
                }
            }
#if SCRIV_CLI_COVERAGE
            result["coverage"] = ["schemaVersion": 1, "format": "llvm-profraw",
                "cumulative": true, "maximumSnapshots": 2, "maximumSnapshotBytes": 16 * 1024 * 1024,
                "attribution": "observed-during-sequence-not-causal"] as [String: Any]
            result["commands"] = (result["commands"] as? [String] ?? []) +
                ["coverage-snapshot", "coverage-read", "coverage-release"]
#endif
            return result
        }
        if command == "check-for-updates" {
            guard Set(request.keys) == ["id", "command"],
                  let workspace = window.rootViewController as? ScrivWorkspaceController,
                  let app = UIApplication.shared as? ScrivUIKitApplication,
                  app.performCLIUpdateCheck(in: workspace) else { throw Failure("The isolated update check is unavailable") }
            return ["dispatched": true]
        }
        if command == "local-image-evidence" {
            guard Set(request.keys).isSubset(of: ["id", "command"]),
                  let workspace = window.rootViewController as? ScrivWorkspaceController else {
                throw Failure("Local image evidence is unavailable or inconsistent.")
            }
            return try ScrivCLILocalImageEvidence.observe(workspace: workspace, windows: ownedWindows())
        }
        if command == "loaded-project" {
            guard Set(request.keys).isSubset(of: ["id", "command"]),
                  let workspace = window.rootViewController as? ScrivWorkspaceController else {
                throw Failure("Synthetic loaded-project observation is unavailable or invalid.")
            }
            return try ScrivCLILoadedProject.observe(workspace: workspace)
        }
        if command == "script-interaction-counts" {
            guard Set(request.keys).isSubset(of: ["id", "command"]),
                  let workspace = window.rootViewController as? ScrivWorkspaceController else {
                throw Failure("Synthetic interaction-count observation is unavailable or invalid.")
            }
            return try ScrivCLIInteractionCounts.observe(workspace: workspace)
        }
        // Public controller state only: this is not pixel visibility, accessibility
        // reachability, or permission to invoke a UIAlertAction handler.
        if command == "presented-alerts" {
            guard Set(request.keys).isSubset(of: ["id", "command"]) else {
                throw Failure("Presented alert observation accepts no parameters")
            }
            return ownedPresentedAlerts().map { alert in
                ["observation": "public-controller-presentation-state",
                 "title": alert.title ?? "",
                 "message": alert.message ?? "",
                 "style": alert.preferredStyle == .alert ? "alert" : "actionSheet",
                 "beingPresented": alert.isBeingPresented,
                 "beingDismissed": alert.isBeingDismissed,
                 "viewAttachedToWindow": alert.viewIfLoaded?.window != nil,
                 "actions": alert.actions.map { action in
                     ["title": action.title ?? "", "enabled": action.isEnabled,
                      "style": action.style == .cancel ? "cancel" :
                        action.style == .destructive ? "destructive" : "default"] as [String: Any]
                 }] as [String: Any]
            }
        }
        if command == "native-accessibility-snapshot" {
            try requireNonsensitiveAccessibility()
            guard Set(request.keys).isSubset(of: ["id", "command"]) else { throw Failure("Native accessibility snapshot accepts no parameters") }
            return try nativeAccessibilityAdapter().snapshot()
        }
        if command == "native-accessibility-activate" {
            try requireNonsensitiveAccessibility()
            guard Set(request.keys).isSubset(of: ["id", "command", "path", "label"]),
                  let path = request["path"] as? String, let label = request["label"] as? String else {
                throw Failure("Native activation requires only an exact path and label")
            }
            let result = try nativeAccessibilityAdapter().activate(request: ["path": path, "label": label])
            guard result["dispatched"] as? Bool == true else { throw Failure("Native accessibility activation was not handled") }
            return result
        }
        if command == "import-json" {
            guard Set(request.keys).isSubset(of: ["id", "command", "text"]),
                  let text = request["text"] as? String,
                  let workspace = window.rootViewController as? ScrivWorkspaceController else {
                throw Failure("JSON import accepts only synthetic text")
            }
            let result = try ScrivCLIImport.importJSON(text: text, workspace: workspace)
            rejectedJSONImport = nil
            if result["projectChanged"] as? Bool == false, let message = workspace.store.errorMessage {
                rejectedJSONImport = (workspace.store.project.id, message)
            }
            return result
        }
        if command == "acknowledge-json-import-error" {
            let alerts = ownedPresentedAlerts()
            guard Set(request.keys).isSubset(of: ["id", "command"]),
                  let rejection = rejectedJSONImport, let workspace = window.rootViewController as? ScrivWorkspaceController,
                  workspace.viewIfLoaded?.window === window, workspace.store.project.id == rejection.projectID,
                  alerts.count == 1, let alert = alerts.first,
                  workspace.store.acknowledgeCLIImportError(rejection.message, alert: alert) else {
                throw Failure("No owned JSON import error can be acknowledged")
            }
            rejectedJSONImport = nil
            return ["dispatched": true]
        }
        if command == "acknowledge-cloud-save-error" {
            let alerts = ownedPresentedAlerts()
            guard run.approvedOrigin != nil, Set(request.keys) == ["id", "command", "message"],
                  let message = request["message"] as? String,
                  let workspace = window.rootViewController as? ScrivWorkspaceController,
                  workspace.viewIfLoaded?.window === window, alerts.count == 1, let alert = alerts.first,
                  workspace.store.acknowledgeCLICloudSaveError(message, alert: alert) else {
                throw Failure("Cloud save error acknowledgement is unavailable")
            }
            return ["acknowledged": true]
        }
        if command == "export-fountain" {
            guard Set(request.keys).isSubset(of: ["id", "command"]),
                  let workspace = window.rootViewController as? ScrivWorkspaceController else {
                throw Failure("Fountain export accepts no parameters")
            }
            return try ScrivCLIExport.exportFountain(workspace: workspace)
        }
        if command == "import-fountain" {
            guard Set(request.keys).isSubset(of: ["id", "command", "text", "filename"]),
                  request["filename"] == nil || request["filename"] is String,
                  let text = request["text"] as? String,
                  let workspace = window.rootViewController as? ScrivWorkspaceController else {
                throw Failure("Fountain import accepts only synthetic text")
            }
            return try ScrivCLIImport.importFountain(text: text, filename: request["filename"] as? String ?? "Import.fountain", workspace: workspace)
        }
        if command == "persisted-projects" { return try persistedProjects() }
        if command == "image-evidence" {
            guard Set(request.keys).isSubset(of: ["id", "command"]),
                  let workspace = window.rootViewController as? ScrivWorkspaceController else { throw Failure("Image evidence accepts no parameters") }
            return try ScrivCLIImageEvidence.observe(workspace: workspace, windows: ownedWindows())
        }
        if command == "controller-keys" {
            var records: [[String: Any]] = []
            var seen = Set<ObjectIdentifier>()
            func visit(_ controller: UIViewController) {
                guard seen.insert(ObjectIdentifier(controller)).inserted else { return }
                if let view = controller.viewIfLoaded, let owner = view.window, ownedWindows().contains(where: { $0 === owner }) {
                    for key in controller.keyCommands ?? [] {
                        guard let action = key.action else { continue }
                        records.append(["controllerType": String(describing: type(of: controller)),
                            "input": key.input == UIKeyCommand.inputEscape ? "Escape" : key.input ?? "",
                            "modifiers": modifierNames(key.modifierFlags), "action": NSStringFromSelector(action),
                            "enabled": isInActivePresentation(view) && controller.canPerformAction(action, withSender: key),
                            "wantsPriorityOverSystemBehavior": key.wantsPriorityOverSystemBehavior])
                    }
                }
                controller.children.forEach { visit($0) }
                if let presented = controller.presentedViewController { visit(presented) }
            }
            ownedWindows().compactMap(\.rootViewController).forEach { visit($0) }
            return records
        }
        if command == "keys" {
            return withShortcutScope {
                keyCommands().map { responder, key in ["input": key.input == UIKeyCommand.inputEscape ? "Escape" : key.input ?? "", "modifiers": modifierNames(key.modifierFlags), "title": key.discoverabilityTitle ?? "", "responderType": String(describing: type(of: responder)), "action": key.action.map { NSStringFromSelector($0) } ?? "", "wantsPriorityOverSystemBehavior": key.wantsPriorityOverSystemBehavior] as [String: Any] }
            }
        }
        if command == "key" {
            return try withShortcutScope {
                guard let input = request["input"] as? String, let modifiers = request["modifiers"] as? [String] else { throw Failure("Expected input and modifier names") }
                let nativeInput = input == "Escape" ? UIKeyCommand.inputEscape : input
                guard let (responder, key) = keyCommands().first(where: { $0.1.input == nativeInput && Set(modifierNames($0.1.modifierFlags)) == Set(modifiers) }) else { throw Failure("No enabled key command in the active responder chain") }
                guard let action = key.action else { throw Failure("Key command lacks an action") }
                let dispatched = (responder as? ScrivUIKitApplication).map { $0.performCLIKeyStroke(key) } ?? UIApplication.shared.sendAction(action, to: responder, from: key, for: nil)
                guard dispatched else { throw Failure("Key action was not handled") }
                return ["dispatched": true]
            }
        }
        if command == "end-editing" {
            var controller = (ownedWindows().first(where: { $0.isKeyWindow }) ?? window).rootViewController
            while let presented = controller?.presentedViewController { controller = presented }
            return (controller?.viewIfLoaded?.window ?? window).endEditing(true)
        }
        if command == "accessibility-snapshot" {
            try requireNonsensitiveAccessibility()
            // Read the public UIKit accessibility container surface. Some native
            // controls expose elements separately from their UIView subviews.
            var result: [[String: Any]] = []
            var seen = Set<ObjectIdentifier>()
            func visit(_ object: NSObject, path: String, owner: UIView, depth: Int) {
                guard depth < 16, result.count < 1024,
                      seen.insert(ObjectIdentifier(object)).inserted else { return }
                let frame = object.accessibilityFrame
                var item: [String: Any] = ["path": path, "owner": owner.accessibilityIdentifier ?? "",
                    "type": String(describing: type(of: object)), "label": object.accessibilityLabel ?? "",
                    "isElement": object.isAccessibilityElement,
                    "button": object.accessibilityTraits.contains(.button),
                    "notEnabled": object.accessibilityTraits.contains(.notEnabled)]
                if frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite {
                    item["frame"] = ["x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height]
                }
                result.append(item)
                if let elements = object.accessibilityElements {
                    for (index, element) in elements.prefix(256).enumerated() {
                        if let child = element as? NSObject { visit(child, path: path + ".a" + String(index), owner: owner, depth: depth + 1) }
                    }
                } else {
                    let count = object.accessibilityElementCount()
                    if count > 0, count <= 256 {
                        for index in 0..<count {
                            if let child = object.accessibilityElement(at: index) as? NSObject {
                                visit(child, path: path + ".a" + String(index), owner: owner, depth: depth + 1)
                            }
                        }
                    }
                }
            }
            for (path, view) in views() where isInActivePresentation(view) {
                visit(view, path: path, owner: view, depth: 0)
            }
            return result
        }
        if command == "snapshot" {
            let sensitiveInputs = self.sensitiveInputs()
            return views().map { path, view -> [String: Any] in
                let sensitive = isSensitiveSubtree(view)
                // Ancestor accessibility metadata can aggregate a field's value.
                let aggregatesSensitive = sensitive || sensitiveInputs.contains(where: { $0.isDescendant(of: view) })
                var item: [String: Any] = ["path": path, "type": String(describing: type(of: view)),
                    "identifier": sensitive ? "<redacted>" : view.accessibilityIdentifier ?? "",
                    "label": aggregatesSensitive ? "<redacted>" : view.accessibilityLabel ?? "",
                    "value": aggregatesSensitive ? "<redacted>" : view.accessibilityValue ?? "", "interactive": view.isUserInteractionEnabled,
                    "firstResponder": view.isFirstResponder, "hittable": isHittable(view), "appearance": view.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"]
                item["accessibility"] = ["isElement": view.isAccessibilityElement,
                    "button": view.accessibilityTraits.contains(.button),
                    "notEnabled": view.accessibilityTraits.contains(.notEnabled)]
                let frame = view.convert(view.bounds, to: view.window ?? window)
                item["windowPath"] = path.split(separator: ".").first.map { String($0) } ?? ""
                item["frame"] = ["x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height]
                if sensitive {
                    // Do not evaluate field/label text, placeholders, attributed
                    // text, segment titles, or selection ranges in this subtree.
                    item["sensitive"] = true; item["text"] = "<redacted>"
                    return item
                }
                if let scroll = view as? UIScrollView { item["scroll"] = ["x": scroll.contentOffset.x, "y": scroll.contentOffset.y, "contentHeight": scroll.contentSize.height] }
                if let slider = view as? UISlider {
                    item["slider"] = ["value": slider.value, "minimum": slider.minimumValue, "maximum": slider.maximumValue]
                }
                if let toggle = view as? UISwitch { item["isOn"] = toggle.isOn }
                if let control = view as? UIControl {
                    var enabled = control.isEnabled && isInActivePresentation(view)
                    var ancestor: UIView? = view
                    while let current = ancestor { enabled = enabled && current.isUserInteractionEnabled; ancestor = current.superview }
                    item["enabled"] = enabled
                }
                if let button = view as? UIButton { item["title"] = button.configuration?.title ?? button.currentTitle ?? "" }
                if let field = view as? UITextField { item["placeholder"] = field.placeholder ?? ""; item["text"] = field.text ?? "" }
                if let text = view as? UITextView {
                    item["text"] = text.text ?? ""
                    item["editable"] = text.isEditable; item["selectable"] = text.isSelectable
                    item["smartInsertDeleteDisabled"] = text.smartInsertDeleteType == .no
                }
                if let input = view as? UITextInput, let selected = input.selectedTextRange {
                    item["selection"] = ["start": input.offset(from: input.beginningOfDocument, to: selected.start), "end": input.offset(from: input.beginningOfDocument, to: selected.end)]
                }
                if let label = view as? UILabel { item["text"] = label.text ?? ""; item["numberOfLines"] = label.numberOfLines }
                // Read actual UIKit metrics; no style/model inference or mutation.
                let font: UIFont? = (view as? UILabel)?.font ?? (view as? UITextView)?.font ?? (view as? UITextField)?.font
                if let font, font.pointSize.isFinite {
                    item["font"] = ["pointSize": font.pointSize, "name": font.fontName]
                }
                if let segments = view as? UISegmentedControl {
                    item["segments"] = (0..<segments.numberOfSegments).map { segments.titleForSegment(at: $0) ?? "" }
                    item["selected"] = segments.selectedSegmentIndex
                }
                return item
            }
        }
        if command == "receive-fixture-email-code" {
            var top = window.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            guard Set(request.keys).isSubset(of: ["id", "command"]), run.approvedOrigin != nil,
                  let workspace = window.rootViewController as? ScrivWorkspaceController,
                  let sheet = top as? UINavigationController,
                  !sheet.isBeingPresented, !sheet.isBeingDismissed,
                  let signIn = sheet.visibleViewController as? ScrivSignInController,
                  signIn.store === workspace.store,
                  let view = signIn.viewIfLoaded, let owned = view.window,
                  ownedWindows().contains(where: { $0 === owned }), isInActivePresentation(view) else {
                throw Failure("An owned synthetic sign-in mailbox is unavailable")
            }
            try signIn.receiveFixtureEmailCode(run)
            return ["delivered": true]
        }
        guard let selector = request["target"] as? String else { throw Failure("Missing target identifier or path") }
        let matches = views().filter { $0.0 == selector || $0.1.accessibilityIdentifier == selector }
        guard matches.count == 1, let view = matches.first?.1 else { throw Failure("Target must match exactly one visible view") }
        guard isInActivePresentation(view) else { throw Failure("Target is behind the active presentation") }
        if command == "picture-timing-gesture" { return try pictureTimingSample(request, at: view) }
        if command == "script-duration-gesture" { return try scriptDurationSample(request, at: view) }
        if command == "menu" {
            var count = 0
            func describe(_ element: UIMenuElement, depth: Int) throws -> [String: Any] {
                count += 1
                guard depth <= 32, count <= 1024 else { throw Failure("Menu observation exceeds its bounds") }
                if let menu = element as? UIMenu {
                    return ["type": "menu", "title": menu.title,
                            "children": try menu.children.map { try describe($0, depth: depth + 1) }]
                }
                if let action = element as? UIAction {
                    return ["type": "action", "title": action.title,
                            "disabled": action.attributes.contains(.disabled),
                            "hidden": action.attributes.contains(.hidden),
                            "state": action.state == .on ? "on" : action.state == .mixed ? "mixed" : "off"]
                }
                // Deferred elements are not resolved: observation must not run
                // providers, handlers, clipboard reads or network operations.
                return ["type": "unresolved", "title": element.title]
            }
            let primaryMenu = (view as? UIButton)?.menu
            let primary = try primaryMenu.map { [try describe($0, depth: 0)] } ?? []
            let secondary = try ScrivSecondaryMenu.menu(of: view).map { [try describe($0, depth: 0)] } ?? []
            // This one known app-owned provider only reads line/lease state
            // and constructs menu actions. It is the same closure registered
            // for ScriptEntryRow's UIContextMenuInteraction, never a handler.
            let contextMenu = (view as? ScriptEntryRow)?.menuProvider?()
            let context = try contextMenu.map { [try describe($0, depth: 0)] } ?? []
            return ["primary": primary, "secondary": secondary, "context": context]
        }
        var ancestor: UIView? = view
        while let current = ancestor {
            guard current.isUserInteractionEnabled else { throw Failure("Target is not interactive") }
            ancestor = current.superview
        }
        if let control = view as? UIControl, !control.isEnabled { throw Failure("Target is disabled") }
        guard isHittable(view) else { throw Failure("Target is clipped, covered, or not hittable; scroll it into view first") }
        switch command {
        case "menu-action":
            let scope = request["scope"] as? String
            if scope == "character-delete" {
                let unavailable = Failure("Character deletion is outside the supported isolated scope")
                guard Set(request.keys) == ["id", "command", "target", "scope", "action", "characterID"],
                      request["action"] as? String == "Delete character…",
                      let characterID = request["characterID"] as? String,
                      run.approvedOrigin == nil, let button = view as? UIButton,
                      let workspace = window.rootViewController as? ScrivWorkspaceController,
                      workspace.presentedViewController == nil, workspace.transitionCoordinator == nil,
                      let characters = workspace.children.first(where: { $0 is CharactersController }) as? CharactersController,
                      characters.store === workspace.store, workspace.store.tab == .characters,
                      workspace.store.account == nil, workspace.store.cloud.account == nil,
                      workspace.store.project.cloudProjectId == nil, workspace.store.cloud.projectId == nil,
                      !workspace.store.isPlaying, !workspace.store.isBootstrapping,
                      let action = characters.cliDeletionAction(on: button, characterID: characterID)
                else { throw unavailable }
                _ = try ScrivCLILoadedProject.observe(workspace: workspace)
                try run.validate()
                button.sendAction(action)
                return ["dispatched": true, "coverage": "semantic-menu-action"]
            }
            if scope == "team-member-actions" {
                guard Set(request.keys) == ["id", "command", "target", "scope", "action", "teamID", "memberID"],
                      let approved = run.approvedOrigin,
                      let workspace = window.rootViewController as? ScrivWorkspaceController,
                      workspace.store.account != nil, workspace.store.cloud.baseURL == approved,
                      let teams = workspace.presentedViewController as? TeamsController,
                      teams.store === workspace.store, let button = view as? UIButton,
                      let teamID = request["teamID"] as? String, let memberID = request["memberID"] as? String,
                      let title = request["action"] as? String,
                      let action = teams.cliMemberAction(on: button, teamID: teamID, memberID: memberID, title: title)
                else { throw Failure("Team member action is outside the supported isolated scope") }
                button.sendAction(action)
                return ["dispatched": true, "coverage": "semantic-menu-action"]
            }
            if scope == "discussion-attachment" {
                guard Set(request.keys) == ["id", "command", "target", "scope", "action"],
                      let approved = run.approvedOrigin,
                      let title = request["action"] as? String, let button = view as? UIButton,
                      let workspace = window.rootViewController as? ScrivWorkspaceController,
                      workspace.store.cloud.baseURL == approved, workspace.store.showDiscussion,
                      workspace.presentedViewController == nil, workspace.transitionCoordinator == nil,
                      let panel = workspace.children.compactMap({ $0 as? ScrivDiscussionController }).first,
                      panel.store === workspace.store, panel.viewIfLoaded?.window === window,
                      let action = panel.cliAttachmentAction(on: button, title: title) else {
                    throw Failure("Discussion attachment action is unavailable")
                }
                button.sendAction(action)
                return ["dispatched": true, "coverage": "semantic-menu-action"]
            }
            if scope == "codex-model-selection" {
                guard Set(request.keys) == ["id", "command", "target", "scope", "action"],
                      let title = request["action"] as? String, let button = view as? UIButton,
                      let workspace = window.rootViewController as? ScrivWorkspaceController,
                      let action = ScrivSettingsController.cliModelAction(on: button, title: title, store: workspace.store) else {
                    throw Failure("Codex model action is unavailable")
                }
                button.sendAction(action)
                return ["dispatched": true, "coverage": "semantic-menu-action"]
            }
            if scope == "workspace-discussion" || scope == "workspace-panels" {
                let discussion = scope == "workspace-discussion"
                let unavailable = discussion ? "Workspace discussion action is unavailable" : "Workspace panel action is unavailable"
                guard Set(request.keys).isSubset(of: ["id", "command", "target", "scope", "action"]),
                      let title = request["action"] as? String,
                      let button = view as? UIButton,
                      let workspace = window.rootViewController as? ScrivWorkspaceController,
                      workspace.presentedViewController == nil,
                      workspace.ownsCLIActionMenu(button),
                      let menu = button.menu else { throw Failure(unavailable) }
                if discussion {
                    let expected = workspace.store.showDiscussion ? "Hide discussion" : "Discussion"
                    guard title == expected || title.hasPrefix(expected + " (") else { throw Failure(unavailable) }
                } else {
                    let panels = ["History…", "Teams and sharing…", "Generation history…", "Codex…"]
                    guard panels.contains(title) || (title == "Scriv account…" && workspace.store.account != nil)
                    else { throw Failure(unavailable) }
                }
                let actions = menu.children.compactMap { $0 as? UIMenu }.filter { $0.options.contains(.displayInline) }
                    .flatMap { $0.children.compactMap { $0 as? UIAction } }
                    .filter { $0.title == title && $0.attributes.isEmpty }
                guard actions.count == 1, let action = actions.first else { throw Failure(unavailable) }
                button.sendAction(action)
                return ["dispatched": true, "coverage": "semantic-menu-action"]
            }
            if ScrivCLICharacterPortraitMenu.canHandle(request) {
                return try ScrivCLICharacterPortraitMenu.dispatch(view: view, window: window, windows: ownedWindows(), request: request)
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
                return try ScrivCLIInspectorPromptMenu.dispatch(view: view, window: window, windows: ownedWindows(), request: request)
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
            // Narrow public dispatch from the actual owning control. This is
            // semantic menu-action coverage, not opening/choosing a native menu.
            guard Set(request.keys).isSubset(of: ["id", "command", "target", "action"]),
                  let title = request["action"] as? String,
                  let button = view as? UIButton, button.accessibilityIdentifier == "script-zoom",
                  let workspace = window.rootViewController as? ScrivWorkspaceController,
                  workspace.presentedViewController == nil, workspace.store.errorMessage == nil,
                  let menu = button.menu, menu.title == "Script text size · shared across views",
                  menu.options.isEmpty else { throw Failure("Menu action is outside the supported scope") }
            var owner: UIResponder? = button
            var script: ScriptScreenController?
            var ownerSteps = 0
            while let current = owner, ownerSteps < 64 {
                if let candidate = current as? ScriptScreenController { script = candidate; break }
                owner = current.next; ownerSteps += 1
            }
            guard let script, script.store === workspace.store else { throw Failure("Menu action owner is not the active script") }
            // Reject submenus/deferred/command elements rather than resolving
            // providers or extracting handlers. No title-only global dispatch.
            let expected = ["70%", "85%", "100% · Default", "115%", "130%", "150%", "200%"]
            let actions = menu.children.compactMap { $0 as? UIAction }
            guard actions.count == expected.count, menu.children.count == expected.count,
                  actions.map({ $0.title }) == expected,
                  actions.allSatisfy({ $0.attributes.isEmpty }),
                  let action = actions.first(where: { $0.title == title }) else { throw Failure("Menu action is outside the supported scope") }
            _ = try ScrivCLILoadedProject.observe(workspace: workspace)
            // Same stored action, same original control, exactly once. No relay,
            // added registration, selector, private handler or denied helper.
            button.sendAction(action)
            return ["dispatched": true, "coverage": "semantic-menu-action"]
        case "accessibility-activate":
            try requireNonsensitiveAccessibility()
            guard view.isAccessibilityElement, view.accessibilityTraits.contains(.button),
                  !view.accessibilityTraits.contains(.notEnabled) else {
                throw Failure("Target is not an enabled accessibility button")
            }
            // Public native accessibility action only. Do not invoke private
            // UIAlertAction handlers, synthesize selectors, or mutate model state.
            guard view.accessibilityActivate() else {
                throw Failure("Native accessibility activation was not handled")
            }
        case "activate":
            if request["modifiers"] != nil {
                guard Set(request.keys) == ["id", "command", "target", "modifiers"],
                      let modifiers = request["modifiers"] as? [String],
                      let workspace = window.rootViewController as? ScrivWorkspaceController,
                      workspace.store.tab == .storyboard,
                      let storyboard = workspace.children.first(where: { $0 is StoryboardViewController }) as? StoryboardViewController,
                      storyboard.store === workspace.store, storyboard.cliActivateWord(view, modifiers: modifiers) else {
                    throw Failure("Storyboard word activation is unavailable for these modifiers")
                }
                return ["dispatched": true]
            }
            if let cell = view as? UICollectionViewCell {
                var parent = cell.superview
                while parent != nil && !(parent is UICollectionView) { parent = parent?.superview }
                guard let collection = parent as? UICollectionView, collection.allowsSelection,
                      let index = collection.indexPath(for: cell),
                      collection.delegate?.collectionView?(collection, shouldSelectItemAt: index) != false else { throw Failure("Collection item cannot be selected") }
                collection.selectItem(at: index, animated: false, scrollPosition: [])
                collection.delegate?.collectionView?(collection, didSelectItemAt: index)
                return ["dispatched": true]
            }
            if let cell = view as? UITableViewCell {
                var parent = cell.superview
                while parent != nil && !(parent is UITableView) { parent = parent?.superview }
                if let table = parent as? UITableView, let delegate = table.delegate,
                   let picker = delegate as? ScrivScreenController,
                   picker is UIKitDiscussionMentionPicker || picker is UIKitDiscussionActivityController || picker is HistoryController {
                    let unavailable = picker is HistoryController ? "History row cannot be selected" : "Discussion picker row cannot be selected"
                    guard Set(request.keys).isSubset(of: ["id", "command", "target"]),
                          table.allowsSelection, !table.isEditing, !table.allowsMultipleSelection,
                          let index = table.indexPath(for: cell), table.cellForRow(at: index) === cell,
                          let pickerView = picker.viewIfLoaded, table.isDescendant(of: pickerView),
                          picker.requireCurrentContext(),
                          delegate.tableView?(table, shouldHighlightRowAt: index) != false else {
                        throw Failure(unavailable)
                    }
                    if delegate.responds(to: #selector(UITableViewDelegate.tableView(_:willSelectRowAt:))),
                       delegate.tableView?(table, willSelectRowAt: index) != index {
                        throw Failure(unavailable)
                    }
                    // Programmatic selection doesn't notify the delegate.
                    table.selectRow(at: index, animated: false, scrollPosition: .none)
                    delegate.tableView?(table, didSelectRowAt: index)
                    return ["dispatched": true]
                }
            }
            guard let control = view as? UIControl else { throw Failure("Activation currently requires a UIControl") }
            if control.allControlEvents.contains(.primaryActionTriggered) {
                control.sendActions(for: .primaryActionTriggered)
            } else { control.sendActions(for: .touchUpInside) }
        case "toggle":
            guard let toggle = view as? UISwitch, let value = request["value"] as? Bool else { throw Failure("Expected switch and Boolean value") }
            toggle.setOn(value, animated: false); toggle.sendActions(for: .valueChanged)
        case "selection":
            guard !isSensitiveSubtree(view) else { throw Failure("Sensitive input is unavailable") }
            guard let input = view as? UITextInput, let start = request["start"] as? Int, let end = request["end"] as? Int,
                  start >= 0, end >= start, end <= input.offset(from: input.beginningOfDocument, to: input.endOfDocument),
                  let first = input.position(from: input.beginningOfDocument, offset: start),
                  let last = input.position(from: input.beginningOfDocument, offset: end),
                  let range = input.textRange(from: first, to: last) else { throw Failure("Expected valid UTF-16 selection") }
            guard (view as? UITextField)?.isSecureTextEntry != true else { throw Failure("Secure input is unavailable") }
            input.selectedTextRange = range
        case "return":
            guard !isSensitiveSubtree(view) else { throw Failure("Sensitive input is unavailable") }
            guard let editor = view as? UITextView, editor.isEditable, editor.isFirstResponder,
                  editor.markedTextRange == nil else {
                throw Failure("Return requires the focused editable text view without composition")
            }
            // UIKeyInput.insertText alone bypasses shouldChange on Catalyst.
            // Explicitly follow the public delegate contract, rather than
            // claiming this command synthesizes a physical keyboard event.
            let allowed = editor.delegate?.textView?(editor, shouldChangeTextIn: editor.selectedRange, replacementText: "\n") ?? true
            if allowed { editor.insertText("\n") }
            return ["dispatched": true, "delegateAcceptedInsertion": allowed]
        case "delete-backward":
            guard !isSensitiveSubtree(view) else { throw Failure("Sensitive input is unavailable") }
            guard Set(request.keys).isSubset(of: ["id", "command", "target"]),
                  let editor = view as? ScriptTextView, editor.isEditable,
                  !editor.isSecureTextEntry, editor.isFirstResponder,
                  editor.markedTextRange == nil else {
                throw Failure("Delete backward requires the focused editable script text view without composition and accepts no extra parameters")
            }
            // One public UIKeyInput operation on the mounted production view.
            // Dynamic dispatch reaches ScriptTextView.deleteBackward: its zero
            // caret override requests the real controller boundary operation;
            // selected/nonzero deletion remains UIKit's native delegate path.
            // No closure/handler/store call, focus repair or insertion fallback.
            editor.deleteBackward()
        case "script-insert":
            // Explicit public delegate-contract insertion, not a keyboard event
            // and not a change to generic type/insertText semantics.
            guard Set(request.keys).isSubset(of: ["id", "command", "target", "text"]),
                  !asynchronousCommandInProgress, !isSensitiveSubtree(view),
                  let text = request["text"] as? String, !text.isEmpty,
                  text.utf8.count <= 64 * 1024, !text.contains("\n"), !text.contains("\r"),
                  let editor = view as? ScriptTextView, editor.isEditable,
                  !editor.isSecureTextEntry, editor.isFirstResponder, editor.markedTextRange == nil,
                  let row = editor.delegate as? ScriptEntryRow, row.editor === editor,
                  editor.isDescendant(of: row),
                  let workspace = window.rootViewController as? ScrivWorkspaceController,
                  workspace.presentedViewController == nil, workspace.store.errorMessage == nil,
                  !workspace.store.isBootstrapping, !workspace.store.isPlaying,
                  !workspace.store.isSyncing, !workspace.store.hasConflicts, !workspace.store.codex.isGenerating,
                  workspace.store.account == nil, workspace.store.cloud.account == nil,
                  workspace.store.project.cloudProjectId == nil, workspace.store.cloud.projectId == nil,
                  editor.window === workspace.viewIfLoaded?.window else {
                throw Failure("Script insertion is outside the supported isolated scope")
            }
            var owner: UIResponder? = row
            var script: ScriptScreenController?
            for _ in 0..<64 {
                guard let current = owner else { break }
                if let candidate = current as? ScriptScreenController { script = candidate; break }
                owner = current.next
            }
            guard let script, script.parent === workspace, script.store === workspace.store,
                  script.presentedViewController == nil,
                  script.cliOwnsReadyInsertion(editor: editor, row: row),
                  let source = editor.text, let selected = editor.selectedTextRange else {
                throw Failure("Script insertion requires the current mounted editing session")
            }
            let range = editor.selectedRange
            guard range.location >= 0, range.length >= 0, range.location <= source.utf16.count,
                  range.length <= source.utf16.count - range.location,
                  Range(range, in: source) != nil,
                  editor.offset(from: editor.beginningOfDocument, to: selected.start) == range.location,
                  editor.offset(from: editor.beginningOfDocument, to: selected.end) == range.location + range.length else {
                throw Failure("Script insertion requires an exact valid UTF-16 selection")
            }
            // Reuse the existing strict synthetic package/root witness. No
            // arbitrary editor, account, path, focus repair or model mutation.
            _ = try ScrivCLILoadedProject.observe(workspace: workspace)
            guard let allowed = editor.delegate?.textView?(editor, shouldChangeTextIn: range, replacementText: text)
            else { throw Failure("The installed script insertion delegate is unavailable") }
            if allowed { editor.insertText(text) }
            // Existing callback counters are independently compared by callers.
            // A duplicate callback fails the journey; never suppress callbacks,
            // replace delegates, manually send didChange, or retry insertion.
            return ["dispatched": true, "delegateAcceptedInsertion": allowed,
                    "coverage": "public-script-insertion-delegate-contract"]
        case "script-delete-selection":
            // Explicit public delegate-contract selected deletion, never a caret
            // backspace/merge or a change to generic delete-backward semantics.
            guard Set(request.keys).isSubset(of: ["id", "command", "target"]),
                  !asynchronousCommandInProgress, !isSensitiveSubtree(view),
                  let editor = view as? ScriptTextView, editor.isEditable,
                  !editor.isSecureTextEntry, editor.isFirstResponder, editor.markedTextRange == nil,
                  let row = editor.delegate as? ScriptEntryRow, row.editor === editor,
                  editor.isDescendant(of: row),
                  let workspace = window.rootViewController as? ScrivWorkspaceController,
                  workspace.presentedViewController == nil, workspace.store.errorMessage == nil,
                  !workspace.store.isBootstrapping, !workspace.store.isPlaying,
                  !workspace.store.isSyncing, !workspace.store.hasConflicts, !workspace.store.codex.isGenerating,
                  workspace.store.account == nil, workspace.store.cloud.account == nil,
                  workspace.store.project.cloudProjectId == nil, workspace.store.cloud.projectId == nil,
                  editor.window === workspace.viewIfLoaded?.window else {
                throw Failure("Script selected deletion is outside the supported isolated scope")
            }
            var owner: UIResponder? = row
            var script: ScriptScreenController?
            for _ in 0..<64 {
                guard let current = owner else { break }
                if let candidate = current as? ScriptScreenController { script = candidate; break }
                owner = current.next
            }
            guard let script, script.parent === workspace, script.store === workspace.store,
                  script.presentedViewController == nil,
                  script.cliOwnsReadyInsertion(editor: editor, row: row),
                  let source = editor.text, let selected = editor.selectedTextRange else {
                throw Failure("Script selected deletion requires the current mounted editing session")
            }
            let range = editor.selectedRange
            guard range.location >= 0, range.length > 0, range.location <= source.utf16.count,
                  range.length <= source.utf16.count - range.location,
                  Range(range, in: source) != nil,
                  editor.offset(from: editor.beginningOfDocument, to: selected.start) == range.location,
                  editor.offset(from: editor.beginningOfDocument, to: selected.end) == range.location + range.length else {
                throw Failure("Script selected deletion requires an exact valid UTF-16 selection")
            }
            // Reuse the existing strict synthetic package/root witness. No
            // arbitrary editor, account, path, focus repair or model mutation.
            _ = try ScrivCLILoadedProject.observe(workspace: workspace)
            guard let allowed = editor.delegate?.textView?(editor, shouldChangeTextIn: range, replacementText: "")
            else { throw Failure("The installed script selected-deletion delegate is unavailable") }
            if allowed { editor.deleteBackward() }
            // Existing callback counters are independently compared by callers.
            // A duplicate callback fails the journey; never suppress callbacks,
            // replace delegates, manually send didChange, or retry deletion.
            return ["dispatched": true, "delegateAcceptedDeletion": allowed,
                    "coverage": "public-script-selection-deletion-delegate-contract"]
        case "type":
            guard !isSensitiveSubtree(view) else { throw Failure("Sensitive input is unavailable") }
            guard let text = request["text"] as? String else { throw Failure("Missing text") }
            if let field = view as? UITextField {
                guard !field.isSecureTextEntry, field.becomeFirstResponder() else { throw Failure("Field cannot be edited") }
                field.insertText(text)
            } else if let editor = view as? UITextView {
                guard editor.isEditable, editor.becomeFirstResponder() else { throw Failure("Text cannot be edited") }
                editor.insertText(text)
            } else { throw Failure("Target is not a text input") }
        case "text":
            guard !isSensitiveSubtree(view) else { throw Failure("Sensitive input is unavailable") }
            guard let text = request["text"] as? String else { throw Failure("Missing text") }
            if let field = view as? UITextField {
                guard !field.isSecureTextEntry, field.becomeFirstResponder() else { throw Failure("Field cannot be edited") }
                field.selectAll(nil); field.insertText(text)
            } else if let editor = view as? UITextView {
                guard editor.isEditable, editor.becomeFirstResponder() else { throw Failure("Editor cannot be edited") }
                editor.selectAll(nil); editor.insertText(text)
            } else { throw Failure("Target is not a text editor") }
        case "select":
            guard let segments = view as? UISegmentedControl, let index = request["index"] as? Int,
                  index >= 0, index < segments.numberOfSegments, segments.isEnabledForSegment(at: index) else { throw Failure("Invalid segment") }
            segments.selectedSegmentIndex = index; segments.sendActions(for: .valueChanged)
        case "slider":
            guard let slider = view as? UISlider, let value = request["value"] as? Double, value.isFinite,
                  value >= Double(slider.minimumValue), value <= Double(slider.maximumValue) else { throw Failure("Slider value must be finite and within its range") }
            slider.setValue(Float(value), animated: false); slider.sendActions(for: .valueChanged)
        case "scroll":
            guard let scroll = view as? UIScrollView, let y = request["y"] as? Double, y.isFinite else { throw Failure("Expected scroll view and finite y") }
            let maximum = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(maximum, max(-scroll.adjustedContentInset.top, CGFloat(y)))), animated: false)
        default: throw Failure("Unknown command: " + command)
        }
        return ["dispatched": true] // Completion is observed separately with snapshot polling.
    }
}
#endif
