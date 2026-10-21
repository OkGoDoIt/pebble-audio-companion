import AppDB
import Foundation
import SegmentStore

// The transcript of ONE PIECE of a segment, as the Conversation screen lays it out: the turns
// that start in the piece, and the quiet and interrupted rows between them.
//
// Two readers need exactly this, and they must not disagree: the app's transcript screen
// (`App/Runtime/TranscriptItems.swift`, which adds names, stamps, word highlights and scrubber
// positions on top) and the archive sync (`ArchiveExport.gaps`, which sends the same quiet and
// interrupted rows to the server, so the web viewer and every assistant read the conversation
// the way the phone shows it). Before this was shared, the export classified the gap records
// with the same classifier but none of the presentation rules, and a conversation the app showed
// as one "audio interrupted" row per recording reached the web as 1,182 separate one-second
// rows.

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
/// Everything downstream of `pieceTimeline` runs on the WALL clock and only the wall clock. The
/// declared timebase says what has to be converted on the way in, not what the renderer works
/// in — see the note in `pieceTimeline` on why mixing the two inside `transcriptTimelineItems`
/// is not survivable.
public enum TranscriptTimebase: Sendable {
    case media
    case wall
}

/// The piece as wall offsets into its segment, for the gap records — which are on the wall clock
/// because they come from sample indices that keep counting through audio nobody stored. Nil for
/// a whole segment: nothing to clip. An open end is unbounded rather than the segment's span,
/// because the live preview can run a flush ahead of the metadata.
///
/// The same rule as everywhere else a media offset becomes a wall one
/// (`ConversationRunPlanner.Member.wall(ofMedia:)`, Ask's stretches): through the gap records
/// where they add up, and left alone where they do not — a proportional guess moves turns by
/// hours on the segments it applies to.
public func pieceWallWindow(_ member: ConversationMember, clock: SegmentMediaClock) -> Range<Int64>? {
    guard !member.isWhole else { return nil }
    func wall(_ mediaMs: Int64) -> Int64 {
        clock.isExact ? clock.wall(fromMedia: mediaMs) : mediaMs
    }
    let lower = member.startMediaMs.map(wall) ?? Int64.min
    let upper = member.endMediaMs.map(wall) ?? Int64.max
    return lower..<max(upper, lower)
}

/// One piece's transcript rows, before the screen dresses them.
public struct PieceTimeline: Sendable {
    /// Speech, breaks, and quiet and interrupted rows, in order, as WALL offsets into the
    /// segment (milliseconds since its first sample).
    public var items: [TranscriptTimelineItem]
    /// The piece's word timings with the looped ones removed, on the wall clock: the stream the
    /// screen's word aligner walks against `items`' speech.
    public var words: [TranscriptWord]
    /// The provider timings came in on the media clock and were converted.
    public var convertsFromMedia: Bool
    /// The provider timings came in on the media clock and could NOT be converted (the
    /// segment's records do not account for its clocks), so they were passed through as they
    /// were — and anything mapped back to the media clock must pass through the same way.
    public var passesMediaThrough: Bool
    /// The piece on the wall clock (`pieceWallWindow`); nil for a whole segment.
    public var window: Range<Int64>?

    /// The quiet and interrupted rows alone — what the archive sync sends as the conversation's
    /// gaps.
    public var pauses: [TranscriptTimelineItem.Pause] { items.compactMap(\.asPause) }
}

/// Builds the rows for one piece of a segment from whatever text exists for it.
///
/// `segments` and `words` are on `timebase` and in the SEGMENT's clock — the piece's bounds are
/// on it too — and may be the whole segment's: anything outside the piece is dropped here, so a
/// caller cannot show a neighbour's words by forgetting to cut first. A turn (and a word) belongs
/// to the piece its first instant falls in — the rule `SegmentTranscript.piece` cuts by — so
/// every turn of a shared segment appears in exactly one conversation.
public func pieceTimeline(
    meta: SegmentMeta,
    member: ConversationMember,
    clock: SegmentMediaClock,
    segments: [TranscriptSegment],
    words: [TranscriptWord] = [],
    timebase: TranscriptTimebase
) -> PieceTimeline {
    let window = pieceWallWindow(member, clock: clock)
    // Whether the durable path can be converted at all. When a segment's gap records do not
    // account for the difference between its stored audio and its elapsed wall time, the clock
    // falls back to a proportional guess, and a guess is worse than the honest default here: 23
    // of the 765 segments in the real library claim hours of wall time around minutes of audio
    // (the worst, 15 h 01 m around 14 m 45 s across 79 records that add up to neither), and
    // spreading their turns proportionally moves 7,285 of them by over a minute, the worst by
    // 14 h 44 m — inventing a stamp for every one. Left alone, the provider's offsets at least
    // sit where the audio does.
    //
    // `ConversationBoundaryDetector.spokenRuns` declines for the same reason. The two must not
    // disagree about when a word was said: the conversation's displayed extent comes from one and
    // the stamps inside it from the other.
    let convertsFromMedia = timebase == .media && clock.isExact
    let passesMediaThrough = timebase == .media && !clock.isExact

    // ONLY THIS PIECE'S WORDS, decided on the clock the piece's bounds are on. Durable timings
    // are on the media clock, as the bounds are; the live preview is on the wall clock, so it is
    // tested against the piece's wall window instead.
    let ownSegments: [TranscriptSegment]
    let ownWords: [TranscriptWord]
    if member.isWhole {
        ownSegments = segments
        ownWords = words
    } else if timebase == .media {
        ownSegments = segments.filter { member.contains(mediaMs: $0.startMs) }
        ownWords = words.filter { member.contains(mediaMs: $0.startMs) }
    } else {
        ownSegments = segments.filter { window?.contains($0.startMs) ?? true }
        ownWords = words.filter { window?.contains($0.startMs) ?? true }
    }

    // ONE CLOCK, DECIDED HERE, BEFORE ANYTHING IS DERIVED.
    //
    // `transcriptTimelineItems` interleaves the provider's speech with the segment's gap records,
    // and those records are WALL offsets — they come from sample indices, which free-run through
    // the audio nobody stored. Handing it media-clock speech therefore ordered two different
    // clocks against each other: a gap row was inserted before the first block whose *media*
    // start exceeded the gap's *wall* start, which pushes every quiet and interrupted marker
    // later in the list by the stored/elapsed difference — measured over the real library, a
    // median of 33 s and a p90 of 3 m 28 s on loss gaps alone, rising to 54 s / 3 m 57 s once
    // watch-side silence suppression ships. It also computed the "quiet for…" rows between
    // blocks as a media-time difference, which is zero across exactly the silence the row
    // exists to describe.
    //
    // Lifting the provider's timings onto the wall clock up front is the whole fix, and it is
    // cheap: one binary search per timing, no allocation beyond the mapped arrays.
    let wallSegments: [TranscriptSegment]
    let wallWords: [TranscriptWord]
    if convertsFromMedia {
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
        // Already the right clock (the live preview), or a segment whose records cannot place
        // it. Deliberately NOT clamped to the segment's span either way: the live preview can be
        // a flush ahead of the metadata it is previewing, and pinning its newest rows to the last
        // known sample would stack them on one instant.
        wallSegments = ownSegments
        wallWords = ownWords
    }

    // Looped transcriber output is taken out of the rows before anything else is derived from
    // them (see `TranscriptLoopSuppression.swift`). Both streams have to be filtered together —
    // the screen's aligner walks the word stream POSITIONALLY against the rendered text, so
    // dropping turns without dropping their words slides every later highlight.
    let cleaned = filteringLoopedArtefacts(segments: wallSegments, words: wallWords)
    // The gap records are the one input nothing above could cut: the renderer reads them off the
    // meta, so it is told which stretch of the segment this is.
    let items = transcriptTimelineItems(
        meta: meta, segments: cleaned.segments, words: cleaned.words,
        suppressedLoops: cleaned.loops, window: window)
    return PieceTimeline(
        items: items, words: cleaned.words, convertsFromMedia: convertsFromMedia,
        passesMediaThrough: passesMediaThrough, window: window)
}
