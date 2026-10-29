import SwiftUI
import AppKit
import ScrivCore

@main
struct ScrivApp: App {
    @NSApplicationDelegateAdaptor(ScrivApplicationDelegate.self) private var delegate
    @StateObject private var store = WorkspaceStore()
    var body: some Scene {
        WindowGroup("Scriv") {
            WorkspaceView().environmentObject(store)
                .frame(minWidth: 1080, minHeight: 720)
                .tint(ScrivTheme.accent)
                .onOpenURL { store.handleOpenURL($0) }
                .task {
                    delegate.flushBeforeTermination = {
                        await store.flushPendingSaves()
                        guard store.statusMessage != "Save failed" else { return false }
                        store.codex.stop()
                        return true
                    }
                    if await NativePeerSmoke.runIfRequested() { return }
                    await NativeScreenshotRunner.runIfRequested(store: store)
                }
        }
        .defaultSize(width: 1440, height: 1000)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { store.undo() }.keyboardShortcut("z").disabled(!store.canUndo)
                Button("Redo") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!store.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project") { store.newProject() }.keyboardShortcut("n")
                Button("Open Project…") { store.openProject() }.keyboardShortcut("o")
                Button("Import Script…") { store.importScript() }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.saveProject() }.keyboardShortcut("s")
                Button("Export Script…") { store.exportScript() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export Project…") { store.exportProject() }
            }
            CommandMenu("Script") {
                Button("Add Dialogue") { store.addEntry(kind: .dialogue) }.keyboardShortcut(.return, modifiers: [.command])
                Button("Add Direction") { store.addEntry(kind: .direction) }.keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("Add Scene") { store.addScene() }
                Divider()
                Button("Script View") { store.tab = .script }.keyboardShortcut("1")
                Button("Storyboard View") { store.tab = .storyboard }.keyboardShortcut("2")
                Button("Characters View") { store.tab = .characters }.keyboardShortcut("3")
                Divider()
                Button("Codex on this Mac") { NotificationCenter.default.post(name: .scrivShowCodexControls, object: nil) }
            }
            CommandMenu("Playback") {
                Button(store.isPlaying ? "Pause" : "Play") { store.togglePlayback() }.keyboardShortcut(" ", modifiers: [.option])
                Button("Return to Beginning") { store.seek(toMs: 0) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Toggle("Follow Playback", isOn: $store.followPlayback)
            }
        }
        Settings { ScrivSettingsView().environmentObject(store) }
    }
}

@MainActor
final class ScrivApplicationDelegate: NSObject, NSApplicationDelegate {
    var flushBeforeTermination: (() async -> Bool)?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        NotificationCenter.default.post(name: .scrivFinishEditing, object: nil)
        sender.keyWindow?.makeFirstResponder(nil)
        Task {
            let saved = await flushBeforeTermination?() ?? true
            if !saved { terminating = false }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}

extension Notification.Name {
    static let scrivFinishEditing = Notification.Name("ScrivFinishEditing")
    static let scrivShowCodexControls = Notification.Name("ScrivShowCodexControls")
}

/// CI captures the actual native view tree. This does not use screen recording,
/// fabricate screenshots, or require a signed-in cloud account.
@MainActor
enum NativeScreenshotRunner {
    private static var started = false
    static func runIfRequested(store: WorkspaceStore) async {
        let args = ProcessInfo.processInfo.arguments
        guard !started, let index = args.firstIndex(of: "--screenshots"), args.indices.contains(index + 1) else { return }
        started = true
        let output = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            guard try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty else {
                throw ScrivError.invalid("Screenshot output must be empty. Use a fresh directory so old renders cannot pass as current evidence.")
            }
            await store.prepareSampleForScreenshot()
            store.showDiscussion = false; store.isPlaying = false
            try await Task.sleep(for: .seconds(1))
            guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible }) else { throw ScrivError.unavailable("No Scriv window was available for screenshots.") }
            window.setContentSize(NSSize(width: 1448, height: 1086))
            window.appearance = NSAppearance(named: .aqua)
            window.makeKeyAndOrderFront(nil)
            var captures: [[String: Any]] = []
            let views: [(WorkspaceTab, String)] = [(.script, "01-script.png"), (.characters, "02-characters.png"), (.storyboard, "03-storyboard.png")]
            for (tab, name) in views {
                store.tab = tab
                if tab == .script {
                    let moment = min(29_400, max(0, store.sceneDurationMs - 1))
                    store.seek(toMs: Double(moment))
                    store.selectedEntryID = store.project.activeEntry(at: moment, sceneId: store.selectedSceneID)?.id
                    store.selectedCueID = store.project.activeCue(at: moment, sceneId: store.selectedSceneID)?.id
                }
                if tab == .characters { store.selectedCharacterID = store.project.characters.first(where: { $0.name.contains("Franklin") })?.id ?? store.project.characters.first?.id }
                try await Task.sleep(for: .seconds(2))
                captures.append(try capture(window, filename: name, role: "workspace", output: output, store: store))
            }
            store.tab = .script
            store.seek(toMs: Double(min(29_400, max(0, store.sceneDurationMs - 1))))
            store.loadDiscussion(itemId: "line-08")
            try await Task.sleep(for: .seconds(1))
            let priorWindows = Set(NSApp.windows.filter(\.isVisible).map { ObjectIdentifier($0) })
            NotificationCenter.default.post(name: .scrivShowCodexControls, object: nil)
            try await Task.sleep(for: .seconds(1))
            captures.append(try capture(window, filename: "04-collaboration-local.png", role: "workspace", output: output, store: store))
            // NSPopover is a separate native window. Preserve that raw capture
            // separately rather than compositing it into a fabricated screenshot.
            let popovers = NSApp.windows.filter {
                $0 !== window && $0.isVisible && !priorWindows.contains(ObjectIdentifier($0)) && $0.contentView != nil && $0.frame.width > 200 && $0.frame.height > 100
            }
            guard let popover = popovers.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                throw ScrivError.unavailable("The real Codex popover window did not open; fourth-state capture is incomplete.")
            }
            captures.append(try capture(popover, filename: "04-codex-popover.png", role: "codex-popover", output: output, store: store))
            let metadata: [String: Any] = [
                "schemaVersion": 1, "status": "captured", "platform": "macOS",
                "coordinateSystem": "AppKit screen points (bottom-left origin); PNGs are raw content-view captures",
                "requestedContentSize": ["width": 1448, "height": 1086],
                "collaborationState": "Local sample; no synthetic collaborators, messages, account or runtime status",
                "captures": captures
            ]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("capture-metadata.json"), options: .atomic)
            try Data("Native SwiftUI/AppKit screenshots captured successfully. Five raw images cover four workspace concepts; Codex popover is a separate native-window capture.\n".utf8).write(to: output.appendingPathComponent("result.txt"), options: .atomic)
            await store.flushPendingSaves()
            NSApp.terminate(nil)
        } catch {
            try? Data(("Screenshot capture failed: " + error.localizedDescription + "\n").utf8).write(to: output.appendingPathComponent("error.txt"), options: .atomic)
            fputs("Scriv screenshot capture failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    private static func capture(_ window: NSWindow, filename: String, role: String, output: URL, store: WorkspaceStore) throws -> [String: Any] {
        guard let content = window.contentView else { throw ScrivError.unavailable("The native window has no content view.") }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw ScrivError.unavailable("Native bitmap creation failed.") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ScrivError.unavailable("Native PNG encoding failed.") }
        try png.write(to: output.appendingPathComponent(filename), options: .atomic)
        func rectangle(_ rect: NSRect) -> [String: Double] {
            ["x": Double(rect.origin.x), "y": Double(rect.origin.y), "width": Double(rect.width), "height": Double(rect.height)]
        }
        return [
            "filename": filename, "windowRole": role, "windowClass": window.className,
            "windowFrame": rectangle(window.frame), "contentBounds": rectangle(content.bounds),
            "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
            "selectedTab": store.tab.rawValue, "playheadMs": store.playheadMs,
            "selectedEntryID": store.selectedEntryID ?? "", "selectedCueID": store.selectedCueID ?? "",
            "discussionVisible": store.showDiscussion, "codexStatus": store.codex.status,
            "codexConnected": store.codex.isConnected, "collaboratorCount": store.peers.count,
            "discussionMessageCount": store.messages.count
        ]
    }
}

struct WindowStyleReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor.windowBackgroundColor
        }
    }
}
