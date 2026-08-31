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
                        router.push(.note(id: note.id))
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
                MarkdownText(note.body, lineSpacing: 7) { number in
                    openCitation(number: number)
                }

                // Only when there is somewhere to go: a note the model wrote without citing
                // anything used to show an empty footer with a chevron that led nowhere.
                if let moments = model.momentsLabel {
                    Rectangle().fill(Tokens.hairline).frame(height: 0.5)
                    Button {
                        openCitation(number: note.citations.first?.number ?? 0)
                    } label: {
                        HStack(spacing: 6) {
                            Text(moments)
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
    }

    /// A chip names a SEGMENT; the screen it opens is a CONVERSATION, cued to where that
    /// segment sits on the scrubber and marked so the cited stretch is what you land on.
    private func openCitation(number: Int) {
        guard let target = model.target(forCitation: number) else { return }
        router.navigate(
            to: .conversation(
                id: target.conversationId,
                atMs: target.mediaOffsetMs,
                focusSegmentId: target.segmentId))
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
    /// Resolved citation destinations, keyed by cited segment id. Resolution is a lookup
    /// (which conversation holds the segment, where it starts on the scrubber), so it happens
    /// once per load rather than on every tap.
    private(set) var targets: [String: CitationTarget] = [:]

    func load(id: String) async {
        note = try? await AskLibraryDataSources.current.notes.note(id: id)
        await resolveTargets()
    }

    private func resolveTargets() async {
        guard let note else {
            targets = [:]
            return
        }
        var resolved: [String: CitationTarget] = [:]
        for citation in note.citations where resolved[citation.segmentId] == nil {
            resolved[citation.segmentId] = await AskLibraryDataSources.current.ask
                .citationTarget(citedId: citation.segmentId)
        }
        targets = resolved.compactMapValues { $0 }
    }

    /// No fallback to "the first citation": a chip whose number the note never recorded (a
    /// model citing [9] with three sources, or an answer imported from the old app) must do
    /// nothing rather than open a moment it does not name.
    func target(forCitation number: Int) -> CitationTarget? {
        guard let note, let citation = note.citations.first(where: { $0.number == number })
        else { return nil }
        return targets[citation.segmentId]
    }

    /// "2 moments · 9:36 PM, 9:51 PM" — the times of the moments this note actually cites.
    /// Nil when it cites none, which is when the footer must not appear at all.
    var momentsLabel: String? {
        guard let note else { return nil }
        var seen = Set<String>()
        var labels: [String] = []
        for citation in note.citations {
            guard let target = targets[citation.segmentId],
                seen.insert(target.segmentId).inserted
            else { continue }
            labels.append(
                target.startedAt.map { TimeFmt.time($0) } ?? target.conversationTitle)
        }
        if labels.isEmpty {
            return note.momentsLabel.isEmpty ? nil : note.momentsLabel
        }
        return Copy.Ask.moments(labels.count, labels.joined(separator: ", "))
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
