import Foundation
import GRDB
import SegmentStore

// The small mappings from what the library stores to what History's builders read, kept here so
// the app's live source and the real-backup tests take them from one place.

// MARK: - Which transcription state a recording is in

public enum HistoryTranscriptionStates {
    /// The state History draws a recording in.
    ///
    /// A finished state on the recording itself wins: a transcript that exists is finished work,
    /// whatever a queue row does or doesn't say about it (`ConversationMemberState`). Otherwise
    /// the queue's row, which moves first (pending → running → failed), else the recording's own.
    /// And "complete" with no transcript file is a bookkeeping fault, not silence: there are no
    /// words anyone can read, so it is drawn as waiting for them (`HistoryDayBuilder`).
    public static func resolve(
        segment: TranscriptionState, task: TranscriptionState?, hasTranscriptFile: Bool
    ) -> TranscriptionState {
        let state: TranscriptionState
        switch segment {
        case .complete, .noSpeech: state = segment
        default: state = task ?? segment
        }
        if state == .complete, !hasTranscriptFile { return .pending }
        return state
    }

    /// Settled with a transcript anyone can read (or settled as holding no speech).
    public static func isTranscribed(_ state: TranscriptionState) -> Bool {
        state == .complete || state == .noSpeech
    }

    /// On its way to a transcript. Failed is not: nothing is coming.
    public static func isWaiting(_ state: TranscriptionState) -> Bool {
        switch state {
        case .pending, .running, .uploading, .disabled: return true
        case .complete, .noSpeech, .failed: return false
        }
    }
}

// MARK: - Audio content

/// The descriptors History may show: labels for what a stretch of sound WAS that the classifier
/// only emits once they met its accuracy bar (plan 7.6, `docs/audio-content-classification.md`).
/// Anything else a span carries — today only `fewWords`, which describes the transcript and not
/// the sound — is the classifier's own bookkeeping and is drawn as plain "No conversation".
///
/// None of these is emitted yet. The list is an allow-list on purpose: a new internal label the
/// classifier adds can never reach the screen by accident; a real content label has to be added
/// here, by name, when it ships.
public enum HistoryContentDescriptors {
    public static let shown: Set<String> = ["music", "tvOrVideo"]

    public static func displayable(_ descriptor: String?) -> String? {
        guard let descriptor, shown.contains(descriptor) else { return nil }
        return descriptor
    }
}

extension HistoryContentSpanInput {
    /// The classifier's verdict as the day builder reads it, with its descriptor passed through
    /// only when it is one History may show (`HistoryContentDescriptors`).
    public init(span: AudioContentSpan) {
        self.init(
            startMs: span.startMs, endMs: span.endMs,
            kind: span.kind == .conversation ? .conversation : .noConversation,
            descriptor: HistoryContentDescriptors.displayable(span.descriptor))
    }
}

// MARK: - Follow-ups

extension FollowUpPlacement {
    /// The one moment a day, a week and the month file this follow-up under: when it was said,
    /// else when its recording started, else the day its id or creation names.
    public var atMs: Int64 {
        switch self {
        case .moment(let ms, _): return ms
        case .span(let range): return range.lowerBound
        case .dayOnly(let ms): return ms
        }
    }
}

extension HistoryFollowUpInput {
    /// A record placed on the clock, as the day builder attaches it to a card.
    public init(record: HistoryFollowUpRecord, placement: FollowUpPlacement, nowMs: Int64) {
        let where_: Placement
        switch placement {
        case .moment(let ms, _): where_ = .moment(ms)
        case .span(let range): where_ = .span(startMs: range.lowerBound, endMs: range.upperBound)
        case .dayOnly: where_ = .dayOnly
        }
        self.init(
            id: record.id, text: record.text, done: record.done, isSnoozed: record.isSnoozed(at: nowMs),
            isApproximate: placement.isApproximate, placement: where_)
    }
}

/// A follow-up record, placed, and the logical day it belongs to.
public struct HistoryPlacedRecord: Equatable, Sendable {
    public var record: HistoryFollowUpRecord
    public var placement: FollowUpPlacement
    public var dayKey: String

    public init(record: HistoryFollowUpRecord, placement: FollowUpPlacement, dayKey: String) {
        self.record = record
        self.placement = placement
        self.dayKey = dayKey
    }

    public func placed(nowMs: Int64) -> HistoryPlacedFollowUp {
        HistoryPlacedFollowUp(line: record.line(placement: placement, nowMs: nowMs), atMs: placement.atMs)
    }
}

extension HistoryPlacedRecord {
    /// Places each record (`FollowUpPlacement.placement`) and files it under the day of its
    /// moment. A record that cannot be placed at all, or that was said inside a conversation
    /// hidden by a pending delete, is left out: it is not on any day.
    ///
    /// A conversation owns a RANGE of a recording, so hiding is decided by where the follow-up
    /// was said: a record placed at a moment inside a hidden piece is hidden; one that could only
    /// be placed by its recording (no located quote) is hidden only when the whole recording is.
    ///
    /// - Parameters:
    ///   - segmentSpan: a recording's wall extent, nil when it no longer exists.
    ///   - hiddenSegmentIds: recordings held entirely by conversations inside their undo window.
    ///   - hiddenWallRanges: the wall ranges of those conversations' pieces.
    public static func place(
        _ records: [HistoryFollowUpRecord], segmentSpan: (String) -> Range<Int64>?,
        hiddenSegmentIds: Set<String> = [], hiddenWallRanges: [Range<Int64>] = [],
        dayKey: (Int64) -> String
    ) -> [HistoryPlacedRecord] {
        records.compactMap { record in
            if let segmentId = record.sourceSegmentId, hiddenSegmentIds.contains(segmentId) { return nil }
            guard let placement = FollowUpPlacement.placement(of: record, segmentSpan: segmentSpan) else {
                return nil
            }
            if case .moment(let ms, _) = placement, hiddenWallRanges.contains(where: { $0.contains(ms) }) {
                return nil
            }
            return HistoryPlacedRecord(record: record, placement: placement, dayKey: dayKey(placement.atMs))
        }
    }
}

// MARK: - Conversation pieces on the wall clock

/// Where the pieces of conversations sit on the wall clock. A conversation is an ordered list
/// of PIECES (`ConversationMember`: a range of one recording's stored audio), so "the
/// conversation's recordings" over-reads: a recording usually holds the end of one conversation
/// and the start of the next.
public enum HistoryPieces {
    /// A piece's wall range: its media bounds through the recording's own clock
    /// (`SegmentMediaClock.wallOffset(ofMedia:)`, the rule every other reader converts by) from
    /// the recording's wall anchor, clamped into `extent` (the recording's placement,
    /// `HistorySegmentState`). An open bound is the extent's edge; a whole piece is the extent.
    public static func wallRange(
        of piece: ConversationMember, meta: SegmentMeta, extent: Range<Int64>
    ) -> Range<Int64> {
        guard !piece.isWhole else { return extent }
        let clock = SegmentMediaClock(meta)
        func wall(_ mediaMs: Int64) -> Int64 {
            min(max(meta.startWallMs + clock.wallOffset(ofMedia: mediaMs), extent.lowerBound), extent.upperBound)
        }
        let lower = piece.startMediaMs.map(wall) ?? extent.lowerBound
        let upper = piece.endMediaMs.map(wall) ?? extent.upperBound
        return lower..<max(upper, lower)
    }

    /// What a set of conversations holds, as History hides it while they are in their undo
    /// window: the wall ranges of their pieces, and the recordings they hold ENTIRELY (every
    /// piece of which is theirs — `owners` lists each recording's pieces across the library).
    public static func hidden(
        _ conversationIds: Set<String>, pieces: [String: [ConversationMember]],
        owners: [String: [String]], metas: [String: SegmentMeta], extents: [String: Range<Int64>]
    ) -> (wallRanges: [Range<Int64>], wholeSegments: Set<String>) {
        var ranges: [Range<Int64>] = []
        var whole: Set<String> = []
        for id in conversationIds.sorted() {
            for piece in pieces[id] ?? [] {
                if let meta = metas[piece.segmentId], let extent = extents[piece.segmentId] {
                    let range = wallRange(of: piece, meta: meta, extent: extent)
                    if !range.isEmpty { ranges.append(range) }
                }
                if (owners[piece.segmentId] ?? [id]).allSatisfy(conversationIds.contains) {
                    whole.insert(piece.segmentId)
                }
            }
        }
        return (ranges, whole)
    }
}

// MARK: - Reads

/// The small windowed reads History needs besides `ConversationQueries.rows(overlappingMs:)` and
/// `FollowUpStore.history(inWallWindow:segmentIds:)`: each is one indexed query over the ids the
/// caller already has, never a table scan of the library.
public struct HistoryLibraryQueries: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public struct TaskRow: Equatable, Sendable {
        public var state: TranscriptionState
        public var lastError: String?
    }

    /// The transcription queue's rows for these recordings. A recording with no row (pruned, or
    /// never queued because it arrived transcribed) is absent.
    public func tasks(segmentIds: [String]) async throws -> [String: TaskRow] {
        guard !segmentIds.isEmpty else { return [:] }
        let ids = String(decoding: try JSONEncoder().encode(segmentIds), as: UTF8.self)
        return try await db.reader.read { db in
            var out: [String: TaskRow] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT segmentId, state, lastError FROM transcription_tasks
                    WHERE segmentId IN (SELECT value FROM json_each(?))
                    """,
                arguments: [ids])
            {
                guard let state = TranscriptionState(rawValue: row["state"]) else { continue }
                out[row["segmentId"]] = TaskRow(state: state, lastError: row["lastError"])
            }
            return out
        }
    }

    /// A conversation carrying a tag.
    public struct TaggedConversation: Equatable, Sendable {
        public var id: String
        public var startMs: Int64
        public var endMs: Int64
        public var title: String?
        public var summary: String?
    }

    /// The conversations carrying a tag (matched case-insensitively; a tag the person removed does
    /// not count), newest first. Through the tag's unique name, then its rows in
    /// `conversation_tags` and the conversations by id — never a walk of the library.
    public func conversations(taggedWith tag: String) async throws -> [TaggedConversation] {
        try await db.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT c.id AS id, c.startMs AS startMs, c.endMs AS endMs, a.title AS title,
                        a.summary AS summary
                    FROM tags t
                    JOIN conversation_tags ct ON ct.tagId = t.id AND ct.source <> '\(TagSource.removed)'
                    JOIN conversations c ON c.id = ct.conversationId
                    LEFT JOIN annotations a ON a.conversationId = c.id
                    WHERE t.name = ? COLLATE NOCASE
                    ORDER BY c.startMs DESC, c.id
                    """,
                arguments: [tag]
            ).map { row in
                let start: Int64 = row["startMs"]
                return TaggedConversation(
                    id: row["id"], startMs: start, endMs: row["endMs"] ?? start, title: row["title"],
                    summary: row["summary"])
            }
        }
    }

    /// One piece of a conversation as History reads it: the range of the recording, and the
    /// state the grouping stored for THAT piece (`NoSpeech` for the silent part of a transcribed
    /// recording, whatever the rest of it holds).
    public struct Piece: Equatable, Sendable {
        public var member: ConversationMember
        public var state: TranscriptionState?

        public init(member: ConversationMember, state: TranscriptionState?) {
            self.member = member
            self.state = state
        }
    }

    /// Each conversation's pieces, in order.
    public func pieces(ofConversations conversationIds: [String]) async throws -> [String: [Piece]] {
        guard !conversationIds.isEmpty else { return [:] }
        let ids = String(decoding: try JSONEncoder().encode(conversationIds), as: UTF8.self)
        return try await db.reader.read { db in
            var out: [String: [Piece]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT conversationId, segmentId, startMediaMs, endMediaMs, transcriptionState
                    FROM conversation_segments
                    WHERE conversationId IN (SELECT value FROM json_each(?))
                    ORDER BY conversationId, ordinal
                    """,
                arguments: [ids])
            {
                out[row["conversationId"], default: []].append(
                    Piece(
                        member: ConversationMember(
                            segmentId: row["segmentId"], startMediaMs: row["startMediaMs"],
                            endMediaMs: row["endMediaMs"]),
                        state: (row["transcriptionState"] as String?).flatMap(TranscriptionState.init(rawValue:))))
            }
            return out
        }
    }

    /// Every conversation holding a piece of each of these recordings (indexed by
    /// `conversation_segments_segment`).
    public func owners(ofSegments segmentIds: [String]) async throws -> [String: [String]] {
        guard !segmentIds.isEmpty else { return [:] }
        let ids = String(decoding: try JSONEncoder().encode(segmentIds), as: UTF8.self)
        return try await db.reader.read { db in
            var out: [String: [String]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT segmentId, conversationId FROM conversation_segments
                    WHERE segmentId IN (SELECT value FROM json_each(?))
                    ORDER BY segmentId, COALESCE(startMediaMs, 0)
                    """,
                arguments: [ids])
            {
                out[row["segmentId"], default: []].append(row["conversationId"])
            }
            return out
        }
    }
}
