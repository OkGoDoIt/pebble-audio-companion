import Foundation
import GRDB

// The week and month briefs History reads (plan 7.4, table `period_briefs`, migration
// `v16-history-briefs`). Written by `PeriodBriefEngine` (Intelligence); read by History's week
// and month pages (`HistoryReader`) and watched through `HistoryDigest`.
//
// A brief is keyed by its period, never by the text it was made from: the week page asks for
// "the week of September 27" whatever its days say today. What it was made FROM is
// `sourceHash`, so the engine can tell a brief that still describes its days from one that has
// fallen behind them — and a brief that has fallen behind is still shown until its successor
// lands. A summary a few hours old is honest; "No summary yet" over a week that has one is not.

/// Which period a brief covers. The raw keys are what `period_briefs.periodKey` stores.
public enum PeriodBriefKey {
    /// `week:<first day>` — the first day as `HistoryCalendar.week(containing:firstWeekday:)`
    /// gives it, so a Monday-first phone and a Sunday-first phone key different weeks (and the
    /// same phone keeps finding its own).
    public static func week(firstDateKey: String) -> String { "week:\(firstDateKey)" }

    /// `month:<yyyy-MM>`.
    public static func month(containing dateKey: String) -> String {
        "month:\(dateKey.prefix(7))"
    }
}

public enum PeriodBriefKind: String, Sendable, Equatable {
    case week
    case month
}

/// One row of `period_briefs`.
public struct PeriodBrief: Equatable, Sendable {
    public var periodKey: String
    public var kind: PeriodBriefKind
    /// The in-brief card's paragraph. Nil when the last completed attempt produced nothing
    /// usable, or none has completed.
    public var text: String?
    /// The month page's week row: a phrase, and a line under it.
    public var headline: String?
    public var lineSummary: String?
    /// The fingerprint of the input the last COMPLETED attempt read. Nil until one completes.
    public var sourceHash: String?
    public var provider: String?
    public var model: String?
    /// When the last completed attempt landed. A failure never moves it.
    public var updatedAtMs: Int64
    /// Consecutive failed attempts since the last completed one.
    public var attempts: Int
    public var nextAttemptAtMs: Int64?
    /// The classified failure kind (`AiFailureKind.rawValue`), never a provider's own words.
    public var lastError: String?

    public init(
        periodKey: String, kind: PeriodBriefKind, text: String? = nil, headline: String? = nil,
        lineSummary: String? = nil, sourceHash: String? = nil, provider: String? = nil,
        model: String? = nil, updatedAtMs: Int64 = 0, attempts: Int = 0,
        nextAttemptAtMs: Int64? = nil, lastError: String? = nil
    ) {
        self.periodKey = periodKey
        self.kind = kind
        self.text = text
        self.headline = headline
        self.lineSummary = lineSummary
        self.sourceHash = sourceHash
        self.provider = provider
        self.model = model
        self.updatedAtMs = updatedAtMs
        self.attempts = attempts
        self.nextAttemptAtMs = nextAttemptAtMs
        self.lastError = lastError
    }

    /// What a page may show: nil when no completed attempt produced anything.
    public var hasContent: Bool { text != nil || headline != nil || lineSummary != nil }
}

public struct PeriodBriefStore: Sendable {
    public let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    static func brief(from row: Row) -> PeriodBrief? {
        guard let kind = PeriodBriefKind(rawValue: row["kind"]) else { return nil }
        return PeriodBrief(
            periodKey: row["periodKey"], kind: kind, text: row["text"], headline: row["headline"],
            lineSummary: row["lineSummary"], sourceHash: row["sourceHash"], provider: row["provider"],
            model: row["model"], updatedAtMs: row["updatedAtMs"], attempts: row["attempts"],
            nextAttemptAtMs: row["nextAttemptAtMs"], lastError: row["lastError"])
    }

    /// Every brief. The table holds one row per recorded week and month — a few dozen a year —
    /// so the engine reads it whole when it is due, rather than asking row by row.
    public func all() async throws -> [PeriodBrief] {
        try await db.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM period_briefs ORDER BY periodKey")
                .compactMap(Self.brief(from:))
        }
    }

    /// The briefs of these periods, by key.
    public func load(keys: [String]) async throws -> [String: PeriodBrief] {
        guard !keys.isEmpty else { return [:] }
        let json = String(decoding: try JSONEncoder().encode(keys), as: UTF8.self)
        return try await db.reader.read { db in
            var result: [String: PeriodBrief] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT * FROM period_briefs WHERE periodKey IN (SELECT value FROM json_each(?))",
                arguments: [json])
            {
                if let brief = Self.brief(from: row) { result[brief.periodKey] = brief }
            }
            return result
        }
    }

    /// Records a COMPLETED attempt: its fields (nil where the answer was unusable), the input it
    /// read, and a clean failure record.
    public func saveCompleted(
        periodKey: String, kind: PeriodBriefKind, text: String?, headline: String?,
        lineSummary: String?, sourceHash: String, provider: String?, model: String?, atMs: Int64
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO period_briefs
                        (periodKey, kind, text, headline, lineSummary, sourceHash, provider, model,
                         updatedAtMs, attempts, nextAttemptAtMs, lastError)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, NULL)
                    ON CONFLICT(periodKey) DO UPDATE SET
                        kind = excluded.kind, text = excluded.text, headline = excluded.headline,
                        lineSummary = excluded.lineSummary, sourceHash = excluded.sourceHash,
                        provider = excluded.provider, model = excluded.model,
                        updatedAtMs = excluded.updatedAtMs, attempts = 0, nextAttemptAtMs = NULL,
                        lastError = NULL
                    """,
                arguments: [
                    periodKey, kind.rawValue, text, headline, lineSummary, sourceHash, provider,
                    model, atMs,
                ])
        }
    }

    /// Records a FAILED attempt without touching what the page shows: the previous brief, if
    /// any, stays (its text, its source and its `updatedAtMs` — which is also what keeps a
    /// failure from rebuilding an open page, see `HistoryDigest`).
    public func saveFailure(
        periodKey: String, kind: PeriodBriefKind, attempts: Int, nextAttemptAtMs: Int64,
        errorKind: String
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO period_briefs
                        (periodKey, kind, updatedAtMs, attempts, nextAttemptAtMs, lastError)
                    VALUES (?, ?, 0, ?, ?, ?)
                    ON CONFLICT(periodKey) DO UPDATE SET
                        attempts = excluded.attempts, nextAttemptAtMs = excluded.nextAttemptAtMs,
                        lastError = excluded.lastError
                    """,
                arguments: [periodKey, kind.rawValue, attempts, nextAttemptAtMs, errorKind])
        }
    }

    /// Every failed period may be tried again now (the AI configuration changed).
    public func clearFailureBackoff() async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: "UPDATE period_briefs SET nextAttemptAtMs = NULL WHERE nextAttemptAtMs IS NOT NULL")
        }
    }

    /// Removes briefs whose period no longer has anything to describe (its days' recaps were
    /// deleted with their audio). A brief of deleted audio must not outlive it on the page.
    public func delete(keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        let json = String(decoding: try JSONEncoder().encode(keys), as: UTF8.self)
        try await db.writer.write { db in
            try db.execute(
                sql: "DELETE FROM period_briefs WHERE periodKey IN (SELECT value FROM json_each(?))",
                arguments: [json])
        }
    }

    public func deleteAll() async throws {
        try await db.writer.write { db in try db.execute(sql: "DELETE FROM period_briefs") }
    }
}
