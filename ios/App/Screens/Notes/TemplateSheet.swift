import SwiftUI

/// The Notes template sheet (plan 6.9): Meeting notes · Decisions · Follow-up email ·
/// Study notes · Interview highlights · Custom prompt… (free text + "Save as template";
/// saved templates join the list with swipe-to-delete). Generation shows inline progress
/// (B10) and opens the result as Saved Notes.
struct TemplateSheet: View {
    let conversationId: String
    let onGenerated: (NoteDisplay) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var templates: [NoteTemplate] = []
    @State private var generatingId: String?
    @State private var showCustomPrompt = false
    @State private var customPrompt = ""
    @State private var customTitle = ""
    @State private var saveAsTemplate = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(templates) { template in
                    Button {
                        generate(template)
                    } label: {
                        HStack {
                            Text(template.title)
                                .font(AppFont.callout)
                                .foregroundStyle(Tokens.label)
                            Spacer()
                            if generatingId == template.id {
                                ProgressView()
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
            .navigationTitle(Copy.Conversation.notes)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Common.cancel) { dismiss() }
                }
            }
            .disabled(generatingId != nil)
            .navigationDestination(isPresented: $showCustomPrompt) {
                customPromptForm
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(generatingId != nil)
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
                if generatingId != nil {
                    ProgressView()
                } else {
                    Button(Copy.Common.done) { generateCustom() }
                        .disabled(
                            customPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func reload() async {
        templates = (try? await AskLibraryDataSources.current.notes.templates()) ?? []
    }

    private func generate(_ template: NoteTemplate) {
        guard generatingId == nil else { return }
        generatingId = template.id
        Task {
            defer { generatingId = nil }
            if let note = try? await AskLibraryDataSources.current.notes.generate(
                conversationId: conversationId, template: template,
                customPrompt: template.prompt)
            {
                onGenerated(note)
            }
        }
    }

    private func generateCustom() {
        let prompt = customPrompt.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty, generatingId == nil else { return }
        let title = customTitle.trimmingCharacters(in: .whitespaces)
        let template = NoteTemplate(
            id: "custom-draft", title: title.isEmpty ? Copy.Conversation.notes : title,
            isCustom: true, prompt: prompt)
        generatingId = template.id
        Task {
            defer { generatingId = nil }
            if saveAsTemplate {
                try? await AskLibraryDataSources.current.notes.saveTemplate(
                    title: template.title, prompt: prompt)
            }
            if let note = try? await AskLibraryDataSources.current.notes.generate(
                conversationId: conversationId, template: template, customPrompt: prompt)
            {
                onGenerated(note)
            }
        }
    }
}
