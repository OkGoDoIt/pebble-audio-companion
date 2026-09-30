import Foundation
import GRDB
import SegmentStore
import Testing
import WireProtocol

@testable import AppDB

// Pieces on disk: `ConversationGrouper.apply` / `rebuildDetailed` / `fetchAll` over the ranged
// `conversation_segments`, the settled cuts in `conversation_cuts`, the person's decisions in
// `conversation_cut_overrides`, and the rule that keeps a conversation's id still while all of
// that moves (`adoptStableIds`).

private typealias Member = ConversationMember

private func totalChanges(_ db: AppDatabase) async throws -> Int {
    try await db.writer.write { try Int.fetchOne($0, sql: "SELECT total_changes()") ?? -1 }
}

/// `(conversationId, segmentId, ordinal, state, start, end)` of every stored piece, in order.
private func storedPieces(_ db: AppDatabase) async throws -> [[String?]] {
    try await db.reader.read { d in
        let rows = try Row.fetchAll(
            d,
            sql: """
                SELECT conversationId, segmentId, ordinal, transcriptionState, startMediaMs, endMediaMs
                FROM conversation_segments ORDER BY conversationId, ordinal
                """)
        var out: [[String?]] = []
        for row in rows {
            let conversationId: String = row["conversationId"]
            let segmentId: String = row["segmentId"]
            let ordinal: Int = row["ordinal"]
            let state: String? = row["transcriptionState"]
            let start: Int64? = row["startMediaMs"]
            let end: Int64? = row["endMediaMs"]
            out.append([
                conversationId, segmentId, String(ordinal), state, start.map { String($0) },
                end.map { String($0) },
            ])
        }
        return out
    }
}

@Suite struct ConversationPiecePersistenceTests {
    let t0 = testEpochMs

    /// Three conversations over three segments, the middle segment shared by all of them.
    private var shared: [GroupedConversation] {
        [
            GroupedConversation(
                id: "conv-s0", startMs: t0, endMs: t0 + 1_000, timeZoneID: "UTC", isLive: false,
                members: [Member(segmentId: "s0"), Member(segmentId: "s1", endMediaMs: 100_000)]),
            GroupedConversation(
                id: "conv-s1-m100000", startMs: t0 + 2_000, endMs: t0 + 3_000,
                timeZoneID: "Asia/Tokyo", isLive: false,
                members: [Member(segmentId: "s1", startMediaMs: 100_000, endMediaMs: 500_000)],
                startReason: .lull),
            GroupedConversation(
                id: "conv-s1-m500000", startMs: t0 + 4_000, endMs: t0 + 5_000, timeZoneID: "UTC",
                isLive: true,
                members: [Member(segmentId: "s1", startMediaMs: 500_000), Member(segmentId: "s2")],
                startReason: .manual),
        ]
    }

    private func apply(
        _ conversations: [GroupedConversation], states: [String: TranscriptionState] = [:],
        silent: Set<ConversationMember> = [], in db: AppDatabase
    ) async throws -> ConversationGrouper.ApplyOutcome {
        try await db.writer.write {
            try ConversationGrouper.apply(
                conversations, segmentStates: states, silentPieces: silent, in: $0)
        }
    }

    // MARK: - apply

    @Test func applyWritesRangesAndReadsThemBack() async throws {
        let db = try AppDatabase.inMemory()
        let outcome = try await apply(shared, in: db)
        #expect(outcome == .init(wrote: true, structureChanged: true))
        #expect(try await db.reader.read { try ConversationGrouper.fetchAll($0) } == shared)

        // The columns themselves: NULL is "from the first frame" / "to the last".
        #expect(
            try await storedPieces(db) == [
                ["conv-s0", "s0", "0", nil, nil, nil],
                ["conv-s0", "s1", "1", nil, nil, "100000"],
                ["conv-s1-m100000", "s1", "0", nil, "100000", "500000"],
                ["conv-s1-m500000", "s1", "0", nil, "500000", nil],
                ["conv-s1-m500000", "s2", "1", nil, nil, nil],
            ])
    }

    @Test func applyWritesNothingWhenIdentical() async throws {
        let db = try AppDatabase.inMemory()
        _ = try await apply(shared, in: db)
        let before = try await totalChanges(db)

        #expect(try await apply(shared, in: db) == .init(wrote: false, structureChanged: false))
        // The order they are handed over in is not a difference …
        #expect(
            try await apply(shared.reversed(), in: db)
                == .init(wrote: false, structureChanged: false))
        // … and neither is `isProvisional`, which is not stored.
        var provisional = shared
        provisional[2].isProvisional = true
        #expect(
            try await apply(provisional, in: db) == .init(wrote: false, structureChanged: false))
        #expect(try await totalChanges(db) == before, "an identical apply must not touch a row")
        #expect(try await db.reader.read { try ConversationGrouper.fetchAll($0) } == shared)
    }

    @Test func aMovedRangeIsStructuralAndACreepingExtentIsNot() async throws {
        let db = try AppDatabase.inMemory()
        _ = try await apply(shared, in: db)

        // The live conversation's extent advances: written, but not news to the AI stages.
        var grown = shared
        grown[2].endMs += 30_000
        #expect(try await apply(grown, in: db) == .init(wrote: true, structureChanged: false))
        // Any extent moving on its own is the same — a transcript landing trims one.
        grown[0].startMs += 250
        grown[1].endMs -= 100
        #expect(try await apply(grown, in: db) == .init(wrote: true, structureChanged: false))

        // ONLY a range moves — same conversations, same ids, same segments, same extents — and
        // that is a change of structure: a minute of talk now belongs to a different one.
        var moved = grown
        moved[1].members = [Member(segmentId: "s1", startMediaMs: 100_000, endMediaMs: 440_000)]
        moved[2].members = [Member(segmentId: "s1", startMediaMs: 440_000), Member(segmentId: "s2")]
        #expect(try await apply(moved, in: db) == .init(wrote: true, structureChanged: true))
        #expect(try await db.reader.read { try ConversationGrouper.fetchAll($0) } == moved)
        #expect(try await apply(moved, in: db) == .init(wrote: false, structureChanged: false))

        // So is each of these, one at a time.
        var closed = moved
        closed[2].isLive = false
        #expect(try await apply(closed, in: db) == .init(wrote: true, structureChanged: true))
        var reason = closed
        reason[1].startReason = .topicChange
        #expect(try await apply(reason, in: db) == .init(wrote: true, structureChanged: true))
        var renamed = reason
        renamed[1].id = "conv-s1-m100001"
        #expect(try await apply(renamed, in: db) == .init(wrote: true, structureChanged: true))
        #expect(
            try await apply(renamed, states: ["s1": .complete], in: db)
                == .init(wrote: true, structureChanged: true))
        #expect(
            try await apply(
                renamed, states: ["s1": .complete], silent: [renamed[1].members[0]], in: db)
                == .init(wrote: true, structureChanged: true))
        #expect(
            try await apply(Array(renamed.dropLast()), states: ["s1": .complete],
                silent: [renamed[1].members[0]], in: db)
                == .init(wrote: true, structureChanged: true))
        // Emptying it is a write too, and then there is nothing to write.
        #expect(try await apply([], in: db) == .init(wrote: true, structureChanged: true))
        #expect(try await apply([], in: db) == .init(wrote: false, structureChanged: false))
    }

    @Test func aSilentPieceOfATranscribedSegmentIsStoredAsNoSpeech() async throws {
        let db = try AppDatabase.inMemory()
        let silent: Set<ConversationMember> = [
            Member(segmentId: "s1", startMediaMs: 100_000, endMediaMs: 500_000),
            // A piece of a segment that is NOT transcribed is not known to be silent.
            Member(segmentId: "s2"),
        ]
        _ = try await apply(
            shared, states: ["s0": .complete, "s1": .complete, "s2": .pending], silent: silent,
            in: db)
        #expect(
            try await storedPieces(db).map { [$0[0], $0[1], $0[3]] } == [
                ["conv-s0", "s0", "Complete"],
                ["conv-s0", "s1", "Complete"],
                ["conv-s1-m100000", "s1", "NoSpeech"],
                ["conv-s1-m500000", "s1", "Complete"],
                ["conv-s1-m500000", "s2", "Pending"],
            ])
    }

    // MARK: - rebuild

    @Test func rebuildStoresSilentPiecesAsNoSpeechAndLeavesWholeMembersAlone() async throws {
        // Talk, an hour of nothing, talk — every segment transcribed. The first conversation
        // ends with two whole silent segments and the silent head of `s3`.
        let db = try AppDatabase.inMemory()
        var segments = rotations(4)
        for index in segments.indices { segments[index].transcriptionState = .complete }
        let evidence = evidenceMap([
            settledEvidence("s0", minutes: [(0, 18)]), settledEvidence("s1", minutes: []),
            settledEvidence("s2", minutes: []), settledEvidence("s3", minutes: [(18, 20)]),
        ])
        let rebuilt = try await ConversationGrouper.rebuildDetailed(
            segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: evidence, policy: .quietOnly, db: db)
        let at = minutesMs(18) - ConversationRunPlanner.preRollMs
        #expect(rebuilt.conversations.map(\.id) == ["conv-s0", "conv-s3-m\(at)"])
        #expect(
            try await storedPieces(db) == [
                ["conv-s0", "s0", "0", "Complete", nil, nil],
                // Whole members keep their segment's own state, whatever was said in them.
                ["conv-s0", "s1", "1", "Complete", nil, nil],
                ["conv-s0", "s2", "2", "Complete", nil, nil],
                // The piece of `s3` before its first word holds none of its turns.
                ["conv-s0", "s3", "3", "NoSpeech", nil, String(at)],
                ["conv-s3-m\(at)", "s3", "0", "Complete", String(at), nil],
            ])

        // A piece of a segment still waiting for its transcript says only that.
        var waiting = segments
        waiting[3].transcriptionState = .pending
        var unsettled = evidence
        unsettled["s3"] = unsettledEvidence("s3")
        _ = try await ConversationGrouper.rebuildDetailed(
            segments: waiting, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: unsettled, policy: .quietOnly, db: db)
        try await ConversationCutStore(db: db).setOverride(
            at: ConversationCut(segmentId: "s3", mediaMs: 300_000), decision: .split)
        _ = try await ConversationGrouper.rebuildDetailed(
            segments: waiting, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: unsettled, policy: .quietOnly, db: db)
        #expect(
            try await storedPieces(db).filter { $0[1] == "s3" }.map { [$0[0], $0[3], $0[4], $0[5]] }
                == [
                    ["conv-s0", "Pending", nil, "300000"],
                    ["conv-s3-m300000", "Pending", "300000", nil],
                ])
    }

    @Test func rebuildCommitsSettledCutsAndASecondRebuildIsTheSameAndWritesNothing() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        // Two people talking, a pause, then 56 minutes of one voice dictating: one cut, four
        // minutes into `s2`, with enough settled talk after it to be written down.
        let talk = day(minutes: 90, talk: [.dialogue(0, 30), .dictation(34, 90)])
        let cut = ConversationCut(
            segmentId: "s2", mediaMs: minutesMs(4) - ConversationRunPlanner.preRollMs)
        func rebuild(_ day: Day = talk, nowMs: Int64) async throws -> ConversationGrouper.RebuiltGrouping {
            try await ConversationGrouper.rebuildDetailed(
                segments: day.segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
                evidence: day.evidence, policy: frozenPolicy, nowMs: nowMs, db: db)
        }
        func committedRows() async throws -> [[String]] {
            try await db.reader.read { d in
                try Row.fetchAll(d, sql: "SELECT * FROM conversation_cuts ORDER BY segmentId, mediaMs")
                    .map { row in
                        [
                            row["segmentId"] as String, String(row["mediaMs"] as Int64),
                            row["reason"] as String, String(row["algorithm"] as Int),
                            String(row["createdAtMs"] as Int64),
                        ]
                    }
            }
        }

        #expect(try await store.committed().isEmpty)
        let first = try await rebuild(nowMs: 1_111)
        #expect(first.conversations.map(\.id) == ["conv-s0", cut.conversationId])
        #expect(first.changed && first.structureChanged)
        #expect(first.candidates.isEmpty)
        #expect(try await store.committed() == [cut])
        #expect(
            try await committedRows()
                == [["s2", String(cut.mediaMs), "lull", String(ConversationCutStore.algorithm), "1111"]])

        // Again, later: the cut is now a held decision rather than a fresh one, and the answer
        // is the same conversation for conversation. Nothing is written — not a row of the
        // grouping, and not the cut, which is never re-dated.
        let before = try await totalChanges(db)
        let second = try await rebuild(nowMs: 9_999)
        #expect(second.conversations == first.conversations)
        #expect(!second.changed && !second.structureChanged)
        #expect(second.previous.isEmpty)
        #expect(try await totalChanges(db) == before, "an identical rebuild must not touch a row")
        #expect(
            try await committedRows()
                == [["s2", String(cut.mediaMs), "lull", String(ConversationCutStore.algorithm), "1111"]])

        // The day grows by a quarter of an hour of the same dictation. The held cut holds, the
        // ids do not move, and the caller is handed the grouping as it was.
        let grown = day(minutes: 105, talk: [.dialogue(0, 30), .dictation(34, 105)])
        let third = try await rebuild(grown, nowMs: 20_000)
        #expect(third.conversations.map(\.id) == ["conv-s0", cut.conversationId])
        #expect(third.structureChanged)
        #expect(third.previous == first.conversations.map(\.asStored))
        #expect(try await store.committed() == [cut])
    }

    @Test func rebuildReadsThePersonsDecisionsAboutPositionsInsideSegments() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        let talk = day(minutes: 45, talk: [.dialogue(0, 45)])
        func rebuild() async throws -> [GroupedConversation] {
            try await ConversationGrouper.rebuild(
                segments: talk.segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
                evidence: talk.evidence, policy: .quietOnly, db: db)
        }
        #expect(try await rebuild().map(\.id) == ["conv-s0"])

        // "Start a new conversation here."
        let here = ConversationCut(segmentId: "s1", mediaMs: 400_000)
        try await store.setOverride(at: here, decision: .split)
        let split = try await rebuild()
        #expect(split.map(\.brief) == [["s0", "s1[..400000)"], ["s1[400000..)", "s2"]])
        #expect(split[1].startReason == .manual)
        // The person's own split is theirs, not a settled segmenter decision.
        #expect(try await store.committed().isEmpty)

        // Undone: the place goes back to the rules.
        try await store.setOverride(at: here, decision: nil)
        #expect(try await rebuild().map(\.id) == ["conv-s0"])

        // A decision at a segment's very start is a decision about the segment's start.
        try await store.setOverride(at: ConversationCut(segmentId: "s2", mediaMs: 0), decision: .split)
        let atStart = try await rebuild()
        #expect(atStart.map(\.brief) == [["s0", "s1"], ["s2"]])
        #expect(atStart[1].startReason == .manual)
    }

    @Test func aJoinRemovesAHeldCutFromTheGroupingOnTheNextRebuild() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        let talk = day(minutes: 45, talk: [.dialogue(0, 45)])
        let cut = ConversationCut(segmentId: "s1", mediaMs: 400_000)
        try await db.writer.write {
            try ConversationCutStore.commit([cut: .topicChange], atMs: 5, in: $0)
        }
        func rebuild() async throws -> [GroupedConversation] {
            try await ConversationGrouper.rebuild(
                segments: talk.segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
                evidence: talk.evidence, policy: .quietOnly, db: db)
        }
        #expect(try await rebuild().map(\.id) == ["conv-s0", "conv-s1-m400000"])
        try await store.setOverride(at: cut, decision: .join)
        let joined = try await rebuild()
        #expect(joined.map(\.brief) == [["s0", "s1", "s2"]])
        // The settled row is left where it is (it is derived, and the join is what is
        // authoritative); clearing the join brings the cut back.
        #expect(try await store.committed() == [cut])
        try await store.setOverride(at: cut, decision: nil)
        #expect(try await rebuild().map(\.id) == ["conv-s0", "conv-s1-m400000"])
    }

    // MARK: - stable ids

    private func conversation(_ id: String, _ members: [ConversationMember], startMs: Int64 = 0)
        -> GroupedConversation
    {
        GroupedConversation(
            id: id, startMs: startMs, endMs: startMs + 1, timeZoneID: "UTC", isLive: false,
            members: members)
    }

    @Test func theFirstPartOfADividedConversationKeepsItsId() {
        // One conversation over two segments; a cut appears in the middle of `b`.
        let previous = [conversation("conv-a", [Member(segmentId: "a"), Member(segmentId: "b")])]
        let fresh = [
            conversation("conv-a", [Member(segmentId: "a"), Member(segmentId: "b", endMediaMs: 7_000)]),
            conversation("conv-b-m7000", [Member(segmentId: "b", startMediaMs: 7_000)], startMs: 5),
        ]
        #expect(
            ConversationGrouper.adoptStableIds(fresh, previous: previous).map(\.id)
                == ["conv-a", "conv-b-m7000"])

        // The same when the conversation had already adopted an older id: the first half keeps
        // it, the second half gets its own.
        let adopted = [conversation("conv-z", [Member(segmentId: "a"), Member(segmentId: "b")])]
        #expect(
            ConversationGrouper.adoptStableIds(fresh, previous: adopted).map(\.id)
                == ["conv-z", "conv-b-m7000"])
    }

    @Test func retentionRemovingTheFirstMemberKeepsTheId() {
        let previous = [
            conversation("conv-a", [Member(segmentId: "a"), Member(segmentId: "b", endMediaMs: 7_000)]),
            conversation(
                "conv-b-m7000", [Member(segmentId: "b", startMediaMs: 7_000), Member(segmentId: "c")],
                startMs: 5),
        ]
        // `a` is deleted. What is left of the first conversation is the head of `b`.
        let fresh = [
            conversation("conv-b", [Member(segmentId: "b", endMediaMs: 7_000)]),
            conversation(
                "conv-b-m7000", [Member(segmentId: "b", startMediaMs: 7_000), Member(segmentId: "c")],
                startMs: 5),
        ]
        #expect(
            ConversationGrouper.adoptStableIds(fresh, previous: previous).map(\.id)
                == ["conv-a", "conv-b-m7000"])

        // `b` goes too: the second conversation is now just `c`, and is still itself.
        let later = [conversation("conv-c", [Member(segmentId: "c")], startMs: 5)]
        #expect(
            ConversationGrouper.adoptStableIds(later, previous: previous).map(\.id)
                == ["conv-b-m7000"])
    }

    @Test func aCutThatMovesKeepsBothIds() {
        // The boundary between two conversations moves from 7 s to 9 s into `a` (a
        // re-transcription shifted the turn it sits in front of). Both are who they were.
        let previous = [
            conversation("conv-a", [Member(segmentId: "a", endMediaMs: 7_000)]),
            conversation("conv-a-m7000", [Member(segmentId: "a", startMediaMs: 7_000)], startMs: 5),
        ]
        let later = [
            conversation("conv-a", [Member(segmentId: "a", endMediaMs: 9_000)]),
            conversation("conv-a-m9000", [Member(segmentId: "a", startMediaMs: 9_000)], startMs: 5),
        ]
        #expect(
            ConversationGrouper.adoptStableIds(later, previous: previous).map(\.id)
                == ["conv-a", "conv-a-m7000"])
        // Moving earlier, the new start falls inside the FIRST conversation's old range — whose
        // id the first conversation still holds — so the second takes the id of its own start.
        let earlier = [
            conversation("conv-a", [Member(segmentId: "a", endMediaMs: 5_000)]),
            conversation("conv-a-m5000", [Member(segmentId: "a", startMediaMs: 5_000)], startMs: 5),
        ]
        #expect(
            ConversationGrouper.adoptStableIds(earlier, previous: previous).map(\.id)
                == ["conv-a", "conv-a-m5000"])
    }

    @Test func aMergedConversationKeepsTheIdOfItsStartAndNoIdIsEverHeldTwice() {
        let previous = [
            conversation("conv-a", [Member(segmentId: "a", endMediaMs: 7_000)]),
            conversation("conv-a-m7000", [Member(segmentId: "a", startMediaMs: 7_000)], startMs: 5),
        ]
        let merged = [conversation("conv-a", [Member(segmentId: "a")])]
        #expect(ConversationGrouper.adoptStableIds(merged, previous: previous).map(\.id) == ["conv-a"])

        // An id a fresh conversation holds by right — its own start — is never handed to a
        // different one, whatever the previous grouping called things.
        let odd = [conversation("conv-b", [Member(segmentId: "a"), Member(segmentId: "b")])]
        let fresh = [
            conversation("conv-a", [Member(segmentId: "a")]),
            conversation("conv-b", [Member(segmentId: "b")], startMs: 5),
        ]
        let adopted = ConversationGrouper.adoptStableIds(fresh, previous: odd)
        #expect(adopted.map(\.id) == ["conv-a", "conv-b"])
        #expect(Set(adopted.map(\.id)).count == adopted.count)

        // Nothing previous, or nothing in common: every conversation keeps its own id.
        #expect(ConversationGrouper.adoptStableIds(fresh, previous: []).map(\.id) == ["conv-a", "conv-b"])
        let unrelated = [conversation("conv-q", [Member(segmentId: "q")])]
        #expect(
            ConversationGrouper.adoptStableIds(fresh, previous: unrelated).map(\.id)
                == ["conv-a", "conv-b"])
    }

    @Test func idsStayStillThroughTheDatabaseWhenACutAppearsAndWhenRetentionTrims() async throws {
        let db = try AppDatabase.inMemory()
        let talk = day(minutes: 45, talk: [.dialogue(0, 45)])
        func rebuild(_ segments: [SegmentMeta]) async throws -> [GroupedConversation] {
            try await ConversationGrouper.rebuild(
                segments: segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
                evidence: talk.evidence, policy: .quietOnly, db: db)
        }
        #expect(try await rebuild(talk.segments).map(\.id) == ["conv-s0"])

        // A cut appears inside `s1`: the first part is still `conv-s0`.
        try await ConversationCutStore(db: db).setOverride(
            at: ConversationCut(segmentId: "s1", mediaMs: 400_000), decision: .split)
        #expect(try await rebuild(talk.segments).map(\.id) == ["conv-s0", "conv-s1-m400000"])

        // Retention deletes `s0`: what is left of the first conversation is the head of `s1`,
        // and it is still `conv-s0`; the second is untouched.
        let trimmed = Array(talk.segments.dropFirst())
        let after = try await rebuild(trimmed)
        #expect(after.map(\.id) == ["conv-s0", "conv-s1-m400000"])
        #expect(after.map(\.brief) == [["s1[..400000)"], ["s1[400000..)", "s2"]])
        // …and again on the next pass, reading its own previous grouping.
        #expect(try await rebuild(trimmed).map(\.id) == ["conv-s0", "conv-s1-m400000"])

        // Through `group(previous:)` directly, the same.
        let direct = ConversationGrouper.group(
            segments: trimmed, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            previous: [
                conversation("conv-s0", [Member(segmentId: "s0"), Member(segmentId: "s1", endMediaMs: 400_000)])
            ],
            evidence: talk.evidence, policy: .quietOnly,
            cutInputs: ConversationCutInputs(splits: ["s1": [400_000]]))
        #expect(direct.map(\.id) == ["conv-s0", "conv-s1-m400000"])
    }
}

// MARK: - "these two are one conversation", through the store

/// The app path for a join: `ConversationCutStore.joinWithPrevious` reads the stored grouping and
/// records the point between the two conversations AND the span they covered, and the next
/// `rebuildDetailed` reads it back.
@Suite struct ConversationJoinTests {
    let t0 = testEpochMs
    private let preRoll = ConversationRunPlanner.preRollMs

    private func rebuild(_ day: Day, in db: AppDatabase, policy: BoundaryPolicy = frozenPolicy)
        async throws -> ConversationGrouper.RebuiltGrouping
    {
        let rebuilt = try await ConversationGrouper.rebuildDetailed(
            segments: day.segments, pauses: [], openSegmentId: day.open, fallbackTimeZoneID: "UTC",
            evidence: day.evidence, policy: policy, db: db)
        expectPiecesTile(rebuilt.conversations, segments: day.segments)
        return rebuilt
    }

    /// Two people (0–30), dictation (34–90), two people about something else (94–150).
    private var threeConversations: Day {
        day(minutes: 150, talk: [.dialogue(0, 30), .dictation(34, 90), .dialogue(94, 150, cookingWords)])
    }
    private var second: ConversationCut {
        ConversationCut(segmentId: "s2", mediaMs: minutesMs(4) - preRoll)
    }
    private var third: ConversationCut {
        ConversationCut(segmentId: "s6", mediaMs: minutesMs(4) - preRoll)
    }

    private func spanRows(_ db: AppDatabase) async throws -> [[String?]] {
        try await db.reader.read { d in
            var out: [[String?]] = []
            for row in try Row.fetchAll(
                d, sql: "SELECT * FROM conversation_cut_overrides ORDER BY segmentId, mediaMs")
            {
                let segmentId: String = row["segmentId"]
                let mediaMs: Int64 = row["mediaMs"]
                let decision: String = row["decision"]
                let from: String? = row["spanFromSegmentId"]
                let fromMs: Int64? = row["spanFromMediaMs"]
                let to: String? = row["spanToSegmentId"]
                let toMs: Int64? = row["spanToMediaMs"]
                out.append([
                    segmentId, String(mediaMs), decision, from, fromMs.map { String($0) }, to,
                    toMs.map { String($0) },
                ])
            }
            return out
        }
    }

    @Test func joiningAConversationToTheOneBeforeItLeavesOneAndItStaysOne() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        let before = try await rebuild(threeConversations, in: db)
        #expect(
            before.conversations.map(\.id)
                == ["conv-s0", second.conversationId, third.conversationId])

        // "The second and the first are one conversation."
        let at = try await store.joinWithPrevious(conversationId: second.conversationId, atMs: 77)
        #expect(at == second)
        // What is written: the point between them, and the span they covered — from the start
        // of the first to the start of the third.
        #expect(
            try await spanRows(db) == [
                ["s2", String(second.mediaMs), "join", "s0", "0", "s6", String(third.mediaMs)]
            ])
        #expect(try await store.overrides() == [second: .join])

        let joined = try await rebuild(threeConversations, in: db)
        // One conversation where there were two, under the first one's id; the third is
        // untouched — the span does not block the cut exactly at its end.
        #expect(joined.conversations.map(\.id) == ["conv-s0", third.conversationId])
        #expect(
            joined.conversations.map(\.brief) == [
                ["s0", "s1", "s2", "s3", "s4", "s5", "s6[..\(third.mediaMs))"],
                ["s6[\(third.mediaMs)..)", "s7", "s8", "s9"],
            ])
        #expect(joined.structureChanged)
        #expect(joined.previous.map(\.id) == before.conversations.map(\.id))

        // And it stays one: the next rebuild changes nothing and writes nothing.
        let changesBefore = try await totalChanges(db)
        let again = try await rebuild(threeConversations, in: db)
        #expect(again.conversations == joined.conversations)
        #expect(!again.changed)
        #expect(try await totalChanges(db) == changesBefore)
    }

    @Test func undoingAJoinRestoresTheTwoWithTheIdsTheyHad() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        let before = try await rebuild(threeConversations, in: db)
        let at = try #require(
            try await store.joinWithPrevious(conversationId: second.conversationId))
        #expect(try await rebuild(threeConversations, in: db).conversations.count == 2)

        try await store.setOverride(at: at, decision: nil)
        #expect(try await store.overrides().isEmpty)
        #expect(try await spanRows(db).isEmpty)
        let restored = try await rebuild(threeConversations, in: db)
        #expect(restored.conversations.map(\.id) == before.conversations.map(\.id))
        #expect(restored.conversations.map(\.members) == before.conversations.map(\.members))
        #expect(
            restored.conversations.map(\.startReason) == before.conversations.map(\.startReason))
    }

    @Test func joinsChain() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        _ = try await rebuild(threeConversations, in: db)
        // The second into the first, regroup, then the third into what that made.
        try await store.joinWithPrevious(conversationId: second.conversationId, atMs: 1)
        #expect(
            try await rebuild(threeConversations, in: db).conversations.map(\.id)
                == ["conv-s0", third.conversationId])
        let at = try await store.joinWithPrevious(conversationId: third.conversationId, atMs: 2)
        #expect(at == third)
        // The second span runs from the start of the (already joined) first conversation to
        // the end of the run: nothing follows the third.
        #expect(
            try await spanRows(db) == [
                ["s2", String(second.mediaMs), "join", "s0", "0", "s6", String(third.mediaMs)],
                ["s6", String(third.mediaMs), "join", "s0", "0", nil, nil],
            ])
        let all = try await rebuild(threeConversations, in: db)
        #expect(all.conversations.map(\.id) == ["conv-s0"])
        #expect(all.conversations[0].members == (0..<10).map { ConversationMember(segmentId: "s\($0)") })

        // Undoing the later join gives back the third and keeps the first join.
        try await store.setOverride(at: third, decision: nil)
        #expect(
            try await rebuild(threeConversations, in: db).conversations.map(\.id)
                == ["conv-s0", third.conversationId])
    }

    @Test func thereIsNothingToJoinTheFirstConversationOrAnUnknownOneTo() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        #expect(try await store.joinWithPrevious(conversationId: "conv-s0") == nil)
        _ = try await rebuild(threeConversations, in: db)
        #expect(try await store.joinWithPrevious(conversationId: "conv-s0") == nil)
        #expect(try await store.joinWithPrevious(conversationId: "conv-nope") == nil)
        #expect(try await store.overrides().isEmpty)
    }

    @Test func aPlainDecisionAtTheSamePlaceReplacesTheJoinAndItsSpan() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        _ = try await rebuild(threeConversations, in: db)
        try await store.joinWithPrevious(conversationId: second.conversationId)
        func spans() async throws -> [ConversationCutInputs.JoinSpan] {
            try await db.reader.read { d in
                var overrides: [String: BoundaryDecision] = [:]
                return try ConversationCutStore.fetchInputs(d, into: &overrides).joinSpans
            }
        }
        #expect(
            try await spans()
                == [.init(from: ConversationCut(segmentId: "s0", mediaMs: 0), to: third)])

        // "Start a new conversation here" at the very place: the join and its span are gone.
        try await store.setOverride(at: second, decision: .split)
        #expect(try await spans().isEmpty)
        #expect(
            try await spanRows(db) == [["s2", String(second.mediaMs), "split", nil, nil, nil, nil]])
        let split = try await rebuild(threeConversations, in: db)
        #expect(
            split.conversations.map(\.id)
                == ["conv-s0", second.conversationId, third.conversationId])
        // (The reason it carries is the held cut's — `lull` — not `manual`: the settled cut at
        // the same position was read first. Reported as a small thing; not pinned.)

        // A join written without a span (a row from before spans existed) is a point join.
        try await store.joinWithPrevious(conversationId: second.conversationId)
        #expect(try await spans().count == 1)
        try await store.setOverride(at: second, decision: .join)
        #expect(try await spans().isEmpty)
        #expect(try await store.overrides() == [second: .join])
    }

    @Test func aJoinAtASegmentsOwnStartAlsoJoinsAcrossAStop() async throws {
        // A Stop ends a conversation; the person says the talk after it is the same one.
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        var stopped = day(minutes: 30, talk: [.dialogue(0, 30)])
        stopped.segments[1].closeReason = userStopClose
        let resumed = day(
            minutes: 30, prefix: "t", startTimeMs: t0 + minutesMs(33), stream: 9,
            talk: [.dictation(0, 30)])
        let library = stopped + resumed
        let before = try await rebuild(library, in: db)
        #expect(before.conversations.map(\.id) == ["conv-s0", "conv-t0"])
        #expect(before.conversations[1].startReason == .userStop)

        let at = try await store.joinWithPrevious(conversationId: "conv-t0")
        #expect(at == ConversationCut(segmentId: "t0", mediaMs: 0))
        for policy in [BoundaryPolicy.quietOnly, frozenPolicy] {
            let joined = try await rebuild(library, in: db, policy: policy)
            #expect(joined.conversations.map(\.brief) == [["s0", "s1", "t0", "t1"]], "\(policy.segmenter == nil)")
        }
        // Undone, the Stop splits again.
        try await store.setOverride(at: ConversationCut(segmentId: "t0", mediaMs: 0), decision: nil)
        #expect(try await rebuild(library, in: db).conversations.map(\.id) == ["conv-s0", "conv-t0"])
    }

    @Test func aJoinAcrossALongSilenceThroughTheStore() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        // Talk, three hours of nothing, talk, an hour of nothing, talk.
        let quiet = day(
            minutes: 360, talk: [.dialogue(0, 20), .dialogue(200, 240), .dialogue(300, 360)])
        let before = try await rebuild(quiet, in: db)
        #expect(before.conversations.map(\.startReason) == [nil, .quiet, .quiet])
        try await store.joinWithPrevious(conversationId: before.conversations[1].id)
        let joined = try await rebuild(quiet, in: db)
        #expect(joined.conversations.map(\.id) == ["conv-s0", before.conversations[2].id])
        #expect(joined.conversations.map(\.startReason) == [nil, .quiet])
    }

    /// Joining the LATEST conversation to the one before it — the join a person is most likely
    /// to make, on the conversation they have just had. Nothing follows it, so its span has no
    /// end. The two are one conversation; what is recorded AFTERWARDS is not part of what the
    /// person joined, and is divided like any other talk.
    ///
    /// REPORTED 2026-09-30 and FAILING: a span with no end is read as "to the end of the run",
    /// and the run is still growing. Every automatic cut — the long-quiet rule included — is
    /// blocked from the join to wherever the run ends, however much later that is: here an hour
    /// of silence and two more hours of different talk all land in the conversation that was
    /// joined, which is now four and three-quarter hours long.
    @Test func joiningTheLatestConversationDoesNotSwallowWhatIsRecordedAfterIt() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        let morning: [Stretch] = [.dialogue(0, 30), .dictation(34, 90)]
        let soFar = day(minutes: 90, talk: morning, recording: true)
        let modeChange = ConversationCut(segmentId: "s2", mediaMs: minutesMs(4) - preRoll)
        #expect(
            try await rebuild(soFar, in: db).conversations.map(\.id)
                == ["conv-s0", modeChange.conversationId])
        try await store.joinWithPrevious(conversationId: modeChange.conversationId)
        #expect(try await rebuild(soFar, in: db).conversations.map(\.id) == ["conv-s0"])

        // The day goes on in the same run: an hour of nothing, fifty minutes of two people on
        // another subject, then an hour of dictation.
        let later = day(
            minutes: 270,
            talk: morning + [.dialogue(150, 200, cookingWords), .dictation(204, 270, sailingWords)],
            recording: true)
        let unjoined = ConversationGrouper.group(
            segments: later.segments, pauses: [], openSegmentId: later.open,
            fallbackTimeZoneID: "UTC", evidence: later.evidence, policy: frozenPolicy)
        #expect(unjoined.map(\.startReason) == [nil, .lull, .quiet, .lull])

        let grown = try await rebuild(later, in: db)
        // The joined pair is still one conversation, and ends where it ended: the hour of
        // silence ends it, and the afternoon's two conversations are their own.
        #expect(
            grown.conversations.map(\.id) == ["conv-s0", unjoined[2].id, unjoined[3].id],
            "\(grown.conversations.map(\.id)) \(grown.conversations.map { ($0.endMs - $0.startMs) / 60_000 }) min")
        #expect(grown.conversations.map(\.startReason) == [nil, .quiet, .lull])
    }
}

// MARK: - the cut store

@Suite struct ConversationCutStoreTests {
    private func cut(_ segment: String, _ mediaMs: Int64) -> ConversationCut {
        ConversationCut(segmentId: segment, mediaMs: mediaMs)
    }

    private func inputs(_ db: AppDatabase) async throws
        -> (inputs: ConversationCutInputs, overrides: [String: BoundaryDecision])
    {
        try await db.reader.read { d in
            var overrides = try BoundaryOverrideStore.fetchAll(d)
            let inputs = try ConversationCutStore.fetchInputs(d, into: &overrides)
            return (inputs, overrides)
        }
    }

    @Test func aFreshDatabaseHoldsNoCutsAndNoDecisions() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        #expect(try await store.committed().isEmpty)
        #expect(try await store.overrides().isEmpty)
        let read = try await inputs(db)
        #expect(read.inputs == .none)
        #expect(read.overrides.isEmpty)
    }

    @Test func thePersonsDecisionsRoundTripAndAreUndoable() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        try await store.setOverride(at: cut("a", 400_000), decision: .split, atMs: 1)
        try await store.setOverride(at: cut("a", 800_000), decision: .join, atMs: 2)
        try await store.setOverride(at: cut("b", 5), decision: .split, atMs: 3)
        #expect(
            try await store.overrides() == [
                cut("a", 400_000): .split, cut("a", 800_000): .join, cut("b", 5): .split,
            ])
        let read = try await inputs(db)
        #expect(
            read.inputs
                == ConversationCutInputs(
                    splits: ["a": [400_000], "b": [5]], joins: ["a": [800_000]]))
        #expect(read.overrides.isEmpty)

        // Changing one's mind at the same place replaces the decision; it does not add a second.
        try await store.setOverride(at: cut("a", 400_000), decision: .join, atMs: 4)
        #expect(try await store.overrides()[cut("a", 400_000)] == .join)
        #expect(try await store.overrides().count == 3)
        #expect(try await inputs(db).inputs.joins == ["a": [400_000, 800_000]])
        #expect(try await inputs(db).inputs.splits == ["b": [5]])

        // `nil` clears it and hands the place back to the rules.
        try await store.setOverride(at: cut("a", 400_000), decision: nil)
        try await store.setOverride(at: cut("nowhere", 1), decision: nil)
        #expect(try await store.overrides() == [cut("a", 800_000): .join, cut("b", 5): .split])
    }

    @Test func aDecisionAtASegmentsOwnStartIsFoldedIntoTheSegmentStartDecisions() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        try await BoundaryOverrideStore(db: db).set(segmentId: "a", decision: .join, atMs: 1)
        try await BoundaryOverrideStore(db: db).set(segmentId: "c", decision: .split, atMs: 1)
        try await store.setOverride(at: cut("b", 0), decision: .split, atMs: 2)
        // The later, position-level decision about the same place wins.
        try await store.setOverride(at: cut("c", 0), decision: .join, atMs: 3)
        let read = try await inputs(db)
        #expect(read.overrides == ["a": .join, "b": .split, "c": .join])
        #expect(read.inputs == .none)
    }

    @Test func settledCutsRoundTripAndAreNeverRedatedOrReexplained() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        try await db.writer.write {
            try ConversationCutStore.commit(
                [
                    self.cut("b", 9): .lull, self.cut("a", 700): .topicChange,
                    self.cut("a", 30): .lull,
                    // A segment's own start is not a position inside it: never written.
                    self.cut("a", 0): .topicChange,
                ], atMs: 100, in: $0)
        }
        #expect(try await store.committed() == [cut("a", 30), cut("a", 700), cut("b", 9)])
        #expect(
            try await inputs(db).inputs
                == ConversationCutInputs(
                    committed: ["a": [30: .lull, 700: .topicChange], "b": [9: .lull]]))

        // Offered again with another reason at another time: the row is left exactly as it is.
        try await db.writer.write {
            try ConversationCutStore.commit([self.cut("a", 30): .topicChange], atMs: 999, in: $0)
        }
        let row = try await db.reader.read {
            try Row.fetchOne(
                $0, sql: "SELECT reason, createdAtMs FROM conversation_cuts WHERE segmentId = 'a' AND mediaMs = 30"
            ).map { [$0["reason"] as String, String($0["createdAtMs"] as Int64)] }
        }
        #expect(row == ["lull", "100"])
        // Committing nothing is nothing.
        try await db.writer.write { try ConversationCutStore.commit([:], atMs: 5, in: $0) }
        #expect(try await store.committed().count == 3)
    }

    @Test func cutsWrittenByAnotherVersionOfTheSegmenterAreIgnoredAndReplaced() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        let other = ConversationCutStore.algorithm + 1
        try await db.writer.write { d in
            try d.execute(
                sql: """
                    INSERT INTO conversation_cuts (segmentId, mediaMs, reason, algorithm, createdAtMs)
                    VALUES ('a', 30, 'lull', ?, 1), ('a', 700, 'topicChange', ?, 1),
                           ('b', 9, 'not-a-reason', ?, 1)
                    """,
                arguments: [other, other, ConversationCutStore.algorithm])
        }
        // Only this version's rows are read — by the diagnostics read and by the grouper's.
        #expect(try await store.committed() == [cut("b", 9)])
        // A reason this build does not know reads as the generic one rather than being dropped.
        #expect(
            try await inputs(db).inputs == ConversationCutInputs(committed: ["b": [9: .topicChange]]))

        // Re-decided by this version at the same place: the old row is replaced — reason,
        // version and date.
        try await db.writer.write {
            try ConversationCutStore.commit([self.cut("a", 30): .topicChange], atMs: 50, in: $0)
        }
        #expect(try await store.committed() == [cut("a", 30), cut("b", 9)])
        let row = try await db.reader.read {
            try Row.fetchOne(
                $0, sql: "SELECT reason, algorithm, createdAtMs FROM conversation_cuts WHERE segmentId = 'a' AND mediaMs = 30"
            ).map { [$0["reason"] as String, String($0["algorithm"] as Int), String($0["createdAtMs"] as Int64)] }
        }
        #expect(row == ["topicChange", String(ConversationCutStore.algorithm), "50"])
        // The other stale row is still there, and still ignored.
        let total = try await db.reader.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM conversation_cuts") ?? -1
        }
        #expect(total == 3)
    }

    @Test func aGroupingIgnoresCutsFromAnotherVersion() async throws {
        let db = try AppDatabase.inMemory()
        let talk = day(minutes: 45, talk: [.dialogue(0, 45)])
        try await db.writer.write { d in
            try d.execute(
                sql: """
                    INSERT INTO conversation_cuts (segmentId, mediaMs, reason, algorithm, createdAtMs)
                    VALUES ('s1', 400000, 'topicChange', ?, 1)
                    """,
                arguments: [ConversationCutStore.algorithm + 1])
        }
        let rebuilt = try await ConversationGrouper.rebuild(
            segments: talk.segments, pauses: [], openSegmentId: nil, fallbackTimeZoneID: "UTC",
            evidence: talk.evidence, policy: .quietOnly, db: db)
        #expect(rebuilt.map(\.id) == ["conv-s0"])
    }

    @Test func forgetRemovesASegmentsCutsAndDecisionsAndNothingElse() async throws {
        let db = try AppDatabase.inMemory()
        let store = ConversationCutStore(db: db)
        try await db.writer.write {
            try ConversationCutStore.commit(
                [self.cut("a", 30): .lull, self.cut("b", 9): .lull, self.cut("c", 77): .lull],
                atMs: 1, in: $0)
        }
        try await store.setOverride(at: cut("a", 400), decision: .split)
        try await store.setOverride(at: cut("b", 800), decision: .join)
        try await store.setOverride(at: cut("c", 0), decision: .join)
        try await BoundaryOverrideStore(db: db).set(segmentId: "a", decision: .split)

        try await store.forget(segmentIds: [])
        #expect(try await store.committed().count == 3)

        try await store.forget(segmentIds: ["a", "c", "never-existed"])
        #expect(try await store.committed() == [cut("b", 9)])
        #expect(try await store.overrides() == [cut("b", 800): .join])
        // Decisions about a segment's START live in their own table with their own `forget`.
        #expect(try await BoundaryOverrideStore(db: db).all() == ["a": .split])
    }
}
