import Foundation
import SegmentStore

// The inputs `HistoryDayBuilder` reads (plan 7.10). Plain values the caller gathers — the
// segment store's metas, the pause journal, transcripts reduced to speech runs, the chapter
// stage's rows, conversations, follow-ups placed on the clock, the audio classifier's spans and
// deletions — so the builder itself touches no file, database or clock.
//
// All times are epoch milliseconds on the wall clock.

/// One stretch of absolute time that belongs to the day, in the zone in effect over it
/// (`ZoneTimeline.windows(of:)`).
public struct HistoryDayWindow: Equatable, Sendable {
    public var range: Range<Int64>
    public var zoneID: String

    public init(range: Range<Int64>, zoneID: String) {
        self.range = range
        self.zoneID = zoneID
    }

    /// `ZoneTimeline.windows(of:)`'s shape.
    public static func from(_ windows: [(range: Range<Int64>, zoneID: String)]) -> [HistoryDayWindow] {
        windows.map { HistoryDayWindow(range: $0.range, zoneID: $0.zoneID) }
    }
}

/// A wall-clock stretch where a transcript has words, and the recording it came from.
///
/// The caller builds these per segment with `ConversationBoundaryDetector.spokenRuns` (the same
/// placement the grouper uses), so a run sits where the conversation screen puts the words.
public struct HistorySpeechRun: Equatable, Sendable {
    public var segmentId: String
    public var startMs: Int64
    public var endMs: Int64

    public init(segmentId: String, startMs: Int64, endMs: Int64) {
        self.segmentId = segmentId
        self.startMs = startMs
        self.endMs = max(endMs, startMs)
    }
}

/// Where one recording sits on the wall clock and how far its transcription has got.
public struct HistorySegmentState: Equatable, Sendable {
    public var segmentId: String
    public var startMs: Int64
    public var endMs: Int64
    public var state: TranscriptionState
    /// The recorded reason for a `.failed` transcription (the queue's last error), if any.
    public var failureReason: String?

    public init(
        segmentId: String, startMs: Int64, endMs: Int64, state: TranscriptionState,
        failureReason: String? = nil
    ) {
        self.segmentId = segmentId
        self.startMs = startMs
        self.endMs = max(endMs, startMs)
        self.state = state
        self.failureReason = failureReason
    }

    /// The recording's extent exactly as `CoverageComputer` places its recorded audio (sample
    /// indexes on the stream's wall anchor), so "recorded" and "which recording" can never
    /// disagree about a minute. `state` defaults to the sidecar's own; pass the queue's when it
    /// is fresher. Nil when the recording holds no sample yet.
    public init?(meta: SegmentMeta, state: TranscriptionState? = nil, failureReason: String? = nil) {
        guard let first = meta.firstSampleIndex, let last = meta.lastSampleIndexExclusive,
            last > first
        else { return nil }
        self.init(
            segmentId: meta.segmentId,
            startMs: ConversationGrouper.wallMs(ofSample: first, in: meta),
            endMs: ConversationGrouper.wallMs(ofSample: last, in: meta),
            state: state ?? meta.transcriptionState,
            failureReason: failureReason)
    }
}

/// A chapter written by the chapter stage (plan 7.3). No such stage exists yet; the builder
/// takes them so the day is ready for it.
public struct HistoryChapterInput: Equatable, Sendable {
    public var id: String
    public var startMs: Int64
    public var endMs: Int64
    public var title: String?
    public var summary: String?
    public var tags: [String]
    public var people: [String]
    public var timesApproximate: Bool

    public init(
        id: String, startMs: Int64, endMs: Int64, title: String?, summary: String? = nil,
        tags: [String] = [], people: [String] = [], timesApproximate: Bool = false
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = max(endMs, startMs)
        self.title = title
        self.summary = summary
        self.tags = tags
        self.people = people
        self.timesApproximate = timesApproximate
    }
}

/// A conversation, for the cards that stand in for talk no chapter covers yet.
public struct HistoryConversationInput: Equatable, Sendable {
    public var id: String
    public var startMs: Int64
    public var endMs: Int64
    public var title: String?
    /// Its member recordings, in order. Speech is assigned to a conversation through these.
    public var segmentIds: [String]

    public init(id: String, startMs: Int64, endMs: Int64, title: String?, segmentIds: [String]) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.title = title
        self.segmentIds = segmentIds
    }
}

/// A follow-up, already placed on the wall clock by the caller.
public struct HistoryFollowUpInput: Equatable, Sendable {
    public enum Placement: Equatable, Sendable {
        /// Said at one moment.
        case moment(Int64)
        /// Said across a stretch.
        case span(startMs: Int64, endMs: Int64)
        /// Known to belong to the day, but not when in it.
        case dayOnly
    }

    public var id: String
    public var text: String
    public var done: Bool
    public var isSnoozed: Bool
    public var isApproximate: Bool
    public var placement: Placement

    public init(
        id: String, text: String, done: Bool, isSnoozed: Bool = false,
        isApproximate: Bool = false, placement: Placement
    ) {
        self.id = id
        self.text = text
        self.done = done
        self.isSnoozed = isSnoozed
        self.isApproximate = isApproximate
        self.placement = placement
    }
}

/// The audio classifier's verdict on a stretch (plan 7.6). No classifier exists yet.
public struct HistoryContentSpanInput: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case conversation, noConversation
    }

    public var startMs: Int64
    public var endMs: Int64
    public var kind: Kind
    /// Present ONLY when the classifier met its accuracy bar for the label.
    public var descriptor: String?

    public init(startMs: Int64, endMs: Int64, kind: Kind, descriptor: String? = nil) {
        self.startMs = startMs
        self.endMs = max(endMs, startMs)
        self.kind = kind
        self.descriptor = descriptor
    }
}

/// Recorded time that was deleted (plan 7.11). Nothing records these yet.
public struct HistoryDeletedSpanInput: Equatable, Sendable {
    public var startMs: Int64
    public var endMs: Int64
    public var cause: HistoryDeletionCause

    public init(startMs: Int64, endMs: Int64, cause: HistoryDeletionCause) {
        self.startMs = startMs
        self.endMs = max(endMs, startMs)
        self.cause = cause
    }
}

/// Every threshold the day builder uses, in one place so they can be tuned against real days.
public struct HistoryDayRules: Equatable, Sendable {
    /// Two runs of speech belong to one card when less than this separates them and the time
    /// between holds nothing but quiet, recorded time with no words, or loss. The grouper's own
    /// "a silence this long may be a boundary" threshold (`BoundaryPolicy.quietCandidateMs`,
    /// 8 min), so a card never bridges a silence the grouper would consider cutting at.
    public var talkBridgeMs: Int64
    /// Recorded sound with no conversation is drawn as its own item only from this length on;
    /// shorter runs are part of the surrounding quiet (plan 7.6).
    public var noConversationMinimumMs: Int64
    /// Holes of quiet up to this long do not break a no-conversation run.
    public var noConversationHoleMs: Int64
    /// Items shorter than this fold into a neighbour — never loss, a deletion, or a pause the
    /// person made (see `HistoryDayBuilder` for which neighbour may take which item).
    public var foldBelowMs: Int64
    /// A follow-up said across a span attaches to the card holding at least this share of it.
    public var followUpSpanShare: Double
    /// OFF by default — the specified rule is that loss outside a card is always its own item,
    /// however short. On: loss shorter than `foldBelowMs` beside a card or beside recorded time
    /// (quiet, no conversation, not transcribed yet, transcription failed) is carried as that
    /// neighbour's `missingMs` instead, still counted and still named (`HistoryGap.missingMs`,
    /// `lossCauses`). Proposed after the real backup: the watch's buffer drops arrive in bursts
    /// of dozens of sub-second records, and one item each drew 2026-09-24 as 949 rows.
    public var carryShortLoss: Bool

    public init(
        talkBridgeMs: Int64 = BoundaryPolicy.default.quietCandidateMs,
        noConversationMinimumMs: Int64 = 15 * 60_000,
        noConversationHoleMs: Int64 = 2 * 60_000,
        foldBelowMs: Int64 = 2 * 60_000,
        followUpSpanShare: Double = 0.8,
        carryShortLoss: Bool = false
    ) {
        self.talkBridgeMs = talkBridgeMs
        self.noConversationMinimumMs = noConversationMinimumMs
        self.noConversationHoleMs = noConversationHoleMs
        self.foldBelowMs = foldBelowMs
        self.followUpSpanShare = followUpSpanShare
        self.carryShortLoss = carryShortLoss
    }

    public static let `default` = HistoryDayRules()
}
