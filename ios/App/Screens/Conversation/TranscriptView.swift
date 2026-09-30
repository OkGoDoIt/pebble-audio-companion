import SwiftUI
import AppDB

/// The transcript card (mockup 2.6): speaker-colored turns (you = tint, other = teal,
/// unresolved = captured marker + dimmed text), inline quiet/missing markers with hairlines
/// (interruptions render where they happened — never banners), and the centered provenance
/// line. Tapping a speaker name opens the rename sheet (plan 6.3).
///
/// While the conversation is playing it also follows the audio: the paragraph being spoken
/// stays at full strength while the rest steps back, and inside it the word being spoken is
/// highlighted. Tapping any paragraph moves playback to the word under the finger. Everything
/// that drives that is optional and defaulted, because the live screen renders this same view
/// with no player behind it.
struct TranscriptView: View {
    let transcript: [TranscriptItem]
    let provenance: String?
    /// Q16 — stamps read in the zone the audio was recorded in, not the one you're in now.
    var timeZone: TimeZone = .current
    /// The stretch a citation chip sent us to. Its rows are banded and carry the play
    /// control; nil on every ordinary open, which is most of them. A `.moment` focus bands
    /// nothing — the screen only scrolls to it.
    var focus: TranscriptFocus?
    /// Nil where names aren't editable yet (the live screen, whose diarization is still
    /// provisional): the name renders as plain text rather than a button that does nothing.
    var onSpeakerTap: ((TranscriptTurn) -> Void)?
    /// Play the conversation from a position on its scrubber. Nil when there is no audio.
    var onPlayFrom: ((Int64) -> Void)?
    /// Move the scrubber without starting playback — a single tap on the words.
    var onSeekTo: ((Int64) -> Void)?
    /// Where the audio is right now. Nil wherever there is no player (the live screen), and the
    /// transcript then renders exactly as it always did.
    var playhead: TranscriptPlayhead?

    /// Measured height of one line of transcript body text. Measured rather than assumed
    /// because Dynamic Type moves it, and a tap on a paragraph is resolved to a word by
    /// counting lines. See `TranscriptTapGeometry`.
    @State private var bodyLineHeight: CGFloat = 0

    /// The `.lineSpacing` every transcript paragraph is rendered with. Named because the tap
    /// geometry has to divide by it, and a silent disagreement between the two would put every
    /// tap on the wrong line.
    static let bodyLineSpacing: CGFloat = 4

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
        // A hidden one-liner in an overlay: overlays do not participate in layout, so this
        // measures the body line height without occupying a pixel of the card.
        .overlay(alignment: .topLeading) {
            Text(verbatim: "Ag")
                .font(AppFont.callout)
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    bodyLineHeight = height
                }
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func blockRow(_ block: TranscriptBlock) -> some View {
        switch block {
        case .speech(_, let turns, _):
            speechBlock(turns)
        // Markers are addressable like paragraphs (`.id(turn.id)` below): a moment inside a
        // quiet stretch or an interruption lands on the marker that describes it.
        case .quiet(let marker, _):
            TranscriptMarkerRow(
                marker: marker, color: Tokens.faint, rule: Tokens.hairline, timeZone: timeZone)
                .id(marker.id)
        case .missing(let marker, _):
            TranscriptMarkerRow(
                marker: marker, color: Tokens.missing, rule: Tokens.missingHair,
                timeZone: timeZone)
                .id(marker.id)
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
            let cited = block.isCited
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
                let cited = isCited(segmentId: turn.segmentId, at: turn.startedAt)
                // Citedness joins the grouping key: a citation that starts partway through one
                // person still talking has to break the block, or the band would swallow lines
                // the note never drew on.
                if case .speech(let id, var turns, let wasCited) = blocks.last,
                    wasCited == cited,
                    let previous = turns.last, previous.speakerLabel == turn.speakerLabel,
                    previous.name == turn.name, previous.role == turn.role,
                    previous.isInProgress == turn.isInProgress
                {
                    turns.append(turn)
                    blocks[blocks.count - 1] = .speech(id: id, turns: turns, isCited: cited)
                } else {
                    blocks.append(.speech(id: turn.id, turns: [turn], isCited: cited))
                }
            case .quiet(let marker):
                blocks.append(
                    .quiet(marker, isCited: isCited(segmentId: marker.segmentId, at: marker.startedAt)))
            case .missing(let marker):
                blocks.append(
                    .missing(marker, isCited: isCited(segmentId: marker.segmentId, at: marker.startedAt)))
            }
        }
        return blocks
    }

    /// Only a citation marks lines. A moment is a place to land, not a quote: banding the row
    /// it lands on would claim somebody pointed at those words.
    private func isCited(segmentId: String, at startedAt: Date?) -> Bool {
        guard let focus, focus.style == .citation else { return false }
        return focus.contains(segmentId: segmentId, at: startedAt)
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
                    TranscriptTurnText(
                        turn: turn,
                        timeZone: timeZone,
                        playhead: playhead,
                        lineHeight: bodyLineHeight,
                        onSeekTo: onSeekTo,
                        onPlayFrom: onPlayFrom
                    )
                    // Addressable by `ScrollViewReader` so playback can keep the paragraph
                    // being spoken on screen.
                    .id(turn.id)
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
}

// MARK: - One paragraph, and the two-way tie to the audio

/// One paragraph of the transcript — the whole follow-along behaviour lives here.
///
/// **Rendering** is one `Text` built from an `AttributedString`, so the word being spoken is
/// highlighted without splitting the paragraph into per-word views. That matters twice: the
/// paragraph is still line-broken by the text system rather than by a hand-rolled flow layout,
/// and a two-hour transcript stays a few hundred views instead of tens of thousands.
///
/// **Touch** is a single `SpatialTapGesture`, whose location `TranscriptTapGeometry` resolves to
/// a word. The first tap seeks there; a second tap inside the double-tap window also starts
/// playback. There is deliberately no `.onTapGesture(count: 2)` beside the single-tap one: that
/// pairing makes EVERY single tap sit out the double-tap window before anything happens, and on
/// a transcript the single tap is the common move. Seeking twice to the same word is a no-op, so
/// recognising the double after the fact costs nothing.
///
/// **VoiceOver** gets a "Play from here" action rather than the gesture, because double tap is
/// VoiceOver's own activation gesture and is not ours to spend.
private struct TranscriptTurnText: View {
    let turn: TranscriptTurn
    let timeZone: TimeZone
    let playhead: TranscriptPlayhead?
    /// Measured height of one line of this font; 0 until the card's probe has reported.
    let lineHeight: CGFloat
    let onSeekTo: ((Int64) -> Void)?
    let onPlayFrom: ((Int64) -> Void)?

    /// Kept locally rather than in a dictionary on the card: a per-row `@State` write on first
    /// layout invalidates one row, where a shared dictionary would invalidate the whole
    /// transcript once per paragraph.
    @State private var size: CGSize = .zero
    @State private var cadence = TapCadence()

    /// `hasStarted` too: the playhead resolves position 0 the moment the player is configured,
    /// so without it every conversation opened highlighted its own first word.
    private var isActive: Bool {
        guard let playhead, playhead.hasStarted else { return false }
        return playhead.turnId == turn.id
    }

    /// True while a DIFFERENT paragraph is the one being spoken. Nothing steps back when
    /// playback is idle or paused — the transcript is a reading surface first, and dimming it
    /// for a player nobody started would be a mode the user never asked for.
    private var isBackgrounded: Bool {
        guard let playhead, playhead.isPlaying, let current = playhead.turnId else { return false }
        return current != turn.id
    }

    var body: some View {
        Text(attributed)
            .font(AppFont.callout)
            .lineSpacing(TranscriptView.bodyLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            // Measured BEFORE the full-width frame, so this is the text block's own size: a
            // wrapped paragraph fills the width anyway, and a one-line turn is measured at its
            // real width instead of the card's, which is what makes a tap on a short line land
            // on the word it is under. The frame below only widens the TARGET; both share an
            // origin, so a tap out in the empty margin simply clamps to the last word.
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                size = newSize
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 1, coordinateSpace: .local)
                    .onEnded { value in handleTap(at: value.location) }
            )
            .animation(Motion.animation(.easeInOut(duration: 0.18)), value: isBackgrounded)
            // One VoiceOver element per turn, carrying the time the eye reads off the stamp
            // beside the name.
            .accessibilityLabel(
                Copy.A11y.transcriptTurn(
                    time: turn.startedAt.map { TranscriptStamp.text($0, in: timeZone) },
                    speaker: turn.name,
                    text: turn.text))
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityActions {
                if let onPlayFrom, let start = turn.mediaOffsetMs {
                    Button(Copy.Conversation.playFromHere) { onPlayFrom(start) }
                }
            }
    }

    /// The paragraph, with the word being spoken picked out.
    ///
    /// Dimming here means BACKGROUNDED, never provisional: `isInProgress` (the still-growing
    /// tail of a live transcript) keeps its own muted colour and is never overridden by
    /// playback, because "these words may still change" and "this is not the bit playing" are
    /// different claims.
    private var attributed: AttributedString {
        var text = AttributedString(turn.text)
        text.foregroundColor = baseColor
        // Only the active paragraph reads `wordIndex`, so a word change invalidates one row
        // rather than the whole transcript.
        guard isActive, let index = playhead?.wordIndex,
            index >= 0, index < turn.words.count,
            let range = characterRange(turn.words[index], in: text)
        else { return text }
        // A highlighter, not a colour swap: the word keeps full label contrast and the tint
        // sits behind it, which stays legible at a glance while the eye is tracking it.
        text[range].backgroundColor = Tokens.tintFill18
        text[range].foregroundColor = Tokens.label
        return text
    }

    private var baseColor: Color {
        if turn.isInProgress { return Tokens.meta }
        return isBackgrounded ? Tokens.secondaryBody : Tokens.label
    }

    private func characterRange(
        _ span: TranscriptWordSpan, in text: AttributedString
    ) -> Range<AttributedString.Index>? {
        let characters = text.characters
        guard span.start >= 0, span.end > span.start, span.end <= characters.count else {
            return nil
        }
        let lower = characters.index(characters.startIndex, offsetBy: span.start)
        let upper = characters.index(characters.startIndex, offsetBy: span.end)
        return lower..<upper
    }

    private func handleTap(at point: CGPoint) {
        guard onSeekTo != nil || onPlayFrom != nil else { return }
        guard
            let target = TranscriptTapGeometry.seekTarget(
                at: point, in: size, lineHeight: lineHeight,
                lineSpacing: TranscriptView.bodyLineSpacing, turn: turn)
        else { return }
        if cadence.register() {
            Haptics.checkedOff()
            onPlayFrom?(target)
        } else {
            onSeekTo?(target)
        }
    }
}

/// A break in the transcript. Short markers ("quiet for 40 sec") sit between hairlines, the
/// artboard's look; long ones ("audio interrupted for 12 sec (watch buffer filled while
/// disconnected)") wrap under a single rule instead.
///
/// An interruption with several causes ("… (3 reasons)") carries a chevron and opens onto the
/// breakdown, so the row can answer "what actually happened?" without the closed transcript
/// having to. Openness is this row's own state: it belongs to the one marker being diagnosed,
/// and it should evaporate with the row rather than outlive it in a set kept by the card.
///
/// The `.fixedSize()` the marker line replaced made the long form as wide as its one unbroken
/// line — which is wider than the phone, and SwiftUI centers an oversized child, so the ENTIRE
/// screen (nav bar, header, player, bottom bar) shifted left and clipped on both edges. Loss
/// markers are exactly the content that must never be cut off.
struct TranscriptMarkerRow: View {
    let marker: TranscriptMarker
    let color: Color
    let rule: Color
    var timeZone: TimeZone = .current

    @State private var isOpen: Bool

    init(
        marker: TranscriptMarker, color: Color, rule: Color, timeZone: TimeZone = .current,
        isOpen: Bool = false
    ) {
        self.marker = marker
        self.color = color
        self.rule = rule
        self.timeZone = timeZone
        _isOpen = State(initialValue: isOpen)
    }

    /// Only a genuinely mixed interruption has anything behind the tap: a single cause is
    /// already spelled out in the label, and a quiet row has none.
    private var opens: Bool { !marker.reasons.isEmpty }

    var body: some View {
        if opens {
            VStack(spacing: 8) {
                Button {
                    Haptics.checkedOff()
                    withAnimation(.easeInOut(duration: 0.2)) { isOpen.toggle() }
                } label: {
                    markerLine(chevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(
                    isOpen
                        ? Copy.Conversation.hideInterruptionReasons
                        : Copy.Conversation.showInterruptionReasons)
                if isOpen { reasonBreakdown }
            }
        } else {
            markerLine(chevron: false)
                .accessibilityElement()
                .accessibilityLabel(accessibilityLabel)
        }
    }

    /// The marker's own line: text between (or under) hairlines, plus the disclosure chevron
    /// when there is a breakdown behind it.
    private func markerLine(chevron: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Rectangle().fill(rule).frame(height: 0.5)
                markerText(chevron: chevron)
                    .fixedSize()
                Rectangle().fill(rule).frame(height: 0.5)
            }
            VStack(spacing: 5) {
                Rectangle().fill(rule).frame(height: 0.5)
                markerText(chevron: chevron)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func markerText(chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(marker.text)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// What the interruption was made of, largest cause first: the wording the rest of the app
    /// uses for that cause, and how much of the gap it accounts for. Reading down it should be
    /// obvious whether this was one long outage or a bad half-hour of many small ones.
    private var reasonBreakdown: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(marker.reasons) { reason in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(reason.text)
                        .font(.system(size: 12))
                        .foregroundStyle(Tokens.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(reason.detail)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(color)
                        .lineLimit(1)
                }
                .accessibilityElement()
                .accessibilityLabel(
                    Copy.A11y.transcriptMarkerReason(text: reason.text, detail: reason.detail))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.missingFill))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var accessibilityLabel: String {
        marker.startedAt.map {
            Copy.A11y.transcriptMarker(
                time: TranscriptStamp.text($0, in: timeZone), text: marker.text)
        } ?? marker.text
    }
}

/// One rendered row of the transcript: a run of consecutive same-speaker turns, or a marker.
private enum TranscriptBlock: Identifiable {
    case speech(id: String, turns: [TranscriptTurn], isCited: Bool)
    case quiet(TranscriptMarker, isCited: Bool)
    case missing(TranscriptMarker, isCited: Bool)

    var id: String {
        switch self {
        case .speech(let id, _, _): return id
        case .quiet(let marker, _), .missing(let marker, _): return marker.id
        }
    }

    var isCited: Bool {
        switch self {
        case .speech(_, _, let cited), .quiet(_, let cited), .missing(_, let cited):
            return cited
        }
    }

    /// Where this block starts on the conversation's scrubber; markers carry no position, so a
    /// run takes the first one any of its blocks knows.
    var mediaOffsetMs: Int64? {
        if case .speech(_, let turns, _) = self { return turns.first?.mediaOffsetMs }
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
///
/// Naming somebody used to be a one-way door. The sheet could only assign, so a typo ("Alx")
/// created a second person that could never be renamed, merged or removed, and picking the
/// wrong speaker could only be papered over by picking another one. The registry has always
/// supported rename / delete / unassign; this is where they became reachable:
///
/// - swipe a person (or long-press) to **Rename** — one edit, and every conversation assigned
///   to them follows (Q17). Renaming onto a name that already exists merges the two.
/// - swipe to **Delete Person** — removes them from the registry and from every conversation.
/// - **Remove name**, shown only while this speaker is actually assigned, clears just this
///   conversation's label and leaves the person alone.
struct SpeakerRenameSheet: View {
    let conversationId: String
    let turn: TranscriptTurn
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var people: [Person] = []
    /// Who this label is assigned to right now — the source of the checkmark and of whether
    /// "Remove name" is offered at all. Matching on the displayed name cannot tell an assigned
    /// "Sam" from a diarizer label that happens to read the same.
    @State private var assigned: Person?
    @State private var freeText = ""
    @State private var renaming: Person?
    @State private var renameDraft = ""
    @State private var deleting: Person?

    var body: some View {
        NavigationStack {
            List {
                if !people.isEmpty {
                    Section {
                        ForEach(people, id: \.id) { person in
                            personRow(person)
                        }
                    } header: {
                        Text(Copy.Speaker.peopleHeader)
                    } footer: {
                        Text(Copy.Speaker.peopleFooter)
                    }
                }
                Section {
                    HStack {
                        TextField(Copy.Speaker.namePlaceholder, text: $freeText)
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
                if let assigned {
                    Section {
                        Button(Copy.Speaker.removeName, role: .destructive) { unassign() }
                            .font(AppFont.callout)
                    } footer: {
                        Text(Copy.Speaker.removeNameFooter(assigned.name))
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
        .presentationDetents([.medium, .large])
        .task { await reload() }
        .alert(Copy.Speaker.renamePerson, isPresented: renamingBinding) {
            TextField(Copy.Speaker.namePlaceholder, text: $renameDraft)
            Button(Copy.Common.cancel, role: .cancel) { renaming = nil }
            Button(Copy.Common.save) { commitRename() }
        } message: {
            Text(Copy.Speaker.renamePersonMessage)
        }
        .confirmationDialog(
            Copy.Speaker.deletePersonTitle(deleting?.name ?? ""),
            isPresented: deletingBinding, titleVisibility: .visible
        ) {
            Button(Copy.Speaker.deletePerson, role: .destructive) { commitDelete() }
        } message: {
            Text(Copy.Speaker.deletePersonMessage)
        }
    }

    private func personRow(_ person: Person) -> some View {
        Button {
            assign(person.name)
        } label: {
            HStack {
                Text(person.name)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                Spacer()
                if person.id == assigned?.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tokens.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleting = person
            } label: {
                Label(Copy.Speaker.deletePerson, systemImage: "trash")
            }
            Button {
                beginRename(person)
            } label: {
                Label(Copy.Speaker.rename, systemImage: "pencil")
            }
            .tint(Tokens.tint)
        }
        // The same two actions without the swipe: a destructive-and-global edit should not be
        // discoverable only by guessing that the row swipes.
        .contextMenu {
            Button(Copy.Speaker.rename) { beginRename(person) }
            Button(Copy.Speaker.deletePerson, role: .destructive) { deleting = person }
        }
    }

    // MARK: - Actions

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func reload() async {
        let people = AskLibraryDataSources.current.people
        self.people = (try? await people.people()) ?? []
        assigned = try? await people.assignedPerson(
            conversationId: conversationId, label: turn.speakerLabel)
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

    private func beginRename(_ person: Person) {
        renameDraft = person.name
        renaming = person
    }

    /// Stays open afterwards: a rename is a registry edit, not an answer to "who is this
    /// speaker?", so the sheet reloads and the user can still pick somebody.
    private func commitRename() {
        guard let person = renaming else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !name.isEmpty, name != person.name else { return }
        Task {
            try? await AskLibraryDataSources.current.people.renamePerson(id: person.id, to: name)
            await reload()
            onDone()
        }
    }

    private func commitDelete() {
        guard let person = deleting else { return }
        deleting = nil
        Haptics.destructiveConfirmed()
        Task {
            try? await AskLibraryDataSources.current.people.deletePerson(id: person.id)
            await reload()
            onDone()
        }
    }

    private func unassign() {
        Task {
            try? await AskLibraryDataSources.current.people.unassign(
                conversationId: conversationId, label: turn.speakerLabel)
            onDone()
            dismiss()
        }
    }
}
