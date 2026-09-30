import AppDB
import Foundation
import SegmentStore

// Opening a conversation at a wall-clock moment (History plan 7.9): the transcript scrolled to
// that time and the player cued there, with nothing highlighted.
//
// A moment is not a citation. A citation names a stretch somebody quoted, and the screen bands
// the lines inside it; a moment is a place on the clock — a chapter's start, a tap on the day —
// and may fall where nobody said anything at all. So it cannot ask for a row INSIDE a window,
// which is what a citation's focus needs; it asks for the row it would be reading at that time.

/// Where a moment lands: which recording, and which transcript row.
enum MomentResolver {
    /// One recording as the resolver sees it: where it sits on the wall clock, and which
    /// conversation holds it.
    struct Span: Equatable, Sendable {
        var segmentId: String
        var conversationId: String
        /// `[startMs, endMs)`, epoch ms — the grouper's placement (`segmentStartMs` /
        /// `segmentEndMs`), so a recording sits exactly where its conversation says it does.
        var startMs: Int64
        var endMs: Int64
        /// Whether any audio frames reached the log. Breaks a tie between two recordings
        /// starting at the same instant in favour of the one there is something to play in.
        var hasFrames: Bool

        init(
            segmentId: String, conversationId: String, startMs: Int64, endMs: Int64,
            hasFrames: Bool
        ) {
            self.segmentId = segmentId
            self.conversationId = conversationId
            self.startMs = startMs
            self.endMs = max(endMs, startMs)
            self.hasFrames = hasFrames
        }

        init(meta: SegmentMeta, conversationId: String) {
            self.init(
                segmentId: meta.segmentId, conversationId: conversationId,
                startMs: ConversationGrouper.segmentStartMs(meta),
                endMs: ConversationGrouper.segmentEndMs(meta),
                hasFrames: meta.frameCount > 0)
        }

        /// Start inclusive, end exclusive, so two recordings that abut hand over cleanly. A
        /// recording with no length (opened, no audio ever arrived) holds its one instant.
        func contains(_ wallMs: Int64) -> Bool {
            startMs == endMs ? wallMs == startMs : (startMs <= wallMs && wallMs < endMs)
        }
    }

    /// A conversation's extent, for a time that falls between its recordings.
    struct Window: Equatable, Sendable {
        var conversationId: String
        var range: Range<Int64>
    }

    /// How far from any conversation a time may fall and still open the nearest recording:
    /// half an hour, the length at which History starts labelling a stretch of quiet at all.
    /// A shorter gap reads on the day as part of what surrounds it, so landing on that is what
    /// the tap meant; further out, the nearest recording is a different part of the day.
    static let nearbyMs: Int64 = 30 * 60_000

    /// The recording a wall-clock moment belongs to (plan 7.9).
    ///
    /// 1. A recording whose span contains the time. Recordings overlap (a reconnect can open
    ///    one before the last has closed), and the latest start wins: it is the one that was
    ///    being written at that moment. On a tie, the one with frames; then the lower id, so
    ///    the answer never depends on the order the spool listed them.
    /// 2. A time between recordings inside a conversation (the gap after a reconnect) stays in
    ///    that conversation: the nearest of its recordings starting after the time, else the
    ///    nearest ending before it.
    /// 3. A time outside every conversation takes the same rule over every recording within
    ///    `nearbyMs` either side.
    ///
    /// Nil only when nothing was recorded near the time.
    static func segment(atWallMs wallMs: Int64, in spans: [Span], windows: [Window]) -> Span? {
        if let hit = spans.filter({ $0.contains(wallMs) }).max(by: { isOrderedBefore($0, $1) }) {
            return hit
        }
        // The window holding the time, latest start first — the same preference as step 1.
        let holding = windows.filter { $0.range.contains(wallMs) }
            .max {
                ($0.range.lowerBound, $1.conversationId) < ($1.range.lowerBound, $0.conversationId)
            }
        if let holding,
            let hit = nearest(
                to: wallMs, in: spans.filter { $0.conversationId == holding.conversationId },
                within: holding.range)
        {
            return hit
        }
        let (low, lowOverflow) = wallMs.subtractingReportingOverflow(nearbyMs)
        let (high, highOverflow) = wallMs.addingReportingOverflow(nearbyMs)
        return nearest(
            to: wallMs, in: spans,
            within: (lowOverflow ? .min : low)..<(highOverflow ? .max : high))
    }

    /// For a time no recording contains: the first recording to START after it inside
    /// `window` — where the audio resumes — else the last to END before it.
    static func nearest(to wallMs: Int64, in spans: [Span], within window: Range<Int64>) -> Span? {
        let after = spans.filter { $0.startMs > wallMs && $0.startMs < window.upperBound }
        if let next = after.min(by: {
            ($0.startMs, $0.hasFrames ? 0 : 1, $0.segmentId)
                < ($1.startMs, $1.hasFrames ? 0 : 1, $1.segmentId)
        }) {
            return next
        }
        let before = spans.filter { $0.endMs <= wallMs && $0.endMs > window.lowerBound }
        return before.max {
            ($0.endMs, $0.startMs, $0.hasFrames ? 1 : 0, $1.segmentId)
                < ($1.endMs, $1.startMs, $1.hasFrames ? 1 : 0, $0.segmentId)
        }
    }

    /// Step 1's order: later start, then frames, then the lower id.
    private static func isOrderedBefore(_ a: Span, _ b: Span) -> Bool {
        (a.startMs, a.hasFrames ? 1 : 0, b.segmentId)
            < (b.startMs, b.hasFrames ? 1 : 0, a.segmentId)
    }

    /// The transcript row a moment lands on: the last row starting at or before `wallMs`, or —
    /// when every timed row starts after it — the first row after it. Nil only when no row has
    /// a time to compare (an empty transcript, or a mock fixture with no stamps).
    ///
    /// Rows are compared by their stamps, not by position: a conversation whose members overlap
    /// can put a row out of time order, and "the last row in the list that starts before" would
    /// then land on the stray row rather than on what was being said. Equal stamps resolve to
    /// the later row going back and the earlier row going forward, which in a well-ordered
    /// transcript is simply the last and the first.
    ///
    /// A marker counts as a row: a moment inside a quiet stretch lands on "quiet for 25 min",
    /// which is the honest answer to "what was happening then?".
    static func rowIndex(in transcript: [TranscriptItem], atWallMs wallMs: Int64) -> Int? {
        var atOrBefore: (index: Int, ms: Int64)?
        var after: (index: Int, ms: Int64)?
        for (index, item) in transcript.enumerated() {
            guard let startedAt = item.startedAt else { continue }
            let ms = Int64((startedAt.timeIntervalSince1970 * 1000).rounded())
            if ms <= wallMs {
                if ms >= (atOrBefore?.ms ?? .min) { atOrBefore = (index, ms) }
            } else if ms < (after?.ms ?? .max) {
                after = (index, ms)
            }
        }
        return atOrBefore?.index ?? after?.index
    }
}

/// The hop from a wall-clock instant inside one member to a position on the conversation's
/// scrubber, shared by citations and moments so the two can never land in different places.
enum ConversationScrubber {
    /// Where `wallMs` inside member `segmentId` falls on the conversation's scrubber: MEDIA
    /// time, gaps excluded — the same accumulation `LiveWorld.walkMembers` lays the transcript
    /// rows out on, so a moment, a citation and a tap on the turn they name all agree.
    ///
    /// Nil when the member is not among `members`, its sidecar is missing, or it holds no audio
    /// — which is also when there is nothing to play. `wallMs` nil means the member's start.
    ///
    /// A member whose sidecar is missing adds nothing to the members after it, exactly as the
    /// transcript walk skips it; the two have to agree on every member or every later position
    /// is off by that member's audio.
    static func mediaOffset(
        ofWallMs wallMs: Int64?,
        inMember segmentId: String,
        members: [String],
        metas: [String: SegmentMeta]
    ) -> Int64? {
        var mediaBeforeMemberMs: Int64 = 0
        for member in members {
            guard let meta = metas[member] else { continue }
            let mediaMs = mediaDurationMs(meta)
            guard member == segmentId else {
                mediaBeforeMemberMs += mediaMs
                continue
            }
            // Where the instant sits on the scrubber, not where its recording starts — the same
            // wall→media conversion the transcript rows and the missing ticks use, through the
            // member's own gap records.
            //
            // This used to interpolate proportionally (a point 40% through the wall span is 40%
            // through the stored audio), which is only true when the gaps are spread evenly.
            // `SegmentMediaClock` replaced that guess for the transcript screen; leaving the copy
            // here meant tapping a citation and tapping the turn it cites landed in different
            // places on the same scrubber. Watch-side silence suppression (PebbleOS a47acac74)
            // makes the disagreement routine rather than occasional: the withheld quiet is
            // 4.1-13.8% of airtime, concentrated in the stretches where nobody is talking, which
            // is exactly where "evenly spread" stops being true.
            //
            // The anchor is `ConversationGrouper.segmentStartMs`, not `startTimeMs`, for the
            // reason `SegmentMeta.startWallMs` documents: `startTimeMs` is the STREAM's birth, so
            // for every mid-stream segment it is early by `firstSampleIndex` samples — a median
            // of 1 h across this library. Subtracting it from a wall time put `into` past the end
            // of the span and pinned the target at the segment's last sample.
            guard mediaMs > 0 else { return nil }
            let memberStartMs = ConversationGrouper.segmentStartMs(meta)
            let clock = SegmentMediaClock(meta)
            let into = min(max((wallMs ?? memberStartMs) - memberStartMs, 0), clock.wallSpanMs)
            // Untouched on the way in, untouched on the way out. `LiveWorld.drafts` (and
            // `TranscriptItems`) leave an inexact segment's offsets on the media clock rather
            // than acting on the proportional guess, so converting back here would apply an
            // inverse that was never applied — on the 2026-09-08 backup that is 169 segments and
            // 4,813 turns that move by over a minute, worst 14 h 44 m.
            return mediaBeforeMemberMs
                + (clock.isExact ? clock.media(fromWall: into) : min(into, clock.mediaSpanMs))
        }
        return nil
    }
}
