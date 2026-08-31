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
    /// The member a citation chip sent us to. Its rows are banded and carry the play control;
    /// nil on every ordinary open, which is most of them.
    var focusSegmentId: String?
    /// Nil where names aren't editable yet (the live screen, whose diarization is still
    /// provisional): the name renders as plain text rather than a button that does nothing.
    var onSpeakerTap: ((TranscriptTurn) -> Void)?
    /// Play the conversation from a position on its scrubber. Nil when there is no audio.
    var onPlayFrom: ((Int64) -> Void)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(runs) { run in
                    if run.isCited {
                        citedBand(run)
                    } else {
                        ForEach(run.blocks) { block in
                            blockRow(block)
                        }
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

    @ViewBuilder
    private func blockRow(_ block: TranscriptBlock) -> some View {
        switch block {
        case .speech(_, let turns):
            speechBlock(turns)
        case .quiet(let marker):
            markerRow(marker, color: Tokens.faint, rule: Tokens.hairline)
        case .missing(let marker):
            markerRow(marker, color: Tokens.missing, rule: Tokens.missingHair)
        }
    }

    /// The stretch a citation points at: tinted, ruled on the leading edge, and headed by the
    /// one thing you came here to do. Arriving from a chip should answer "which part?" before
    /// you have read a word.
    private func citedBand(_ run: BlockRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(Copy.Conversation.citedMoment)
                    .font(AppFont.micro)
                    .foregroundStyle(Tokens.tint)
                Spacer(minLength: 0)
                if let onPlayFrom, let offset = run.mediaOffsetMs {
                    Button {
                        onPlayFrom(offset)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(Copy.Conversation.playFromHere)
                                .font(AppFont.tagChip)
                        }
                        .foregroundStyle(Tokens.tint)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 30)
                        .background(Capsule().fill(Tokens.tintFill12))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(run.blocks) { block in
                blockRow(block)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Tokens.tintFill10)
        )
        .overlay(alignment: .leading) {
            Capsule().fill(Tokens.tint).frame(width: 2).padding(.vertical, 6)
        }
        .id(Self.citedAnchor)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Conversation.citedMoment)
    }

    /// Scroll target for the cited band. A member's blocks are contiguous, so there is at most
    /// one of these in a transcript.
    static let citedAnchor = "transcript-cited-moment"

    /// Blocks in reading order, split into runs by whether they belong to the cited member, so
    /// one citation draws ONE band even though its speech is many speaker blocks.
    private var runs: [BlockRun] {
        var runs: [BlockRun] = []
        for block in blocks {
            let cited = focusSegmentId != nil && block.segmentId == focusSegmentId
            if var last = runs.last, last.isCited == cited {
                last.blocks.append(block)
                runs[runs.count - 1] = last
            } else {
                runs.append(BlockRun(blocks: [block], isCited: cited))
            }
        }
        return runs
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

            // Provider fragments of one person's speech are paragraphs, not one run-on
            // block: they get their own spacing under the single name header.
            VStack(alignment: .leading, spacing: 7) {
                ForEach(turns) { turn in
                    Text(turn.text)
                        .font(AppFont.callout)
                        // Dimming means PROVISIONAL — words still being revised. It used to
                        // also mean "we don't know who said this", which dimmed every turn of
                        // every final transcript that had no speaker assignments (all of a
                        // migrated library), making finished work read as a draft. An
                        // unresolved speaker is marked at the NAME, by the captured dot and
                        // the muted name colour; the words themselves are final.
                        .foregroundStyle(turn.isInProgress ? Tokens.meta : Tokens.label)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        // One VoiceOver element per turn, carrying the time the eye reads
                        // off the stamp beside the name.
                        .accessibilityLabel(
                            Copy.A11y.transcriptTurn(
                                time: turn.startedAt.map {
                                    TranscriptStamp.text($0, in: timeZone)
                                },
                                speaker: turn.name,
                                text: turn.text))
                }
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

    var segmentId: String {
        switch self {
        case .speech(_, let turns): return turns.first?.segmentId ?? ""
        case .quiet(let marker), .missing(let marker): return marker.segmentId
        }
    }

    /// Where this block starts on the conversation's scrubber; markers inherit nothing, so a
    /// run takes the first position any of its blocks knows.
    var mediaOffsetMs: Int64? {
        if case .speech(_, let turns) = self { return turns.first?.mediaOffsetMs }
        return nil
    }
}

/// Consecutive blocks that are all cited, or all not.
private struct BlockRun: Identifiable {
    var blocks: [TranscriptBlock]
    var isCited: Bool

    var id: String { "\(isCited)-\(blocks.first?.id ?? "")" }
    var mediaOffsetMs: Int64? { blocks.compactMap(\.mediaOffsetMs).first }
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
