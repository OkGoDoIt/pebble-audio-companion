import SwiftUI

/// The Notes template sheet (plan 6.9): Extended summary · Meeting notes · Decisions ·
/// Follow-up email · Study notes · Interview highlights · Custom prompt… (free text +
/// "Save as template"; saved templates join the list with swipe-to-delete).
///
/// A tap here **starts** a note and gets out of the way. It used to finish one: the sheet set
/// `generatingId`, disabled itself, turned off interactive dismissal and awaited the model, so a
/// thirty-second call over a long conversation was thirty seconds of an app that could not be
/// used. The user's report was exactly that. Now the tap enqueues a `NoteJobCenter` job and the
/// sheet dismisses immediately; `NoteJobDock`, mounted app-wide in `RootView`, reports it and
/// hands the finished note back wherever the user has got to.
///
/// So there is no progress state on this screen any more — with one exception. A template whose
/// job is *already* running says so on the row, because the dedupe in `NoteJobCenter.enqueue`
/// makes a second tap a no-op, and a no-op that looks like a dead button is worse than the wait
/// we just removed.
struct TemplateSheet: View {
    let conversationId: String
    /// Shown on the dock's card while the note is being written, so a user who has wandered off
    /// can tell two running jobs apart. Optional because the conversation screen does not have
    /// to know about the dock to open this sheet — the finished note carries the title anyway.
    var conversationTitle: String? = nil
    /// "Show the person this note." No longer a *completion* path — the sheet is gone long before
    /// a generated note exists, and the dock owns that hand-off — but still needed, because the
    /// sheet now lists the notes this conversation already has and tapping one has to go
    /// somewhere. Optional so a presenter with nowhere to push simply doesn't offer them.
    var onOpenNote: ((NoteDisplay) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var jobs = NoteJobCenter.shared
    @State private var templates: [NoteTemplate] = []
    /// The notes this conversation already has, so the sheet is the whole menu rather than half
    /// of it. Loaded alongside the templates on every appearance.
    @State private var notes: [NoteDisplay] = []
    @State private var showCustomPrompt = false
    @State private var customPrompt = ""
    @State private var customTitle = ""
    @State private var saveAsTemplate = false

    var body: some View {
        NavigationStack {
            List {
                // What this conversation already has, above what it could have. The bottom bar
                // used to open the first existing note DIRECTLY and only show this sheet when
                // there were none, which made [Notes] a one-shot button — a second template was
                // unreachable once any note existed. Opening the sheet every time fixes that, but
                // only if the notes you already wrote are still one tap away. They are, here.
                if !notes.isEmpty, let onOpenNote {
                    Section(Copy.NoteJobs.existingNotesHeader) {
                        ForEach(notes) { note in
                            Button {
                                dismiss()
                                onOpenNote(note)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(note.title)
                                            .font(AppFont.callout)
                                            .foregroundStyle(Tokens.label)
                                        Text(note.provenance)
                                            .font(AppFont.footnote)
                                            .foregroundStyle(Tokens.meta)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Tokens.chevron)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section(notes.isEmpty ? "" : Copy.NoteJobs.newNoteHeader) {
                    ForEach(templates) { template in
                        Button {
                            generate(template)
                        } label: {
                            HStack {
                                Text(template.title)
                                    .font(AppFont.callout)
                                    .foregroundStyle(Tokens.label)
                                Spacer()
                                if isRunning(template) {
                                    Text(Copy.NoteJobs.writingShort)
                                        .font(AppFont.footnote)
                                        .foregroundStyle(Tokens.meta)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .deleteDisabled(!template.isCustom)
                    }
                    .onDelete { offsets in
                        for offset in offsets where templates[offset].isCustom {
                            let id = templates[offset].id
                            Task {
                                try? await AskLibraryDataSources.current.notes.deleteTemplate(id: id)
                                await reload()
                            }
                        }
                    }

                    Button {
                        showCustomPrompt = true
                    } label: {
                        Text(Copy.Notes.templateCustomPrompt)
                            .font(AppFont.callout)
                            .foregroundStyle(Tokens.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(Copy.Conversation.notes)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Common.cancel) { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showCustomPrompt) {
                customPromptForm
            }
        }
        .presentationDetents([.medium, .large])
        .task { await reload() }
    }

    private var customPromptForm: some View {
        Form {
            Section {
                TextField("Title", text: $customTitle)
                TextEditor(text: $customPrompt)
                    .frame(minHeight: 120)
                    .font(AppFont.callout)
            }
            Section {
                Toggle(Copy.Notes.saveAsTemplate, isOn: $saveAsTemplate)
                    .tint(Tokens.good)
            }
        }
        .navigationTitle(Copy.Notes.templateCustomPrompt)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(Copy.Common.done) { generateCustom() }
                    .disabled(customPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func reload() async {
        let source = AskLibraryDataSources.current.notes
        templates = (try? await source.templates()) ?? []
        notes = (try? await source.notes(conversationId: conversationId)) ?? []
    }

    /// Is this exact request already in flight? Read from the job center rather than from local
    /// state, because the job outlives this sheet — reopening it mid-generation has to show the
    /// same truth the dock is showing.
    private func isRunning(_ template: NoteTemplate) -> Bool {
        jobs.isRunning(
            conversationId: conversationId, template: template, customPrompt: template.prompt)
    }

    /// Start it and leave. Everything the user needs from here on lives on the dock.
    private func generate(_ template: NoteTemplate) {
        jobs.enqueue(
            conversationId: conversationId,
            conversationTitle: conversationTitle,
            template: template,
            customPrompt: template.prompt
        )
        dismiss()
    }

    private func generateCustom() {
        let prompt = customPrompt.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }
        let title = customTitle.trimmingCharacters(in: .whitespaces)
        let template = NoteTemplate(
            id: "custom-draft", title: title.isEmpty ? Copy.Conversation.notes : title,
            isCustom: true, prompt: prompt)
        if saveAsTemplate {
            // Unstructured on purpose. This is a plain `Task`, not `.task {}`, so dismissing the
            // sheet on the next line does not take the save with it — the local copies below are
            // all it needs from a view that is about to stop existing.
            let templateTitle = template.title
            Task {
                try? await AskLibraryDataSources.current.notes.saveTemplate(
                    title: templateTitle, prompt: prompt)
            }
        }
        jobs.enqueue(
            conversationId: conversationId,
            conversationTitle: conversationTitle,
            template: template,
            customPrompt: prompt
        )
        dismiss()
    }
}
