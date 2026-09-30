import Foundation

// The conversation UNIT (2026-09-30).
//
// A conversation used to be a set of WHOLE ~15-minute recording segments, so it could only begin
// or end where the recorder happened to rotate its file, and an always-on recorder produced
// "conversations" of five, ten and twenty-four hours. A segment is a storage detail; a
// conversation is a stretch of talk about one thing. The two are now separate:
//
//  - a conversation is an ordered list of PIECES, each a range of one segment's stored audio
//    (`ConversationMember`), so it can start and stop anywhere between two turns;
//  - one segment can therefore hold the end of one conversation and the start of the next;
//  - where a conversation starts is a `ConversationCut`: a position in a segment's stored-audio
//    clock, which survives regrouping, re-transcription and retention because segment ids and
//    media offsets never change.
//
// Every sample still belongs to exactly one conversation (the pieces of all conversations tile
// the library), which is what keeps Delete complete.

/// The single place other modules ask whether conversations are topic-sized — cut between turns
/// by `ConversationSegmenter` — rather than whole-segment runs. History reads conversations as
/// its day cards when this is true.
public enum ConversationUnits {
    public static let isTopicSized = true
}

/// One piece of a conversation: a range of one segment's stored audio.
///
/// The bounds are in the segment's MEDIA clock (milliseconds of stored audio from its first
/// frame — the clock transcript turns and follow-up sources already use), so they do not move
/// when the wall-clock placement of a segment is repaired. `nil` means "from the segment's first
/// frame" / "to its last", which is how a whole segment, and the still-growing end of the open
/// one, are written.
public struct ConversationMember: Equatable, Hashable, Sendable {
    public var segmentId: String
    public var startMediaMs: Int64?
    public var endMediaMs: Int64?

    public init(segmentId: String, startMediaMs: Int64? = nil, endMediaMs: Int64? = nil) {
        self.segmentId = segmentId
        self.startMediaMs = startMediaMs.flatMap { $0 > 0 ? $0 : nil }
        self.endMediaMs = endMediaMs
    }

    /// True when the piece is the whole segment.
    public var isWhole: Bool { startMediaMs == nil && endMediaMs == nil }

    /// Whether something that STARTS at this media offset belongs to the piece. A turn belongs
    /// to the conversation its first instant falls in, so nothing is ever in two.
    public func contains(mediaMs: Int64) -> Bool {
        if let startMediaMs, mediaMs < startMediaMs { return false }
        if let endMediaMs, mediaMs >= endMediaMs { return false }
        return true
    }

    /// The piece as a half-open range clamped into `0..<mediaSpanMs`.
    public func mediaRange(mediaSpanMs: Int64) -> Range<Int64> {
        let lower = min(max(startMediaMs ?? 0, 0), max(mediaSpanMs, 0))
        let upper = min(max(endMediaMs ?? mediaSpanMs, lower), max(mediaSpanMs, lower))
        return lower..<upper
    }
}

/// A position where a conversation starts: `mediaMs` into `segmentId`'s stored audio. `0` is the
/// segment's own start (the join with the segment before it).
public struct ConversationCut: Equatable, Hashable, Sendable, Comparable {
    public var segmentId: String
    public var mediaMs: Int64

    public init(segmentId: String, mediaMs: Int64) {
        self.segmentId = segmentId
        self.mediaMs = max(mediaMs, 0)
    }

    public static func < (a: ConversationCut, b: ConversationCut) -> Bool {
        a.segmentId == b.segmentId ? a.mediaMs < b.mediaMs : a.segmentId < b.segmentId
    }

    /// The id of the conversation that starts here. A conversation that starts with its segment
    /// keeps the id it always had (`conv-<segmentId>`), so nothing keyed on those moves.
    public var conversationId: String {
        mediaMs > 0 ? "conv-\(segmentId)-m\(mediaMs)" : "conv-\(segmentId)"
    }
}
