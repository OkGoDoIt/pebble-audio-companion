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

/// What one member segment contributes to a conversation's transcript.
struct MemberTranscript {
    var items: [TranscriptItem] = []
    /// Id of the last speech row, so a still-open member can mark it as the growing tail.
    var lastTurnId: String?
    /// Stored audio in the member (the player's clock), gaps excluded.
    var mediaMs: Int64 = 0
    /// Media offsets, within this member, of each gap — for the scrubber's amber ticks.
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
enum TranscriptTimebase {
    case media
    case wall
}

@MainActor
enum TranscriptItems {
    /// Builds the rows for one member segment from whatever text exists for it — the durable
    /// transcript when it has landed, the live preview while it hasn't.
    static func member(
        segmentId: String,
        meta: SegmentMeta,
        segments: [SearchKit.TranscriptSegment],
        words: [SearchKit.TranscriptWord] = [],
        assignments: [SpeakerAssignment],
        /// Media time consumed by the members already walked, so each turn can carry its
        /// position on the CONVERSATION's scrubber rather than one local to this segment.
        mediaBeforeMemberMs: Int64 = 0,
        /// Which clock `segments`/`words` are on. Defaults to `.wall` because that is what this
        /// builder assumed before the two were told apart; the durable path passes `.media`.
        timebase: TranscriptTimebase = .wall
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
        result.mediaMs = clock.mediaSpanMs
        func wallDate(_ offsetMs: Int64) -> Date {
            Date(timeIntervalSince1970: Double(wallStartMs + offsetMs) / 1000)
        }
        /// A provider timing, as a wall offset into this member.
        func wallOffset(_ providerMs: Int64) -> Int64 {
            switch timebase {
            case .wall: return min(max(providerMs, 0), clock.wallSpanMs)
            case .media: return clock.wall(fromMedia: providerMs)
            }
        }
        /// A provider timing, as a position on the CONVERSATION's scrubber.
        func mediaOffset(_ providerMs: Int64) -> Int64? {
            guard result.mediaMs > 0 else { return nil }
            switch timebase {
            case .wall: return mediaBeforeMemberMs + clock.media(fromWall: providerMs)
            case .media:
                return mediaBeforeMemberMs + min(max(providerMs, 0), clock.mediaSpanMs)
            }
        }

        let timeline = transcriptTimelineItems(meta: meta, segments: segments, words: words)
        // Word timings are aligned to the rendered turns ONCE for the whole member, because the
        // only reliable correspondence between them is positional: both derive from the same
        // provider token stream, so the Nth letter of the transcript is the Nth letter of the
        // words. Aligning turn-by-turn on time windows instead would drift wherever
        // `splitSpeechBlock` interpolated a chunk boundary.
        var aligner = TranscriptWordAligner(
            words: words, speechTexts: timeline.compactMap { $0.asSpeech?.text })

        for (offset, item) in timeline.enumerated() {
            let itemId = "\(segmentId)-\(offset)"
            switch item {
            case .speech(let speech):
                // Everything that reads `result` is computed BEFORE the append: `mediaOffset`
                // closes over `result`, and calling it inside the argument of a mutating call
                // on `result.items` is an overlapping access to the same variable.
                let startedAt = wallDate(wallOffset(speech.startMs))
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
                    let tick = clock.media(fromWall: pause.startMs)
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

/// Stored audio in a segment, in milliseconds — frames on disk, not the wall span the segment
/// covers. `segmentDurationMs` is the latter, and the two differ by exactly the audio lost.
func mediaDurationMs(_ meta: SegmentMeta) -> Int64 {
    let frames = meta.frameCount * Int64(meta.frameDurationMs)
    return frames > 0 ? frames : segmentDurationMs(meta)
}

// MARK: - Wall ↔ media

/// Converts one segment's two clocks into each other using its own gap records.
///
/// Media time is wall time minus everything that was never stored — lost audio and VAD-skipped
/// silence alike, since neither reaches the frame log. Both directions are therefore exact
/// arithmetic over the gap spans, not the proportional guess this replaced: proportionally, a
/// point 40% through a member's wall span is 40% through its stored audio, which is only true
/// when the gaps happen to be spread evenly. On a real recording — where the quiet hours are
/// one long gap and the talking is another — it is wrong by minutes.
///
/// Gap records overlap routinely (a sequence-skip inside a silence-suppressed span records
/// both), so the spans are unioned before anything is counted; summing raw durations would
/// double-count and push media time negative.
struct SegmentMediaClock {
    let wallSpanMs: Int64
    let mediaSpanMs: Int64

    /// Unioned gap spans in wall ms since the segment's first sample.
    private let starts: [Int64]
    private let ends: [Int64]
    /// Gap time already closed BEFORE span i, and the media time consumed when span i begins.
    private let closedBefore: [Int64]
    private let mediaAtStart: [Int64]
    /// False when the gap records do not account for the wall/media difference (truncated
    /// sidecars, metadata written by an older build). The proportional mapping is then still
    /// the best available guess, and pretending otherwise would be the actual lie.
    private let exact: Bool

    init(_ meta: SegmentMeta) {
        let wall = max(segmentDurationMs(meta), 0)
        let media = mediaDurationMs(meta)
        wallSpanMs = wall
        mediaSpanMs = media

        let rate = Int64(max(meta.sampleRateHz, 1))
        var raw: [(Int64, Int64)] = []
        raw.reserveCapacity(meta.gaps.count)
        for gap in meta.gaps {
            let anchor = meta.firstSampleIndex ?? gap.firstMissingSampleIndex
            let samples =
                gap.firstMissingSampleIndex >= anchor
                ? gap.firstMissingSampleIndex - anchor : 0
            let start = min(max(Int64(samples) * 1_000 / rate, 0), wall)
            let duration = max(Int64(gap.missingFrameCount) * Int64(meta.frameDurationMs), 0)
            let end = min(start + duration, wall)
            if end > start { raw.append((start, end)) }
        }
        raw.sort { $0.0 < $1.0 }

        var mergedStarts: [Int64] = []
        var mergedEnds: [Int64] = []
        for span in raw {
            if let last = mergedEnds.last, span.0 <= last {
                if span.1 > last { mergedEnds[mergedEnds.count - 1] = span.1 }
            } else {
                mergedStarts.append(span.0)
                mergedEnds.append(span.1)
            }
        }
        starts = mergedStarts
        ends = mergedEnds

        var closed: [Int64] = []
        var atStart: [Int64] = []
        closed.reserveCapacity(mergedStarts.count)
        atStart.reserveCapacity(mergedStarts.count)
        var running: Int64 = 0
        for index in mergedStarts.indices {
            closed.append(running)
            atStart.append(max(mergedStarts[index] - running, 0))
            running += mergedEnds[index] - mergedStarts[index]
        }
        closedBefore = closed
        mediaAtStart = atStart
        // 5% (or 2 s, whichever is larger) of slack: gap durations are frame-quantized and the
        // wall span is sample-derived, so they never agree to the millisecond.
        exact = abs((wall - running) - media) <= max(2_000, media / 20)
    }

    /// Where a wall offset into the segment lands on the scrubber.
    func media(fromWall wallMs: Int64) -> Int64 {
        guard mediaSpanMs > 0, wallSpanMs > 0 else { return 0 }
        let point = min(max(wallMs, 0), wallSpanMs)
        guard exact else { return mediaSpanMs * point / wallSpanMs }
        guard let index = lastIndex(in: starts, notAfter: point) else {
            return min(point, mediaSpanMs)
        }
        let insideThisGap = min(max(point - starts[index], 0), ends[index] - starts[index])
        let skipped = closedBefore[index] + insideThisGap
        return min(max(point - skipped, 0), mediaSpanMs)
    }

    /// Where a scrubber position sits on the wall clock — what a transcript stamp reads.
    func wall(fromMedia mediaMs: Int64) -> Int64 {
        guard mediaSpanMs > 0, wallSpanMs > 0 else { return 0 }
        let point = min(max(mediaMs, 0), mediaSpanMs)
        guard exact else { return wallSpanMs * point / mediaSpanMs }
        guard let index = lastIndex(in: mediaAtStart, notAfter: point) else {
            return min(point, wallSpanMs)
        }
        // Media time does not advance during a gap, so a media instant at or past a gap's start
        // is on the far side of it: the whole span has elapsed.
        let skipped = closedBefore[index] + (ends[index] - starts[index])
        return min(point + skipped, wallSpanMs)
    }

    /// Last index whose value is <= `value`; nil when the array is empty or starts after it.
    private func lastIndex(in values: [Int64], notAfter value: Int64) -> Int? {
        guard let first = values.first, first <= value else { return nil }
        var low = 0
        var high = values.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if values[mid] <= value {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
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
