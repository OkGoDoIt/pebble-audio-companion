import AppDB
import Foundation
import SearchKit
import SegmentStore
import StatusUI

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

/// Which clock a set of provider timings is measured on.
///
/// This is not a detail — the two producers disagree, and reading one as the other is worth
/// minutes on an hour-long recording:
///
/// - **Durable** transcripts come from `TranscriptionProcessor.segmentPcmSource`, which decodes
///   the segment's STORED frames and hands them to the provider. Gaps (lost audio and
///   VAD-skipped silence alike) are simply absent from that stream, so provider timings are
///   offsets into the stored audio — `.media`, the player's own clock.
/// - The **live preview** (`LiveTranscriber`) offsets each chunk by `sampleOffsetMs`, which
///   counts samples since the segment's first sample — `.wall`.
///
/// Everything downstream of `member` runs on the WALL clock and only the wall clock. The
/// declared timebase says what has to be converted on the way in, not what the renderer works
/// in — see the note in `member` on why mixing the two inside `transcriptTimelineItems` is not
/// survivable.
enum TranscriptTimebase {
    case media
    case wall
}

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
        // Whether the durable path can be converted at all. When a segment's gap records do not
        // account for the difference between its stored audio and its elapsed wall time, the
        // clock falls back to a proportional guess, and a guess is worse than the honest default
        // here: 23 of the 765 segments in the real library claim hours of wall time around
        // minutes of audio (the worst, 15 h 01 m around 14 m 45 s across 79 records that add up
        // to neither), and spreading their turns proportionally moves 7,285 of them by over a
        // minute, the worst by 14 h 44 m — inventing a stamp for every one. Left alone, the
        // provider's offsets at least sit where the audio does.
        //
        // `ConversationBoundaryDetector.spokenRuns` declines for the same reason. The two must
        // not disagree about when a word was said: the conversation's displayed extent comes
        // from one and the stamps inside it from the other.
        let convertsFromMedia = timebase == .media && clock.isExact
        let passesMediaThrough = timebase == .media && !clock.isExact
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

        // ONE CLOCK, DECIDED HERE, BEFORE ANYTHING IS DERIVED.
        //
        // `transcriptTimelineItems` interleaves the provider's speech with the segment's gap
        // records, and those records are WALL offsets — they come from sample indices, which
        // free-run through the audio nobody stored. Handing it media-clock speech therefore
        // ordered two different clocks against each other: a gap row was inserted before the
        // first block whose *media* start exceeded the gap's *wall* start, which pushes every
        // quiet and interrupted marker later in the list by the stored/elapsed difference —
        // measured over the real library, a median of 33 s and a p90 of 3 m 28 s TODAY, on loss
        // gaps alone, rising to 54 s / 3 m 57 s once watch-side silence suppression ships
        // (PebbleOS a47acac74; 4.1-13.8% of airtime withheld). It also computed the "quiet
        // for…" rows between blocks as a media-time difference, which is zero across exactly
        // the silence the row exists to describe.
        //
        // Lifting the provider's timings onto the wall clock up front is the whole fix, and it
        // is cheap: one binary search per timing, no allocation beyond the mapped arrays. The
        // rows' own stamps were already converted individually and were already right; this is
        // about the order they appear in and the gaps derived BETWEEN them.
        // ONLY THIS PIECE'S WORDS, decided on the clock the piece's bounds are on. A turn (and
        // a word) belongs to the piece its first instant falls in — the rule
        // `SegmentTranscript.piece` cuts by — so every turn of a shared segment appears in
        // exactly one conversation. Durable timings are on the media clock, as the bounds are;
        // the live preview is on the wall clock, so it is tested against the piece's wall
        // window instead.
        let ownSegments: [SearchKit.TranscriptSegment]
        let ownWords: [SearchKit.TranscriptWord]
        if own.member.isWhole {
            ownSegments = segments
            ownWords = words
        } else if timebase == .media {
            ownSegments = segments.filter { own.member.contains(mediaMs: $0.startMs) }
            ownWords = words.filter { own.member.contains(mediaMs: $0.startMs) }
        } else {
            ownSegments = segments.filter { own.wallMs?.contains($0.startMs) ?? true }
            ownWords = words.filter { own.wallMs?.contains($0.startMs) ?? true }
        }

        let wallSegments: [SearchKit.TranscriptSegment]
        let wallWords: [SearchKit.TranscriptWord]
        if convertsFromMedia {
            // `wallOffset(ofMedia:)` is the shared form of this rule (exact → converted); this
            // branch only runs on an exact clock, so it is `wall(fromMedia:)` here.
            wallSegments = ownSegments.map {
                var span = $0
                span.startMs = clock.wallOffset(ofMedia: $0.startMs)
                span.endMs = clock.wallOffset(ofMedia: max($0.endMs, $0.startMs))
                return span
            }
            wallWords = ownWords.map {
                var span = $0
                span.startMs = clock.wallOffset(ofMedia: $0.startMs)
                span.endMs = clock.wallOffset(ofMedia: max($0.endMs, $0.startMs))
                return span
            }
        } else {
            // Already the right clock (the live preview), or a segment whose records cannot
            // place it. Deliberately NOT clamped to the segment's span either way: the live
            // preview can be a flush ahead of the metadata it is previewing, and pinning its
            // newest rows to the last known sample would stack them on one instant. The stamp
            // is clamped where it is rendered, exactly as it was before.
            wallSegments = ownSegments
            wallWords = ownWords
        }

        // Looped transcriber output is taken out of the rows before anything else is derived
        // from them (see `SearchKit/TranscriptLoopSuppression.swift`). Both streams have to be
        // filtered together — the aligner below walks the word stream POSITIONALLY against the
        // rendered text, so dropping turns without dropping their words slides every later
        // highlight by the removed characters.
        let cleaned = filteringLoopedArtefacts(segments: wallSegments, words: wallWords)
        // The gap records are the one input nothing above could cut: the renderer reads them
        // off the meta, so it is told which stretch of the segment this is.
        let timeline = transcriptTimelineItems(
            meta: meta, segments: cleaned.segments, words: cleaned.words,
            suppressedLoops: cleaned.loops, window: own.wallMs)
        // Word timings are aligned to the rendered turns ONCE for the whole member, because the
        // only reliable correspondence between them is positional: both derive from the same
        // provider token stream, so the Nth letter of the transcript is the Nth letter of the
        // words. Aligning turn-by-turn on time windows instead would drift wherever
        // `splitSpeechBlock` interpolated a chunk boundary.
        var aligner = TranscriptWordAligner(
            words: cleaned.words, speechTexts: timeline.compactMap { $0.asSpeech?.text })

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
                result.lastTurnId = itemId
                result.items.append(
                    .turn(
                        TranscriptTurn(
                            id: itemId,
                            speakerLabel: speech.speaker ?? "",
                            name: speakerName(speech.speaker, assignments: assignments),
                            role: speakerRole(speech.speaker, assignments: assignments),
                            text: speech.text,
                            startedAt: startedAt,
                            segmentId: segmentId,
                            mediaOffsetMs: startOffset,
                            mediaEndMs: endOffset,
                            words: wordSpans
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

    static func speakerName(_ speaker: String?, assignments: [SpeakerAssignment]) -> String {
        guard let speaker else { return "Speaker" }
        if let match = assignments.first(where: { $0.label == speaker }) {
            return match.personName
        }
        return speakerLabel(speaker)
    }

    static func speakerRole(_ speaker: String?, assignments: [SpeakerAssignment]) -> SpeakerRole {
        guard let speaker else { return .unresolved }
        guard let match = assignments.first(where: { $0.label == speaker }) else {
            return .unresolved
        }
        // The wearer is whoever the user named "You"; everyone else is a counterpart.
        return match.personName.caseInsensitiveCompare("You") == .orderedSame ? .you : .other
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
