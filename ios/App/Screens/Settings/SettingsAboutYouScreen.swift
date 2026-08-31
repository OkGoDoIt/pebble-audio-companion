import SwiftUI

/// Settings · About You (artboard 2.13): explainer ON TOP (the one screen whose footnote
/// leads), bio card with a modal editor (Cancel + Save — B19), import rows with inline
/// progress, confirmed destructive clear.
struct SettingsAboutYouScreen: View {
    private var aboutYou: AboutYouSource { SettingsDataSources.current.aboutYou }

    @State private var editingBio = false
    @State private var confirmClear = false

    var body: some View {
        SettingsScroll {
            SettingsFooter(text: Copy.Settings.AboutYou.explainer)

            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text(aboutYou.bio)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.secondaryBody)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        editingBio = true
                    } label: {
                        Text(Copy.Common.edit)
                            .font(AppFont.chip)
                            .foregroundStyle(Tokens.tint)
                            .padding(.leading, 12)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            ListCard {
                importRow(
                    title: Copy.Settings.AboutYou.contacts,
                    summary: aboutYou.contactsSummary,
                    importing: aboutYou.contactsImporting,
                    action: aboutYou.importContacts
                )
                importRow(
                    title: Copy.Settings.AboutYou.calendar,
                    summary: aboutYou.calendarSummary,
                    importing: aboutYou.calendarImporting,
                    action: aboutYou.importCalendar
                )
            }

            ListCard {
                DestructiveRow(title: Copy.Settings.AboutYou.clearImported) {
                    confirmClear = true
                }
            }
        }
        .navigationTitle(Copy.Settings.AboutYou.title)
        .sheet(isPresented: $editingBio) {
            BioEditorSheet(source: aboutYou)
        }
        .confirmationDialog(
            Copy.Settings.AboutYou.clearImported,
            isPresented: $confirmClear,
            titleVisibility: .hidden
        ) {
            Button("Clear Imported Context", role: .destructive) {
                aboutYou.clearImported()
            }
        }
    }

    /// Tap re-imports; progress shows inline where the value sits.
    private func importRow(
        title: String, summary: String?, importing: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                Spacer(minLength: 10)
                if importing {
                    ProgressView().controlSize(.small)
                } else {
                    Text(summary ?? Copy.Settings.AboutYou.notImported)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.meta)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Modal bio editor — Cancel discards, Save commits (B19: no modal edit without Cancel).
private struct BioEditorSheet: View {
    let source: AboutYouSource

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $draft)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.secondaryBody)
                .scrollContentBackground(.hidden)
                .padding(Tokens.screenMargin)
                .background(Tokens.surface)
                .navigationTitle(Copy.Settings.AboutYou.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Copy.Common.cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Copy.Common.save) {
                            source.bio = draft
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
        }
        .onAppear { draft = source.bio }
        .tint(Tokens.tint)
    }
}

#Preview("About You") {
    NavigationStack {
        SettingsAboutYouScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
