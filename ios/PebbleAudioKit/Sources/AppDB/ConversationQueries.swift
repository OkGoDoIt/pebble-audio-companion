import Foundation
import GRDB
import SegmentStore

// Library/Today conversation projections (plan Part 3 + mockup spec 2.5/2.6). Read-only over
// the derived grouping plus annotations, tags, follow-ups, the shared transcription_tasks
// table (read-only here — the queue port owns writes), and the coverage cache (for the
// "mostly quiet" meta and the missing-audio filter).

/// Conversation-level transcription lifecycle (plan Part 3 aggregation).
public enum ConversationLifecycle: String, Equatable, Sendable {
    /// Any member Running/Uploading.
    case transcribing
    /// Else any member Pending (or Disabled — waiting for a usable provider), or missing a
    /// task row entirely.
    case capturedWaiting
    /// Else any member Failed.
    case failed
    /// All members terminal-success (Complete/NoSpeech).
    case complete
}

/// The Library "All ⌄" menu (plan 6.7).
public enum LibraryFilter: String, Equatable, Sendable {
    case all
    case untranscribed
    case withFollowUps
    case withMissingAudio
}

public struct ConversationListRow: Equatable, Sendable {
    public var id: String
    /// Annotation title; nil until enrichment lands (UI falls back to a time label).
    public var title: String?
    public var summary: String?
    public var startMs: Int64
    public var endMs: Int64
    public var timeZoneID: String
    public var isLive: Bool
    public var tags: [String]
    public var lifecycle: ConversationLifecycle
    /// Quiet > 60% of the span ("mostly quiet" folds into the row meta).
    public var mostlyQuiet: Bool
    public var hasMissingAudio: Bool
    public var followUpCount: Int
    public var openFollowUpCount: Int
    /// Logical-day key (5 AM boundary) in the conversation's recorded zone.
    public var dateKey: String

    public var durationMs: Int64 { max(0, endMs - startMs) }
}

public struct LibraryDaySection: Equatable, Sendable {
    public var dateKey: String
    public var rows: [ConversationListRow]
}

/// Per-segment provenance for the conversation Details view (visible per plan Part 3).
public struct SegmentProvenance: Equatable, Sendable {
    public var segmentId: String
    public var ordinal: Int
    public var state: TranscriptionState?
    public var providerId: String?
    public var modelUsed: String?
    public var modeUsed: String?
    public var attempts: Int
    public var lastError: String?
}

public struct ConversationDetail: Equatable, Sendable {
    public var row: ConversationListRow
    public var members: [SegmentProvenance]
}

public struct ConversationQueries: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    // --- aggregation --------------------------------------------------------------------------

    /// Plan Part 3: any Running/Uploading ⇒ transcribing; else any Pending ⇒ captured-waiting;
    /// else any Failed ⇒ failed; else complete. A member without a task row counts as Pending;
    /// Disabled counts as Pending (eligible again once a provider is usable).
    static func aggregateLifecycle(_ states: [TranscriptionState?]) -> ConversationLifecycle {
        if states.contains(where: { $0 == .running || $0 == .uploading }) { return .transcribing }
        if states.contains(where: { $0 == nil || $0 == .pending || $0 == .disabled }) {
            return .capturedWaiting
        }
        if states.contains(.failed) { return .failed }
        return .complete
    }

    /// Sums quiet/missing coverage overlapping [startMs, endMs) from cached day spans.
    static func coverageStats(
        spans: [CoverageSpan], startMs: Int64, endMs: Int64
    ) -> (quietMs: Int64, missingMs: Int64) {
        var quiet: Int64 = 0
        var missing: Int64 = 0
        for span in spans {
            let overlap = min(span.endMs, endMs) - max(span.startMs, startMs)
            guard overlap > 0 else { continue }
            if span.kind == .quiet { quiet += overlap }
            if span.kind == .missing { missing += overlap }
        }
        return (quiet, missing)
    }

    /// Logical-day keys a conversation touches (capped — conversations don't span weeks).
    static func dateKeys(startMs: Int64, endMs: Int64, timeZoneID: String) -> [String] {
        var keys = [LogicalDay.dateKey(forMs: startMs, timeZoneID: timeZoneID)]
        var cursor = startMs
        for _ in 0..<3 {
            guard
                let bounds = LogicalDay.bounds(ofDateKey: keys[keys.count - 1], timeZoneID: timeZoneID),
                bounds.endMs < endMs
            else { break }
            cursor = bounds.endMs
            keys.append(LogicalDay.dateKey(forMs: cursor, timeZoneID: timeZoneID))
        }
        return keys
    }

    // --- the library build (shared by fetch + observation) --------------------------------------

    static func buildRows(_ db: Database) throws -> [ConversationListRow] {
        let convoRows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id AS id, c.startMs AS startMs, c.endMs AS endMs,
                    c.timezone AS timezone, c.state AS state,
                    a.title AS title, a.summary AS summary
                FROM conversations c
                LEFT JOIN annotations a ON a.conversationId = c.id
                ORDER BY c.startMs DESC, c.id
                """
        )

        var memberStates: [String: [TranscriptionState?]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT cs.conversationId AS conversationId, tt.state AS state
                FROM conversation_segments cs
                LEFT JOIN transcription_tasks tt ON tt.segmentId = cs.segmentId
                ORDER BY cs.conversationId, cs.ordinal
                """
        ) {
            let state = (row["state"] as String?).flatMap(TranscriptionState.init(rawValue:))
            memberStates[row["conversationId"], default: []].append(state)
        }

        var tagNames: [String: [String]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT ct.conversationId AS conversationId, t.name AS name
                FROM conversation_tags ct JOIN tags t ON t.id = ct.tagId
                ORDER BY t.name COLLATE NOCASE ASC
                """
        ) {
            tagNames[row["conversationId"], default: []].append(row["name"])
        }

        var followUps: [String: (total: Int, open: Int)] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT sourceConversationId AS conversationId, COUNT(*) AS total,
                    SUM(CASE WHEN done = 0 THEN 1 ELSE 0 END) AS open
                FROM follow_ups WHERE sourceConversationId IS NOT NULL
                GROUP BY sourceConversationId
                """
        ) {
            followUps[row["conversationId"]] = (row["total"], row["open"])
        }

        // Coverage spans for every logical day the listed conversations touch.
        struct Prelim {
            var row: Row
            var keys: [String]
        }
        var prelims: [Prelim] = []
        var wantedKeys = Set<String>()
        for row in convoRows {
            let keys = dateKeys(
                startMs: row["startMs"], endMs: row["endMs"] ?? row["startMs"],
                timeZoneID: row["timezone"])
            wantedKeys.formUnion(keys)
            prelims.append(Prelim(row: row, keys: keys))
        }
        var coverage: [String: [CoverageSpan]] = [:]
        if !wantedKeys.isEmpty {
            let keyList = Array(wantedKeys)
            let placeholders = databaseQuestionMarks(count: keyList.count)
            for row in try Row.fetchAll(
                db,
                sql: "SELECT dateKey, spans FROM coverage_days WHERE dateKey IN (\(placeholders))",
                arguments: StatementArguments(keyList)
            ) {
                coverage[row["dateKey"]] = CoverageDayStore.decodeSpans(row["spans"]) ?? []
            }
        }

        return prelims.map { prelim in
            let row = prelim.row
            let id: String = row["id"]
            let startMs: Int64 = row["startMs"]
            let endMs: Int64 = row["endMs"] ?? startMs
            let spans = prelim.keys.flatMap { coverage[$0] ?? [] }
            let stats = coverageStats(spans: spans, startMs: startMs, endMs: endMs)
            let counts = followUps[id] ?? (0, 0)
            return ConversationListRow(
                id: id,
                title: row["title"],
                summary: row["summary"],
                startMs: startMs,
                endMs: endMs,
                timeZoneID: row["timezone"],
                isLive: (row["state"] as String) == "live",
                tags: tagNames[id] ?? [],
                lifecycle: aggregateLifecycle(memberStates[id] ?? []),
                mostlyQuiet: endMs > startMs && stats.quietMs * 10 > (endMs - startMs) * 6,
                hasMissingAudio: stats.missingMs > 0,
                followUpCount: counts.total,
                openFollowUpCount: counts.open,
                dateKey: prelim.keys[0]
            )
        }
    }

    static func matches(_ row: ConversationListRow, filter: LibraryFilter, tagName: String?)
        -> Bool
    {
        if let tagName, !row.tags.contains(tagName) { return false }
        switch filter {
        case .all: return true
        case .untranscribed: return row.lifecycle != .complete
        case .withFollowUps: return row.followUpCount > 0
        case .withMissingAudio: return row.hasMissingAudio
        }
    }

    static func buildLibrary(
        _ db: Database, filter: LibraryFilter, tagName: String?
    ) throws -> [LibraryDaySection] {
        let rows = try buildRows(db).filter { matches($0, filter: filter, tagName: tagName) }
        var sections: [String: [ConversationListRow]] = [:]
        for row in rows {
            sections[row.dateKey, default: []].append(row)
        }
        return sections.keys.sorted(by: >).map { key in
            LibraryDaySection(
                dateKey: key,
                rows: sections[key]!.sorted { a, b in
                    if a.startMs != b.startMs { return a.startMs > b.startMs }  // newest first
                    return a.id < b.id
                }
            )
        }
    }

    // --- public API ---------------------------------------------------------------------------

    /// Day-sectioned library list, newest first, sectioned by recorded-zone logical day.
    public func library(
        filter: LibraryFilter = .all, tagName: String? = nil
    ) async throws -> [LibraryDaySection] {
        try await db.reader.read { db in
            try Self.buildLibrary(db, filter: filter, tagName: tagName)
        }
    }

    public func observeLibrary(
        filter: LibraryFilter = .all, tagName: String? = nil
    ) -> AsyncValueObservation<[LibraryDaySection]> {
        ValueObservation.tracking { db in
            try Self.buildLibrary(db, filter: filter, tagName: tagName)
        }.values(in: db.reader)
    }

    static func buildDetail(_ db: Database, id: String) throws -> ConversationDetail? {
        guard let row = try buildRows(db).first(where: { $0.id == id }) else { return nil }
        let members = try Row.fetchAll(
            db,
            sql: """
                SELECT cs.segmentId AS segmentId, cs.ordinal AS ordinal, tt.state AS state,
                    tt.providerId AS providerId, tt.modelUsed AS modelUsed,
                    tt.modeUsed AS modeUsed, tt.attempts AS attempts, tt.lastError AS lastError
                FROM conversation_segments cs
                LEFT JOIN transcription_tasks tt ON tt.segmentId = cs.segmentId
                WHERE cs.conversationId = ?
                ORDER BY cs.ordinal
                """,
            arguments: [id]
        ).map { member in
            SegmentProvenance(
                segmentId: member["segmentId"],
                ordinal: member["ordinal"],
                state: (member["state"] as String?).flatMap(TranscriptionState.init(rawValue:)),
                providerId: member["providerId"],
                modelUsed: member["modelUsed"],
                modeUsed: member["modeUsed"],
                attempts: member["attempts"] ?? 0,
                lastError: member["lastError"]
            )
        }
        return ConversationDetail(row: row, members: members)
    }

    /// One conversation with ordered members and per-segment provenance.
    public func detail(id: String) async throws -> ConversationDetail? {
        try await db.reader.read { db in try Self.buildDetail(db, id: id) }
    }

    public func observeDetail(id: String) -> AsyncValueObservation<ConversationDetail?> {
        ValueObservation.tracking { db in
            try Self.buildDetail(db, id: id)
        }.values(in: db.reader)
    }
}
