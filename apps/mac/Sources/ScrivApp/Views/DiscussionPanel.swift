import SwiftUI
import ScrivCore

struct PresenceAvatars: View {
    @EnvironmentObject private var store: WorkspaceStore
    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: -5) {
                ForEach(Array(store.peers.prefix(4).enumerated()), id: \.element.id) { index, peer in
                    InitialAvatar(name: peer.name, color: ScrivTheme.color(["blue", "green", "purple", "orange"][index % 4]), size: 23)
                        .help(peer.name + (peer.itemId == nil ? " is here" : " is editing"))
                }
            }
            Text("\(store.peers.count) here").font(.system(size: 10)).foregroundStyle(.secondary)
        }.accessibilityLabel("\(store.peers.count) collaborators connected")
    }
}

struct DiscussionPanel: View {
    @EnvironmentObject private var store: WorkspaceStore
    @State private var draft = ""
    @State private var submittedText: String?
    @State private var messageIDsAtSubmit: Set<String> = []
    private var ready: Bool { store.account != nil && store.project.cloudProjectId != nil }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Discussion", systemImage: "bubble.left").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.2)) { store.showDiscussion = false } } label: { Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.plain).accessibilityLabel("Close discussion")
            }.foregroundStyle(ScrivTheme.accent).padding(.top, 4)
            PillSegmentPicker(values: ["Project", "This item"], selection: Binding(get: { store.discussionItemID == nil ? "Project" : "This item" }, set: { value in
                if value == "Project" { store.loadDiscussion(itemId: nil) }
                else { store.loadDiscussion(itemId: store.selectedEntryID ?? store.selectedCharacterID ?? store.selectedCue?.imageId) }
            })) { $0 }
            if store.discussionItemID != nil { contextSelector }
            if !ready { unavailable }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if store.messages.isEmpty {
                                Text("Start the conversation. Notes stay attached to this \(store.discussionItemID == nil ? "project" : "item") as the script changes.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                            }
                            ForEach(store.messages) { message in
                                messageRow(message).id(message.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
                    }.background(ScrivTheme.panel.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
                        .onChange(of: store.messages.count) { _, _ in
                            if let id = store.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                            clearSentDraft()
                        }
                }
                if let thread = store.activeThread {
                    HStack {
                        Button { store.resolveThread() } label: { Label(thread.resolved ? "Reopen thread" : "Resolve thread", systemImage: thread.resolved ? "arrow.uturn.backward" : "checkmark") }
                            .buttonStyle(.bordered).controlSize(.small)
                        Spacer()
                        if thread.resolved { Label("Resolved", systemImage: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green) }
                    }
                }
                composer
            }
        }.padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(ScrivTheme.hairline))
            .shadow(color: .black.opacity(0.15), radius: 25, y: 7)
            .onChange(of: store.discussionItemID) { _, _ in submittedText = nil; messageIDsAtSubmit = [] }
    }
    private var contextSelector: some View {
        Menu {
            Section("Lines and directions") {
                ForEach(Array(store.sceneEntries.enumerated()), id: \.element.id) { index, entry in
                    Button("\(index + 1) · \(entry.kind == .direction ? "Direction" : store.project.character(entry.characterId)?.name ?? "Dialogue") · \(entry.text.prefix(45))") { store.loadDiscussion(itemId: entry.id) }
                }
            }
            Section("Characters") { ForEach(store.project.characters) { character in Button(character.name) { store.loadDiscussion(itemId: character.id) } } }
            Section("Images") { ForEach(store.project.images) { image in Button(imageLabel(image)) { store.loadDiscussion(itemId: image.id) } } }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: contextSymbol(store.discussionItemID))
                Text(itemLabel(store.discussionItemID)).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 9))
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(ScrivTheme.accent).padding(9)
                .background(ScrivTheme.panel.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
        }.menuStyle(.borderlessButton)
    }
    private var unavailable: some View {
        VStack(spacing: 15) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
            Text(store.account == nil ? "Sign in to keep the conversation" : "Save this project to Scriv Cloud")
                .font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            Text("Threads attach to lines, directions, characters and images. Shared projects include everyone on your team.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(store.account == nil ? "Sign in to Scriv" : "Save script to cloud") { if store.account == nil { store.signIn() } else { store.syncProject() } }
                .buttonStyle(.borderedProminent)
            Spacer()
        }.padding(12).frame(maxWidth: .infinity)
    }
    private func messageRow(_ message: DiscussionMessage) -> some View {
        HStack(alignment: .top, spacing: 9) {
            InitialAvatar(name: message.name ?? "Editor", color: message.userId == store.account?.id || message.authorId == store.account?.id ? ScrivTheme.accent : .teal, size: 27)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(message.name ?? "Editor").font(.system(size: 11, weight: .semibold))
                    Text(message.timestamp, style: .time).font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { store.discussionReplyToID = message.id } label: { Image(systemName: "arrowshape.turn.up.left").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Reply to this message")
                }
                if let reply = message.replyToId, let original = store.messages.first(where: { $0.id == reply }) {
                    Text(original.body).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        .padding(.leading, 8).overlay(alignment: .leading) { Rectangle().fill(ScrivTheme.hairline).frame(width: 2) }
                }
                Text(message.body).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                ForEach(Array((message.attachments ?? []).enumerated()), id: \.offset) { _, attachment in attachmentView(attachment) }
            }
        }
    }
    @ViewBuilder private func attachmentView(_ attachment: JSONValue) -> some View {
        let id = attachment["itemId"]?.string
        if let image = store.project.images.first(where: { $0.id == id || $0.id == attachment["imageVersionId"]?.string }) {
            Button { store.loadDiscussion(itemId: image.id) } label: {
                HStack(spacing: 8) {
                    AssetImageView(url: store.assetURL(image), title: imageLabel(image), cornerRadius: 5).frame(width: 83, height: 53)
                    Text(imageLabel(image)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }.padding(5).background(ScrivTheme.inset.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain)
        } else if let id {
            Button { store.loadDiscussion(itemId: id) } label: { Label(itemLabel(id), systemImage: contextSymbol(id)).font(.system(size: 10)).lineLimit(1) }.buttonStyle(.bordered)
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let replyId = store.discussionReplyToID, let message = store.messages.first(where: { $0.id == replyId }) {
                HStack {
                    Label("Replying to \(message.name ?? "editor")", systemImage: "arrowshape.turn.up.left").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.discussionReplyToID = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain)
                }
            }
            if !store.discussionAttachments.isEmpty {
                HStack {
                    Text("\(store.discussionAttachments.count) attached item\(store.discussionAttachments.count == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { store.discussionAttachments = [] }.font(.system(size: 10)).buttonStyle(.borderless)
                }
            }
            HStack(alignment: .bottom, spacing: 9) {
                Menu {
                    if let id = store.selectedEntryID { Button("Selected line or direction") { store.addDiscussionAttachment(itemId: id) } }
                    if let id = store.selectedCharacterID { Button("Selected character") { store.addDiscussionAttachment(itemId: id) } }
                    if let image = store.project.asset(store.selectedCue?.imageId ?? store.currentCue?.imageId) {
                        Button("Current image, version \(image.version)") { store.addDiscussionAttachment(itemId: image.id, imageVersionId: image.id) }
                    }
                } label: { Image(systemName: "paperclip").font(.system(size: 16)).frame(width: 20, height: 26) }
                    .menuStyle(.borderlessButton).fixedSize().disabled(store.discussionAttachments.count >= 8)
                TextField("Reply to \(store.discussionItemID == nil ? "project" : "this item")…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...4).onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(width: 28, height: 28).background(ScrivTheme.accent, in: Circle()) }
                    .buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 8000)
                    .accessibilityLabel("Send message")
            }.padding(9).background(ScrivTheme.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
            if draft.count > 7500 { Text("\(draft.count) / 8,000 characters").font(.system(size: 9)).foregroundStyle(draft.count > 8000 ? Color.red : .secondary) }
        }
    }
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 8000 else { return }
        submittedText = text; messageIDsAtSubmit = Set(store.messages.map(\.id)); store.sendMessage(text)
    }
    private func clearSentDraft() {
        guard let submittedText, let userId = store.account?.id, store.messages.contains(where: { !messageIDsAtSubmit.contains($0.id) && $0.body == submittedText && ($0.userId == userId || $0.authorId == userId) }) else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) == submittedText { draft = "" }
        self.submittedText = nil; messageIDsAtSubmit = []
    }
    private func imageLabel(_ image: ImageAsset) -> String { "\(store.project.cues.first(where: { $0.imageId == image.id })?.label ?? "Image") · v\(image.version)" }
    private func itemLabel(_ id: String?) -> String {
        guard let id else { return "Project" }
        if let entry = store.project.entries.first(where: { $0.id == id }) {
            let number = (store.project.entries(in: entry.sceneId).firstIndex(where: { $0.id == id }) ?? 0) + 1
            return "\(entry.kind == .direction ? "Direction" : "Line") \(String(format: "%02d", number)) · \(entry.kind == .direction ? String(entry.text.prefix(35)) : store.project.character(entry.characterId)?.name ?? "Dialogue")"
        }
        if let character = store.project.character(id) { return character.name }
        if let image = store.project.asset(id) { return imageLabel(image) }
        if let cue = store.project.cues.first(where: { $0.id == id }) { return cue.label.isEmpty ? "Image cue" : cue.label }
        return "Archived item"
    }
    private func contextSymbol(_ id: String?) -> String {
        if store.project.asset(id) != nil { return "photo" }
        if store.project.character(id) != nil { return "person.fill" }
        return store.project.entries.first(where: { $0.id == id })?.kind == .direction ? "arrow.turn.down.right" : "text.quote"
    }
}
