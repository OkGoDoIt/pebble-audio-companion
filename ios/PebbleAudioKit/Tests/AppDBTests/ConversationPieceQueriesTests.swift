import Foundation
import GRDB
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// `ConversationQueries` over pieces. A citation, a follow-up source and a loss notice all name a
// SEGMENT and a time inside it, while every screen navigates by CONVERSATION — and a segment can
// now hold the end of one conversation and the start of the next, so "the conversation of a
// segment" is only a well-formed question at a moment.

private typealias Member = ConversationMember

@Suite struct ConversationPieceQueriesTests {
    let t0 = testEpochMs

    /// Three conversations over three segments; `s1` is shared by all three.
    private var shared: [GroupedConversation] {
        [
            GroupedConversation(
                id: "A", startMs: t0, endMs: t0 + 1_000, timeZoneID: "UTC", isLive: false,
                members: [Member(segmentId: "s0"), Member(segmentId: "s1", endMediaMs: 100_000)]),
            GroupedConversation(
                id: "B", startMs: t0 + 2_000, endMs: t0 + 3_000, timeZoneID: "UTC", isLive: false,
                members: [Member(segmentId: "s1", startMediaMs: 100_000, endMediaMs: 500_000)],
                startReason: .lull),
            GroupedConversation(
                id: "C", startMs: t0 + 4_000, endMs: t0 + 5_000, timeZoneID: "UTC", isLive: false,
                members: [Member(segmentId: "s1", startMediaMs: 500_000), Member(segmentId: "s2")],
                startReason: .manual),
        ]
    }

    private func library(
        _ conversations: [GroupedConversation], states: [String: TranscriptionState] = [:],
        silent: Set<ConversationMember> = []
    ) async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try await db.writer.write {
            _ = try ConversationGrouper.apply(
                conversations, segmentStates: states, silentPieces: silent, in: $0)
        }
        return db
    }

    // MARK: - the conversation that owns a moment

    @Test func theOwnerOfAMomentInASegmentSharedByThreeConversations() async throws {
        let queries = ConversationQueries(db: try await library(shared))
        // Before the first cut, inside the middle piece, after the second cut.
        #expect(try await queries.conversationId(ofSegment: "s1", atMediaMs: 0) == "A")
        #expect(try await queries.conversationId(ofSegment: "s1", atMediaMs: 99_999) == "A")
        #expect(try await queries.conversationId(ofSegment: "s1", atMediaMs: 100_000) == "B")
        #expect(try await queries.conversationId(ofSegment: "s1", atMediaMs: 300_000) == "B")
        #expect(try await queries.conversationId(ofSegment: "s1", atMediaMs: 499_999) == "B")
        #expect(try await queries.conversationId(ofSegment: "s1", atMediaMs: 500_000) == "C")
        // Past the end of the segment's audio: the piece that runs to its end.
        #expect(try await queries.conversationId(ofSegment: "s1", atMediaMs: 86_400_000) == "C")
        #expect(try await queries.conversationId(ofSegment: "s1", atMediaMs: .max) == "C")
        // With no moment given — and for one before the segment's start — its first instant.
        #expect(try await queries.conversationId(ofSegment: "s1") == "A")
        #expect(try await queries.conversationId(ofSegment: "s1", atMediaMs: -400) == "A")

        // Whole segments belong to one conversation at every moment.
        for offset: Int64 in [0, 250_000, 900_000] {
            #expect(try await queries.conversationId(ofSegment: "s0", atMediaMs: offset) == "A")
            #expect(try await queries.conversationId(ofSegment: "s2", atMediaMs: offset) == "C")
        }
        #expect(try await queries.conversationId(ofSegment: "nope", atMediaMs: 0) == nil)
        #expect(try await queries.conversationId(ofSegment: "nope") == nil)
    }

    @Test func aMomentPastEveryStoredPieceStillBelongsToTheLastOne() async throws {
        // A stale offset into a segment whose stored pieces stop short (a row not yet rewritten
        // by the regroup): it still opens a conversation rather than "not found".
        let stale = [
            GroupedConversation(
                id: "A", startMs: t0, endMs: t0 + 1, timeZoneID: "UTC", isLive: false,
                members: [Member(segmentId: "s9", endMediaMs: 100_000)]),
            GroupedConversation(
                id: "B", startMs: t0 + 2, endMs: t0 + 3, timeZoneID: "UTC", isLive: false,
                members: [Member(segmentId: "s9", startMediaMs: 100_000, endMediaMs: 500_000)]),
        ]
        let queries = ConversationQueries(db: try await library(stale))
        #expect(try await queries.conversationId(ofSegment: "s9", atMediaMs: 50_000) == "A")
        #expect(try await queries.conversationId(ofSegment: "s9", atMediaMs: 499_999) == "B")
        #expect(try await queries.conversationId(ofSegment: "s9", atMediaMs: 500_000) == "B")
        #expect(try await queries.conversationId(ofSegment: "s9", atMediaMs: 9_000_000) == "B")
    }

    @Test func theOwnerDoesNotDependOnTheOrderThePiecesWereStoredIn() async throws {
        // `apply` writes conversations in whatever order it is handed them.
        let queries = ConversationQueries(db: try await library(shared.reversed()))
        #expect(try await queries.conversationId(ofSegment: "s1", atMediaMs: 0) == "A")
        #expect(try await queries.conversationId(ofSegment: "s1", atMediaMs: 100_000) == "B")
        #expect(try await queries.conversationId(ofSegment: "s1", atMediaMs: 500_000) == "C")
        #expect(try await queries.conversationIdsBySegment() == ["s0": "A", "s1": "A", "s2": "C"])
        #expect(try await queries.membersBySegment()["s1"]?.map(\.conversationId) == ["A", "B", "C"])
    }

    // MARK: - every piece of every segment

    @Test func membersBySegmentListsEachSegmentsPiecesInMediaOrder() async throws {
        let queries = ConversationQueries(db: try await library(shared))
        let bySegment = try await queries.membersBySegment()
        #expect(Set(bySegment.keys) == ["s0", "s1", "s2"])
        #expect(bySegment["s0"]?.map(\.conversationId) == ["A"])
        #expect(bySegment["s0"]?.map(\.member) == [Member(segmentId: "s0")])
        #expect(bySegment["s1"]?.map(\.conversationId) == ["A", "B", "C"])
        #expect(
            bySegment["s1"]?.map(\.member) == [
                Member(segmentId: "s1", endMediaMs: 100_000),
                Member(segmentId: "s1", startMediaMs: 100_000, endMediaMs: 500_000),
                Member(segmentId: "s1", startMediaMs: 500_000),
            ])
        #expect(bySegment["s2"]?.map(\.conversationId) == ["C"])
        #expect(bySegment["s2"]?.first?.member.isWhole == true)

        // An empty library has no segments.
        let empty = ConversationQueries(db: try AppDatabase.inMemory())
        #expect(try await empty.membersBySegment().isEmpty)
        #expect(try await empty.conversationIdsBySegment().isEmpty)
    }

    @Test func conversationIdsBySegmentFilesASharedSegmentUnderTheOwnerOfItsStart() async throws {
        let queries = ConversationQueries(db: try await library(shared))
        #expect(try await queries.conversationIdsBySegment() == ["s0": "A", "s1": "A", "s2": "C"])
        // It agrees with the moment query at media 0, for every segment.
        for (segment, owner) in try await queries.conversationIdsBySegment() {
            #expect(try await queries.conversationId(ofSegment: segment, atMediaMs: 0) == owner)
        }
    }

    // MARK: - one conversation's pieces

    @Test func detailReturnsEachMembersRange() async throws {
        let db = try await library(
            shared, states: ["s0": .complete, "s1": .complete, "s2": .pending],
            silent: [Member(segmentId: "s1", startMediaMs: 100_000, endMediaMs: 500_000)])
        try await db.writer.write { d in
            try d.execute(
                sql: """
                    INSERT INTO transcription_tasks
                        (segmentId, state, attempts, retryable, createdAtMs, updatedAtMs, providerId)
                    VALUES ('s1', 'Complete', 2, 1, 0, 0, 'soniox')
                    """)
        }
        let queries = ConversationQueries(db: db)

        let a = try #require(try await queries.detail(id: "A"))
        #expect(a.members.map(\.segmentId) == ["s0", "s1"])
        #expect(a.members.map(\.ordinal) == [0, 1])
        #expect(a.members.map(\.member) == shared[0].members)
        #expect(a.members[1].startMediaMs == nil && a.members[1].endMediaMs == 100_000)

        let b = try #require(try await queries.detail(id: "B"))
        #expect(b.members.map(\.member) == shared[1].members)
        #expect(b.members[0].startMediaMs == 100_000 && b.members[0].endMediaMs == 500_000)
        // The piece's own state is what the conversation shows; the segment's queue row is
        // shared by every conversation that holds a piece of it.
        #expect(b.members[0].segmentState == .noSpeech)
        #expect(b.members[0].state == .complete)
        #expect(b.members[0].providerId == "soniox" && b.members[0].attempts == 2)

        let c = try #require(try await queries.detail(id: "C"))
        #expect(c.members.map(\.member) == shared[2].members)
        #expect(c.members.map(\.segmentState) == [.complete, .pending])
        #expect(c.members.map(\.state) == [.complete, nil])
        #expect(try await queries.detail(id: "nope") == nil)

        #expect(try await queries.startReason(ofConversation: "A") == nil)
        #expect(try await queries.startReason(ofConversation: "B") == .lull)
        #expect(try await queries.startReason(ofConversation: "C") == .manual)
        #expect(try await queries.startReason(ofConversation: "nope") == nil)
    }

    @Test func aConversationMadeOnlyOfSilentPiecesIsFinishedAndHasNothingToTitle() async throws {
        let db = try await library(
            shared, states: ["s0": .complete, "s1": .complete, "s2": .pending],
            silent: [Member(segmentId: "s1", startMediaMs: 100_000, endMediaMs: 500_000)])
        let rows = try await ConversationQueries(db: db).library().flatMap(\.rows)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        // `A`: both pieces transcribed, with words.
        #expect(byId["A"]?.lifecycle == .complete)
        #expect(byId["A"]?.hasSpeech == true)
        #expect(byId["A"]?.awaitingAnnotation == true)
        // `B`: a piece of a transcribed segment in which nobody spoke. It is not waiting for a
        // transcript, and it must not be counted as waiting for a title either.
        #expect(byId["B"]?.lifecycle == .complete)
        #expect(byId["B"]?.hasSpeech == false)
        #expect(byId["B"]?.awaitingAnnotation == false)
        // `C`: the tail of `s1` is transcribed, `s2` is not.
        #expect(byId["C"]?.lifecycle == .capturedWaiting)
    }

    // MARK: - end to end

    @Test func everyTurnOfARegroupedLibraryOpensTheConversationThatHoldsIt() async throws {
        // Two people talking, a pause, one voice dictating — then an hour of nothing, and more
        // talk. Cut by the segmenter once and by the long silence once; `s2` and `s9` are shared.
        let db = try AppDatabase.inMemory()
        let talk = day(
            minutes: 180,
            talk: [.dialogue(0, 30), .dictation(34, 80), .dialogue(140, 180, cookingWords)])
        let rebuilt = try await ConversationGrouper.rebuild(
            segments: talk.segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: talk.evidence, policy: frozenPolicy, db: db)
        #expect(rebuilt.map(\.startReason) == [nil, .lull, .quiet])
        expectPiecesTile(rebuilt, segments: talk.segments)

        let queries = ConversationQueries(db: db)
        let bySegment = try await queries.membersBySegment()
        #expect(bySegment["s2"]?.count == 2)
        #expect(bySegment["s9"]?.count == 2)
        var checked = 0
        for (segmentId, evidence) in talk.evidence {
            for turn in evidence.speech {
                let expected = rebuilt.first { $0.contains(segmentId: segmentId, mediaMs: turn.startMs) }
                let owner = try await queries.conversationId(ofSegment: segmentId, atMediaMs: turn.startMs)
                #expect(owner == expected?.id, "\(segmentId)@\(turn.startMs)")
                #expect(owner != nil)
                checked += 1
            }
        }
        #expect(checked > 300)
        // A shared segment's start belongs to the conversation that was already going.
        #expect(try await queries.conversationIdsBySegment()["s2"] == "conv-s0")
        #expect(try await queries.conversationIdsBySegment()["s9"] == rebuilt[1].id)
    }
}
