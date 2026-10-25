import AppDB
import Foundation
import GRDB

// What the person allowed on the phone (`sync-protocol.md` §5, `PUT /sync/preferences`): whether
// assistants may ask for clips, whether they may add follow-ups and notes, and the sharing
// scope, which decides which conversations the server may hold at all.
//
// The phone owns all three. It sends them to the server, and it ALSO enforces them itself: it
// never sends anything dated outside the scope (`ArchiveScopeGate`), it never answers a clip
// request while clips are off, and it never writes an assistant's follow-up or note while edits
// are off (`ArchiveRequestHandler`). A stale server preference can therefore never move audio or
// text the person did not allow.

/// Which conversations the server may hold.
public enum ArchiveSharingScope: Hashable, Sendable, Codable {
    /// Everything the phone sends, kept even after the phone's own retention ages it out.
    case all
    /// "From today on": nothing that started before `ms`.
    case since(ms: Int64)
    /// A rolling window: nothing older than this many days, pruned by the server every day.
    case lastDays(Int)

    /// The windows the app offers.
    public static let rollingChoices = [7, 30, 90, 180, 365]
    public static let defaultRollingDays = 90

    /// Nothing dated before this instant is held; nil holds everything.
    public func cutoffMs(nowMs: Int64) -> Int64? {
        switch self {
        case .all: return nil
        case .since(let ms): return ms
        case .lastDays(let days): return nowMs - Int64(days) * 86_400_000
        }
    }

    /// The part of the timeline `to` holds that `from` did not, at `nowMs`: what has to be sent
    /// again when the person widens the scope (the server forgot the versions of what it
    /// removed, and never recorded what it was told to ignore). Nil when nothing was added.
    public static func widening(
        from old: ArchiveSharingScope, to new: ArchiveSharingScope, nowMs: Int64
    ) -> ArchiveScopeRange? {
        guard let oldCutoff = old.cutoffMs(nowMs: nowMs) else { return nil }  // held everything
        let newCutoff = new.cutoffMs(nowMs: nowMs)
        if let newCutoff, newCutoff >= oldCutoff { return nil }
        return ArchiveScopeRange(fromMs: newCutoff, toMs: oldCutoff)
    }

    /// True when `new` holds less than `old` at `nowMs`: the server removes things at once.
    public static func narrows(
        from old: ArchiveSharingScope, to new: ArchiveSharingScope, nowMs: Int64
    ) -> Bool {
        guard let newCutoff = new.cutoffMs(nowMs: nowMs) else { return false }
        guard let oldCutoff = old.cutoffMs(nowMs: nowMs) else { return true }
        return newCutoff > oldCutoff
    }

    // MARK: Wire (`{ "kind": "all" }`, `{ "kind": "since", "since": … }`, `{ "kind": "lastDays", "days": 90 }`)

    enum CodingKeys: String, CodingKey { case kind, since, days }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "all":
            self = .all
        case "since":
            // The server answers with a time; the phone's own saved state may hold the number.
            if let text = try? c.decodeIfPresent(String.self, forKey: .since),
                let ms = ArchiveTime.ms(text)
            {
                self = .since(ms: ms)
            } else if let ms = try c.decodeIfPresent(Int64.self, forKey: .since) {
                self = .since(ms: ms)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .since, in: c, debugDescription: "since needs a time")
            }
        case "lastDays":
            let days = try c.decode(Int.self, forKey: .days)
            guard days >= 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .days, in: c, debugDescription: "days must be 1 or more")
            }
            self = .lastDays(days)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown scope kind \(other)")
        }
    }

    /// Optional fields go as an explicit `null` (§ preamble).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try c.encode("all", forKey: .kind)
            try c.encodeNil(forKey: .since)
            try c.encodeNil(forKey: .days)
        case .since(let ms):
            try c.encode("since", forKey: .kind)
            try c.encode(ArchiveTime.string(ms), forKey: .since)
            try c.encodeNil(forKey: .days)
        case .lastDays(let days):
            try c.encode("lastDays", forKey: .kind)
            try c.encodeNil(forKey: .since)
            try c.encode(days, forKey: .days)
        }
    }
}

/// `[fromMs, toMs)` on the clock; `fromMs` nil reaches back to the beginning.
public struct ArchiveScopeRange: Equatable, Sendable {
    public var fromMs: Int64?
    public var toMs: Int64

    public init(fromMs: Int64?, toMs: Int64) {
        self.fromMs = fromMs
        self.toMs = toMs
    }
}

/// The body of `PUT /sync/preferences`, and what the phone remembers the server confirmed.
public struct ArchivePreferences: Hashable, Sendable, Codable {
    /// Assistants may ask for a short clip of audio (D5a).
    public var clips: Bool
    /// Assistants may add follow-ups and notes (D5b).
    public var edits: Bool
    public var scope: ArchiveSharingScope

    public init(clips: Bool = false, edits: Bool = false, scope: ArchiveSharingScope = .all) {
        self.clips = clips
        self.edits = edits
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey { case clips, edits, scope }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clips = try c.decodeIfPresent(Bool.self, forKey: .clips) ?? false
        edits = try c.decodeIfPresent(Bool.self, forKey: .edits) ?? false
        scope = try c.decodeIfPresent(ArchiveSharingScope.self, forKey: .scope) ?? .all
    }
}

// MARK: - Dating (§5: what "dated before the scope" means for each kind)

/// Decides, for one outbox row at a time, whether its entity is inside the scope. "Dated" is the
/// server's own rule: a conversation (and its transcript) by when it started, a note by its
/// conversation (else when it was written), a follow-up by when it was said (else when it was
/// written), a recap and a day's coverage by their day, a brief by its last day. A day is inside
/// when it is on or after the logical day the cutoff falls on. People are not dated.
///
/// Every lookup is about the one row being built, so a batch costs what it holds.
public struct ArchiveScopeGate: Sendable {
    public let cutoffMs: Int64?
    /// The logical day the cutoff falls on, in the account's zone (the latest conversation's).
    public let cutoffDay: String?

    public init(cutoffMs: Int64?, cutoffDay: String?) {
        self.cutoffMs = cutoffMs
        self.cutoffDay = cutoffDay
    }

    /// The gate for `scope` at `nowMs`. The server keys the account's zone off the latest
    /// conversation it was sent, so the phone does too (UTC before the first, as there).
    public static func make(
        _ scope: ArchiveSharingScope, nowMs: Int64, database: AppDatabase
    ) async throws -> ArchiveScopeGate {
        guard let cutoff = scope.cutoffMs(nowMs: nowMs) else {
            return ArchiveScopeGate(cutoffMs: nil, cutoffDay: nil)
        }
        let zone = try await accountZone(database)
        return ArchiveScopeGate(
            cutoffMs: cutoff, cutoffDay: LogicalDay.dateKey(forMs: cutoff, timeZoneID: zone))
    }

    /// The zone the server counts the account's days in: the latest conversation's.
    public static func accountZone(_ database: AppDatabase) async throws -> String {
        try await database.reader.read { d in
            try String.fetchOne(
                d, sql: "SELECT timezone FROM conversations ORDER BY startMs DESC LIMIT 1")
        } ?? "UTC"
    }

    public var holdsEverything: Bool { cutoffMs == nil }

    /// Whether `(kind, id)` may go to the server. Something whose date cannot be found here (a
    /// row whose entity is gone) is left to the builder, which turns it into a delete.
    public func contains(
        _ kind: ArchiveEntityKind, id: String, in database: AppDatabase
    ) async throws -> Bool {
        guard !holdsEverything else { return true }
        return holds(try await Self.date(of: kind, id: id, in: database))
    }

    /// Whether an item dated `date` is inside: an instant at or after the cutoff, a day on or
    /// after the cutoff's day. Something undated always is.
    public func holds(_ date: ArchiveItemDate) -> Bool {
        guard let cutoffMs, let cutoffDay else { return true }
        switch date {
        case .instant(let ms): return ms >= cutoffMs
        case .day(let day): return day >= cutoffDay
        case .undated: return true
        }
    }

    /// What `(kind, id)` is dated by (the rule in this type's comment). The one statement of it:
    /// the phone's sync and the backup importer (`ios/Tools/ArchiveImport`) both ask here.
    public static func date(
        of kind: ArchiveEntityKind, id: String, in database: AppDatabase
    ) async throws -> ArchiveItemDate {
        func at(_ sql: String) async throws -> ArchiveItemDate {
            let ms = try await database.reader.read { d in
                try Int64.fetchOne(d, sql: sql, arguments: [id])
            }
            return ms.map { .instant($0) } ?? .undated
        }
        switch kind {
        case .person, .voiceRevocation:
            return .undated
        case .recap, .coverage:
            return .day(id)
        case .brief:
            return ArchiveOutbox.lastDay(ofPeriod: id).map { .day($0) } ?? .undated
        case .conversation, .transcript:
            return try await at("SELECT startMs FROM conversations WHERE id = ?")
        case .note:
            return try await at(
                """
                SELECT COALESCE(c.startMs, n.createdAtMs) FROM notes n
                LEFT JOIN conversations c ON c.id = n.conversationId WHERE n.id = ?
                """)
        case .followUp:
            return try await at(
                "SELECT COALESCE(sourceWallStartMs, createdAtMs) FROM follow_ups WHERE id = ?")
        }
    }
}

/// What an outbox item is dated by, for the sharing scope (`ArchiveScopeGate.date(of:id:in:)`).
public enum ArchiveItemDate: Equatable, Sendable {
    case instant(Int64)
    /// A logical day key (`recap`, `coverage`, a brief's last day).
    case day(String)
    /// Never dated (a person), or its entity is gone (left to the builder).
    case undated
}

// MARK: - What the phone can say about a scope before choosing it

/// The phone's own counts for the scope picker and the confirmations: how many conversations
/// each choice holds, and how far back. Conversations are what the server receives, music and
/// TV stretches included (they are synced, flagged, so days add up).
public struct ArchiveScopeCounts: Equatable, Sendable {
    public var total: Int
    /// When the oldest conversation started; nil with none.
    public var oldestStartMs: Int64?
    /// Each conversation's start, newest first, for counting any window without a query.
    public var startsMs: [Int64]

    public init(startsMs: [Int64]) {
        self.startsMs = startsMs.sorted(by: >)
        self.total = startsMs.count
        self.oldestStartMs = startsMs.min()
    }

    /// How many conversations `scope` holds at `nowMs`.
    public func count(_ scope: ArchiveSharingScope, nowMs: Int64) -> Int {
        guard let cutoff = scope.cutoffMs(nowMs: nowMs) else { return total }
        return count(since: cutoff)
    }

    public func count(since cutoffMs: Int64) -> Int {
        // Newest first: the ones at or after the cutoff are a prefix.
        var low = 0
        var high = startsMs.count
        while low < high {
            let mid = (low + high) / 2
            if startsMs[mid] >= cutoffMs { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// What going from `old` to `new` removes from the server now (zero when it widens).
    public func removed(from old: ArchiveSharingScope, to new: ArchiveSharingScope, nowMs: Int64) -> Int {
        max(0, count(old, nowMs: nowMs) - count(new, nowMs: nowMs))
    }

    /// One indexed read of the starts. A few thousand integers at most.
    public static func load(_ database: AppDatabase) async throws -> ArchiveScopeCounts {
        let starts = try await database.reader.read { d in
            try Int64.fetchAll(d, sql: "SELECT startMs FROM conversations")
        }
        return ArchiveScopeCounts(startsMs: starts)
    }
}

// MARK: - What an assistant read, named

/// The titles of the conversations an assistant read (the server's AI-read log gives ids only).
public enum ArchiveReadTitles {
    public static func load(_ ids: [String], in database: AppDatabase) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        return try await database.reader.read { d in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(
                d,
                sql: """
                    SELECT conversationId, title FROM annotations
                    WHERE conversationId IN (\(databaseQuestionMarks(count: ids.count)))
                    """,
                arguments: StatementArguments(ids))
            {
                if let title: String = row["title"], !title.isEmpty { out[row["conversationId"]] = title }
            }
            return out
        }
    }
}
