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

    /// The rows, rebuilt only when what they are built from changes. The screen re-creates this
    /// view on every scroll-state change, and regrouping a day-long transcript each time would
    /// be thousands of allocations for an identical answer.
    @State private var memo = TranscriptLayoutMemo()

    /// Rows, not one card. See `TranscriptLayout` for why: a lazy stack can only be lazy about
    /// its own children, and the card used to be ONE child holding every paragraph.
    ///
    /// The `LazyVStack` here is nested in the screen's own. Its rows are laid out, and exist,
    /// only near the visible part of the scroll view, and they sit at zero spacing: each row
    /// carries its share of the gaps around it, and draws its own slice of the card behind it.
    var body: some View {
        let layout = memo.layout(transcript: transcript, provenance: provenance, focus: focus)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(layout.rows) { row in
                rowView(row)
            }
        }
        // A hidden one-liner behind the stack: a background does not participate in layout, so
        // this measures the body line height without occupying a pixel of the card. On the
        // stack rather than on a row, so it is there whichever rows happen to be built.
        .background(alignment: .topLeading) { lineHeightProbe }
    }

    private func rowView(_ row: TranscriptLayout.Row) -> some View {
        rowContent(row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, row.topInset)
            .padding(.bottom, row.bottomInset)
            .padding(.horizontal, 16)
            .background { TranscriptCardSlice(isFirst: row.isFirst, isLast: row.isLast) }
    }

    @ViewBuilder
    private func rowContent(_ row: TranscriptLayout.Row) -> some View {
        switch row.content {
        case .turn(let turn, let opensRun):
            if opensRun {
                VStack(alignment: .leading, spacing: 3) {
                    speakerHeader(turn)
                    paragraph(turn)
                }
            } else {
                paragraph(turn)
            }
        case .quiet(let marker):
            quietRow(marker)
        case .missing(let marker):
            missingRow(marker)
        case .moment(let marker):
            if let id = marker.momentId {
                MarkedMomentLink(id: id, text: marker.text)
            } else {
                TranscriptMarkerRow(
                    marker: marker, color: Tokens.tint, rule: Tokens.tintSoft, timeZone: timeZone,
                    symbol: "pin.fill")
            }
        case .band(let blocks, let playFromMs):
            citedBand(blocks, playFromMs: playFromMs)
        case .provenance(let text):
            Text(text)
                .font(AppFont.micro)
                .foregroundStyle(Tokens.faint)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    private var lineHeightProbe: some View {
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

    // MARK: - Blocks inside a cited band

    @ViewBuilder
    private func blockRow(_ block: TranscriptBlock) -> some View {
        switch block {
        case .speech(_, let turns):
            speechBlock(turns)
        case .quiet(let marker):
            quietRow(marker)
        case .missing(let marker):
            missingRow(marker)
        }
    }

    /// The stretch a citation points at: tinted, ruled on the leading edge, and headed by the
    /// one thing you came here to do. Arriving from a chip should answer "which part?" before
    /// you have read a word.
    private func citedBand(_ blocks: [TranscriptBlock], playFromMs: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(Copy.Conversation.citedMoment)
                    .font(AppFont.micro)
                    .foregroundStyle(Tokens.tint)
                Spacer(minLength: 0)
                if let onPlayFrom, let offset = playFromMs {
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
            ForEach(blocks) { block in
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.Conversation.citedMoment)
    }

    /// One speaker's consecutive turns inside a band: a name header and a paragraph each.
    private func speechBlock(_ turns: [TranscriptTurn]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            speakerHeader(turns[0])
            // Provider fragments of one person's speech are paragraphs, not one run-on
            // block: they get their own spacing under the single name header.
            VStack(alignment: .leading, spacing: TranscriptLayout.paragraphGap) {
                ForEach(turns) { turn in
                    paragraph(turn)
                        // Inside a band the paragraphs are not rows of their own, so they need
                        // their own scroll ids for playback to keep the one being spoken on
                        // screen. Everywhere else the row's identity is the turn's id already.
                        .id(turn.id)
                }
            }
        }
    }

    // MARK: - The pieces every row is made of

    private func quietRow(_ marker: TranscriptMarker) -> some View {
        TranscriptMarkerRow(
            marker: marker, color: Tokens.faint, rule: Tokens.hairline, timeZone: timeZone)
    }

    private func missingRow(_ marker: TranscriptMarker) -> some View {
        TranscriptMarkerRow(
            marker: marker, color: Tokens.missing, rule: Tokens.missingHair, timeZone: timeZone)
    }

    /// The name that heads a run of one speaker's paragraphs, and the time the run began.
    private func speakerHeader(_ lead: TranscriptTurn) -> some View {
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
    }

    private func paragraph(_ turn: TranscriptTurn) -> some View {
        TranscriptTurnText(
            turn: turn,
            timeZone: timeZone,
            playhead: playhead,
            lineHeight: bodyLineHeight,
            onSeekTo: onSeekTo,
            onPlayFrom: onPlayFrom
        )
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

/// Holds the last layout and what it was built from. A class so the view can refresh it from
/// `body` without that write being a state change.
@MainActor
final class TranscriptLayoutMemo {
    private var transcript: [TranscriptItem] = []
    private var provenance: String?
    private var focus: TranscriptFocus?
    private var cached: TranscriptLayout?

    func layout(
        transcript: [TranscriptItem], provenance: String?, focus: TranscriptFocus?
    ) -> TranscriptLayout {
        // `==` on the array is O(1) when it is the same array, which it is on every re-render
        // that did not reload the conversation — the case this exists for.
        if let cached, transcript == self.transcript, provenance == self.provenance,
            focus == self.focus
        {
            return cached
        }
        let layout = TranscriptLayout(transcript: transcript, provenance: provenance, focus: focus)
        self.transcript = transcript
        self.provenance = provenance
        self.focus = focus
        cached = layout
        return layout
    }
}

/// One row's slice of the transcript card: the card's surface, rounded only where the card's
/// own corners are. Slices meet edge to edge; each one also reaches a point under the next, so
/// a fractional row height can never show a hairline of the page between two of them — the
/// next row paints over the overlap with the same opaque colour.
private struct TranscriptCardSlice: View {
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        let radius = Tokens.cardRadius
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? radius : 0,
            bottomLeadingRadius: isLast ? radius : 0,
            bottomTrailingRadius: isLast ? radius : 0,
            topTrailingRadius: isFirst ? radius : 0
        )
        .fill(Tokens.surface)
        .padding(.bottom, isLast ? 0 : -1)
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
    /// An SF Symbol before the text: a marked moment's pin.
    var symbol: String?

    @State private var isOpen: Bool

    init(
        marker: TranscriptMarker, color: Color, rule: Color, timeZone: TimeZone = .current,
        symbol: String? = nil, isOpen: Bool = false
    ) {
        self.marker = marker
        self.color = color
        self.rule = rule
        self.timeZone = timeZone
        self.symbol = symbol
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
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
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

/// The clock stamp beside a speaker name: 11pt `faint`, monospaced digits so a column of
/// them doesn't shiver, formatted in the recording's own zone (Q16) and by the user's
/// 12/24-hour setting — never a hand-built string.
struct TranscriptStamp: View {
    let date: Date
    var timeZone: TimeZone = .current

    nonisolated static func text(_ date: Date, in timeZone: TimeZone) -> String {
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
/// carrying the same diarization label in the same segment of this conversation — labels are
/// per segment (`SpeakerKey`), so the next segment's "Speaker 1" is somebody to name on its
/// own; renames of a person apply everywhere via the people registry.
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
