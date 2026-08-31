import Foundation
import GRDB
import AppDB

// Port of `core/search/.../TranscriptIndex.kt`, rebuilt per plan 4.7 (the D7 fix): the index is
// PERSISTENT — SQLite FTS5 (`search_fts` in `AppDatabase`, plan 6.5) instead of the old iOS
// in-memory map — and transcript text IS indexed (the old `includeFullTranscript = { false }`
// knob is deliberately gone).
//
// Structural adjustments vs KMP (mirrored in SearchKitTests):
// - `IndexKind` uses the rebuild's entity model (conversation/note/recap/followup — the
//   `search_fts.kind` vocabulary) instead of Segment/DayDigest/ActionItem. The recap keeps the
//   KMP `day-<dateKey>` id convention so redonating a regenerated recap REPLACES the day's
//   document instead of accumulating copies.
// - `IndexHit.summary` became `snippet` + `matchRanges`: FTS5 produces a match-centred snippet,
//   which is what the Search screen renders (tintFill18 highlight per the mockup spec).
// - `excluded` documents are not stored at all (the FTS table has no excluded column, and not
//   persisting excluded content is the stronger privacy behavior). Observable contract is the
//   KMP one: excluded items never come back from search.

/// What a searchable document is about. Raw values are the `search_fts.kind` column vocabulary.
public enum IndexKind: String, CaseIterable, Sendable, Codable {
    case conversation
    case note
    case recap
    case followUp = "followup"
}

/// One searchable document (conversation, note, day recap, or follow-up).
public struct IndexItem: Equatable, Sendable {
    public var id: String
    public var kind: IndexKind
    public var title: String
    public var summary: String?
    public var tags: [String]
    /// Full transcript/body text. Indexed (D7 fix) — never withheld.
    public var fullText: String?
    public var startDateMs: Int64?
    public var contentCreationDateMs: Int64
    /// Excluded documents are removed from (never written to) the index.
    public var excluded: Bool

    public init(
        id: String,
        kind: IndexKind,
        title: String,
        summary: String? = nil,
        tags: [String] = [],
        fullText: String? = nil,
        startDateMs: Int64? = nil,
        contentCreationDateMs: Int64,
        excluded: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.tags = tags
        self.fullText = fullText
        self.startDateMs = startDateMs
        self.contentCreationDateMs = contentCreationDateMs
        self.excluded = excluded
    }
}

/// One search result row: a match-centred snippet plus the character ranges of the matched
/// terms within it (for highlight rendering).
public struct IndexHit: Equatable, Sendable {
    public var id: String
    public var kind: IndexKind
    public var title: String
    /// Plain-text snippet around the best match ("…" elision at cut edges).
    public var snippet: String
    /// Character offsets of matched terms within `snippet`.
    public var matchRanges: [Range<Int>]
    /// Relevance, higher is better (negated FTS5 bm25).
    public var score: Double

    public init(
        id: String,
        kind: IndexKind,
        title: String,
        snippet: String,
        matchRanges: [Range<Int>] = [],
        score: Double = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.snippet = snippet
        self.matchRanges = matchRanges
        self.score = score
    }
}

/// The app-search index seam (KMP `TranscriptIndex` interface). The FTS implementation below is
/// the production one; tests may substitute fakes.
public protocol TranscriptIndexing: Sendable {
    func upsert(_ items: [IndexItem]) throws
    func search(_ query: String, limit: Int) throws -> [IndexHit]
    /// Removes one document (entityId + kind).
    func remove(id: String, kind: IndexKind) throws
    /// Removes every document with this entityId, whatever its kind.
    func remove(id: String) throws
    func removeAll() throws
    var isAvailable: Bool { get }
}

extension TranscriptIndexing {
    public func search(_ query: String) throws -> [IndexHit] { try search(query, limit: 20) }
}

/// Persistent FTS5-backed index over `AppDatabase.search_fts`.
public final class TranscriptIndex: TranscriptIndexing {
    private let database: AppDatabase

    /// Private-use-area sentinels handed to FTS5 `snippet()` so match ranges survive the trip
    /// through SQL and are stripped before display.
    private static let matchStart = "\u{E000}"
    private static let matchEnd = "\u{E001}"

    public init(database: AppDatabase) {
        self.database = database
    }

    public var isAvailable: Bool { true }

    public func upsert(_ items: [IndexItem]) throws {
        guard !items.isEmpty else { return }
        try database.writer.write { db in
            for item in items {
                try db.execute(
                    sql: "DELETE FROM search_fts WHERE entityId = ? AND kind = ?",
                    arguments: [item.id, item.kind.rawValue]
                )
                if item.excluded { continue }
                try db.execute(
                    sql: """
                        INSERT INTO search_fts (entityId, kind, title, body, tags)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        item.id,
                        item.kind.rawValue,
                        item.title,
                        Self.body(of: item),
                        item.tags.joined(separator: ", "),
                    ]
                )
            }
        }
    }

    public func search(_ query: String, limit: Int) throws -> [IndexHit] {
        guard let match = Self.ftsQuery(query) else { return [] }
        let rows = try database.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT entityId, kind, title,
                           snippet(search_fts, -1, ?, ?, '…', 12) AS snip,
                           bm25(search_fts) AS rank
                    FROM search_fts
                    WHERE search_fts MATCH ?
                    ORDER BY bm25(search_fts)
                    LIMIT ?
                    """,
                arguments: [Self.matchStart, Self.matchEnd, match, limit]
            )
        }
        return rows.compactMap { row in
            let kindRaw: String = row["kind"] ?? ""
            guard let kind = IndexKind(rawValue: kindRaw) else { return nil }
            let marked: String = row["snip"] ?? ""
            let (snippet, ranges) = Self.parseSnippet(marked)
            let id: String = row["entityId"] ?? ""
            let title: String = row["title"] ?? ""
            let rank: Double = row["rank"] ?? 0
            return IndexHit(
                id: id,
                kind: kind,
                title: title,
                snippet: snippet,
                matchRanges: ranges,
                score: -rank
            )
        }
    }

    public func remove(id: String, kind: IndexKind) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM search_fts WHERE entityId = ? AND kind = ?",
                arguments: [id, kind.rawValue]
            )
        }
    }

    public func remove(id: String) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM search_fts WHERE entityId = ?", arguments: [id])
        }
    }

    public func removeAll() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM search_fts")
        }
    }

    /// Indexed body: summary + full text (transcript). Both indexed — D7.
    private static func body(of item: IndexItem) -> String {
        [item.summary, item.fullText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Turns free user text into a safe FTS5 MATCH expression: each token becomes a quoted
    /// prefix phrase (`"budg"*`), joined by implicit AND. Nil when no searchable tokens remain.
    static func ftsQuery(_ query: String) -> String? {
        let tokens = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }

    /// Strips the snippet markers, returning plain text plus the match ranges (character offsets).
    static func parseSnippet(_ marked: String) -> (String, [Range<Int>]) {
        var plain = ""
        var ranges: [Range<Int>] = []
        var openedAt: Int?
        var count = 0
        for char in marked {
            if String(char) == matchStart {
                openedAt = count
            } else if String(char) == matchEnd {
                if let start = openedAt, count > start {
                    ranges.append(start..<count)
                }
                openedAt = nil
            } else {
                plain.append(char)
                count += 1
            }
        }
        return (plain, ranges)
    }
}
