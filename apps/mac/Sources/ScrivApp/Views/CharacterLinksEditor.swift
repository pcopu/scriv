import SwiftUI
import ScrivCore

/// A focused correction surface: accepting a suggestion changes metadata only.
/// Legacy names are never silently promoted to historical identity claims.
struct CharacterLinksEditor: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var entry: ScriptEntry
    @State private var navigationContext: Int
    @State private var links: [CharacterTextLink] = []
    @State private var phrase = ""
    @State private var hasLease = false
    @State private var ready = false
    init(entry: ScriptEntry, navigationContext: Int) {
        _entry = State(initialValue: entry)
        _navigationContext = State(initialValue: navigationContext)
    }
    private var suggestions: Int { links.filter { !$0.isConfirmed }.count }
    private var occurrences: [NSRange] {
        guard !phrase.isEmpty else { return [] }
        let source = entry.text as NSString
        var found: [NSRange] = [], cursor = 0
        while cursor < source.length {
            let range = source.range(of: phrase, options: .literal, range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound, range.length > 0 else { break }
            found.append(range); cursor = range.location + range.length
        }
        return found
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Character links").font(.title2.weight(.semibold))
            Text("Confirm a name once to keep it linked to the same character through renames. Suggestions are guesses; correcting or unlinking never changes your script's wording.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(ScrivTheme.inset, in: RoundedRectangle(cornerRadius: 8))
                    if links.isEmpty { Text("No character links in this line yet.").foregroundStyle(.secondary) }
                    ForEach(links) { link in linkRow(link) }
                    if suggestions > 0 {
                        Button("Confirm \(suggestions) suggested \(suggestions == 1 ? "link" : "links")") {
                            for i in links.indices where links[i].characterId != nil { links[i].isConfirmed = true }
                        }.buttonStyle(.bordered)
                    }
                    Button("Find more name suggestions") {
                        links += CharacterMentions.suggestions(in: entry.text, characters: store.project.characters, excluding: links)
                        links.sort { $0.location < $1.location }
                    }.font(.callout)
                    Divider()
                    Text("Link other wording").font(.headline)
                    TextField("Exact words from this line", text: $phrase).textFieldStyle(.roundedBorder)
                    if !phrase.isEmpty && occurrences.isEmpty { Text("Those exact words are not in this line.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(occurrences.enumerated()), id: \.offset) { index, range in
                        HStack {
                            Text("Occurrence \(index + 1) · character \(range.location + 1)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu("Choose character") {
                                ForEach(store.project.characters) { person in
                                    Button(person.name) { assign(range, characterId: person.id) }
                                }
                                Divider()
                                Button("Keep unlinked") { assign(range, characterId: nil) }
                            }
                        }
                    }
                }.padding(.vertical, 2)
            }.disabled(!hasLease)
            HStack {
                if !ready { ProgressView().controlSize(.small); Text("Opening line…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save links") {
                    guard store.navigationContext == navigationContext else { dismiss(); return }
                    if store.saveCharacterLinks(entry.id, expectedText: entry.text, links: links) { dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!hasLease)
            }
        }.padding(24).frame(width: 580, height: 590)
            .task {
                links = entry.characterLinks ?? CharacterMentions.suggestions(in: entry.text, characters: store.project.characters)
                guard store.navigationContext == navigationContext else { dismiss(); return }
                let allowed = await store.beginEdit(entry.id)
                guard !Task.isCancelled, store.navigationContext == navigationContext else {
                    if allowed { store.endEdit(entry.id, context: navigationContext) }; return
                }
                hasLease = allowed; ready = true
            }
            .onDisappear { if hasLease { store.endEdit(entry.id, context: navigationContext) } }
            .onChange(of: store.navigationContext) { _, value in if value != navigationContext { dismiss() } }
    }
    private func linkRow(_ link: CharacterTextLink) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("“\(link.text)”").lineLimit(2)
                Text("Character \(link.location + 1) · \(link.isConfirmed ? (link.characterId == nil ? "Unlinked" : "Confirmed") : "Suggestion")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu(link.characterId.flatMap { store.project.character($0)?.name } ?? (link.characterId == nil ? "Unlinked" : "Missing character")) {
                ForEach(store.project.characters) { person in Button(person.name) { assign(link.range, characterId: person.id) } }
                Divider()
                Button("Keep unlinked") { assign(link.range, characterId: nil) }
            }.fixedSize()
            if !link.isConfirmed, let id = link.characterId {
                Button("Confirm") { assign(link.range, characterId: id) }.buttonStyle(.borderless)
            }
        }
    }
    private func assign(_ range: NSRange, characterId: String?) {
        var copy = entry; copy.characterLinks = links
        do {
            try CharacterMentions.assign(&copy, range: range, characterId: characterId, characters: store.project.characters)
            links = copy.characterLinks ?? []
        } catch { store.errorMessage = error.localizedDescription }
    }
}
