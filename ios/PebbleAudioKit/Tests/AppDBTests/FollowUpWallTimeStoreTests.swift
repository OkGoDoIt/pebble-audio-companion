import Foundation
import GRDB
import SegmentStore
import Testing

@testable import AppDB

// The wall time a follow-up was said at (`sourceWall`), as the two stores read and write it.

@Suite struct FollowUpWallTimeStoreTests {
    private let db: AppDatabase
    private let followUps: FollowUpStore
    private let candidates: FollowUpCandidateStore

    init() throws {
        db = try AppDatabase.inMemory()
        followUps = FollowUpStore(db: db)
        candidates = FollowUpCandidateStore(db: db)
    }

    private static let exact = SegmentWallRange(startMs: 5_000, endMs: 6_000, isApproximate: false)
    private static let rough = SegmentWallRange(startMs: 7_000, endMs: 7_500, isApproximate: true)

    private func extracted(
        segment: String? = "seg-a", start: Int64? = 100, end: Int64? = 200,
        wall: SegmentWallRange? = exact
    ) -> FollowUp {
        FollowUp(
            id: "f1", text: "Call Sam", done: false, sourceConversationId: "conv",
            sourceSegmentId: segment, createdAtMs: 1, sourceStartMs: start, sourceEndMs: end,
            sourceWall: wall)
    }

    @Test func bothStoresRoundTripTheWallTimeAndItsFlag() async throws {
        try await followUps.upsertExtracted(extracted(wall: Self.rough))
        #expect(try await followUps.load(id: "f1")?.sourceWall == Self.rough)

        try await candidates.save(
            FollowUpCandidate(
                id: "c1", conversationId: "conv", segmentId: "seg-a", task: "t", startMs: 1,
                endMs: 2, createdAtMs: 1, sourceWall: Self.exact))
        #expect(try await candidates.list(conversationId: "conv").first?.sourceWall == Self.exact)
    }

    @Test func noWallTimeIsStoredAsNullsNotAsZero() async throws {
        try await followUps.add(text: "Mine")
        let nulls = try await db.reader.read { d in
            try Int.fetchOne(
                d,
                sql: """
                    SELECT COUNT(*) FROM follow_ups
                    WHERE sourceWallStartMs IS NULL AND sourceWallEndMs IS NULL
                        AND sourceWallApproximate IS NULL
                    """)
        }
        #expect(nulls == 1)
        #expect(try await followUps.list(scope: .open, nowMs: 0).first?.sourceWall == nil)
    }

    /// A start with no flag beside it was vouched for by nothing, so it reads as approximate.
    @Test func aStartWithoutAFlagReadsAsApproximate() async throws {
        try await db.writer.write { d in
            try d.execute(
                sql: """
                    INSERT INTO follow_ups (id, text, createdAtMs, sourceWallStartMs)
                    VALUES ('raw', 'x', 1, 9000)
                    """)
        }
        #expect(
            try await followUps.load(id: "raw")?.sourceWall
                == SegmentWallRange(startMs: 9_000, endMs: 9_000, isApproximate: true))
    }

    /// Re-curation of the same words does not erase a time something else stored for them…
    @Test func anUpsertWithoutAWallTimeKeepsTheOneForTheSameLocation() async throws {
        try await followUps.upsertExtracted(extracted(wall: Self.exact))
        try await followUps.upsertExtracted(extracted(wall: nil))
        #expect(try await followUps.load(id: "f1")?.sourceWall == Self.exact)
    }

    /// …but a quote that moved takes the incoming value, even none: a time never outlives the
    /// location it was computed from.
    @Test func aRelocatedQuoteNeverKeepsTheOldTime() async throws {
        try await followUps.upsertExtracted(extracted(wall: Self.exact))
        try await followUps.upsertExtracted(extracted(start: 300, end: 400, wall: nil))
        #expect(try await followUps.load(id: "f1")?.sourceWall == nil)

        try await followUps.upsertExtracted(extracted(wall: Self.exact))
        try await followUps.upsertExtracted(extracted(segment: "seg-b", wall: nil))
        #expect(try await followUps.load(id: "f1")?.sourceWall == nil)

        try await followUps.upsertExtracted(extracted(wall: Self.exact))
        try await followUps.upsertExtracted(extracted(wall: Self.rough))
        #expect(try await followUps.load(id: "f1")?.sourceWall == Self.rough, "a new value wins")
    }

    /// Candidates are re-derived whole on every save, so the incoming location — times
    /// included — always wins there.
    @Test func aCandidateResaveReplacesItsWallTime() async throws {
        let first = FollowUpCandidate(
            id: "c1", conversationId: "conv", segmentId: "seg-a", task: "t", startMs: 1,
            endMs: 2, createdAtMs: 1, sourceWall: Self.exact)
        try await candidates.save(first)
        var moved = first
        moved.sourceWall = Self.rough
        try await candidates.save(moved)
        #expect(try await candidates.list(conversationId: "conv").first?.sourceWall == Self.rough)
    }
}
