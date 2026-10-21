import AppDB
import Foundation
import Intelligence
import LiveAudio
import SegmentStore
import Transcription

import func SearchKit.pieceWallWindow

// A conversation is an ordered list of PIECES — a range of each member segment's stored audio
// (`AppDB/ConversationUnits.swift`) — and one segment routinely holds the end of one
// conversation and the start of the next. Every reader in the app that used to walk "the
// conversation's segments" therefore has to walk its pieces, or it shows, plays, exports,
// indexes and cites the neighbour's words as this conversation's own. Nothing fails to compile
// when a reader forgets: the whole segment is still there to be read.
//
// This file is the arithmetic those readers share, so that they cannot disagree about it:
//
//  - `PieceSpan`: one piece on the three clocks the app reads it on — frames (what is played
//    and exported), stored-audio ms (what transcript timings are on) and wall ms (what the
//    segment's gap records are on).
//  - `ConversationTimeline`: the pieces laid end to end, which is the conversation's own clock
//    — the scrubber. A position on it is the length of the earlier pieces plus how far into
//    this one; nothing in it is a position in a segment.
//  - `ConversationText`: the words of a conversation, from its pieces only.

/// One piece of a conversation, placed in its segment.
struct PieceSpan: Equatable, Sendable {
    let member: ConversationMember
    /// The piece as indexes into the segment's sequence-sorted frame log.
    let frames: Range<Int>
    /// The same range in the segment's stored-audio clock. Snapped to whole frames, so the
    /// length the scrubber shows is exactly the audio the player will be handed.
    let mediaMs: Range<Int64>
    /// The piece as wall offsets into the segment, for the gap records — which are on the wall
    /// clock because they come from sample indices that keep counting through audio nobody
    /// stored. Nil for a whole segment: nothing to clip. An open end is unbounded rather than
    /// the segment's span, because the live preview can run a flush ahead of the metadata.
    let wallMs: Range<Int64>?

    var durationMs: Int64 { mediaMs.upperBound - mediaMs.lowerBound }

    init(_ member: ConversationMember, meta: SegmentMeta) {
        self.init(
            member, clock: SegmentMediaClock(meta), frameDurationMs: Int64(meta.frameDurationMs))
    }

    /// For a caller that has already built the segment's clock (building one walks every gap
    /// record, and silence suppression multiplied those by an order of magnitude).
    init(_ member: ConversationMember, clock: SegmentMediaClock, frameDurationMs: Int64) {
        self.member = member
        let frameMs = max(frameDurationMs, 1)
        let spanMs = max(clock.mediaSpanMs, 0)
        // Rounded UP: a segment whose sidecar has no frame count yet reports its wall span as
        // its audio, which need not be a whole number of frames, and the tail must not be cut.
        let frameCount = Int((spanMs + frameMs - 1) / frameMs)
        frames = SegmentFrameRange.frames(
            fromMediaMs: member.startMediaMs, toMediaMs: member.endMediaMs,
            frameCount: frameCount, frameDurationMs: frameMs)
        let lower = min(Int64(frames.lowerBound) * frameMs, spanMs)
        let upper = min(Int64(frames.upperBound) * frameMs, spanMs)
        mediaMs = lower..<max(upper, lower)

        // The kit's rule, so this window and the one the transcript rows are cut by
        // (`SearchKit.pieceTimeline`) are the same window.
        wallMs = pieceWallWindow(member, clock: clock)
    }

    /// How far into the PIECE a moment of the segment's stored audio is. A moment outside the
    /// piece lands on its nearer edge: a turn belongs to the piece it starts in, so its last
    /// words can run a little past the end, and the scrubber has nowhere further to go.
    func offset(ofSegmentMediaMs segmentMediaMs: Int64) -> Int64 {
        min(max(segmentMediaMs - mediaMs.lowerBound, 0), durationMs)
    }

    /// The piece's own frames out of the segment's whole log. Cut against the log actually
    /// read rather than the sidecar's count, which lags while a segment is still open.
    func slice<Frame>(_ log: [Frame]) -> ArraySlice<Frame> {
        let lower = min(frames.lowerBound, log.count)
        let upper = member.endMediaMs == nil ? log.count : min(frames.upperBound, log.count)
        return log[lower..<max(upper, lower)]
    }
}

/// A conversation's pieces laid end to end: the clock its player, its transcript rows and its
/// citations are all placed on.
struct ConversationTimeline: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var span: PieceSpan
        /// Stored audio in the pieces before this one — where it starts on the scrubber.
        var beforeMs: Int64
    }

    let entries: [Entry]
    /// Stored audio across every piece: the scrubber's length. Never the wall span, and never
    /// the members' whole segments.
    let durationMs: Int64

    /// A piece whose segment has no sidecar (retention took it between the read of the grouping
    /// and this one) contributes nothing, exactly as the walk that renders the rows skips it.
    init(members: [ConversationMember], metas: [String: SegmentMeta]) {
        var entries: [Entry] = []
        var total: Int64 = 0
        for member in members {
            guard let meta = metas[member.segmentId] else { continue }
            let span = PieceSpan(member, meta: meta)
            entries.append(Entry(span: span, beforeMs: total))
            total += span.durationMs
        }
        self.entries = entries
        durationMs = total
    }

    /// Where a moment of a segment — `mediaMs` into its stored audio — sits on this
    /// conversation's scrubber. Nil when the conversation owns no piece of that segment, or a
    /// piece with no stored audio in it (there is then nothing to play from).
    func offset(segmentId: String, mediaMs: Int64) -> Int64? {
        let candidates = entries.filter { $0.span.member.segmentId == segmentId }
        guard
            let entry = candidates.first(where: { $0.span.member.contains(mediaMs: mediaMs) })
                ?? candidates.last,
            entry.span.durationMs > 0
        else { return nil }
        return entry.beforeMs + entry.span.offset(ofSegmentMediaMs: mediaMs)
    }
}

/// A conversation's audio, as the frames its player is handed.
enum ConversationAudio {
    /// Every piece's own frames, in order — never a member's whole log. `readFrames` is the
    /// spool's sequence-sorted read; `frameDurationMs` answers per segment and falls back to
    /// the 20 ms every recording made so far uses.
    static func payloads(
        of members: [ConversationMember],
        frameDurationMs: (String) -> Int64? = { _ in nil },
        readFrames: (String) -> [FrameRecord]
    ) -> [[UInt8]] {
        members.flatMap { member -> [[UInt8]] in
            let log = readFrames(member.segmentId)
            let range = SegmentFrameRange.frames(
                fromMediaMs: member.startMediaMs, toMediaMs: member.endMediaMs,
                frameCount: log.count, frameDurationMs: frameDurationMs(member.segmentId) ?? 20)
            return log[range].map(\.payload)
        }
    }
}

/// The words of a conversation.
enum ConversationText {
    /// One member's transcript cut to the piece the conversation owns, with looped transcriber
    /// output collapsed — in THAT order. `piece` rebuilds the text from the turns it keeps, so
    /// collapsing first would lose the notes that say a loop was removed.
    static func piece(
        _ member: ConversationMember, of transcript: SegmentTranscript?
    ) -> SegmentTranscript? {
        transcript?.piece(member).withLoopedArtefactsCollapsed()
    }

    /// Everything said in the conversation, one member per line — what Spotlight indexes and
    /// what the App Intents entity hands Siri. Nil when nothing was said.
    static func joined(
        _ members: [ConversationMember], load: (String) -> SegmentTranscript?
    ) -> String? {
        let text = members
            .compactMap { piece($0, of: load($0.segmentId))?.text }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}

extension ConversationDetail {
    /// The pieces this conversation is made of, in order.
    var pieces: [ConversationMember] { members.map(\.member) }
}
