import SwiftUI
import AppDB

/// The transcript card (mockup 2.6): speaker-colored turns (you = tint, other = teal,
/// unresolved = captured marker + dimmed text), inline quiet/missing markers with hairlines
/// (interruptions render where they happened — never banners), and the centered provenance
/// line. Tapping a speaker name opens the rename sheet (plan 6.3).
struct TranscriptView: View {
    let transcript: [TranscriptItem]
    let provenance: String?
    let onSpeakerTap: (TranscriptTurn) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(transcript) { item in
                    switch item {
                    case .turn(let turn):
                        turnView(turn)
                    case .quiet(_, let duration):
                        markerRow(text: duration, color: Tokens.faint, rule: Tokens.hairline)
                    case .missing(_, let marker):
                        markerRow(text: marker, color: Tokens.missing, rule: Tokens.missingHair)
                    }
                }
                if let provenance {
                    Text(provenance)
                        .font(AppFont.micro)
                        .foregroundStyle(Tokens.faint)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func turnView(_ turn: TranscriptTurn) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                onSpeakerTap(turn)
            } label: {
                HStack(spacing: 5) {
                    if turn.role == .unresolved {
                        StatusDot(color: Tokens.captured, size: .legend)
                    }
                    Text(turn.name)
                        .font(AppFont.speaker)
                        .foregroundStyle(speakerColor(turn.role))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename \(turn.name)")

            Text(turn.text)
                .font(AppFont.callout)
                .foregroundStyle(turn.role == .unresolved ? Tokens.meta : Tokens.label)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func speakerColor(_ role: SpeakerRole) -> Color {
        switch role {
        case .you: return Tokens.tint
        case .other: return Tokens.speakerOther
        case .unresolved: return Tokens.meta
        }
    }

    private func markerRow(text: String, color: Color, rule: Color) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(rule).frame(height: 0.5)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .fixedSize()
            Rectangle().fill(rule).frame(height: 0.5)
        }
    }
}

// MARK: - Speaker rename sheet (plan 6.3)

/// Offers the known-people list first, then free text. The choice applies to every turn
/// carrying the same diarization label in this conversation; renames of a person apply
/// everywhere via the people registry.
struct SpeakerRenameSheet: View {
    let conversationId: String
    let turn: TranscriptTurn
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var people: [Person] = []
    @State private var freeText = ""

    var body: some View {
        NavigationStack {
            List {
                if !people.isEmpty {
                    Section {
                        ForEach(people, id: \.id) { person in
                            Button {
                                assign(person.name)
                            } label: {
                                HStack {
                                    Text(person.name)
                                        .font(AppFont.callout)
                                        .foregroundStyle(Tokens.label)
                                    Spacer()
                                    if person.name == turn.name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Tokens.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    HStack {
                        TextField("Name", text: $freeText)
                            .font(AppFont.callout)
                            .submitLabel(.done)
                            .onSubmit { assignFreeText() }
                        Button(Copy.Common.save) { assignFreeText() }
                            .font(AppFont.cardHead)
                            .foregroundStyle(Tokens.tint)
                            .buttonStyle(.plain)
                            .disabled(freeText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle(turn.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Common.cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .task {
            people = (try? await AskLibraryDataSources.current.people.people()) ?? []
        }
    }

    private func assignFreeText() {
        let trimmed = freeText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        assign(trimmed)
    }

    private func assign(_ name: String) {
        Task {
            try? await AskLibraryDataSources.current.people.assign(
                conversationId: conversationId, label: turn.speakerLabel, personName: name)
            onDone()
            dismiss()
        }
    }
}
