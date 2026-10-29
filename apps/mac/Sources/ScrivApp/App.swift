import SwiftUI
import AppKit
import ScrivCore

@main
struct ScrivApp: App {
    @StateObject private var store = WorkspaceStore()
    var body: some Scene {
        WindowGroup("Scriv") {
            WorkspaceView().environmentObject(store)
                .frame(minWidth: 1080, minHeight: 720)
                .tint(ScrivTheme.accent)
                .onOpenURL { store.handleOpenURL($0) }
        }
        .defaultSize(width: 1440, height: 1000)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
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
