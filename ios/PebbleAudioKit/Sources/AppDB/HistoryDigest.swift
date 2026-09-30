import Foundation
import GRDB

// The content gate of History's read side (plan 7.10 "The data source", 7.13).
//
// A visible History page keeps ONE database observation: over this digest of its window, never
// over the page itself. The digest is small and cheap — a handful of indexed reads of ids,
// states and stamps — and it is exactly what the page is built from, so an unchanged digest
// means an unchanged page and nothing is rebuilt. That is the rule the 2026-09-09 drain taught
// (an observer never re-publishes what it observes, and a refresh that changes nothing publishes
// nothing): the pipeline's regroup rewrites every conversation row each pass, and for a past day
// that produces this very same digest.
//
// What is in it, and why each thing:
// - the conversations overlapping the window: id, live/closed, start, end, title — the day's
//   talk cards, the week's headline, what a pending delete hides;
// - their members, with each member's mirrored transcription state (a recording joining or
//   leaving a conversation, or settling);
// - the tags on those conversations, for week and month pages (a day draws none of them);
// - the transcription queue's rows for the window's recordings and those members: state and
//   last error (failed / waiting, and why);
// - pause intervals overlapping the window;
// - the window's follow-up rows (`FollowUpStore.historySQL`, archived ones never), with every
//   field a line or its placement reads;
// - the recaps of the window's days: `updatedAtMs` and `shortOfHash` (the condensed form landing);
// - the audio classifier's digest of the window (`AudioContentStore.digest(in:overlappingMs:)`).
//
// Not in it: anything memory-only (the pending-delete buffer — the live source adds its own
// version for that), the segment spool's sidecars (a closed recording's extent does not move;
// a new one shows up here as a conversation change), and the wall clock.

/// What one window's digest reads.
public struct HistoryDigestScope: Equatable, Sendable {
    /// The window's absolute extent (a day's windows are one stretch unless a zone change split
    /// them; the digest reads the hull, which can only add rows).
    public var window: Range<Int64>
    /// Recordings known to lie in the window when the scope was made.
    public var segmentIds: [String]
    /// Logical days whose recap the page shows.
    public var recapDateKeys: [String]
    /// Week and month pages draw tags; a day page does not, so a tag edit does not rebuild it.
    public var includeTags: Bool
    /// A day whose cards are the conversations themselves draws their summaries.
    public var includeSummaries: Bool

    public init(
        window: Range<Int64>, segmentIds: [String], recapDateKeys: [String], includeTags: Bool,
        includeSummaries: Bool = false
    ) {
        self.window = window
        self.segmentIds = segmentIds
        self.recapDateKeys = recapDateKeys
        self.includeTags = includeTags
        self.includeSummaries = includeSummaries
    }
}

public struct HistoryDigest: Equatable, Sendable {
    /// The conversations overlapping the window: lets a pending-delete change be matched to the
    /// pages it can affect without a read.
    public var conversationIds: Set<String>
    /// A fingerprint of everything else listed in the file header.
    public var fingerprint: Int64

    public init(conversationIds: Set<String>, fingerprint: Int64) {
        self.conversationIds = conversationIds
        self.fingerprint = fingerprint
    }
}

extension HistoryDigest {
    /// One read of the digest.
    public static func read(_ database: AppDatabase, scope: HistoryDigestScope) async throws -> HistoryDigest {
        try await database.reader.read { db in try fetch(db, scope: scope) }
    }

    /// The digest, now and after every write that changes it. Duplicate values are dropped at
    /// the source. Cancelling the consuming task ends the observation.
    ///
    /// - Parameter onFetch: called every time the digest is computed (tests count queries).
    public static func observe(
        _ database: AppDatabase, scope: HistoryDigestScope, onFetch: (@Sendable () -> Void)? = nil
    ) -> AsyncStream<HistoryDigest> {
        let observation = ValueObservation.tracking { db -> HistoryDigest in
            onFetch?()
            return try fetch(db, scope: scope)
        }.removeDuplicates()
        let values = observation.values(in: database.reader)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    for try await digest in values { continuation.yield(digest) }
                } catch {
                    // The database went away; the page keeps what it last showed.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The digest inside a caller's read.
    public static func fetch(_ db: Database, scope: HistoryDigestScope) throws -> HistoryDigest {
        let window = scope.window
        var hasher = Hasher64()
        guard !window.isEmpty else { return HistoryDigest(conversationIds: [], fingerprint: hasher.value) }

        // Conversations overlapping the window: the same edges as `ConversationQueries.rows`.
        let conversations = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id AS id, c.state AS state, c.startMs AS startMs, c.endMs AS endMs,
                    a.title AS title, a.summary AS summary
                FROM conversations c LEFT JOIN annotations a ON a.conversationId = c.id
                WHERE c.startMs < ? AND (c.endMs IS NULL OR c.endMs > ? OR c.startMs >= ?)
                ORDER BY c.id
                """,
            arguments: [window.upperBound, window.lowerBound, window.lowerBound])
        var ids: [String] = []
        hasher.combine("conversations")
        for row in conversations {
            let id: String = row["id"]
            ids.append(id)
            hasher.combine(id)
            hasher.combine(row["state"] as String? ?? "")
            hasher.combine(row["startMs"] as Int64? ?? 0)
            hasher.combine(row["endMs"] as Int64? ?? -1)
            hasher.combine(row["title"] as String? ?? "\u{0}")
            if scope.includeSummaries { hasher.combine(row["summary"] as String? ?? "\u{0}") }
        }
        let idsJSON = try jsonArray(ids)

        hasher.combine("members")
        var memberIds: [String] = []
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT conversationId, segmentId, ordinal, transcriptionState
                FROM conversation_segments
                WHERE conversationId IN (SELECT value FROM json_each(?))
                ORDER BY conversationId, ordinal
                """,
            arguments: [idsJSON])
        {
            let segmentId: String = row["segmentId"]
            memberIds.append(segmentId)
            hasher.combine(row["conversationId"] as String)
            hasher.combine(segmentId)
            hasher.combine(row["transcriptionState"] as String? ?? "")
        }

        if scope.includeTags {
            hasher.combine("tags")
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT ct.conversationId AS conversationId, t.name AS name, ct.source AS source
                    FROM conversation_tags ct JOIN tags t ON t.id = ct.tagId
                    WHERE ct.conversationId IN (SELECT value FROM json_each(?))
                    ORDER BY ct.conversationId, t.name
                    """,
                arguments: [idsJSON])
            {
                hasher.combine(row["conversationId"] as String)
                hasher.combine(row["name"] as String)
                hasher.combine(row["source"] as String)
            }
        }

        hasher.combine("tasks")
        let taskIds = Array(Set(scope.segmentIds).union(memberIds)).sorted()
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT segmentId, state, lastError FROM transcription_tasks
                WHERE segmentId IN (SELECT value FROM json_each(?))
                ORDER BY segmentId
                """,
            arguments: [try jsonArray(taskIds)])
        {
            hasher.combine(row["segmentId"] as String)
            hasher.combine(row["state"] as String)
            hasher.combine(row["lastError"] as String? ?? "")
        }

        hasher.combine("pauses")
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT id, startMs, endMs, source FROM pause_intervals
                WHERE startMs < ? AND (endMs IS NULL OR endMs > ?)
                ORDER BY startMs, id
                """,
            arguments: [window.upperBound, window.lowerBound])
        {
            hasher.combine(row["id"] as Int64)
            hasher.combine(row["startMs"] as Int64)
            hasher.combine(row["endMs"] as Int64? ?? -1)
            hasher.combine(row["source"] as String)
        }

        hasher.combine("followUps")
        let idRange = FollowUpStore.segmentIdRange(receivedIn: window)
        let followUps = try Row.fetchAll(
            db, sql: FollowUpStore.historySQL,
            arguments: [
                "start": window.lowerBound, "end": window.upperBound,
                "ids": try jsonArray(scope.segmentIds),
                "idFrom": idRange.lowerBound, "idTo": idRange.upperBound,
            ]
        ).sorted { ($0["id"] as String) < ($1["id"] as String) }
        for row in followUps {
            hasher.combine(row["id"] as String)
            hasher.combine(row["text"] as String)
            hasher.combine((row["done"] as Bool) ? 1 : 0)
            hasher.combine(row["snoozedUntilMs"] as Int64? ?? -1)
            hasher.combine(row["origin"] as String? ?? "")
            hasher.combine(row["sourceSegmentId"] as String? ?? "")
            hasher.combine(row["createdAtMs"] as Int64)
            hasher.combine(row["sourceWallStartMs"] as Int64? ?? -1)
            hasher.combine(row["sourceWallEndMs"] as Int64? ?? -1)
            hasher.combine((row["sourceWallApproximate"] as Bool?) == true ? 1 : 0)
        }

        hasher.combine("recaps")
        if !scope.recapDateKeys.isEmpty {
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT dateKey, updatedAtMs, shortOfHash FROM recaps
                    WHERE dateKey IN (SELECT value FROM json_each(?))
                    ORDER BY dateKey
                    """,
                arguments: [try jsonArray(scope.recapDateKeys)])
            {
                hasher.combine(row["dateKey"] as String)
                hasher.combine(row["updatedAtMs"] as Int64)
                hasher.combine(row["shortOfHash"] as String? ?? "")
            }
        }

        hasher.combine("audioContent")
        hasher.combine(try AudioContentStore.digest(in: db, overlappingMs: window))

        return HistoryDigest(conversationIds: Set(ids), fingerprint: hasher.value)
    }

    private static func jsonArray(_ values: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }
}
