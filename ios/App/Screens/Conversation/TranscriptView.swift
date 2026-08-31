import SwiftUI
import AppDB

/// The transcript card (mockup 2.6): speaker-colored turns (you = tint, other = teal,
/// unresolved = captured marker + dimmed text), inline quiet/missing markers with hairlines
/// (interruptions render where they happened — never banners), and the centered provenance
/// line. Tapping a speaker name opens the rename sheet (plan 6.3).
struct TranscriptView: View {
    let transcript: [TranscriptItem]
    let provenance: String?
    /// Q16 — stamps read in the zone the audio was recorded in, not the one you're in now.
    var timeZone: TimeZone = .current
    /// Nil where names aren't editable yet (the live screen, whose diarization is still
    /// provisional): the name renders as plain text rather than a button that does nothing.
    var onSpeakerTap: ((TranscriptTurn) -> Void)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(blocks) { block in
                    switch block {
                    case .speech(_, let turns):
                        speechBlock(turns)
                    case .quiet(let marker):
                        markerRow(marker, color: Tokens.faint, rule: Tokens.hairline)
                    case .missing(let marker):
                        markerRow(marker, color: Tokens.missing, rule: Tokens.missingHair)
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
                    previous.name == turn.name, previous.role == turn.role,
                    previous.isInProgress == turn.isInProgress
                {
                    turns.append(turn)
                    blocks[blocks.count - 1] = .speech(id: id, turns: turns)
                } else {
                    blocks.append(.speech(id: turn.id, turns: [turn]))
                }
            case .quiet(let marker):
                blocks.append(.quiet(marker))
            case .missing(let marker):
                blocks.append(.missing(marker))
            }
        }
        return blocks
    }

    private func speechBlock(_ turns: [TranscriptTurn]) -> some View {
        let lead = turns[0]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let onSpeakerTap {
                    Button {
                        onSpeakerTap(lead)
                    } label: {
                        speakerName(lead).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename \(lead.name)")
                } else {
                    speakerName(lead)
                }

                // The growing tail carries no stamp: its words are still being revised, so a
                // final-looking time would be a lie.
                if let startedAt = lead.startedAt, !lead.isInProgress {
                    TranscriptStamp(date: startedAt, timeZone: timeZone)
                }
                Spacer(minLength: 0)
            }

            ForEach(turns) { turn in
                Text(turn.text)
                    .font(AppFont.callout)
                    .foregroundStyle(
                        turn.role == .unresolved || turn.isInProgress
                            ? Tokens.meta : Tokens.label)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    // One VoiceOver element per turn, carrying the time the eye reads off
                    // the stamp beside the name.
                    .accessibilityLabel(
                        Copy.A11y.transcriptTurn(
                            time: turn.startedAt.map { TranscriptStamp.text($0, in: timeZone) },
                            speaker: turn.name,
                            text: turn.text))
            }
        }
    }

    private func speakerName(_ turn: TranscriptTurn) -> some View {
        HStack(spacing: 5) {
            if turn.role == .unresolved {
                StatusDot(color: Tokens.captured, size: .legend)
            }
            Text(turn.name)
                .font(AppFont.speaker)
                .foregroundStyle(speakerColor(turn.role))
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
    private func markerRow(_ marker: TranscriptMarker, color: Color, rule: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Rectangle().fill(rule).frame(height: 0.5)
                markerText(marker.text, color: color)
                    .fixedSize()
                Rectangle().fill(rule).frame(height: 0.5)
            }
            VStack(spacing: 5) {
                Rectangle().fill(rule).frame(height: 0.5)
                markerText(marker.text, color: color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(
            marker.startedAt.map { Copy.A11y.transcriptMarker(
                time: TranscriptStamp.text($0, in: timeZone), text: marker.text) }
                ?? marker.text)
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
    case quiet(TranscriptMarker)
    case missing(TranscriptMarker)

    var id: String {
        switch self {
        case .speech(let id, _): return id
        case .quiet(let marker), .missing(let marker): return marker.id
        }
    }
}

/// The clock stamp beside a speaker name: 11pt `faint`, monospaced digits so a column of
/// them doesn't shiver, formatted in the recording's own zone (Q16) and by the user's
/// 12/24-hour setting — never a hand-built string.
struct TranscriptStamp: View {
    let date: Date
    var timeZone: TimeZone = .current

    static func text(_ date: Date, in timeZone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
    }

    var body: some View {
        Text(Self.text(date, in: timeZone))
            .font(AppFont.micro.monospacedDigit())
            .foregroundStyle(Tokens.faint)
            .lineLimit(1)
            .accessibilityHidden(true)
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
