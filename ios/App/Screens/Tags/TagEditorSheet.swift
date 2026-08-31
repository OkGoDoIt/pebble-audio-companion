import SwiftUI
import AppDB

/// The Tag Editor sheet (mockup 2.15, Q10 — ≈430pt detent): removable chips with one
/// tap-to-rename state (white fill, 1.5px tint border, caret), an "Add tag…" field,
/// AI suggestion chips ("+ budget…"), and the rename-applies-everywhere footer. Tags mutate
/// ONLY here (plan 2-C).
struct TagEditorSheet: View {
    let conversationId: String

    @Environment(\.dismiss) private var dismiss
    @State private var tags: [ConversationTag] = []
    @State private var suggestions: [String] = []
    @State private var addDraft = ""
    @State private var renamingTagId: String?
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetGrabber()

            SheetTitleRow(title: Copy.Tags.title) {
                Button(Copy.Common.done) {
                    commitRenameIfNeeded()
                    dismiss()
                }
                .font(AppFont.headline)
                .foregroundStyle(Tokens.tint)
                .buttonStyle(.plain)
            }

            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(tags, id: \.id) { tag in
                    if renamingTagId == tag.id {
                        renameChip
                    } else {
                        Button {
                            beginRename(tag)
                        } label: {
                            EditableTagChip(text: tag.name) {
                                remove(tag)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            addField

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Copy.Tags.suggestionsSection.uppercased())
                        .font(AppFont.sectionHeader)
                        .kerning(0.4)
                        .foregroundStyle(Tokens.meta)
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(suggestions, id: \.self) { name in
                            SuggestionChip(name: name) { add(name) }
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Text(Copy.Tags.footer)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.meta)
        }
        .padding(.horizontal, Tokens.screenMargin)
        .padding(.bottom, 18)
        .background(Tokens.ground)
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.hidden)
        .task { await reload() }
    }

    /// Mid-rename chip: white fill, 1.5px tint border, live caret (the TextField's own).
    private var renameChip: some View {
        HStack(spacing: 6) {
            TextField("", text: $renameDraft)
                .font(AppFont.editableChip)
                .foregroundStyle(Tokens.tint)
                .focused($renameFocused)
                .fixedSize()
                .submitLabel(.done)
                .onSubmit { commitRenameIfNeeded() }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 11)
        .background(Capsule().fill(Tokens.surface))
        .overlay(Capsule().strokeBorder(Tokens.tint, lineWidth: 1.5))
    }

    private var addField: some View {
        TextField(Copy.Tags.addTagPlaceholder, text: $addDraft)
            .font(AppFont.callout)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            .onSubmit {
                add(addDraft)
                addDraft = ""
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Tokens.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Tokens.barHairline, lineWidth: 0.5)))
    }

    // MARK: - Actions

    private func reload() async {
        let sources = AskLibraryDataSources.current.tagEditor
        tags = (try? await sources.tags(forConversation: conversationId)) ?? []
        suggestions = (try? await sources.suggestions(forConversation: conversationId)) ?? []
    }

    private func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            try? await AskLibraryDataSources.current.tagEditor.addTag(
                conversationId: conversationId, name: trimmed)
            await reload()
        }
    }

    private func remove(_ tag: ConversationTag) {
        Task {
            try? await AskLibraryDataSources.current.tagEditor.removeTag(
                conversationId: conversationId, tagId: tag.id)
            await reload()
        }
    }

    private func beginRename(_ tag: ConversationTag) {
        commitRenameIfNeeded()
        renamingTagId = tag.id
        renameDraft = tag.name
        renameFocused = true
    }

    private func commitRenameIfNeeded() {
        guard let tagId = renamingTagId else { return }
        let newName = renameDraft.trimmingCharacters(in: .whitespaces)
        renamingTagId = nil
        renameDraft = ""
        guard !newName.isEmpty else { return }
        Task {
            // Rename is GLOBAL (Q10) — applies everywhere.
            try? await AskLibraryDataSources.current.tagEditor.renameTag(
                tagId: tagId, to: newName)
            await reload()
        }
    }
}

#Preview("Tag editor") {
    Color.black.sheet(isPresented: .constant(true)) {
        TagEditorSheet(conversationId: "planning-work")
    }
}
