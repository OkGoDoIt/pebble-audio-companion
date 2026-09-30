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

    /// A split inside a segment is a row in the cut overrides; a split at a segment's own
    /// start is a row in `boundary_overrides`, where decisions about that join have always
    /// lived. Never both.
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
        let holiday = try await edits.decision(at: Self.holiday)
        let start = try await edits.decision(at: segmentStart)
        #expect(holiday == .split)
        #expect(start == .split)
    }

    /// Joining a conversation that starts where the person split takes the split away, and
    /// leaves nothing standing in its place. Joining one the RULES started writes the join.
    @Test func joiningClearsThePersonsSplitOrWritesAJoin() async throws {
        let db = try AppDatabase.inMemory()
        let edits = ConversationBoundaryEdits(database: db)
        try await edits.split(at: Self.holiday)

        let undone = try await edits.joinWithPrevious(conversationStartingAt: Self.holiday)
        #expect(undone == .clearedSplit)
        var stored = try await ConversationCutStore(db: db).overrides()
        #expect(stored.isEmpty)

        let joined = try await edits.joinWithPrevious(conversationStartingAt: Self.holiday)
        #expect(joined == .joined)
        stored = try await ConversationCutStore(db: db).overrides()
        #expect(stored == [Self.holiday: .join])

        // The same two steps at a segment's own start, in the other table.
        let segmentStart = ConversationCut(segmentId: "seg-b", mediaMs: 0)
        try await edits.split(at: segmentStart)
        let undoneAtStart = try await edits.joinWithPrevious(conversationStartingAt: segmentStart)
        let joinedAtStart = try await edits.joinWithPrevious(conversationStartingAt: segmentStart)
        #expect(undoneAtStart == .clearedSplit)
        #expect(joinedAtStart == .joined)
        let atStarts = try await BoundaryOverrideStore(db: db).all()
        #expect(atStarts == ["seg-b": .join])
    }

    /// "Separate them again" takes back a JOIN. A split stored at the same kind of place is
    /// left alone: clearing it from here would join two conversations under a button that
    /// says it separates them.
    @Test func separatingClearsAJoinAndNothingElse() async throws {
        let db = try AppDatabase.inMemory()
        let edits = ConversationBoundaryEdits(database: db)
        try await edits.joinWithPrevious(conversationStartingAt: Self.holiday)
        try await edits.split(at: Self.budget)

        try await edits.clearJoin(at: Self.holiday)
        try await edits.clearJoin(at: Self.budget)

        let stored = try await ConversationCutStore(db: db).overrides()
        #expect(stored == [Self.budget: .split])
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

        let start = try #require(grouped[1].members.first)
        let wrote = try await edits.joinWithPrevious(
            conversationStartingAt: ConversationCut(
                segmentId: start.segmentId, mediaMs: start.startMediaMs ?? 0))
        #expect(wrote == .clearedSplit)
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

        let wrote = try await edits.joinWithPrevious(conversationStartingAt: Self.holiday)
        #expect(wrote == .joined)
        grouped = try await Library.regroup(db, policy: eager)
        #expect(
            grouped.map(\.members) == [
                [
                    ConversationMember(segmentId: "seg-a"),
                    ConversationMember(segmentId: "seg-b", endMediaMs: Library.cutB),
                ],
                [ConversationMember(segmentId: "seg-b", startMediaMs: Library.cutB)],
            ])

        let inside = try await ConversationCutStore(db: db).overrides()
        let atStarts = try await BoundaryOverrideStore(db: db).all()
        func joins(_ pieces: [ConversationMember]) -> [ConversationBoundaryPoint] {
            ConversationSplitPoints.joins(
                pieces: pieces, metas: Library.metas, turns: Library.turns,
                insideSegments: inside, atSegmentStarts: atStarts,
                conversationStartMs: Int64(Library.t0) + 2_000)
        }
        let listed = joins(grouped[0].members)
        #expect(listed.map(\.cut) == [Self.holiday])
        #expect(listed.map(\.opening) == ["So about the holiday plans."])
        #expect(listed.map(\.offsetMs) == [36_500])
        // Not in the conversation after it, which the join has nothing to do with.
        #expect(joins(grouped[1].members).isEmpty)

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
        let listed = ConversationSplitPoints.joins(
            pieces: second, metas: Library.metas, turns: Library.turns,
            insideSegments: [Self.holiday: .join], atSegmentStarts: ["seg-b": .join],
            conversationStartMs: Int64(Library.t0) + 40_000)
        // The join between the two recordings is inside it; the one at its start is not.
        #expect(listed.map(\.cut) == [ConversationCut(segmentId: "seg-b", mediaMs: 0)])
    }
}
