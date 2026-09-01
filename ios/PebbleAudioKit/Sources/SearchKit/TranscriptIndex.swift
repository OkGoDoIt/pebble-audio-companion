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
        try search(query, limit: limit, kinds: nil, within: nil)
    }

    /// Search narrowed to the documents that can actually be shown.
    ///
    /// The Search screen's scope pill (Today / Yesterday / Last 7 days / a date range) used to be
    /// applied AFTER an unscoped `LIMIT 40`, which meant a conversation inside the window that
    /// ranked 41st across the whole library was invisible under its own pill — a quiet
    /// under-report that gets worse with every conversation added. Both narrowings belong in the
    /// query: `kinds` because the caller throws away every other kind anyway, and `ids` because
    /// the window resolves to a known set of conversations. The limit is then spent entirely on
    /// rows the caller can use, so the top N is the true top N *within the scope*.
    ///
    /// `ids` travels as one JSON array rather than N bound parameters, so a wide date range on a
    /// large library cannot run into SQLite's variable ceiling. An EMPTY set means "the window
    /// holds nothing" and short-circuits; `nil` means unrestricted.
    public func search(
        _ query: String,
        limit: Int,
        kinds: Set<IndexKind>? = nil,
        within ids: Set<String>? = nil,
        mode: MatchMode = .all
    ) throws -> [IndexHit] {
        guard let match = Self.ftsQuery(query, mode: mode) else { return [] }
        if let ids, ids.isEmpty { return [] }
        if let kinds, kinds.isEmpty { return [] }

        var conditions = ["search_fts MATCH ?"]
        var arguments: [any DatabaseValueConvertible] = [
            Self.matchStart, Self.matchEnd, match,
        ]
        if let kinds {
            let sorted = kinds.map(\.rawValue).sorted()
            conditions.append(
                "kind IN (\(Array(repeating: "?", count: sorted.count).joined(separator: ", ")))")
            arguments.append(contentsOf: sorted)
        }
        if let ids {
            conditions.append("entityId IN (SELECT value FROM json_each(?))")
            arguments.append(Self.jsonArray(ids))
        }
        arguments.append(limit)

        let rows = try database.reader.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT entityId, kind, title,
                           snippet(search_fts, -1, ?, ?, '…', 12) AS snip,
                           bm25(search_fts) AS rank
                    FROM search_fts
                    WHERE \(conditions.joined(separator: " AND "))
                    ORDER BY bm25(search_fts)
                    LIMIT ?
                    """,
                arguments: StatementArguments(arguments)
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

    /// The id set as a JSON array literal for `json_each`. Hand-built rather than
    /// `JSONEncoder`ed so the escaping is explicit and the function cannot throw mid-query;
    /// entity ids are our own UUID-shaped strings, but a quote or backslash in one would still
    /// have produced a silently empty result set rather than an error.
    static func jsonArray(_ ids: Set<String>) -> String {
        let escaped = ids.sorted().map { id -> String in
            var out = ""
            for character in id {
                switch character {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case let control where control.unicodeScalars.allSatisfy({ $0.value < 0x20 }):
                    for scalar in control.unicodeScalars {
                        out += String(format: "\\u%04x", scalar.value)
                    }
                default: out.append(character)
                }
            }
            return "\"\(out)\""
        }
        return "[\(escaped.joined(separator: ","))]"
    }

    /// Indexed body: summary + full text (transcript). Both indexed — D7.
    private static func body(of item: IndexItem) -> String {
        [item.summary, item.fullText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// How the terms of a query combine.
    public enum MatchMode: Sendable {
        /// Every term must appear. What a Search box should do: the user typed two words
        /// because they want the row with both.
        case all
        /// Any term may appear, ranked by bm25 — so a document matching more of the rare terms
        /// still sorts first, but one good term is enough to be recalled at all.
        ///
        /// This is what asking a QUESTION needs. "Do I have travel plans for the rest of the
        /// year?" ANDed is a demand for one conversation containing every one of those words,
        /// which essentially no transcript satisfies; the query silently matched nothing and
        /// Ask fell back to whatever happened to be first in the library.
        case any
    }

    /// Words carrying no retrieval signal. Stripped from multi-term queries: they are in
    /// virtually every transcript, so under `.all` they veto real matches and under `.any` they
    /// dominate the ranking with noise. Kept when they are ALL the user typed, so searching for
    /// "the" still searches for "the".
    static let stopWords: Set<String> = [
        "a", "about", "am", "an", "and", "any", "are", "as", "at", "be", "been", "being",
        "but", "by", "can", "could", "did", "do", "does", "for", "from", "had", "has", "have",
        "he", "her", "him", "his", "i", "if", "in", "into", "is", "it", "its", "just", "me",
        "my", "of", "on", "or", "our", "she", "should", "so", "than", "that", "the", "their",
        "them", "then", "there", "these", "they", "this", "those", "to", "up", "us", "was",
        "we", "were", "what", "when", "where", "which", "who", "whom", "why", "will", "with",
        "would", "you", "your",
    ]

    /// Turns free user text into a safe FTS5 MATCH expression: each token becomes a quoted
    /// prefix phrase (`"budg"*`), joined by AND or OR per `mode`. Nil when no searchable tokens
    /// remain.
    static func ftsQuery(_ query: String, mode: MatchMode = .all) -> String? {
        let tokens = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        // A single term is the whole query — never strip it to nothing.
        let content = tokens.count == 1
            ? tokens
            : tokens.filter { !stopWords.contains($0.lowercased()) }
        let usable = content.isEmpty ? tokens : content
        let phrases = usable.map {
            "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*"
        }
        return phrases.joined(separator: mode == .all ? " " : " OR ")
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
