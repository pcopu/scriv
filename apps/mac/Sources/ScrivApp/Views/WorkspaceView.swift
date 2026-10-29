import SwiftUI
import ScrivCore

struct WorkspaceView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var accountOpen = false
    @State private var codexOpen = false
    @State private var projectBrowserOpen = false
    @State private var teamOpen = false
    @State private var historyOpen = false
    @State private var renaming = false
    @State private var titleDraft = ""
    var body: some View {
        VStack(spacing: 0) {
            chrome
            ZStack(alignment: .bottomTrailing) {
                workspace.padding(10)
                if store.showDiscussion {
                    DiscussionPanel().environmentObject(store)
                        .frame(width: 368, height: 515)
                        .padding(.trailing, 24).padding(.bottom, 24)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    Button { withAnimation(.spring(response: 0.3)) { store.showDiscussion = true; store.loadDiscussion(itemId: store.discussionItemID) } } label: {
                        Label("Discussion", systemImage: "bubble.left.and.bubble.right")
                            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(ScrivTheme.hairline)).shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    }.buttonStyle(.plain).foregroundStyle(ScrivTheme.accent).padding(.trailing, 24).padding(.bottom, store.tab == .storyboard ? 90 : 22)
                }
            }
        }.background(ScrivTheme.canvas)
            .background(WindowStyleReader())
            .sheet(isPresented: $projectBrowserOpen) { ProjectBrowserSheet().environmentObject(store) }
            .sheet(isPresented: $teamOpen) { TeamSheet().environmentObject(store) }
            .sheet(isPresented: $historyOpen) { HistorySheet().environmentObject(store) }
            .alert("Scriv", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .alert("Rename project", isPresented: $renaming) {
                TextField("Project title", text: $titleDraft)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { store.setProjectTitle(titleDraft) }
            }
    }
    private var chrome: some View {
        HStack(spacing: 14) {
            Menu {
                Button("Projects…", systemImage: "folder") { projectBrowserOpen = true }
                Button("New project", systemImage: "plus") { store.newProject() }
                Button("Open…", systemImage: "folder.badge.plus") { store.openProject() }
                Button("Rename…", systemImage: "pencil") { titleDraft = store.project.title; renaming = true }
                Divider()
                Button("Import script…") { store.importScript() }
                Button("Export script…") { store.exportScript() }
                Button("Export project…") { store.exportProject() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.fill").font(.system(size: 22, weight: .ultraLight)).foregroundStyle(ScrivTheme.accent.opacity(0.55))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.project.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text("Scriv").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
            }.menuStyle(.borderlessButton).fixedSize().frame(maxWidth: 220, alignment: .leading)
            Spacer(minLength: 8)
            PillSegmentPicker(values: WorkspaceTab.allCases, selection: $store.tab) { $0.rawValue }
            Spacer(minLength: 8)
            Button { historyOpen = true } label: { Image(systemName: "clock.arrow.circlepath").font(.system(size: 15)) }
                .buttonStyle(.plain).help("History").accessibilityLabel("History")
            Button { teamOpen = true } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 15)) }
                .buttonStyle(.plain).help("Team and sharing").accessibilityLabel("Team and sharing")
            Button { accountOpen.toggle() } label: {
                HStack(spacing: 7) {
                    InitialAvatar(name: store.account?.name ?? "S", size: 24)
                    Text(store.account?.name ?? "Sign in").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }.padding(.vertical, 6).padding(.horizontal, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).popover(isPresented: $accountOpen, arrowEdge: .bottom) { AccountPopover().environmentObject(store) }
            CodexToolbarButton(controller: store.codex, isOpen: $codexOpen)
                .popover(isPresented: $codexOpen, arrowEdge: .bottom) { CodexPopover(controller: store.codex) }
        }.padding(.leading, 80).padding(.trailing, 17).frame(height: 60)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { Divider().opacity(0.25) }
    }
    @ViewBuilder private var workspace: some View {
        switch store.tab {
        case .script:
            HSplitView {
                ScriptEditorView().frame(minWidth: 430, idealWidth: 650)
                PreviewPane().frame(minWidth: 470, idealWidth: 660)
            }
        case .characters:
            HSplitView {
                ScriptEditorView(compact: true).frame(minWidth: 410, idealWidth: 610)
                CharactersView().frame(minWidth: 460, idealWidth: 700)
            }
        case .storyboard:
            StoryboardView()
        }
    }
}
