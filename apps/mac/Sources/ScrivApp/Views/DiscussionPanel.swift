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
    private var draft: Binding<String> { Binding(get: { store.discussionDraft }, set: { store.discussionDraft = $0 }) }
    private var ready: Bool { store.account != nil && store.project.cloudProjectId != nil }
    @State private var mentionsOpen = false
    @State private var onlyMentions = false
    @State private var activityOpen = false
    private var mentionsOfMe: [DiscussionMessage] {
        guard let id = store.account?.id else { return [] }
        return store.messages.filter { $0.mentionedUserIds.contains(id) }
    }
    private var visibleMessages: [DiscussionMessage] { onlyMentions ? mentionsOfMe : store.messages }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Discussion", systemImage: "bubble.left").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { activityOpen = true } label: {
                    Image(systemName: store.unreadDiscussionMentionCount > 0 ? "bell.badge.fill" : "bell")
                        .font(.system(size: 13)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).disabled(!ready)
                    .help("Project mentions and conversations")
                    .accessibilityLabel("Project activity, \(store.unreadDiscussionMentionCount) unread mentions")
                    .popover(isPresented: $activityOpen) { DiscussionActivityPopover().environmentObject(store) }
                if !mentionsOfMe.isEmpty {
                    Button { onlyMentions.toggle() } label: {
                        Label("\(mentionsOfMe.count)", systemImage: "at").font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(ScrivTheme.accent.opacity(onlyMentions ? 0.18 : 0.07), in: Capsule())
                    }.buttonStyle(.plain).help(onlyMentions ? "Show all messages" : "Show messages mentioning you")
                        .accessibilityLabel("\(mentionsOfMe.count) messages mention you. " + (onlyMentions ? "Show all messages" : "Filter to your mentions"))
                }
                Button { withAnimation(.easeInOut(duration: 0.2)) { store.showDiscussion = false } } label: { Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)) }
                    .buttonStyle(.plain).accessibilityLabel("Close discussion")
            }.foregroundStyle(ScrivTheme.accent).padding(.top, 4)
            PillSegmentPicker(values: ["Project", "This item"], selection: Binding(get: { store.discussionItemID == nil ? "Project" : "This item" }, set: { value in
                if value == "Project" { store.loadDiscussion(itemId: nil) }
                else {
                    let item: String?
                    switch store.tab { case .characters: item = store.selectedCharacterID; case .storyboard: item = store.selectedCue?.imageId ?? store.selectedCueID; case .script: item = store.selectedEntryID }
                    store.loadDiscussion(itemId:item)
                }
            })) { $0 }
            if store.discussionItemID != nil { contextSelector }
            if !ready { unavailable }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if store.discussionLoading { ProgressView("Loading conversation…").controlSize(.small).padding(.vertical, 18) }
                            else if visibleMessages.isEmpty {
                                Text(onlyMentions ? "No messages mention you in this conversation." : "Start the conversation. Notes stay attached to this \(store.discussionItemID == nil ? "project" : "item") as the script changes.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                            }
                            ForEach(visibleMessages) { message in
                                messageRow(message).id(message.id)
                                    .padding(5).background(store.discussionFocusedMessageID == message.id ? ScrivTheme.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
                    }.background(ScrivTheme.panel.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
                        .onChange(of: store.messages.count) { _, _ in
                            if let id = store.discussionFocusedMessageID, visibleMessages.contains(where: { $0.id == id }) { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                            else if let id = visibleMessages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                        }
                        .onChange(of: store.discussionFocusedMessageID) { _, id in
                            if let id, visibleMessages.contains(where: { $0.id == id }) { withAnimation { proxy.scrollTo(id, anchor: .center) } }
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
            .onChange(of: store.discussionItemID) { _, _ in onlyMentions = false; mentionsOpen = false }
            .onChange(of: store.navigationContext) { _, _ in onlyMentions = false; mentionsOpen = false; activityOpen = false }
            .task(id: store.project.cloudProjectId) {
                guard ready else { return }
                try? await store.refreshDiscussionMembers()
            }
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
                if !message.mentionedUserIds.isEmpty {
                    FlowLayout(spacing: 4, rowSpacing: 4) {
                        ForEach(Array(Set(message.mentionedUserIds)).sorted(), id: \.self) { id in
                            Label(id == store.account?.id ? "You" : mentionName(id), systemImage: "at")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(id == store.account?.id ? Color.white : ScrivTheme.accent)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(id == store.account?.id ? ScrivTheme.accent : ScrivTheme.accent.opacity(0.08), in: Capsule())
                                .accessibilityLabel(id == store.account?.id ? "You were mentioned" : "Mentioned " + mentionName(id))
                        }
                    }
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
            if !store.discussionMentionedUserIDs.isEmpty {
                FlowLayout(spacing: 5, rowSpacing: 5) {
                    ForEach(store.discussionMentionedUserIDs, id: \.self) { id in
                        Button { store.removeDiscussionMention(id) } label: {
                            HStack(spacing: 4) {
                                Text("@" + mentionName(id)).lineLimit(1)
                                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                            }.font(.system(size: 10)).padding(.horizontal, 7).padding(.vertical, 4)
                                .foregroundStyle(ScrivTheme.accent).background(ScrivTheme.accent.opacity(0.08), in: Capsule())
                        }.buttonStyle(.plain).help("Remove mention of " + mentionName(id))
                            .accessibilityLabel("Remove mention of " + mentionName(id))
                    }
                }
            }
            if !store.discussionAttachments.isEmpty {
                HStack {
                    Text("\(store.discussionAttachments.count) attached item\(store.discussionAttachments.count == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { store.discussionAttachments = [] }.font(.system(size: 10)).buttonStyle(.borderless)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                TextField("Reply to \(store.discussionItemID == nil ? "project" : "this item")…", text: draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...6).onSubmit(send)
                HStack(alignment: .bottom, spacing: 12) {
                Menu {
                    if let id = store.selectedEntryID { Button("Selected line or direction") { store.addDiscussionAttachment(itemId: id) } }
                    if let id = store.selectedCharacterID { Button("Selected character") { store.addDiscussionAttachment(itemId: id) } }
                    if let image = store.project.asset(store.selectedCue?.imageId ?? store.currentCue?.imageId) {
                        Button("Current image, version \(image.version)") { store.addDiscussionAttachment(itemId: image.id, imageVersionId: image.id) }
                    }
                } label: { Image(systemName: "paperclip").font(.system(size: 16)).frame(width: 20, height: 26) }
                    .menuStyle(.borderlessButton).fixedSize().disabled(store.discussionAttachments.count >= 8)
                Button { mentionsOpen = true } label: { Image(systemName: "at").font(.system(size: 16)).frame(width: 20, height: 26) }
                    .buttonStyle(.plain).foregroundStyle(ScrivTheme.accent).help("Mention a project member")
                    .accessibilityLabel("Mention a project member")
                    .popover(isPresented: $mentionsOpen) { DiscussionMentionPicker().environmentObject(store) }
                Spacer()
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(width: 28, height: 28).background(ScrivTheme.accent, in: Circle()) }
                    .buttonStyle(.plain).disabled(store.isSendingDiscussion || store.discussionLoading || store.discussionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.discussionDraft.utf16.count > 8000)
                    .accessibilityLabel("Send message")
                }
            }.padding(12).background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ScrivTheme.hairline))
            if !store.discussionDraft.isEmpty { Text("Draft — not sent").font(.system(size: 10)).foregroundStyle(.secondary) }

            if store.discussionDraft.utf16.count > 7500 { Text("\(store.discussionDraft.utf16.count) / 8,000 characters").font(.system(size: 9)).foregroundStyle(store.discussionDraft.utf16.count > 8000 ? Color.red : .secondary) }
        }
    }
    private func send() {
        let text = store.discussionDraft.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 8000, !store.isSendingDiscussion else { return }
        Task { do { try await store.sendMessage(text) } catch is CancellationError { } catch { store.errorMessage = error.localizedDescription } }
    }
    private func mentionName(_ id: String) -> String {
        if id == store.account?.id { return store.account?.name ?? "You" }
        return store.discussionMemberName(id)
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

private struct DiscussionMentionPicker: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    private var members: [DiscussionMember] {
        store.discussionMembers.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.role.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mention a member").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text("\(store.discussionMentionedUserIDs.count) / 20").font(.caption).foregroundStyle(.secondary)
            }
            Text("Choose who to include. They’ll see the mention in project activity; no email is sent.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search project members", text: $search).textFieldStyle(.plain)
            }.padding(11).background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 9))
            if loading { ProgressView("Loading members…").controlSize(.small).padding(.vertical, 12) }
            else if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Retry") { Task { await reload() } }
            } else if members.isEmpty {
                Text(search.isEmpty ? "No members are available." : "No matching members.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(members) { member in
                            let selected = store.discussionMentionedUserIDs.contains(member.id)
                            Button {
                                if selected { store.removeDiscussionMention(member.id) }
                                else { store.addDiscussionMention(member) }
                            } label: {
                                HStack(spacing: 8) {
                                    InitialAvatar(name: member.name, size: 40)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(member.name + (member.id == store.account?.id ? " (you)" : "")).font(.system(size: 14, weight: .medium))
                                        Text(member.role.capitalized).font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? ScrivTheme.accent : ScrivTheme.secondary)
                                }.padding(10).contentShape(Rectangle())
                                    .background(selected ? ScrivTheme.accent.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).disabled(!selected && store.discussionMentionedUserIDs.count >= 20)
                                .accessibilityLabel((selected ? "Remove mention of " : "Mention ") + member.name + ", " + member.role)
                        }
                    }
                }.frame(maxHeight: 320)
            }
            HStack {
                if !store.discussionMentionedUserIDs.isEmpty { Button("Clear") { for id in store.discussionMentionedUserIDs { store.removeDiscussionMention(id) } } }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(ScrivPrimaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 360).background(ScrivTheme.panel)
            .task { await reload() }
    }
    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { try await store.refreshDiscussionMembers() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct DiscussionActivityPopover: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "Mentions"
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Project activity").font(.system(size: 18, weight: .semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            PillSegmentPicker(values: ["Mentions", "Conversations"], selection: $tab) { $0 }
            if loading { ProgressView("Refreshing activity…").controlSize(.small) }
            if let error { HStack { Text(error).font(.caption).foregroundStyle(.red); Button("Retry") { Task { await refresh() } } } }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if tab == "Mentions" {
                        if store.discussionMentions.isEmpty && !loading && error == nil { empty("No mentions yet", message: "Messages mentioning you in this project appear here, including those in other conversations.") }
                        ForEach(store.discussionMentions) { message in
                            Button { store.openDiscussionMention(message); dismiss() } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    ZStack(alignment: .bottomTrailing) {
                                        InitialAvatar(name: message.name ?? "Project member", size: 35)
                                        if store.isDiscussionMentionUnread(message) { Circle().fill(ScrivTheme.accent).frame(width: 9, height: 9).overlay(Circle().stroke(ScrivTheme.panel, lineWidth: 2)) }
                                    }
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(message.name ?? "Project member").font(.system(size: 13, weight: .semibold))
                                            Spacer()
                                            Text(message.timestamp, style: .relative).font(.system(size: 9)).foregroundStyle(.secondary)
                                        }
                                        Text(message.body).font(.system(size: 13)).lineLimit(4).multilineTextAlignment(.leading)
                                        if let thread = store.discussionThreads.first(where: { $0.id == message.threadId }) {
                                            Text(threadLabel(thread)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }.padding(9).background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).accessibilityLabel((store.isDiscussionMentionUnread(message) ? "Unread mention. " : "Mention. ") + message.body)
                        }
                    } else {
                        if store.discussionThreads.isEmpty && !loading && error == nil { empty("No conversations yet", message: "Project and item discussions stay available here after an item is renamed, moved or deleted.") }
                        ForEach(store.discussionThreads) { thread in
                            Button { store.openDiscussionThread(thread); dismiss() } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: thread.resolved ? "checkmark.bubble" : "bubble.left").foregroundStyle(thread.resolved ? .green : ScrivTheme.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(threadLabel(thread)).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(thread.resolved ? "Resolved conversation" : "Open conversation").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                                }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 350)
            if tab == "Mentions" {
                Button { tab = "Conversations" } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "bubble.left.and.bubble.right")
                        Text("Looking for a conversation? View all project discussions.").font(.system(size: 12)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption)
                    }.padding(12).foregroundStyle(ScrivTheme.accent).background(ScrivTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }
            Text("In-app activity only. No email or push notification is sent.").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(20).frame(width: 390).background(ScrivTheme.panel).task { await refresh() }
    }
    @MainActor private func refresh() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { try await store.refreshDiscussionActivity() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    private func empty(_ title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 13, weight: .semibold)); Text(message).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 18)
    }
    private func threadLabel(_ thread: DiscussionThread) -> String {
        guard let id = thread.itemId else { return "Project discussion" }
        if let entry = store.project.entries.first(where: { $0.id == id }) { return String(entry.text.prefix(90)) }
        if let character = store.project.character(id) { return character.name }
        if let image = store.project.asset(id) { return "Image · version \(image.version)" }
        if let cue = store.project.cues.first(where: { $0.id == id }) { return cue.label.isEmpty ? "Image placement" : cue.label }
        return "Archived item · …" + id.suffix(8)
    }
}
