import SwiftUI

/// Saved Notes (mockup 2.16): back to the conversation, Share + "+" (re-enters the template
/// sheet, plan 6.9) + ⋯; title; provenance; cited bullets with 16×16 citation chips; the
/// moments footer; pills [Copy][Edit][Regenerate]. Edit gains Cancel (B19); Regenerate shows
/// inline progress + a result line (B10). No tab bar, no bottom bar.
struct SavedNotesScreen: View {
    let noteId: String

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model = SavedNotesViewModel()

    var body: some View {
        VStack(spacing: 0) {
            DetailNavBar(
                backLabel: model.note?.conversationTitle ?? Copy.Library.title,
                onBack: { dismiss() },
                shareText: model.note?.shareText,
                trailingExtras: {
                    Button {
                        model.showTemplates = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Tokens.tint)
                            .hitTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Copy.Conversation.notes)
                },
                menu: {
                    EllipsisMenu {
                        Button(Copy.Notes.copy) { model.copyNote() }
                        Button(Copy.Conversation.delete, role: .destructive) {
                            model.confirmDelete = true
                        }
                    }
                }
            )

            if let note = model.note {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.blockGap) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.title)
                                .font(AppFont.detailTitle)
                                .foregroundStyle(Tokens.label)
                            Text(note.provenance)
                                .font(AppFont.footnote)
                                .foregroundStyle(Tokens.meta)
                        }

                        if model.editing {
                            editCard
                        } else {
                            noteCard(note)
                            pillsRow
                            if let result = model.resultLine {
                                Text(result)
                                    .font(AppFont.footnote)
                                    .foregroundStyle(Tokens.meta)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .padding(.horizontal, Tokens.screenMargin)
                    .padding(.top, 4)
                    .padding(.bottom, Tokens.blockGap)
                }
            } else {
                Spacer()
            }
        }
        .background(Tokens.ground)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task(id: noteId) { await model.load(id: noteId) }
        .sheet(isPresented: $model.showTemplates) {
            if let conversationId = model.note?.conversationId {
                TemplateSheet(conversationId: conversationId) { note in
                    model.showTemplates = false
                    if note.id != noteId {
                        router.libraryPath.append(Route.note(id: note.id))
                    }
                }
            }
        }
        .confirmationDialog(
            Copy.Conversation.delete, isPresented: $model.confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Note", role: .destructive) {
                Haptics.destructiveConfirmed()
                Task {
                    try? await AskLibraryDataSources.current.notes.deleteNote(id: noteId)
                    dismiss()
                }
            }
        }
    }

    // MARK: - Note card

    private func noteCard(_ note: NoteDisplay) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(note.body.split(separator: "\n").enumerated()), id: \.offset) {
                    _, line in
                    CitedText(String(line), lineSpacing: 7) { number in
                        openCitation(note: note, number: number)
                    }
                }

                Rectangle().fill(Tokens.hairline).frame(height: 0.5)
                Button {
                    openCitation(note: note, number: note.citations.first?.number ?? 1)
                } label: {
                    HStack(spacing: 6) {
                        Text(note.momentsLabel)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tokens.chevron)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func openCitation(note: NoteDisplay, number: Int) {
        guard let citation = note.citations.first(where: { $0.number == number })
            ?? note.citations.first else { return }
        router.navigate(to: .conversation(id: citation.segmentId, atMs: nil))
    }

    // MARK: - Pills [Copy][Edit][Regenerate]

    private var pillsRow: some View {
        FlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
            ActionPill(title: model.copied ? "✓" : Copy.Notes.copy) { model.copyNote() }
            ActionPill(title: Copy.Common.edit) { model.beginEdit() }
            if model.regenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Copy.Notes.regenerate)
                        .font(AppFont.pill)
                        .foregroundStyle(Tokens.meta)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .background(Capsule().fill(Tokens.pillFill))
            } else {
                ActionPill(title: Copy.Notes.regenerate) { model.regenerate() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Edit mode (B19 — Cancel alongside Save)

    private var editCard: some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
            Card {
                TextEditor(text: $model.editDraft)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.label)
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
            }
            FlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                ActionPill(title: Copy.Common.cancel) { model.cancelEdit() }
                ActionPill(title: Copy.Common.save, style: .filled) {
                    model.saveEdit(noteId: noteId)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - View model

@MainActor
@Observable
final class SavedNotesViewModel {
    var note: NoteDisplay?
    var editing = false
    var editDraft = ""
    var regenerating = false
    var resultLine: String?
    var copied = false
    var showTemplates = false
    var confirmDelete = false

    func load(id: String) async {
        note = try? await AskLibraryDataSources.current.notes.note(id: id)
    }

    func copyNote() {
        guard let note else { return }
        UIPasteboard.general.string = note.shareText
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    func beginEdit() {
        guard let note else { return }
        editDraft = note.body
        editing = true
    }

    func cancelEdit() {
        editing = false
        editDraft = ""
    }

    func saveEdit(noteId: String) {
        guard let note else { return }
        let body = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        guard !body.isEmpty, body != note.body else { return }
        Task {
            try? await AskLibraryDataSources.current.notes.saveEdit(
                noteId: noteId, title: note.title, body: body)
            await load(id: noteId)
        }
    }

    /// B10: inline progress, then a result line ("Notes updated").
    func regenerate() {
        guard let note, !regenerating else { return }
        regenerating = true
        resultLine = nil
        Task {
            defer { regenerating = false }
            if let updated = try? await AskLibraryDataSources.current.notes.regenerate(
                noteId: note.id)
            {
                self.note = updated
                resultLine = Copy.Notes.updated
            } else {
                resultLine = nil
            }
            try? await Task.sleep(for: .seconds(4))
            resultLine = nil
        }
    }
}

#Preview("Saved notes") {
    NavigationStack {
        SavedNotesScreen(noteId: "meeting-notes")
    }
    .environment(AppRouter())
    .tint(Tokens.tint)
}
