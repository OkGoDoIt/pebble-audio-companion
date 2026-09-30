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
    /// moment. A record that cannot be placed at all, or that belongs to a recording hidden by a
    /// pending delete, is left out: it is not on any day.
    ///
    /// - Parameters:
    ///   - segmentSpan: a recording's wall extent, nil when it no longer exists.
    ///   - hiddenSegmentIds: recordings of conversations inside their undo window.
    public static func place(
        _ records: [HistoryFollowUpRecord], segmentSpan: (String) -> Range<Int64>?,
        hiddenSegmentIds: Set<String> = [], dayKey: (Int64) -> String
    ) -> [HistoryPlacedRecord] {
        records.compactMap { record in
            if let segmentId = record.sourceSegmentId, hiddenSegmentIds.contains(segmentId) { return nil }
            guard let placement = FollowUpPlacement.placement(of: record, segmentSpan: segmentSpan) else {
                return nil
            }
            return HistoryPlacedRecord(record: record, placement: placement, dayKey: dayKey(placement.atMs))
        }
    }
}

// MARK: - Reads

/// The two small windowed reads History needs besides `ConversationQueries.rows(overlappingMs:)`
/// and `FollowUpStore.history(inWallWindow:segmentIds:)`: each is one indexed query over the ids
/// the caller already has, never a table scan of the library.
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

    /// Each conversation's member recordings, in order.
    public func members(ofConversations conversationIds: [String]) async throws -> [String: [String]] {
        guard !conversationIds.isEmpty else { return [:] }
        let ids = String(decoding: try JSONEncoder().encode(conversationIds), as: UTF8.self)
        return try await db.reader.read { db in
            var out: [String: [String]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT conversationId, segmentId FROM conversation_segments
                    WHERE conversationId IN (SELECT value FROM json_each(?))
                    ORDER BY conversationId, ordinal
                    """,
                arguments: [ids])
            {
                out[row["conversationId"], default: []].append(row["segmentId"])
            }
            return out
        }
    }
}
