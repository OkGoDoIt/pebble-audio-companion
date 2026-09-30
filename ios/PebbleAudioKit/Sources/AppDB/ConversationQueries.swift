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
    /// Else any member with NO durable transcript that is Pending (or Disabled — waiting for a
    /// usable provider), or missing a task row entirely.
    case capturedWaiting
    /// Else any member Failed with nothing on disk.
    case failed
    /// All members terminal-success (Complete/NoSpeech).
    case complete
}

/// One member as the aggregation sees it: what the QUEUE thinks, and what is actually on disk.
public struct ConversationMemberState: Equatable, Sendable {
    /// `transcription_tasks.state`, or nil where the segment has no queue row — pruned, or
    /// never enqueued because it arrived already transcribed.
    public var task: TranscriptionState?
    /// The segment's own `SegmentMeta.transcriptionState`, mirrored into the derived table.
    public var segment: TranscriptionState?

    public init(task: TranscriptionState?, segment: TranscriptionState?) {
        self.task = task
        self.segment = segment
    }

    /// Terminal success on disk. A transcript that exists is finished work, whatever a queue
    /// row does or doesn't say about it.
    public var hasDurableTranscript: Bool {
        segment == .complete || segment == .noSpeech
    }
}

/// The Library "All ⌄" menu (plan 6.7).
public enum LibraryFilter: String, Equatable, Sendable {
    case all
    case untranscribed
    case withFollowUps
    case withMissingAudio
}

/// Shared with the enrichment worker (Intelligence depends on this module) so the library's
/// "waiting" count and the worker's give-up rule cannot drift apart.
public enum AnnotationPolicy {
    public static let maxFinalAttempts = 3
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
    /// True once enrichment has written anything for this conversation (a title or a summary).
    /// False means AI has not landed yet — which the UI must say out loud rather than render
    /// as an untitled, untagged row that looks broken.
    public var hasAnnotation: Bool
    /// Authoritative-pass attempts already spent (`EnrichmentWorker.maxAttempts` bounds them).
    /// Lets the UI tell "still working on it" apart from "it tried and gave up".
    public var annotationFinalAttempts: Int
    /// At least one member finished with a transcript that has words in it. A conversation whose
    /// every member ended as no-speech has nothing for the enrichment pass to read, so it will
    /// never get a title — and must not be counted as waiting for one.
    public var hasSpeech: Bool

    /// Public so callers outside the kit can build one. Without it the memberwise initializer is
    /// internal, and the app layer's mappers from this type into its display models (Today's
    /// conversation rows, the Library rows) could not be tested at all — which is exactly where
    /// a hard-coded field goes unnoticed.
    public init(
        id: String,
        title: String? = nil,
        summary: String? = nil,
        startMs: Int64 = 0,
        endMs: Int64 = 0,
        timeZoneID: String = TimeZone.current.identifier,
        isLive: Bool = false,
        tags: [String] = [],
        lifecycle: ConversationLifecycle = .complete,
        mostlyQuiet: Bool = false,
        hasMissingAudio: Bool = false,
        followUpCount: Int = 0,
        openFollowUpCount: Int = 0,
        dateKey: String = "",
        hasAnnotation: Bool = false,
        annotationFinalAttempts: Int = 0,
        hasSpeech: Bool = true
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.startMs = startMs
        self.endMs = endMs
        self.timeZoneID = timeZoneID
        self.isLive = isLive
        self.tags = tags
        self.lifecycle = lifecycle
        self.mostlyQuiet = mostlyQuiet
        self.hasMissingAudio = hasMissingAudio
        self.followUpCount = followUpCount
        self.openFollowUpCount = openFollowUpCount
        self.dateKey = dateKey
        self.hasAnnotation = hasAnnotation
        self.annotationFinalAttempts = annotationFinalAttempts
        self.hasSpeech = hasSpeech
    }

    public var durationMs: Int64 { max(0, endMs - startMs) }

    /// Enrichment has produced nothing yet AND the transcript it needs is ready — so the row
    /// is waiting on AI, not on capture.
    /// Untitled AND still eligible for a title. A conversation the enrichment worker has
    /// already given up on (`AnnotationPolicy.maxFinalAttempts` failed final passes) is not
    /// "waiting": counting it made Diagnostics say "54 waiting" all afternoon for work that was
    /// never going to happen.
    public var awaitingAnnotation: Bool {
        !hasAnnotation && lifecycle == .complete && hasSpeech
            && annotationFinalAttempts < AnnotationPolicy.maxFinalAttempts
    }

    /// Untitled because every final pass failed; nothing will retry it on its own.
    public var annotationGivenUp: Bool {
        !hasAnnotation && lifecycle == .complete
            && annotationFinalAttempts >= AnnotationPolicy.maxFinalAttempts
    }
}

public struct LibraryDaySection: Equatable, Sendable {
    public var dateKey: String
    public var rows: [ConversationListRow]
}

/// Per-segment provenance for the conversation Details view (visible per plan Part 3).
public struct SegmentProvenance: Equatable, Sendable {
    public var segmentId: String
    public var ordinal: Int
    /// Queue state (`transcription_tasks`), nil where the segment has no row.
    public var state: TranscriptionState?
    /// The segment's own durable state — the truth about whether a transcript exists.
    public var segmentState: TranscriptionState?
    public var providerId: String?
    public var modelUsed: String?
    public var modeUsed: String?
    public var attempts: Int
    public var lastError: String?
    /// The range of the segment's stored audio this conversation owns (media ms). Nil bounds
    /// mean "from the segment's start" / "to its end"; both nil is the whole segment.
    public var startMediaMs: Int64?
    public var endMediaMs: Int64?

    public init(
        segmentId: String, ordinal: Int, state: TranscriptionState? = nil,
        segmentState: TranscriptionState? = nil, providerId: String? = nil,
        modelUsed: String? = nil, modeUsed: String? = nil, attempts: Int = 0,
        lastError: String? = nil, startMediaMs: Int64? = nil, endMediaMs: Int64? = nil
    ) {
        self.segmentId = segmentId
        self.ordinal = ordinal
        self.state = state
        self.segmentState = segmentState
        self.providerId = providerId
        self.modelUsed = modelUsed
        self.modeUsed = modeUsed
        self.attempts = attempts
        self.lastError = lastError
        self.startMediaMs = startMediaMs
        self.endMediaMs = endMediaMs
    }

    /// The piece itself — what to hand `SegmentTranscript.piece(_:)` or a frame reader.
    public var member: ConversationMember {
        ConversationMember(
            segmentId: segmentId, startMediaMs: startMediaMs, endMediaMs: endMediaMs)
    }
}

public struct ConversationDetail: Equatable, Sendable {
    public var row: ConversationListRow
    public var members: [SegmentProvenance]
}

public struct ConversationQueries: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    /// Why a conversation starts where it does (see `ConversationBoundaries.swift`). Read on its
    /// own rather than carried on every `ConversationListRow`, because it belongs under the
    /// title of the ONE conversation being read — not on every row of a list, where it would be
    /// noise. Nil for the oldest conversation and for anything grouped before the column
    /// existed.
    public func startReason(ofConversation id: String) async throws -> ConversationStartReason? {
        try await db.reader.read { db in
            try String.fetchOne(
                db, sql: "SELECT startReason FROM conversations WHERE id = ?", arguments: [id]
            ).flatMap(ConversationStartReason.init(rawValue:))
        }
    }

    // --- aggregation --------------------------------------------------------------------------

    /// Plan Part 3: any Running/Uploading ⇒ transcribing; else any Pending ⇒ captured-waiting;
    /// else any Failed ⇒ failed; else complete. A member without a task row counts as Pending;
    /// Disabled counts as Pending (eligible again once a provider is usable).
    ///
    /// **A member holding a durable transcript is done, whatever the queue table says.** The
    /// queue is a work list, not a record of what exists: rows get pruned, and a segment
    /// imported with its transcript already on disk never had one. Reading the task rows alone
    /// made every migrated conversation announce "Captured · waiting to transcribe" directly
    /// above its own finished transcript, and offer a pointless "Transcribe Now" (anti-goal B2).
    static func aggregateLifecycle(_ members: [ConversationMemberState]) -> ConversationLifecycle {
        // A re-transcribe in flight is worth showing even over an existing transcript.
        if members.contains(where: { $0.task == .running || $0.task == .uploading }) {
            return .transcribing
        }
        let unfinished = members.filter { !$0.hasDurableTranscript }
        if unfinished.contains(where: {
            $0.task == nil || $0.task == .pending || $0.task == .disabled
        }) {
            return .capturedWaiting
        }
        if unfinished.contains(where: { $0.task == .failed }) { return .failed }
        return .complete
    }

    /// Task-row-only overload (no durable-transcript information available).
    static func aggregateLifecycle(_ states: [TranscriptionState?]) -> ConversationLifecycle {
        aggregateLifecycle(states.map { ConversationMemberState(task: $0, segment: nil) })
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

    /// Which conversations a row build reads.
    enum RowScope: Sendable {
        /// The whole library (the Library screen, its observation, the widget and Spotlight).
        case all
        /// Just these conversations — one, for `detail(id:)`.
        case ids([String])
        /// Conversations whose `[startMs, endMs)` overlaps the window (see
        /// `rows(overlappingMs:)` for the edges).
        case overlapping(Range<Int64>)
    }

    /// The conversation rows in `scope`, newest first. Every per-conversation read (members,
    /// tags, follow-ups, coverage) is restricted to the conversations the scope selected, so a
    /// scoped build does work in proportion to what it returns rather than to the library. For
    /// `.all` the queries are the ones it always ran.
    static func buildRows(_ db: Database, scope: RowScope = .all) throws -> [ConversationListRow] {
        let select = """
            SELECT c.id AS id, c.startMs AS startMs, c.endMs AS endMs,
                c.timezone AS timezone, c.state AS state,
                a.title AS title, a.summary AS summary, a.finalAttempts AS finalAttempts
            FROM conversations c
            LEFT JOIN annotations a ON a.conversationId = c.id
            """
        let order = "ORDER BY c.startMs DESC, c.id"
        let convoRows: [Row]
        switch scope {
        case .all:
            convoRows = try Row.fetchAll(db, sql: "\(select)\n\(order)")
        case .ids(let ids):
            guard !ids.isEmpty else { return [] }
            convoRows = try Row.fetchAll(
                db,
                sql: "\(select)\nWHERE c.id IN (\(databaseQuestionMarks(count: ids.count)))\n\(order)",
                arguments: StatementArguments(ids))
        case .overlapping(let window):
            guard !window.isEmpty else { return [] }
            // Overlap of [startMs, endMs) with the window. A row with no end runs on; one with no
            // length (a recording that never received audio) is a point, and is in the window
            // when its start is. `startMs < ?` is what `conversations_start` serves.
            convoRows = try Row.fetchAll(
                db,
                sql: """
                    \(select)
                    WHERE c.startMs < ?
                        AND (c.endMs IS NULL OR c.endMs > ? OR c.startMs >= ?)
                    \(order)
                    """,
                arguments: [window.upperBound, window.lowerBound, window.lowerBound])
        }
        // For a scoped build, the per-conversation reads below take `WHERE … IN (<these ids>)`;
        // for the whole library they take nothing, exactly as before.
        let scopedIds: [String]?
        switch scope {
        case .all: scopedIds = nil
        case .ids, .overlapping:
            guard !convoRows.isEmpty else { return [] }
            scopedIds = convoRows.map { $0["id"] }
        }
        func restricted(_ column: String, joiner: String) -> String {
            guard let scopedIds else { return "" }
            return "\(joiner) \(column) IN (\(databaseQuestionMarks(count: scopedIds.count)))"
        }
        let scopedArguments = StatementArguments(scopedIds ?? [])

        var memberStates: [String: [ConversationMemberState]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT cs.conversationId AS conversationId, tt.state AS state,
                    cs.transcriptionState AS segmentState
                FROM conversation_segments cs
                LEFT JOIN transcription_tasks tt ON tt.segmentId = cs.segmentId
                \(restricted("cs.conversationId", joiner: "WHERE"))
                ORDER BY cs.conversationId, cs.ordinal
                """,
            arguments: scopedArguments
        ) {
            memberStates[row["conversationId"], default: []].append(
                ConversationMemberState(
                    task: (row["state"] as String?).flatMap(TranscriptionState.init(rawValue:)),
                    segment: (row["segmentState"] as String?)
                        .flatMap(TranscriptionState.init(rawValue:))
                )
            )
        }

        var tagNames: [String: [String]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT ct.conversationId AS conversationId, t.name AS name
                FROM conversation_tags ct JOIN tags t ON t.id = ct.tagId
                WHERE ct.source <> '\(TagSource.removed)'
                \(restricted("ct.conversationId", joiner: "AND"))
                ORDER BY t.name COLLATE NOCASE ASC
                """,
            arguments: scopedArguments
        ) {
            tagNames[row["conversationId"], default: []].append(row["name"])
        }

        var followUps: [String: (total: Int, open: Int)] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT sourceConversationId AS conversationId, COUNT(*) AS total,
                    SUM(
                        CASE WHEN done = 0 AND archivedAtMs IS NULL THEN 1 ELSE 0 END
                    ) AS open
                FROM follow_ups WHERE sourceConversationId IS NOT NULL
                \(restricted("sourceConversationId", joiner: "AND"))
                GROUP BY sourceConversationId
                """,
            arguments: scopedArguments
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
            let title: String? = row["title"]
            let summary: String? = row["summary"]
            return ConversationListRow(
                id: id,
                title: title,
                summary: summary,
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
                dateKey: prelim.keys[0],
                hasAnnotation: !(title ?? "").isEmpty || !(summary ?? "").isEmpty,
                annotationFinalAttempts: row["finalAttempts"] ?? 0,
                hasSpeech: (memberStates[id] ?? []).contains { $0.segment == .complete }
            )
        }
    }

    static func matches(_ row: ConversationListRow, filter: LibraryFilter, tagName: String?)
        -> Bool
    {
        // Case-insensitively: the selected name can arrive from a deep link
        // (`companion://library?tag=travel`) typed by hand, and a chip that filters to nothing
        // because the tag is stored as "Travel" is indistinguishable from an empty library.
        if let tagName,
            !row.tags.contains(where: { $0.caseInsensitiveCompare(tagName) == .orderedSame })
        {
            return false
        }
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

    /// One conversation's row and members. Builds only that conversation's row — it used to build
    /// the row of every conversation in the library and pick one, on every open of a
    /// conversation and on every database change while one was on screen.
    static func buildDetail(_ db: Database, id: String) throws -> ConversationDetail? {
        guard let row = try buildRows(db, scope: .ids([id])).first else { return nil }
        let members = try Row.fetchAll(
            db,
            sql: """
                SELECT cs.segmentId AS segmentId, cs.ordinal AS ordinal, tt.state AS state,
                    cs.transcriptionState AS segmentState,
                    tt.providerId AS providerId, tt.modelUsed AS modelUsed,
                    tt.modeUsed AS modeUsed, tt.attempts AS attempts, tt.lastError AS lastError,
                    cs.startMediaMs AS startMediaMs, cs.endMediaMs AS endMediaMs
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
                segmentState: (member["segmentState"] as String?)
                    .flatMap(TranscriptionState.init(rawValue:)),
                providerId: member["providerId"],
                modelUsed: member["modelUsed"],
                modeUsed: member["modeUsed"],
                attempts: member["attempts"] ?? 0,
                lastError: member["lastError"],
                startMediaMs: member["startMediaMs"],
                endMediaMs: member["endMediaMs"]
            )
        }
        return ConversationDetail(row: row, members: members)
    }

    /// The conversations whose `[startMs, endMs)` overlaps `window` (epoch ms), newest first — a
    /// History day's, week's or month's conversations without building the whole library.
    ///
    /// Edges: touching is not overlapping (a conversation ending exactly at the window's start,
    /// or starting exactly at its end, is out); a conversation spanning the whole window is in;
    /// a conversation with no length (opened, no audio ever arrived) is in when its start is
    /// inside the window; an empty window has nothing in it. A live conversation is read at its
    /// extent so far — the grouper writes every conversation's end, a live one's included, and
    /// keeps it current each pass — and a row with no end at all (the column is nullable) is
    /// treated as running on from its start.
    public func rows(overlappingMs window: Range<Int64>) async throws -> [ConversationListRow] {
        try await db.reader.read { db in try Self.buildRows(db, scope: .overlapping(window)) }
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

    /// The conversation that owns a moment of a segment. AI citations, follow-up sources and
    /// loss notices name a SEGMENT and a time inside it, while every screen navigates by
    /// CONVERSATION, so this is the hop between them — without it a citation tap opens
    /// "conversation not found".
    ///
    /// `mediaMs` is an offset into the segment's stored audio. A segment can hold the end of
    /// one conversation and the start of the next, so "the conversation of a segment" is only
    /// a well-formed question at a moment; with no moment given, this answers for the
    /// segment's first instant.
    public func conversationId(
        ofSegment segmentId: String, atMediaMs mediaMs: Int64 = 0
    ) async throws -> String? {
        try await db.reader.read { db in
            try Self.conversationId(db, ofSegment: segmentId, atMediaMs: mediaMs)
        }
    }

    static func conversationId(
        _ db: Database, ofSegment segmentId: String, atMediaMs mediaMs: Int64
    ) throws -> String? {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT conversationId, startMediaMs, endMediaMs FROM conversation_segments
                WHERE segmentId = ? ORDER BY COALESCE(startMediaMs, 0)
                """,
            arguments: [segmentId])
        let owner = rows.first { row in
            ConversationMember(
                segmentId: segmentId, startMediaMs: row["startMediaMs"],
                endMediaMs: row["endMediaMs"]
            ).contains(mediaMs: max(mediaMs, 0))
        }
        // A moment past every piece (a stale offset) still belongs somewhere: the last piece.
        return (owner ?? rows.last)?["conversationId"]
    }

    /// Every piece of every segment: which conversations own which part of it, in media order.
    public func membersBySegment() async throws -> [String: [(conversationId: String, member: ConversationMember)]] {
        try await db.reader.read { db in
            var out: [String: [(conversationId: String, member: ConversationMember)]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT segmentId, conversationId, startMediaMs, endMediaMs
                    FROM conversation_segments ORDER BY segmentId, COALESCE(startMediaMs, 0)
                    """)
            {
                let segmentId: String = row["segmentId"]
                out[segmentId, default: []].append(
                    (
                        row["conversationId"],
                        ConversationMember(
                            segmentId: segmentId, startMediaMs: row["startMediaMs"],
                            endMediaMs: row["endMediaMs"])
                    ))
            }
            return out
        }
    }

    /// Every segment's conversation, in one read. Ask counts its coverage in conversations,
    /// and one query per recording in an "Everything" scope would be hundreds of them.
    public func conversationIdsBySegment() async throws -> [String: String] {
        try await db.reader.read { db in
            var out: [String: String] = [:]
            // A segment shared by two conversations is filed, for this coarse per-segment
            // view, under the one that owns its start — the rows arrive latest piece first so
            // the last write is the earliest piece.
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT segmentId, conversationId FROM conversation_segments
                    ORDER BY segmentId, COALESCE(startMediaMs, 0) DESC
                    """)
            {
                out[row["segmentId"]] = row["conversationId"]
            }
            return out
        }
    }
}
