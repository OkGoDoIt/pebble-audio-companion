import Foundation
import GRDB
import SegmentStore
import WireProtocol

// The conversation model (plan Part 3, normative). Conversations are the UX unit; segments
// stay the storage/transport unit. Grouping is DERIVED state: rebuildable idempotently from
// the segment metas + the pause journal — same input ⇒ same conversation ids.

/// One grouped conversation, before/after persistence into the derived tables.
public struct GroupedConversation: Equatable, Sendable {
    /// Deterministic: `conv-<firstMemberSegmentId>` (stabilized against a previous grouping
    /// when retention removes the first member — see `group(segments:...)`).
    public var id: String
    public var startMs: Int64
    /// Wall-clock end of the last member so far. For a live conversation this is the
    /// last-flushed extent end; `isLive` (not a nil end) marks liveness so queries and
    /// coverage never have to special-case NULL.
    public var endMs: Int64
    /// IANA zone id — the first member's `recordedTimeZone`, falling back to the device's
    /// current zone (plan 6.4) when the member predates the field.
    public var timeZoneID: String
    /// True while the last member is the store's open segment.
    public var isLive: Bool
    /// Ordered member segment ids.
    public var memberSegmentIds: [String]

    public init(
        id: String, startMs: Int64, endMs: Int64, timeZoneID: String, isLive: Bool,
        memberSegmentIds: [String]
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.timeZoneID = timeZoneID
        self.isLive = isLive
        self.memberSegmentIds = memberSegmentIds
    }
}

public enum ConversationGrouper {
    /// Segments with a start/end gap under this chain into one conversation (any stream id).
    public static let chainWindowMs: Int64 = 5 * 60 * 1000

    // --- segment wall-clock endpoints ---------------------------------------------------------

    /// `startTimeMs` is the STREAM birth wall clock (sample index 0); a segment's own start is
    /// its first persisted sample anchored there. Falls back to `receivedAtMs` (phone clock)
    /// for extent-less segments.
    public static func segmentStartMs(_ meta: SegmentMeta) -> Int64 {
        guard let first = meta.firstSampleIndex else { return meta.receivedAtMs }
        return wallMs(ofSample: first, in: meta)
    }

    /// End = start anchor + duration derived from the sample extents at the segment's rate
    /// (16 kHz in practice); falls back to `closedAtMs` where extents are missing.
    public static func segmentEndMs(_ meta: SegmentMeta) -> Int64 {
        guard meta.firstSampleIndex != nil, let last = meta.lastSampleIndexExclusive else {
            return meta.closedAtMs ?? segmentStartMs(meta)
        }
        return wallMs(ofSample: last, in: meta)
    }

    static func wallMs(ofSample sampleIndex: UInt64, in meta: SegmentMeta) -> Int64 {
        let rate = meta.sampleRateHz > 0 ? UInt64(meta.sampleRateHz) : 16_000
        return Int64(meta.startTimeMs) + Int64(sampleIndex * 1000 / rate)
    }

    // --- split predicates ---------------------------------------------------------------------

    /// An explicit on-watch/app Stop: closeReason "stopped" with StopReason.userDisabled.
    static func endsWithUserStop(_ meta: SegmentMeta) -> Bool {
        guard let close = meta.closeReason, close.kind == CloseReasonMeta.kindStopped,
            let raw = close.stopReasonRaw
        else { return false }
        return raw == Int(StopReason.userDisabled.rawValue)
    }

    /// True when a pause-journal interval overlaps the no-audio window BETWEEN two segments.
    /// Overlap (not strict containment) tolerates the small clock jitter between the pause ack
    /// and the segment close it causes. A pause wholly inside one segment's span never matches
    /// (the rule applies between segments, never within one).
    static func pauseFalls(
        between prevEndMs: Int64, and nextStartMs: Int64, pauses: [PauseInterval]
    ) -> Bool {
        guard nextStartMs > prevEndMs else { return false }
        return pauses.contains { pause in
            let end = pause.endMs ?? Int64.max
            return pause.startMs < nextStartMs && end > prevEndMs
        }
    }

    // --- grouping -----------------------------------------------------------------------------

    /// Pure grouping. Rules (plan Part 3):
    /// - same `streamId` chains (rotation/reattach), OR next start < 5 min after previous end
    ///   (any stream id);
    /// - VAD quiet never splits (quiet lives inside segments — nothing to do here);
    /// - PRECEDENCE: an explicit user Stop on the previous segment, or a pause-journal entry
    ///   between the segments, ALWAYS splits — even same-stream within 5 min;
    /// - a single segment is never split, however long.
    ///
    /// `previous` (optional) keeps ids stable when retention deletes a conversation's first
    /// member: a fresh group adopts the id of the previous conversation that contained its
    /// first member, so annotations/tags keyed by conversation id survive the rebuild.
    public static func group(
        segments: [SegmentMeta],
        pauses: [PauseInterval],
        openSegmentId: String?,
        fallbackTimeZoneID: String = TimeZone.current.identifier,
        previous: [GroupedConversation]? = nil
    ) -> [GroupedConversation] {
        let ordered = segments.sorted { a, b in
            if a.receivedAtMs != b.receivedAtMs { return a.receivedAtMs < b.receivedAtMs }
            return a.segmentId < b.segmentId
        }

        var result: [GroupedConversation] = []
        var members: [SegmentMeta] = []

        func flush() {
            guard let first = members.first, let last = members.last else { return }
            result.append(
                GroupedConversation(
                    id: "conv-\(first.segmentId)",
                    startMs: segmentStartMs(first),
                    endMs: members.map(segmentEndMs).max() ?? segmentEndMs(last),
                    timeZoneID: first.recordedTimeZone ?? fallbackTimeZoneID,
                    isLive: openSegmentId != nil && last.segmentId == openSegmentId,
                    memberSegmentIds: members.map(\.segmentId)
                )
            )
            members = []
        }

        for meta in ordered {
            if let prev = members.last {
                let prevEnd = segmentEndMs(prev)
                let nextStart = segmentStartMs(meta)
                let splits =
                    endsWithUserStop(prev)
                    || pauseFalls(between: prevEnd, and: nextStart, pauses: pauses)
                    || !(prev.streamId == meta.streamId || nextStart - prevEnd < chainWindowMs)
                if splits { flush() }
            }
            members.append(meta)
        }
        flush()

        guard let previous, !previous.isEmpty else { return result }
        return adoptStableIds(result, previous: previous)
    }

    /// Deterministic id adoption: in order, each fresh group takes the id of the previous
    /// conversation that contained its first member (unless another fresh group already
    /// claimed it — a split keeps the old id on its first half only).
    static func adoptStableIds(
        _ fresh: [GroupedConversation], previous: [GroupedConversation]
    ) -> [GroupedConversation] {
        var byMember: [String: String] = [:]
        for convo in previous {
            for member in convo.memberSegmentIds where byMember[member] == nil {
                byMember[member] = convo.id
            }
        }
        var used = Set<String>()
        return fresh.map { convo in
            var convo = convo
            if let firstMember = convo.memberSegmentIds.first,
                let inherited = byMember[firstMember], !used.contains(inherited) {
                convo.id = inherited
            }
            used.insert(convo.id)
            return convo
        }
    }

    // --- persistence --------------------------------------------------------------------------

    /// Idempotently replaces the derived `conversations`/`conversation_segments` tables in one
    /// transaction. Annotations/tags/follow-ups reference conversation ids by value and the
    /// ids are deterministic, so a rebuild leaves them attached.
    public static func apply(_ conversations: [GroupedConversation], in db: Database) throws {
        try db.execute(sql: "DELETE FROM conversation_segments")
        try db.execute(sql: "DELETE FROM conversations")
        for convo in conversations {
            try db.execute(
                sql: """
                    INSERT INTO conversations (id, startMs, endMs, timezone, state)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    convo.id, convo.startMs, convo.endMs, convo.timeZoneID,
                    convo.isLive ? "live" : "closed",
                ]
            )
            for (ordinal, segmentId) in convo.memberSegmentIds.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO conversation_segments (conversationId, segmentId, ordinal)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [convo.id, segmentId, ordinal]
                )
            }
        }
    }

    /// Group + persist in one write. Reads the previous grouping from the DB first so ids stay
    /// stable across retention deletions of first members.
    @discardableResult
    public static func rebuild(
        segments: [SegmentMeta],
        pauses: [PauseInterval],
        openSegmentId: String?,
        fallbackTimeZoneID: String = TimeZone.current.identifier,
        db: AppDatabase
    ) async throws -> [GroupedConversation] {
        try await db.writer.write { d in
            let previous = try fetchAll(d)
            let grouped = group(
                segments: segments, pauses: pauses, openSegmentId: openSegmentId,
                fallbackTimeZoneID: fallbackTimeZoneID, previous: previous
            )
            try apply(grouped, in: d)
            return grouped
        }
    }

    /// Reads the persisted grouping back (ordered by startMs, members by ordinal).
    public static func fetchAll(_ db: Database) throws -> [GroupedConversation] {
        let rows = try Row.fetchAll(
            db, sql: "SELECT id, startMs, endMs, timezone, state FROM conversations ORDER BY startMs, id"
        )
        let memberRows = try Row.fetchAll(
            db,
            sql: """
                SELECT conversationId, segmentId FROM conversation_segments
                ORDER BY conversationId, ordinal
                """
        )
        var members: [String: [String]] = [:]
        for row in memberRows {
            members[row["conversationId"], default: []].append(row["segmentId"])
        }
        return rows.map { row in
            GroupedConversation(
                id: row["id"],
                startMs: row["startMs"],
                endMs: row["endMs"] ?? row["startMs"],
                timeZoneID: row["timezone"],
                isLive: (row["state"] as String) == "live",
                memberSegmentIds: members[row["id"]] ?? []
            )
        }
    }
}
