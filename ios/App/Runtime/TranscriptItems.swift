import AppDB
import CompanionRuntime
import Foundation
import Intelligence
import SearchKit
import SegmentStore
import StatusUI
import Transcription

// One builder for the transcript both detail screens render.
//
// The Conversation screen and the Live screen used to derive their rows separately — the
// finished one from durable transcripts, the live one from the open segment's rolling preview
// — which is how the Live screen ended up showing ONLY the open segment: a conversation that
// spanned a reconnect lost everything before it, on a screen the user was watching at the
// time. They share this now, so a live conversation is the same conversation, still growing.

/// What one member contributes to a conversation's transcript: the PIECE of its segment the
/// conversation owns, which is the whole segment only when nothing else shares it.
struct MemberTranscript {
    var items: [TranscriptItem] = []
    /// Id of the last speech row, so a still-open member can mark it as the growing tail.
    var lastTurnId: String?
    /// Stored audio in the piece (the player's clock), gaps excluded.
    var mediaMs: Int64 = 0
    /// Offsets, within this piece's stored audio, of each gap — for the scrubber's amber ticks.
    var missingMediaOffsets: [Int64] = []
}

// `TranscriptTimebase` (which clock the provider's timings are on) and the piece's rows
// themselves come from the kit (`SearchKit/PieceTimeline.swift`), so the archive sync sends the
// server exactly the quiet and interrupted rows this screen shows.

/// Deliberately NOT `@MainActor`. Nothing in here touches the UI — it maps stored segments and
/// word timings onto the screen's value types — and the isolation was costing real freezes: the
/// conversation screen rebuilds its whole display on every database tick it observes, and on a
/// long conversation this loop is 136 ms of pure computation for ONE member segment (measured on
/// the largest real transcript in the 2026-09-09 backup: 24,854 words, on a Mac; a phone is
/// slower and a conversation has several members). All of it ran on the main thread, so a
/// pipeline pass writing an annotation froze the screen the reader was looking at.
enum TranscriptItems {
    /// Builds the rows for one member segment from whatever text exists for it — the durable
    /// transcript when it has landed, the live preview while it hasn't.
    ///
    /// `piece` is the range of the segment this conversation owns; nil is the whole segment. A
    /// segment routinely holds the end of one conversation and the start of the next, so with
    /// a piece this builds ONLY what is inside it: the turns that start in it, the quiet and
    /// interrupted rows whose records start in it, and scrubber positions counted from the
    /// piece's first frame rather than the segment's. `segments` and `words` are still handed
    /// over in the SEGMENT's clock — the piece's bounds are on it too — and may be the whole
    /// segment's: anything outside the piece is dropped here, so a caller cannot show a
    /// neighbour's words by forgetting to cut first.
    static func member(
        segmentId: String,
        meta: SegmentMeta,
        segments: [SearchKit.TranscriptSegment],
        words: [SearchKit.TranscriptWord] = [],
        assignments: [SpeakerAssignment],
        identities: SpeakerIdentitySnapshot = .init(),
        /// Media time consumed by the pieces already walked, so each turn can carry its
        /// position on the CONVERSATION's scrubber rather than one local to this segment.
        mediaBeforeMemberMs: Int64 = 0,
        /// Which clock `segments`/`words` are on. Defaults to `.wall` because that is what this
        /// builder assumed before the two were told apart; the durable path passes `.media`.
        timebase: TranscriptTimebase = .wall,
        piece: ConversationMember? = nil
    ) -> MemberTranscript {
        var result = MemberTranscript()
        // Two clocks: wall time (the stamps beside each speaker) and media time (what the
        // scrubber counts — stored audio only, gaps excluded). `SegmentMediaClock` converts
        // between them through the segment's own gap records, so a point 40% through the wall
        // span no longer has to be assumed to be 40% through the stored audio — an assumption
        // that put every transcript position on a silence-suppressed recording in the wrong
        // place, which is what made "play from here" land somewhere else entirely.
        // The SAME anchor the grouper files this segment under, not the raw `startTimeMs`.
        // The watch's sample counter free-runs across reattach, so `startTimeMs` alone can place
        // a segment hours into the future; `ConversationGrouper.segmentStartMs` clamps it to
        // `receivedAtMs`, on the ground that audio cannot have been recorded after the phone
        // received it. This screen used the unclamped value, so its clock stamps disagreed with
        // the conversation the stamps sit inside: on Roger's library 503 of 765 segments differ
        // by more than a minute, the worst by 19h32m. Every per-turn time and every quiet/missing
        // marker on those was wrong.
        let wallStartMs = ConversationGrouper.segmentStartMs(meta)
        let clock = SegmentMediaClock(meta)
        // The piece on all three clocks. For a whole segment this is `0..<mediaSpanMs` with no
        // wall window, and everything below is exactly what it was before pieces existed.
        let own = PieceSpan(
            piece ?? ConversationMember(segmentId: segmentId), clock: clock,
            frameDurationMs: Int64(meta.frameDurationMs))
        result.mediaMs = own.durationMs
        func wallDate(_ offsetMs: Int64) -> Date {
            Date(timeIntervalSince1970: Double(wallStartMs + offsetMs) / 1000)
        }
        // The piece's rows — its turns on the wall clock, loops taken out, and the quiet and
        // interrupted rows between them — come from the kit, so the archive sync sends the
        // server exactly what this screen shows (`SearchKit/PieceTimeline.swift` carries the
        // clock and cutting rules this used to spell out here).
        var renderSegments = segments
        var resolvedByKey: [String: SpeakerAttributedTurn] = [:]
        if timebase == .media, !identities.automaticAttributions.isEmpty || !identities.corrections.isEmpty {
            let attributed = SpeakerAttribution.attributedTurns(
                segments: segments.map { Transcription.TranscriptSegment(text: $0.text, startMs: $0.startMs,
                                                                          endMs: $0.endMs, speaker: $0.speaker) },
                words: words.map { Transcription.TranscriptWord(text: $0.text, startMs: $0.startMs, endMs: $0.endMs) },
                segmentId: segmentId, identity: identities, legacyAssignments: assignments)
            renderSegments = attributed.map { turn in
                // A key exists even for unknown speech so the formatter retains identity
                // boundaries instead of coalescing all unlabeled local-ASR words again.
                let key = turn.person.map { "person:\($0.id):\(turn.isVoiceMatch)" }
                    ?? "unknown:\(turn.originalSpeaker ?? "")"
                resolvedByKey[key] = turn
                return SearchKit.TranscriptSegment(text: turn.text, startMs: turn.startMs, endMs: turn.endMs,
                                                   speaker: turn.originalSpeaker, attributionKey: key)
            }
        }
        let built = pieceTimeline(
            meta: meta, member: own.member, clock: clock, segments: renderSegments, words: words,
            timebase: timebase)
        let passesMediaThrough = built.passesMediaThrough
        let timeline = built.items
        /// A wall offset into this member, as a position on the CONVERSATION's scrubber: the
        /// pieces before this one, plus how far into THIS piece the moment is. Not how far into
        /// the segment — the part of the segment before the piece is another conversation's
        /// audio, and the player never holds it.
        func mediaOffset(_ wallMs: Int64) -> Int64? {
            guard result.mediaMs > 0 else { return nil }
            // Untouched on the way in (`passesMediaThrough`), so untouched on the way out.
            let segmentMediaMs =
                passesMediaThrough
                ? min(max(wallMs, 0), clock.mediaSpanMs) : clock.media(fromWall: wallMs)
            return mediaBeforeMemberMs + own.offset(ofSegmentMediaMs: segmentMediaMs)
        }
        /// The stamp beside a turn. Clamped to the member's span so a live preview that has
        /// run past the metadata cannot print a time outside the recording it belongs to.
        func speechDate(_ wallMs: Int64) -> Date {
            wallDate(min(max(wallMs, 0), clock.wallSpanMs))
        }

        // Word timings are aligned to the rendered turns ONCE for the whole member, because the
        // only reliable correspondence between them is positional: both derive from the same
        // provider token stream, so the Nth letter of the transcript is the Nth letter of the
        // words. Aligning turn-by-turn on time windows instead would drift wherever
        // `splitSpeechBlock` interpolated a chunk boundary.
        var aligner = TranscriptWordAligner(
            words: built.words, speechTexts: timeline.compactMap { $0.asSpeech?.text })

        for (offset, item) in timeline.enumerated() {
            let itemId = "\(segmentId)-\(offset)"
            switch item {
            case .speech(let speech):
                // Everything that reads `result` is computed BEFORE the append: `mediaOffset`
                // closes over `result`, and calling it inside the argument of a mutating call
                // on `result.items` is an overlapping access to the same variable.
                let startedAt = speechDate(speech.startMs)
                let startOffset = mediaOffset(speech.startMs)
                let endOffset = mediaOffset(speech.endMs)
                let wordSpans = aligner.spans(for: speech.text, media: mediaOffset)
                // The provider labelled THIS segment's speakers, so a name is looked up, and
                // filed, under the segment as well as the label (`SpeakerKey`).
                let key = speech.speaker.map { SpeakerKey(segmentId: segmentId, label: $0) }
                // Highlighting tolerates provider punctuation/token differences. Identity does
                // not: only exact text correspondence may narrow a range to word boundaries.
                let exactWords = aligner.hasExactTextMatch && !wordSpans.isEmpty
                let identityWords = exactWords ? wordSpans : []
                let fullScope = speech.hasEstimatedTiming && !exactWords ? speech.identificationScope : nil
                let exactWordStart = identityWords.map(\.mediaStartMs).min().map {
                    $0 - mediaBeforeMemberMs + own.mediaMs.lowerBound
                }
                // A point-timed final word still has to belong to the half-open correction.
                // Include that timestamp by one millisecond; the piece check below prevents
                // this from claiming the neighbor's first instant at a conversation boundary.
                let exactWordEnd = identityWords.map { word in
                    word.mediaEndMs > word.mediaStartMs ? word.mediaEndMs
                        : word.mediaStartMs + (word.mediaStartMs < Int64.max ? 1 : 0)
                }.max().map {
                    $0 - mediaBeforeMemberMs + own.mediaMs.lowerBound
                }
                let scopeStart = fullScope?.startMs ?? speech.startMs
                let scopeEnd = fullScope?.endMs ?? speech.endMs
                let sourceStart = exactWordStart ?? (passesMediaThrough
                    ? scopeStart : clock.media(fromWall: scopeStart))
                let sourceEnd = exactWordEnd ?? (passesMediaThrough
                    ? scopeEnd : clock.media(fromWall: scopeEnd))
                // Never clamp and quietly label different audio than the text being confirmed.
                let withinPiece = sourceStart >= own.mediaMs.lowerBound && sourceEnd <= own.mediaMs.upperBound
                    && sourceEnd <= clock.mediaSpanMs && sourceEnd > sourceStart
                let reliableRange = withinPiece && (!speech.hasEstimatedTiming || exactWords || fullScope != nil)
                let attributed = speech.attributionKey.flatMap { resolvedByKey[$0] }
                let directIdentity = identities.resolvedIdentity(
                    segmentId: segmentId, startMediaMs: sourceStart, endMediaMs: sourceEnd,
                    speaker: speech.speaker, legacyAssignments: assignments)
                let person = attributed != nil ? attributed?.person : (reliableRange ? directIdentity?.person : nil)
                let isVoiceMatch = attributed?.isVoiceMatch ?? directIdentity?.isVoiceMatch ?? false
                let identificationStartOffset = reliableRange ? fullScope.flatMap { mediaOffset($0.startMs) } : nil
                let identificationEndOffset = reliableRange ? fullScope.flatMap { mediaOffset($0.endMs) } : nil
                result.lastTurnId = itemId
                result.items.append(
                    .turn(
                        TranscriptTurn(
                            id: itemId,
                            speakerLabel: key?.stored ?? "",
                            name: person.map { $0.isCurrentUser ? "You" : $0.name }
                                ?? key.map { speakerLabel($0.label) } ?? "Speaker",
                            role: person.map { $0.isCurrentUser ? .you : .other } ?? .unresolved,
                            text: speech.text,
                            startedAt: startedAt,
                            segmentId: segmentId,
                            mediaOffsetMs: startOffset,
                            mediaEndMs: endOffset,
                            words: wordSpans,
                            personId: person?.id,
                            isVoiceMatch: person != nil && isVoiceMatch,
                            sourceStartMs: reliableRange ? sourceStart : nil,
                            sourceEndMs: reliableRange ? sourceEnd : nil,
                            identificationText: reliableRange ? fullScope?.text : nil,
                            identificationMediaOffsetMs: identificationStartOffset,
                            identificationMediaEndMs: identificationEndOffset
                        )))
            case .silenceBreak:
                break  // an unlabeled visual break; the card's row spacing carries it
            case .pause(let pause):
                // Gap rows are always on the WALL clock whatever the text is on: they come from
                // the segment's own gap records, not from the provider.
                let marker = TranscriptMarker(
                    id: itemId, text: pause.label, startedAt: wallDate(pause.startMs),
                    segmentId: segmentId,
                    reasons: pause.hasReasonBreakdown ? markerReasons(pause.reasons) : [])
                if pause.missing {
                    // Where the gap falls on the SCRUBBER. Recorded even for the brief
                    // interruptions that earn no transcript row below — the tick and the
                    // recording's missing total are how those stay visible.
                    let tick = own.offset(ofSegmentMediaMs: clock.media(fromWall: pause.startMs))
                    result.missingMediaOffsets.append(tick)
                    if pause.isShownInTranscript { result.items.append(.missing(marker)) }
                } else {
                    result.items.append(.quiet(marker))
                }
            }
        }
        return result
    }

    /// `items` with a row for each moment marked on the watch, placed before the first row that
    /// starts after it. Moments outside `[startMs, endMs)` are not this conversation's.
    static func insertingMoments(
        _ moments: [Moment], into items: [TranscriptItem], startMs: Int64, endMs: Int64,
        timeZone: TimeZone
    ) -> [TranscriptItem] {
        let inside = moments.filter { $0.wallMs >= startMs && $0.wallMs < endMs }
        guard !inside.isEmpty else { return items }
        var result = items
        for moment in inside.sorted(by: { $0.wallMs < $1.wallMs }) {
            let at = Date(timeIntervalSince1970: Double(moment.wallMs) / 1000)
            let marker = TranscriptMarker(
                id: "moment-\(moment.id)",
                text: Copy.Conversation.markedAt(at.formatted(
                    Date.FormatStyle(date: .omitted, time: .standard, timeZone: timeZone)))
                    + (moment.note.isEmpty ? "" : " · \(moment.note)"),
                startedAt: at, momentId: moment.id)
            let index =
                result.firstIndex { item in
                    guard let started = item.startedAt else { return false }
                    return started > at
                } ?? result.endIndex
            result.insert(.moment(marker), at: index)
        }
        return result
    }

    /// The opened form of a mixed interruption: each cause with the time it accounts for, and
    /// how many separate interruptions it covers when that is more than one — twelve brief
    /// dropouts and one long outage are different problems.
    private static func markerReasons(_ reasons: [LossReason]) -> [TranscriptMarkerReason] {
        reasons.map { reason in
            let duration = Formatting.duration(reason.durationMs)
            return TranscriptMarkerReason(
                text: reason.text,
                detail: reason.count > 1 ? "\(duration) · \(reason.count) times" : duration)
        }
    }

    /// A transcript with no timings at all: the live preview before the provider has returned
    /// segment boundaries. One unstamped, still-growing row rather than nothing on screen.
    static func untimedTail(segmentId: String, text: String) -> [TranscriptItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [
            .turn(
                TranscriptTurn(
                    id: "\(segmentId)-tail", speakerLabel: "", name: "Speaker",
                    role: .unresolved, text: trimmed, isInProgress: true,
                    segmentId: segmentId))
        ]
    }

    static func speakerName(_ speaker: SpeakerKey?, assignments: [SpeakerAssignment]) -> String {
        guard let speaker else { return "Speaker" }
        if let match = SpeakerAssignment.match(speaker, in: assignments) {
            return match.personName
        }
        return speakerLabel(speaker.label)
    }

    static func speakerRole(_ speaker: SpeakerKey?, assignments: [SpeakerAssignment]) -> SpeakerRole
    {
        guard let speaker else { return .unresolved }
        guard let match = SpeakerAssignment.match(speaker, in: assignments) else {
            return .unresolved
        }
        return match.isCurrentUser ? .you : .other
    }

    /// The recording's own zone (Q16), so stamps keep the times things happened at.
    static func timeZone(_ meta: SegmentMeta?) -> TimeZone? {
        meta?.recordedTimeZone.flatMap { TimeZone(identifier: $0) }
    }
}

// MARK: - Word alignment

/// Attaches provider word timings to the turns of one member.
///
/// The only trustworthy correspondence between the two is POSITIONAL. Both the segment text and
/// the word list are built from the same provider token stream (`SonioxTranscriptionProvider`
/// concatenates the very tokens it also emits as words), and every transformation between there
/// and the rendered turn — trimming, `joinTranscriptText`, `readableChunks` — moves whitespace
/// around without touching letters. So the Nth letter of the transcript is the Nth letter of the
/// words, and walking the two in step is exact. Matching on time windows instead would drift
/// wherever `splitSpeechBlock` interpolated a chunk boundary from word COUNTS, which is
/// routinely a second or two out — and a karaoke highlight two seconds out is worse than none.
struct TranscriptWordAligner {
    private let words: [SearchKit.TranscriptWord]
    /// Letters/digits preceding each word in the stream.
    private let wordStartChar: [Int]
    private let usable: Bool
    let hasExactTextMatch: Bool
    /// How far into that stream the turns walked so far have taken us.
    private var consumed = 0

    init(words: [SearchKit.TranscriptWord], speechTexts: [String]) {
        let ordered =
            words
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startMs < $1.startMs }
        self.words = ordered

        var cumulative: [Int] = []
        cumulative.reserveCapacity(ordered.count)
        var total = 0
        for word in ordered {
            cumulative.append(total)
            total += Self.significantCount(word.text)
        }
        wordStartChar = cumulative

        let rendered = speechTexts.reduce(0) { $0 + Self.significantCount($1) }
        func compact(_ text: String) -> String {
            String(text.filter { !$0.isWhitespace })
        }
        // Identity attribution also requires the original tokens to reproduce the text.
        // Highlighting can tolerate punctuation/case differences; saving a narrower name
        // cannot, or the shared attribution/export path will reject the saved range.
        hasExactTextMatch = !ordered.isEmpty && rendered > 0
            && compact(ordered.map(\.text).joined()) == compact(speechTexts.joined())
        // The two streams should agree letter for letter; 5% covers a provider that drops the
        // odd filler token from one side. Beyond that they are describing different audio (a
        // migrated row whose words were never stored, a provider whose words and segments come
        // from separate passes) and this yields NO spans — the transcript then highlights whole
        // turns, which is honest, rather than sliding a marker along text it cannot place.
        usable =
            !ordered.isEmpty && rendered > 0 && total > 0
            && abs(total - rendered) * 20 <= max(total, rendered)
    }

    /// Spans for one turn, in the order they appear in `text`. Consumes this turn's share of the
    /// word stream, so the turns of a member must be passed in reading order.
    mutating func spans(
        for text: String, media: (Int64) -> Int64?
    ) -> [TranscriptWordSpan] {
        guard usable else { return [] }
        let characters = Array(text)
        var spans: [TranscriptWordSpan] = []
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }
            let start = index
            var significant = 0
            while index < characters.count, !characters[index].isWhitespace {
                if characters[index].isLetter || characters[index].isNumber { significant += 1 }
                index += 1
            }
            let end = index
            // A token with no letters at all ("—", "…") is punctuation the provider never timed:
            // it joins the span before it instead of claiming a timing of its own.
            guard significant > 0 else {
                if !spans.isEmpty { spans[spans.count - 1].end = end }
                continue
            }
            let firstWord = wordIndex(atCharacter: consumed)
            let lastWord = wordIndex(atCharacter: consumed + significant - 1)
            consumed += significant
            guard let firstWord, let lastWord,
                let startMs = media(words[firstWord].startMs),
                let endMs = media(max(words[lastWord].endMs, words[lastWord].startMs))
            else { continue }
            // Monotonic by construction: a provider that emits an out-of-order pair must not be
            // able to make the highlight jump backwards mid-paragraph.
            let floor = spans.last?.mediaStartMs ?? Int64.min
            let clampedStart = max(startMs, floor)
            spans.append(
                TranscriptWordSpan(
                    start: start, end: end,
                    mediaStartMs: clampedStart,
                    mediaEndMs: max(endMs, clampedStart)))
        }
        return spans
    }

    private func wordIndex(atCharacter offset: Int) -> Int? {
        guard !wordStartChar.isEmpty else { return nil }
        if offset <= 0 { return 0 }
        var low = 0
        var high = wordStartChar.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if wordStartChar[mid] <= offset {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    private static func significantCount(_ text: String) -> Int {
        text.reduce(0) { $0 + (($1.isLetter || $1.isNumber) ? 1 : 0) }
    }
}
