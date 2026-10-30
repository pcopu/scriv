import SwiftUI
import AppKit
import ScrivCore

/// A private draft, including for creation: Cancel never leaves a placeholder
/// character in the project. Existing identity is carried by the immutable ID.
struct CharacterEditor: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScriptCharacter
    @State private var addingAlias = false
    @State private var alias = ""
    @State private var saveIssue: String?
    @FocusState private var nameFocused: Bool
    @FocusState private var aliasFocused: Bool
    let navigationContext: Int
    let isNew: Bool

    init(character: ScriptCharacter, navigationContext: Int, isNew: Bool = false) {
        _draft = State(initialValue: character)
        self.navigationContext = navigationContext
        self.isNew = isNew
    }

    private var cleanName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var colors: [String] {
        let supported = ["orange", "green", "teal", "blue", "purple", "coral", "pink"]
        return supported.contains(draft.color) ? supported : [draft.color] + supported
    }
    private var sheetHeight: CGFloat { min(844, max(560, (NSScreen.main?.visibleFrame.height ?? 954) - 110)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "Add character" : "Edit character").font(.system(size: 26, weight: .semibold))
                Spacer()
                IconButton(symbol: "xmark", label: "Close character editor") { dismiss() }
            }.padding(.horizontal, 27).padding(.vertical, 17)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    identityFields
                    CharacterFormNotice(message: "Confirmed links stay attached. Script wording never changes.")
                    notesField("Biography", text: $draft.biography)
                    notesField("Appearance & image direction", text: $draft.appearance)
                    if let saveIssue {
                        Text(saveIssue).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.horizontal, 27).padding(.vertical, 22)
            }
            Divider()
            HStack(spacing: 15) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(ScrivSecondaryButtonStyle(fontSize: 16))
                Button("Save character", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(ScrivPrimaryButtonStyle(fontSize: 16)).disabled(cleanName.isEmpty)
            }.padding(.horizontal, 27).padding(.vertical, 13)
        }
        .frame(width: 710, height: sheetHeight).background(ScrivTheme.panel)
        .task { nameFocused = true }
        .onChange(of: store.navigationContext) { _, context in if context != navigationContext { dismiss() } }
    }

    private var identityFields: some View {
        HStack(alignment: .top, spacing: 22) {
            CharacterPortrait(character: draft).frame(width: 205, height: 226)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(cleanName.isEmpty ? "New character portrait" : "Portrait of \(cleanName)")
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Circle().fill(ScrivTheme.color(draft.color)).frame(width: 19, height: 19)
                    Text(cleanName.isEmpty ? "New character" : draft.name).font(.system(size: 24, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    CharacterFormLabel(title: "Name")
                    TextField("Character name", text: $draft.name).textFieldStyle(.plain)
                        .font(.system(size: 18)).focused($nameFocused)
                        .modifier(CharacterFormField()).accessibilityLabel("Name")
                }
                VStack(alignment: .leading, spacing: 8) {
                    CharacterFormLabel(title: "Also called")
                    FlowLayout(spacing: 9, rowSpacing: 8) {
                        ForEach(Array(draft.aliases.enumerated()), id: \.offset) { index, value in
                            HStack(spacing: 10) {
                                Text(value).font(.system(size: 15))
                                Button { if draft.aliases.indices.contains(index) { draft.aliases.remove(at: index) } } label: {
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                }.buttonStyle(.plain).foregroundStyle(.secondary)
                                    .accessibilityLabel("Remove alias \(value)")
                            }.padding(.horizontal, 13).padding(.vertical, 9)
                                .background(ScrivTheme.inset, in: Capsule())
                        }
                        Button { addingAlias = true } label: {
                            Label("Add alias", systemImage: "plus").font(.system(size: 15))
                                .padding(.horizontal, 13).padding(.vertical, 9)
                                .background(ScrivTheme.inset.opacity(0.5), in: Capsule())
                                .overlay(Capsule().strokeBorder(ScrivTheme.hairline))
                        }.buttonStyle(.plain)
                            .popover(isPresented: $addingAlias, arrowEdge: .bottom) { aliasForm }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    CharacterFormLabel(title: "Character colour")
                    HStack(spacing: 12) {
                        ForEach(colors, id: \.self) { color in
                            Button { draft.color = color } label: {
                                Circle().fill(ScrivTheme.color(color).gradient).frame(width: 29, height: 29)
                                    .padding(4)
                                    .overlay(Circle().strokeBorder(draft.color == color ? ScrivTheme.secondary : .clear, lineWidth: 2))
                            }.buttonStyle(.plain).accessibilityLabel("\(color.capitalized) character colour")
                                .accessibilityAddTraits(draft.color == color ? .isSelected : [])
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var aliasForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add alias").font(.headline)
            TextField("Another name for this character", text: $alias).textFieldStyle(.roundedBorder)
                .focused($aliasFocused).onSubmit(addAlias)
            Text("New matches are suggestions until you confirm them.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { alias = ""; addingAlias = false }
                Button("Add", action: addAlias).buttonStyle(.borderedProminent)
                    .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(18).frame(width: 330).onAppear { aliasFocused = true }
    }

    private func notesField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CharacterFormLabel(title: title)
            TextEditor(text: text).font(.system(size: 18)).scrollContentBackground(.hidden)
                .padding(10).frame(height: 107).background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ScrivTheme.hairline))
                .accessibilityLabel(title)
        }
    }

    private func addAlias() {
        let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        draft.aliases = CharacterFormValues.addingAlias(clean, to: draft.aliases)
        alias = ""; addingAlias = false
    }

    private func save() {
        guard store.navigationContext == navigationContext else { dismiss(); return }
        guard !cleanName.isEmpty else { nameFocused = true; return }
        draft.name = cleanName
        let succeeded = isNew ? store.createCharacter(draft) : store.updateCharacter(draft)
        if succeeded { dismiss() }
        else { saveIssue = store.errorMessage ?? "The character could not be saved. Your changes are still here." }
    }
}

enum CharacterFormValues {
    static func addingAlias(_ alias: String, to existing: [String]) -> [String] {
        let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !existing.contains(where: { $0.localizedCaseInsensitiveCompare(clean) == .orderedSame }) else { return existing }
        return existing + [clean]
    }
}

struct CharacterFormLabel: View {
    let title: String
    var body: some View { Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(ScrivTheme.secondary) }
}

struct CharacterFormField: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 15).padding(.vertical, 11)
            .background(ScrivTheme.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ScrivTheme.hairline))
    }
}

struct CharacterFormNotice: View {
    let message: String
    var prominent = false
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "info.circle.fill").font(.system(size: 21)).foregroundStyle(prominent ? ScrivTheme.accent : ScrivTheme.secondary)
            Text(message).font(.system(size: 15)).foregroundStyle(ScrivTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17).padding(.vertical, 13)
            .background(ScrivTheme.accent.opacity(prominent ? 0.075 : 0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}
