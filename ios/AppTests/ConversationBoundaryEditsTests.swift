import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

// The person's own boundary decisions: which places the "Split or join" sheet offers, what each
// tap writes, and what the grouper then does with it. Same small library as
// `ConversationPiecesTests` (`PieceLibrary`): two one-minute segments handed straight over, with
// 26 s of nothing before "So about the holiday plans." in the first and 25 s before "Right, the
// budget review." in the second.

@Suite("conversation split and join") @MainActor
struct ConversationBoundaryEditsTests {
    typealias Library = PieceLibrary

    static let holiday = ConversationCut(segmentId: "seg-a", mediaMs: Library.cutA)
    static let budget = ConversationCut(segmentId: "seg-b", mediaMs: Library.cutB)

    /// The whole library as ONE conversation's pieces.
    static let whole = [
        ConversationMember(segmentId: "seg-a"), ConversationMember(segmentId: "seg-b"),
    ]

    static func points(_ pieces: [ConversationMember]) -> [ConversationBoundaryPoint] {
        ConversationSplitPoints.points(
            pieces: pieces, metas: Library.metas, turns: Library.turns,
            conversationStartMs: Int64(Library.t0) + 2_000)
    }

    // MARK: - Where a split is offered

    /// The places offered are where talk resumed after a break of twenty seconds or more —
    /// not the join between the two recordings, which is where a split used to be offered
    /// and where nobody paused at all.
    @Test func splitPointsAreWhereTalkResumedAfterABreak() {
        let points = Self.points(Self.whole)

        #expect(points.map(\.cut) == [Self.holiday, Self.budget])
        #expect(points.map(\.pauseMs) == [26_000, 25_000])
        #expect(points.map(\.opening) == ["So about the holiday plans.", "Right, the budget review."])
        // How far into the conversation (which starts at its first word, 2 s in).
        #expect(points.map(\.offsetMs) == [38_000, 88_000])
        #expect(
            points.map { Int64(($0.startedAt.timeIntervalSince1970 * 1000).rounded()) }
                == [Int64(Library.t0) + 40_000, Int64(Library.t0) + 90_000])
    }

    /// A conversation is offered only the breaks inside its own pieces, and never its own
    /// first turn — it already starts there.
    @Test func aConversationIsOfferedOnlyItsOwnBreaks() {
        let second = [
            ConversationMember(segmentId: "seg-a", startMediaMs: Library.cutA),
            ConversationMember(segmentId: "seg-b"),
        ]
        #expect(Self.points(second).map(\.cut) == [Self.budget])

        let first = [ConversationMember(segmentId: "seg-a", endMediaMs: Library.cutA)]
        #expect(Self.points(first).isEmpty)
    }

    /// A split lands a little ahead of the turn's first word, never before the turn before it
    /// has ended, and never after the turn itself. At a segment's very first words it is the
    /// segment's own start.
    @Test func aSplitIsPlacedJustAheadOfTheTurn() {
        func cut(_ startMs: Int64, after previousEndMs: Int64) -> Int64 {
            ConversationSplitPoints.cut(
                segmentId: "seg-a", turnStartMs: startMs, previousTurnEndMs: previousEndMs
            ).mediaMs
        }
        #expect(cut(40_000, after: 14_000) == 38_500)
        #expect(cut(40_000, after: 39_200) == 39_200)
        // Two people talking at once: the turn before is still going.
        #expect(cut(40_000, after: 41_000) == 40_000)
        #expect(cut(800, after: 0) == 0)
    }

    /// Only the longest dozen are offered, in the order they happened.
    @Test func onlyTheLongestDozenAreOfferedInTimeOrder() {
        // Twenty turns, each after a longer break than the one before: 20 s, 21 s, … 39 s.
        var turns: [Transcription.TranscriptSegment] = [Library.turn("Start.", 0, 1_000, "1")]
        var cursor: Int64 = 1_000
        for index in 0..<20 {
            cursor += Int64(20 + index) * 1_000
            turns.append(Library.turn("Turn \(index).", cursor, cursor + 1_000, "1"))
            cursor += 1_000
        }
        let meta = Library.meta(
            "seg-long", index: 0, wallMs: cursor + 1_000, storedMs: cursor + 1_000)
        let points = ConversationSplitPoints.points(
            pieces: [ConversationMember(segmentId: "seg-long")], metas: ["seg-long": meta],
            turns: ["seg-long": turns], conversationStartMs: Int64(Library.t0))

        #expect(points.count == ConversationSplitPoints.limit)
        #expect(points.map(\.opening) == (8..<20).map { "Turn \($0)." })
        #expect(points.map(\.pauseMs) == (8..<20).map { Int64(20 + $0) * 1_000 })
    }

    @Test func theOpeningIsAFewWords() {
        #expect(ConversationSplitPoints.opening(of: "Right, the budget review.") == "Right, the budget review.")
        #expect(
            ConversationSplitPoints.opening(
                of: "one two three four five six seven eight nine ten")
                == "one two three four five six seven eight…")
    }

    // MARK: - What a tap writes

    /// A split inside a segment is a cut override; a split at a segment's own start is a row
    /// in `boundary_overrides`, where a decision about that join has always lived. Never both.
    @Test func aSplitIsWrittenToTheTableThatOwnsThatKindOfPosition() async throws {
        let db = try AppDatabase.inMemory()
        let edits = ConversationBoundaryEdits(database: db)
        let segmentStart = ConversationCut(segmentId: "seg-b", mediaMs: 0)

        try await edits.split(at: Self.holiday)
        try await edits.split(at: segmentStart)

        let inside = try await ConversationCutStore(db: db).overrides()
        let atStarts = try await BoundaryOverrideStore(db: db).all()
        #expect(inside == [Self.holiday: .split])
        #expect(atStarts == ["seg-b": .split])
        let decisions = try await edits.decisions()
        #expect(decisions == [Self.holiday: .split, segmentStart: .split])
    }

    /// A join is the kit's to write, from the grouping as stored: it lands where the
    /// conversation starts, and replaces a split the person made there — which is how a split
    /// is undone.
    @Test func joiningWritesTheJoinWhereTheConversationStarts() async throws {
        let db = try await Library.sharedLibrary()
        let edits = ConversationBoundaryEdits(database: db)

        let at = try await edits.joinWithPrevious(conversationId: Library.second)
        #expect(at == Self.holiday)
        var decisions = try await edits.decisions()
        #expect(decisions == [Self.holiday: .join, Self.budget: .split])

        // Nothing comes before the first conversation: nothing is written.
        let none = try await edits.joinWithPrevious(conversationId: Library.first)
        #expect(none == nil)
        decisions = try await edits.decisions()
        #expect(decisions == [Self.holiday: .join, Self.budget: .split])
    }

    /// At a segment's own start the person's split lives in the older table. Joining there
    /// clears it, so one decision stands at the place — and splitting there again clears the
    /// join, which would otherwise outrank the split and silently overrule it.
    @Test func atASegmentsStartTheNewerDecisionReplacesTheOlder() async throws {
        let db = try AppDatabase.inMemory()
        let edits = ConversationBoundaryEdits(database: db)
        let segmentStart = ConversationCut(segmentId: "seg-b", mediaMs: 0)
        try await edits.split(at: segmentStart)
        let grouped = try await Library.regroup(db)
        #expect(grouped.map(\.id) == ["conv-seg-a", "conv-seg-b"])

        let at = try await edits.joinWithPrevious(conversationId: "conv-seg-b")
        #expect(at == segmentStart)
        var atStarts = try await BoundaryOverrideStore(db: db).all()
        var inside = try await ConversationCutStore(db: db).overrides()
        #expect(atStarts.isEmpty)
        #expect(inside == [segmentStart: .join])
        let joined = try await Library.regroup(db)
        #expect(joined.map(\.members) == [Self.whole])

        try await edits.split(at: segmentStart)
        atStarts = try await BoundaryOverrideStore(db: db).all()
        inside = try await ConversationCutStore(db: db).overrides()
        #expect(atStarts == ["seg-b": .split])
        #expect(inside.isEmpty)
        let split = try await Library.regroup(db)
        #expect(split.map(\.id) == ["conv-seg-a", "conv-seg-b"])
    }

    /// "Separate them again" takes back a JOIN — from either table. A split stored at the
    /// same kind of place is left alone: clearing it from here would join two conversations
    /// under a button that says it separates them.
    @Test func separatingClearsAJoinAndNothingElse() async throws {
        let db = try await Library.sharedLibrary()
        let edits = ConversationBoundaryEdits(database: db)
        try await edits.joinWithPrevious(conversationId: Library.second)
        // A join from before joins carried a span: a row in the older table.
        try await BoundaryOverrideStore(db: db).set(segmentId: "seg-b", decision: .join)
        let legacy = ConversationCut(segmentId: "seg-b", mediaMs: 0)

        try await edits.clearJoin(at: Self.holiday)
        try await edits.clearJoin(at: Self.budget)
        try await edits.clearJoin(at: legacy)

        let decisions = try await edits.decisions()
        #expect(decisions == [Self.budget: .split])
    }

    // MARK: - What the grouper does with it

    /// The whole loop with the real grouper: one conversation, split at a place the sheet
    /// offers, is two — the second starting exactly there, "split by you" — and joining the
    /// second to the first makes it one again.
    @Test func aSplitStartsAConversationThereAndJoiningUndoesIt() async throws {
        let db = try AppDatabase.inMemory()
        let edits = ConversationBoundaryEdits(database: db)
        let queries = ConversationQueries(db: db)

        var grouped = try await Library.regroup(db)
        #expect(grouped.map(\.members) == [Self.whole])

        let offered = try #require(Self.points(grouped[0].members).first)
        try await edits.split(at: offered.cut)
        grouped = try await Library.regroup(db)

        #expect(
            grouped.map(\.members) == [
                [ConversationMember(segmentId: "seg-a", endMediaMs: Library.cutA)],
                [
                    ConversationMember(segmentId: "seg-a", startMediaMs: Library.cutA),
                    ConversationMember(segmentId: "seg-b"),
                ],
            ])
        #expect(grouped.map(\.id) == [Library.first, Library.second])
        let reason = try await queries.startReason(ofConversation: Library.second)
        #expect(reason == .manual)
        // The place is no longer offered in the first half: it is the start of the second.
        #expect(Self.points(grouped[0].members).isEmpty)

        let at = try await edits.joinWithPrevious(conversationId: Library.second)
        #expect(at == offered.cut)
        grouped = try await Library.regroup(db)
        #expect(grouped.map(\.members) == [Self.whole])
    }

    /// Where the RULES start a conversation, the join overrules them — and is then listed
    /// inside the conversation it made, so it can be taken back from there. (Once two
    /// conversations are joined the later one no longer exists to be opened.)
    @Test func aJoinOverrulesTheRulesAndCanBeTakenBack() async throws {
        let db = try AppDatabase.inMemory()
        let edits = ConversationBoundaryEdits(database: db)
        // Twenty seconds of nothing ends a conversation, for this test: the rules now cut
        // before "So about the holiday plans." and "Right, the budget review." by themselves.
        let eager = BoundaryPolicy(
            quietSplitMs: 20_000, quietCandidateMs: 10_000, segmenter: nil)

        var grouped = try await Library.regroup(db, policy: eager)
        #expect(grouped.map(\.id) == [Library.first, Library.second, Library.third])

        let at = try await edits.joinWithPrevious(conversationId: Library.second)
        #expect(at == Self.holiday)
        grouped = try await Library.regroup(db, policy: eager)
        // No conversation starts at the join any more: the moment is inside the one before.
        // (How far either side of it the rules are also held off is the planner's business —
        // two minutes, which in a two-minute library is everything.)
        #expect(!grouped.contains { $0.members.first?.startMediaMs == Library.cutA })
        let merged = try #require(grouped.first)
        #expect(merged.id == Library.first)
        #expect(merged.contains(segmentId: "seg-a", mediaMs: Library.cutA))

        let decisions = try await edits.decisions()
        let listed = ConversationSplitPoints.joins(
            pieces: merged.members, metas: Library.metas, turns: Library.turns,
            decisions: decisions, conversationStartMs: Int64(Library.t0) + 2_000)
        #expect(listed.map(\.cut) == [Self.holiday])
        #expect(listed.map(\.opening) == ["So about the holiday plans."])
        #expect(listed.map(\.offsetMs) == [36_500])

        try await edits.clearJoin(at: Self.holiday)
        grouped = try await Library.regroup(db, policy: eager)
        #expect(grouped.map(\.id) == [Library.first, Library.second, Library.third])
    }

    /// A join at a conversation's OWN start is "joined with the previous conversation" — it
    /// has its own row in the sheet and is not listed among the joins inside.
    @Test func aJoinAtTheConversationsOwnStartIsNotAnInteriorJoin() {
        let second = [
            ConversationMember(segmentId: "seg-a", startMediaMs: Library.cutA),
            ConversationMember(segmentId: "seg-b"),
        ]
        let betweenRecordings = ConversationCut(segmentId: "seg-b", mediaMs: 0)
        let listed = ConversationSplitPoints.joins(
            pieces: second, metas: Library.metas, turns: Library.turns,
            decisions: [Self.holiday: .join, betweenRecordings: .join, Self.budget: .split],
            conversationStartMs: Int64(Library.t0) + 40_000)
        // The join between the two recordings is inside it; the one at its start is not.
        // Nor is a split, which is not a join at all.
        #expect(listed.map(\.cut) == [betweenRecordings])
    }
}
