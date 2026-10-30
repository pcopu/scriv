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
                workspace.padding(12)
                if store.showDiscussion {
                    DiscussionPanel().environmentObject(store)
                        .frame(width: 368, height: 515)
                        .padding(.trailing, 24).padding(.bottom, 24)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }.background(ScrivTheme.canvas)
            .background(WindowStyleReader())
            .onReceive(NotificationCenter.default.publisher(for: .scrivShowCodexControls)) { _ in codexOpen = true }
            .sheet(isPresented: $projectBrowserOpen) { ProjectBrowserSheet().environmentObject(store) }
            .sheet(isPresented: $teamOpen) { TeamSheet().environmentObject(store) }
            .sheet(isPresented: $historyOpen) { HistorySheet().environmentObject(store) }
            .sheet(isPresented: $store.showAccountSignIn) { ScrivSignInSheet().environmentObject(store) }
            .alert("Rename project", isPresented: $renaming) {
                TextField("Project title", text: $titleDraft)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { store.setProjectTitle(titleDraft) }
            }
    }
    private var chrome: some View {
        HStack(spacing: 14) {
            projectControls
            Spacer(minLength: 8)
            PillSegmentPicker(values: WorkspaceTab.allCases, selection: $store.tab) { $0.rawValue }
            Spacer(minLength: 8)
            IconButton(symbol: "bubble.left.and.bubble.right", label: "Discussion", prominent: store.showDiscussion) {
                withAnimation(.spring(response: 0.3)) {
                    if store.showDiscussion { store.showDiscussion = false }
                    else { store.loadDiscussion(itemId: store.discussionItemID) }
                }
            }.overlay(alignment: .topTrailing) {
                if store.unreadDiscussionMentionCount > 0 {
                    Text(store.unreadDiscussionMentionCount > 99 ? "99+" : "\(store.unreadDiscussionMentionCount)")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2).background(ScrivTheme.accent, in: Capsule())
                        .offset(x: 4, y: -3).allowsHitTesting(false)
                }
            }.accessibilityValue("\(store.unreadDiscussionMentionCount) unread mentions")
            Button { historyOpen = true } label: { Image(systemName: "clock.arrow.circlepath").font(.system(size: 15)) }
                .buttonStyle(.plain).help("History").accessibilityLabel("History")
            Button { teamOpen = true } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 15)) }
                .buttonStyle(.plain).help("Team and sharing").accessibilityLabel("Team and sharing")
            Button {
                if store.account == nil { accountOpen = false; store.signIn() }
                else { accountOpen.toggle() }
            } label: {
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
            .background(ScrivTheme.chrome.opacity(0.72))
            .overlay(alignment: .bottom) { Divider().opacity(0.25) }
    }
    private var projectControls: some View {
        HStack(spacing: 8) {
            Button { projectBrowserOpen = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.fill").font(.system(size: 22, weight: .ultraLight)).foregroundStyle(ScrivTheme.accent.opacity(0.55))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.project.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text("Scriv").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }.buttonStyle(.plain).help("Open project browser")
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
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Project actions")
        }.frame(maxWidth: 220, alignment: .leading)
    }
    @ViewBuilder private var workspace: some View {
        switch store.tab {
        case .script:
            if store.project.entries.isEmpty { emptyWorkspace }
            else {
                HSplitView {
                    ScriptEditorView().frame(minWidth: 440, idealWidth: 690)
                    PreviewPane().frame(minWidth: 470, idealWidth: 650)
                }
            }
        case .characters:
            HSplitView {
                ScriptEditorView(compact: true).frame(minWidth: 410, idealWidth: 690)
                CharactersView().frame(minWidth: 460, idealWidth: 650)
            }
        case .storyboard:
            StoryboardView()
        }
    }
    private var emptyWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Spacer()
                    Image(systemName: "doc.text").font(.system(size: 58, weight: .ultraLight))
                        .foregroundStyle(ScrivTheme.secondary.opacity(0.6)).padding(.bottom, 24)
                    Text("Your story starts here").font(.system(size: 27, weight: .semibold))
                    Text("Write a first line, or bring in a script.").font(.system(size: 17)).foregroundStyle(.secondary).padding(.top, 10)
                    HStack(spacing: 10) {
                        Button("Add dialogue") { store.addEntry(kind: .dialogue) }.buttonStyle(ScrivPrimaryButtonStyle(fontSize: 14))
                        Button("Add direction") { store.addEntry(kind: .direction) }.buttonStyle(ScrivSecondaryButtonStyle(fontSize: 14))
                        Button("Import script…") { store.importScript() }.buttonStyle(ScrivSecondaryButtonStyle(fontSize: 14))
                    }.padding(.top, 32)
                    Divider().frame(maxWidth: 440).padding(.top, 35).opacity(0.5)
                    Text("Fountain or plain text").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 18)
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                Rectangle().fill(ScrivTheme.hairline.opacity(0.4)).frame(width: 1)
                VStack(spacing: 22) {
                    Image(systemName: "photo").font(.system(size: 91, weight: .ultraLight)).foregroundStyle(ScrivTheme.secondary.opacity(0.28))
                    Text("Images appear as you build\nthe scene").font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(width: 280).frame(maxHeight: .infinity).background(ScrivTheme.inset.opacity(0.24))
            }
            Divider().opacity(0.5)
            HStack {
                Text("Local editing is free. Sign in only for cloud storage or teams.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(store.statusMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                StatusDot(color: store.statusMessage == "Saved on this Mac" ? .green : .orange)
            }.padding(.horizontal, 20).padding(.vertical, 15)
        }.background(ScrivTheme.panel).clipShape(RoundedRectangle(cornerRadius: ScrivTheme.panelRadius))
    }
}
