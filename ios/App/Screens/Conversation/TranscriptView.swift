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
                ForEach(blocks) { block in
                    switch block {
                    case .speech(_, let turns):
                        speechBlock(turns)
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
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
        }
    }

    /// Consecutive turns by the same speaker read as one person still talking, so they get
    /// ONE name header and a paragraph each. Real transcripts arrive split at provider
    /// segment boundaries — mid-sentence, often — and repeating "Speaker 1" over every
    /// fragment turned the card into a wall of labels.
    private var blocks: [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        for item in transcript {
            switch item {
            case .turn(let turn):
                if case .speech(let id, var turns) = blocks.last,
                    let previous = turns.last, previous.speakerLabel == turn.speakerLabel,
                    previous.name == turn.name, previous.role == turn.role
                {
                    turns.append(turn)
                    blocks[blocks.count - 1] = .speech(id: id, turns: turns)
                } else {
                    blocks.append(.speech(id: turn.id, turns: [turn]))
                }
            case .quiet(let id, let duration):
                blocks.append(.quiet(id: id, duration: duration))
            case .missing(let id, let marker):
                blocks.append(.missing(id: id, marker: marker))
            }
        }
        return blocks
    }

    private func speechBlock(_ turns: [TranscriptTurn]) -> some View {
        let lead = turns[0]
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                onSpeakerTap(lead)
            } label: {
                HStack(spacing: 5) {
                    if lead.role == .unresolved {
                        StatusDot(color: Tokens.captured, size: .legend)
                    }
                    Text(lead.name)
                        .font(AppFont.speaker)
                        .foregroundStyle(speakerColor(lead.role))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename \(lead.name)")

            ForEach(turns) { turn in
                Text(turn.text)
                    .font(AppFont.callout)
                    .foregroundStyle(turn.role == .unresolved ? Tokens.meta : Tokens.label)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func speakerColor(_ role: SpeakerRole) -> Color {
        switch role {
        case .you: return Tokens.tint
        case .other: return Tokens.speakerOther
        case .unresolved: return Tokens.meta
        }
    }

    /// A break in the transcript. Short markers ("quiet for 40 sec") sit between hairlines,
    /// the artboard's look; long ones ("audio interrupted for 12 sec (watch buffer filled
    /// while disconnected)") wrap under a single rule instead.
    ///
    /// The `.fixedSize()` this replaces made the long form as wide as its one unbroken line —
    /// which is wider than the phone, and SwiftUI centers an oversized child, so the ENTIRE
    /// screen (nav bar, header, player, bottom bar) shifted left and clipped on both edges.
    /// Loss markers are exactly the content that must never be cut off.
    private func markerRow(text: String, color: Color, rule: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Rectangle().fill(rule).frame(height: 0.5)
                markerText(text, color: color)
                    .fixedSize()
                Rectangle().fill(rule).frame(height: 0.5)
            }
            VStack(spacing: 5) {
                Rectangle().fill(rule).frame(height: 0.5)
                markerText(text, color: color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(text)
    }

    private func markerText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

/// One rendered row of the transcript: a run of consecutive same-speaker turns, or a marker.
private enum TranscriptBlock: Identifiable {
    case speech(id: String, turns: [TranscriptTurn])
    case quiet(id: String, duration: String)
    case missing(id: String, marker: String)

    var id: String {
        switch self {
        case .speech(let id, _): return id
        case .quiet(let id, _): return id
        case .missing(let id, _): return id
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
