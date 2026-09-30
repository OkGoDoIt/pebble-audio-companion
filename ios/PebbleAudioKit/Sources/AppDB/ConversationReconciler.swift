import Foundation
import GRDB

// Keeps what is ATTACHED to a conversation attached when conversations move.
//
// A conversation's id is its start position (`ConversationCut.conversationId`), and the grouping
// is derived: every rebuild may cut a conversation in two, join two, or move a cut, and on the
// first run after conversations became topic-sized it re-cut the whole library. Everything else
// in the database that names a conversation names it by id — a follow-up's source, a saved
// note, a tag, a speaker's name, a title — and none of those tables is rebuilt with the
// grouping. Left alone they drift: a follow-up opens the conversation BEFORE the one it was
// said in, and the notes of a conversation whose id went away belong to nothing.
//
// Two kinds of record, two rules:
//
//  - A record about a MOMENT (a follow-up, a follow-up candidate: segment + media offset)
//    belongs to whichever conversation owns that moment now. `ConversationQueries
//    .conversationId(ofSegment:atMediaMs:)` is the rule, and the only one.
//  - A record about a CONVERSATION (a note, a tag, a speaker assignment, a typed title) follows
//    its conversation. When the id is gone, the conversation that now holds the old one's START
//    is its successor, and takes them.
//
// WHAT IT NEVER DOES
//
//  - It never deletes a follow-up, a note, or a tag a person made. Those are moved or left
//    where they are.
//  - It does nothing about a conversation that has NO successor. No successor means the audio
//    at its start is in no conversation at all: either it was deleted — and `DeleteCascade`
//    owns that — or the grouping is momentarily empty (a rebuild over a store that could not be
//    listed), in which case the ids come back on the next rebuild and everything keyed by them
//    must still be there. Only an id that was provably SUPERSEDED has its derived rows (the
//    model's title, its tags, its extraction bookkeeping) removed.
//  - It is safe to run twice: every step reads the state it is about to change, and a second
//    run finds nothing left to do.
//
// COST. `reconcile(previous:current:)` looks only at what a rebuild changed: the conversations
// whose pieces differ, the rows that name their segments, the ids that went away. A rebuild that
// changed nothing structural never calls it. `sweep()` is the whole-library version, for once
// per launch — see its own comment.

public struct ConversationReconciler: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// What one run did. Counts, for the log and the tests; `superseded` for whoever keeps an
    /// index keyed by conversation id outside this database's reach (Spotlight).
    public struct Outcome: Equatable, Sendable {
        /// Each id that no longer exists and was taken over, with the conversation that holds
        /// its start now. Named whether or not it had anything to hand over — and named again
        /// by a second run over the same rebuild, which is what makes removing its index rows
        /// repeatable.
        public var superseded: [String: String] = [:]
        public var followUpsRepointed = 0
        public var candidatesRepointed = 0
        public var notesMoved = 0
        /// Person-made tag pairs (added, or removed-and-remembered) carried to a successor.
        public var tagsMoved = 0
        public var speakerAssignmentsMoved = 0
        /// Titles the person typed, carried to a successor that had none of its own.
        public var titlesMoved = 0
        /// Annotations of superseded conversations removed (the model's; a typed title was
        /// carried first).
        public var annotationsRemoved = 0

        public init() {}

        /// Nothing was moved or removed.
        public var isEmpty: Bool {
            followUpsRepointed == 0 && candidatesRepointed == 0
                && notesMoved == 0 && tagsMoved == 0 && speakerAssignmentsMoved == 0
                && titlesMoved == 0 && annotationsRemoved == 0
        }
    }

    /// A conversation id that may be gone, and the position it started at.
    struct Departed: Equatable {
        var id: String
        var segmentId: String
        var mediaMs: Int64
    }

    // MARK: - After a rebuild

    /// Reconciles after a rebuild that changed the grouping's structure. `previous` is the
    /// grouping as it was (`ConversationGrouper.RebuiltGrouping.previous`), `current` as it is.
    ///
    /// The two are only used to find WHAT CHANGED; who owns a moment, and whether an id is
    /// really gone, are read from the database inside the write — so a second rebuild that
    /// landed in between cannot make this one re-point a row at a conversation that no longer
    /// exists.
    @discardableResult
    public func reconcile(
        previous: [GroupedConversation], current: [GroupedConversation]
    ) async throws -> Outcome {
        let now = Dictionary(current.map { ($0.id, $0.members) }, uniquingKeysWith: { a, _ in a })
        var touchedSegments = Set<String>()
        var departed: [Departed] = []
        for old in previous {
            if let members = now[old.id] {
                // Same id, same pieces: every moment that was inside it still is.
                if members == old.members { continue }
            } else if let first = old.members.first {
                departed.append(
                    Departed(
                        id: old.id, segmentId: first.segmentId,
                        mediaMs: first.startMediaMs ?? 0))
            }
            touchedSegments.formUnion(old.memberSegmentIds)
        }
        guard !touchedSegments.isEmpty || !departed.isEmpty else { return Outcome() }
        let segments = Array(touchedSegments)
        let gone = departed
        return try await db.writer.write { d in
            var outcome = Outcome()
            try Self.repointMoments(d, segmentIds: segments, into: &outcome)
            try Self.supersede(d, gone, into: &outcome)
            return outcome
        }
    }

    // MARK: - Once per launch

    /// The same reconciliation over the whole library, from the database alone.
    ///
    /// `reconcile` needs the grouping as it WAS, and that exists only in the rebuild that
    /// replaced it: the grouper writes the new grouping in its own transaction and hands the
    /// old one back. If the process dies between that write and the reconcile — the first
    /// rebuild after the re-cut is the longest the app ever runs, and iOS kills what it
    /// suspends — the old grouping is gone for good, and with it the only record of which
    /// follow-ups moved. This is how that heals: every moment-record is checked against who
    /// owns its moment now, and every conversation-record whose id no longer exists is carried
    /// to the conversation holding the position its ID names (`conv-<segment>` starts at the
    /// segment's first frame, `conv-<segment>-m<ms>` at that offset).
    ///
    /// Reads every follow-up and pending candidate once, and the distinct conversation ids of
    /// five small tables. Meant for the first regroup of a launch, not for every pass.
    @discardableResult
    public func sweep() async throws -> Outcome {
        try await db.writer.write { d in
            var outcome = Outcome()
            try Self.repointMoments(d, segmentIds: nil, into: &outcome)

            var orphans = Set<String>()
            var sources = [
                "SELECT DISTINCT conversationId AS named FROM notes",
                "SELECT DISTINCT conversationId AS named FROM conversation_tags",
                "SELECT DISTINCT conversationId AS named FROM speaker_assignments",
                "SELECT conversationId AS named FROM annotations",
                """
                SELECT DISTINCT sourceConversationId AS named FROM follow_ups
                WHERE sourceConversationId IS NOT NULL AND sourceSegmentId IS NULL
                """,
            ]
            if try d.tableExists("follow_up_extractions") {
                sources.append("SELECT conversationId AS named FROM follow_up_extractions")
            }
            for sql in sources {
                orphans.formUnion(
                    try String.fetchAll(
                        d,
                        sql: """
                            SELECT named FROM (\(sql))
                            WHERE named NOT IN (SELECT id FROM conversations)
                            """))
            }
            let departed = orphans.sorted().compactMap(Self.startPosition(ofConversationId:))
            try Self.supersede(d, departed, into: &outcome)
            return outcome
        }
    }

    /// Where the conversation an id names started: `conv-<segmentId>` at the segment's first
    /// frame, `conv-<segmentId>-m<ms>` at that offset (`ConversationCut.conversationId`). Nil
    /// for an id of any other shape, which no position can be read from.
    static func startPosition(ofConversationId id: String) -> Departed? {
        guard id.hasPrefix("conv-"), id.count > 5 else { return nil }
        let rest = String(id.dropFirst(5))
        if let marker = rest.range(of: "-m", options: .backwards),
            let mediaMs = Int64(rest[marker.upperBound...]), mediaMs > 0,
            marker.lowerBound > rest.startIndex
        {
            return Departed(
                id: id, segmentId: String(rest[..<marker.lowerBound]), mediaMs: mediaMs)
        }
        return Departed(id: id, segmentId: rest, mediaMs: 0)
    }

    // MARK: - Moments

    /// Re-points every follow-up and pending candidate whose source moment is no longer inside
    /// the conversation it names. `segmentIds` limits the look to rows about those segments;
    /// nil looks at every row.
    ///
    /// Only PENDING candidates: a decided one is history (what curation made of a proposal, for
    /// Diagnostics), and the follow-up it became carries the link that matters.
    static func repointMoments(
        _ d: Database, segmentIds: [String]?, into outcome: inout Outcome
    ) throws {
        struct Moment {
            var id: String
            var conversationId: String
            var segmentId: String
            var startMs: Int64?
        }
        /// The rows `select` names, limited to `segmentIds` through `segmentColumn` (each has an
        /// index, or a table small enough not to need one).
        func moments(_ select: String, segmentColumn: String) throws -> [Moment] {
            func read(_ filter: String, _ arguments: StatementArguments) throws -> [Moment] {
                try Row.fetchAll(d, sql: "\(select) \(filter)", arguments: arguments).map {
                    Moment(
                        id: $0["id"], conversationId: $0["conversationId"],
                        segmentId: $0["segmentId"], startMs: $0["startMs"])
                }
            }
            guard let segmentIds else { return try read("", []) }
            var out: [Moment] = []
            // Chunked: the first run after the re-cut names every segment in the library.
            for start in stride(from: 0, to: segmentIds.count, by: 400) {
                let chunk = Array(segmentIds[start..<min(start + 400, segmentIds.count)])
                out += try read(
                    "AND \(segmentColumn) IN (\(databaseQuestionMarks(count: chunk.count)))",
                    StatementArguments(chunk))
            }
            return out
        }

        let followUps = try moments(
            """
            SELECT id, sourceConversationId AS conversationId, sourceSegmentId AS segmentId,
                sourceStartMs AS startMs
            FROM follow_ups
            WHERE sourceConversationId IS NOT NULL AND sourceSegmentId IS NOT NULL
            """, segmentColumn: "sourceSegmentId")
        for row in followUps {
            guard
                let current = try owner(
                    d, of: row.segmentId, at: row.startMs, recorded: row.conversationId),
                current != row.conversationId
            else { continue }
            try d.execute(
                sql: "UPDATE follow_ups SET sourceConversationId = ? WHERE id = ?",
                arguments: [current, row.id])
            outcome.followUpsRepointed += 1
        }

        let candidates = try moments(
            """
            SELECT id, conversationId, segmentId, startMs FROM follow_up_candidates
            WHERE state = 'pending' AND segmentId IS NOT NULL
            """, segmentColumn: "segmentId")
        for row in candidates {
            guard
                let current = try owner(
                    d, of: row.segmentId, at: row.startMs, recorded: row.conversationId),
                current != row.conversationId
            else { continue }
            try d.execute(
                sql: "UPDATE follow_up_candidates SET conversationId = ? WHERE id = ?",
                arguments: [current, row.id])
            outcome.candidatesRepointed += 1
        }
    }

    /// The conversation a source moment belongs to now; nil when its segment is in none.
    ///
    /// A row with no offset (its quote was found in the recording's text but not in a timed
    /// turn) cannot be placed inside the segment, so it stays with the conversation it names
    /// for as long as that conversation owns any of the segment, and goes to the owner of the
    /// segment's start only once it does not.
    private static func owner(
        _ d: Database, of segmentId: String, at startMs: Int64?, recorded: String
    ) throws -> String? {
        if startMs == nil,
            try Bool.fetchOne(
                d,
                sql: """
                    SELECT EXISTS(SELECT 1 FROM conversation_segments
                        WHERE segmentId = ? AND conversationId = ?)
                    """,
                arguments: [segmentId, recorded]) == true
        {
            return recorded
        }
        return try ConversationQueries.conversationId(
            d, ofSegment: segmentId, atMediaMs: startMs ?? 0)
    }

    // MARK: - Conversations

    /// Carries what belonged to each departed conversation to its successor. An id that still
    /// exists, or has no successor, is skipped whole.
    static func supersede(
        _ d: Database, _ departed: [Departed], into outcome: inout Outcome
    ) throws {
        let hasExtractions = try d.tableExists("follow_up_extractions")
        for old in departed {
            let exists = try Bool.fetchOne(
                d, sql: "SELECT EXISTS(SELECT 1 FROM conversations WHERE id = ?)",
                arguments: [old.id])
            guard exists != true,
                let successor = try ConversationQueries.conversationId(
                    d, ofSegment: old.segmentId, atMediaMs: old.mediaMs),
                successor != old.id
            else { continue }
            outcome.superseded[old.id] = successor

            // Moment-records that carry no moment (a follow-up or candidate with no segment)
            // can only follow their conversation.
            try d.execute(
                sql: """
                    UPDATE follow_ups SET sourceConversationId = ?
                    WHERE sourceConversationId = ? AND sourceSegmentId IS NULL
                    """,
                arguments: [successor, old.id])
            outcome.followUpsRepointed += d.changesCount
            try d.execute(
                sql: """
                    UPDATE follow_up_candidates SET conversationId = ?
                    WHERE conversationId = ? AND state = 'pending' AND segmentId IS NULL
                    """,
                arguments: [successor, old.id])
            outcome.candidatesRepointed += d.changesCount

            try d.execute(
                sql: "UPDATE notes SET conversationId = ? WHERE conversationId = ?",
                arguments: [successor, old.id])
            outcome.notesMoved += d.changesCount

            try moveTags(d, from: old.id, to: successor, into: &outcome)
            try moveSpeakers(d, from: old.id, to: successor, into: &outcome)
            try moveAnnotation(d, from: old.id, to: successor, into: &outcome)

            // What extraction knew about a conversation that no longer exists is about nothing.
            // (Created by its store, not by a migration, so it may not exist yet.)
            if hasExtractions {
                try d.execute(
                    sql: "DELETE FROM follow_up_extractions WHERE conversationId = ?",
                    arguments: [old.id])
            }
        }
    }

    /// The person's tags — the ones they added, and the ones they took off and whose removal is
    /// remembered — go with the conversation. The model's tags do not: they described the old
    /// conversation, and the successor gets its own when it is titled.
    ///
    /// Where the successor already carries the same tag, the person's decision is the one kept:
    /// an added tag beats a remembered removal, and either beats a tag the model proposed.
    private static func moveTags(
        _ d: Database, from old: String, to successor: String, into outcome: inout Outcome
    ) throws {
        func rank(_ source: String) -> Int {
            source == TagSource.user ? 2 : (source == TagSource.removed ? 1 : 0)
        }
        for row in try Row.fetchAll(
            d, sql: "SELECT tagId, source FROM conversation_tags WHERE conversationId = ?",
            arguments: [old])
        {
            let tagId: String = row["tagId"]
            let source: String = row["source"]
            guard rank(source) > 0 else { continue }
            let held = try String.fetchOne(
                d,
                sql: "SELECT source FROM conversation_tags WHERE conversationId = ? AND tagId = ?",
                arguments: [successor, tagId])
            if let held {
                guard rank(source) > rank(held) else { continue }
                try d.execute(
                    sql: """
                        UPDATE conversation_tags SET source = ?
                        WHERE conversationId = ? AND tagId = ?
                        """,
                    arguments: [source, successor, tagId])
            } else {
                try d.execute(
                    sql: """
                        INSERT INTO conversation_tags (conversationId, tagId, source)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [successor, tagId, source])
            }
            outcome.tagsMoved += 1
        }
        // Everything the person made is on the successor now; what is left under the old id is
        // the model's, or a duplicate of what the successor holds.
        try d.execute(
            sql: "DELETE FROM conversation_tags WHERE conversationId = ?", arguments: [old])
    }

    /// A speaker's name goes to the successor where the successor has not named that label
    /// itself. Where it has, the old row is LEFT: it is the person's, it costs nothing, and if
    /// the two conversations are ever parted again the id comes back and finds it.
    private static func moveSpeakers(
        _ d: Database, from old: String, to successor: String, into outcome: inout Outcome
    ) throws {
        try d.execute(
            sql: """
                UPDATE speaker_assignments SET conversationId = ?
                WHERE conversationId = ? AND label NOT IN
                    (SELECT label FROM speaker_assignments WHERE conversationId = ?)
                """,
            arguments: [successor, old, successor])
        outcome.speakerAssignmentsMoved += d.changesCount
    }

    /// The old conversation's annotation goes — it was written about audio the successor only
    /// partly holds, and the successor has or will get its own. A title the PERSON typed is the
    /// exception: it goes to the successor, unless the successor has one the person typed too.
    ///
    /// The successor's row keeps whatever else it holds; a successor with no row gets one with
    /// the title and nothing else, which the enrichment pass then fills in around it (no source
    /// key, so it is due, and the marked title is kept).
    private static func moveAnnotation(
        _ d: Database, from old: String, to successor: String, into outcome: inout Outcome
    ) throws {
        guard
            let row = try Row.fetchOne(
                d,
                sql: "SELECT title, titleEditedAtMs FROM annotations WHERE conversationId = ?",
                arguments: [old])
        else { return }
        if let editedAtMs: Int64 = row["titleEditedAtMs"], let title: String = row["title"],
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let held = try Row.fetchOne(
                d, sql: "SELECT titleEditedAtMs FROM annotations WHERE conversationId = ?",
                arguments: [successor])
            if held == nil {
                try d.execute(
                    sql: """
                        INSERT INTO annotations (conversationId, title, titleEditedAtMs)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [successor, title, editedAtMs])
                outcome.titlesMoved += 1
            } else if (held?["titleEditedAtMs"] as Int64?) == nil {
                try d.execute(
                    sql: """
                        UPDATE annotations SET title = ?, titleEditedAtMs = ?
                        WHERE conversationId = ?
                        """,
                    arguments: [title, editedAtMs, successor])
                outcome.titlesMoved += 1
            }
        }
        try d.execute(sql: "DELETE FROM annotations WHERE conversationId = ?", arguments: [old])
        outcome.annotationsRemoved += 1
    }
}
