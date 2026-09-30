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

// MARK: - The one-time fill

/// Rows written before extraction stored a wall time get one from their segment's clock, once.
@Suite struct FollowUpWallTimeFillTests {
    private let db: AppDatabase
    private let followUps: FollowUpStore
    private let candidates: FollowUpCandidateStore

    init() throws {
        db = try AppDatabase.inMemory()
        followUps = FollowUpStore(db: db)
        candidates = FollowUpCandidateStore(db: db)
    }

    private static let startWallMs: Int64 = 1_788_193_000_000
    private static let rate: UInt64 = 16_000

    /// Ten minutes of wall time, five of audio; the missing five (60 s..360 s) recorded or not.
    private static func meta(_ segmentId: String, recordsTheGap: Bool = true) -> SegmentMeta {
        SegmentMeta(
            segmentId: segmentId, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: UInt32(rate), bitRateBps: 9_800,
            frameDurationMs: 20, startTimeMs: UInt64(startWallMs), startMonotonicMs: 1,
            receivedAtMs: startWallMs + 600_000,
            firstSampleIndex: 0, lastSampleIndexExclusive: 600 * rate, frameCount: 15_000,
            gaps: recordsTheGap
                ? [
                    GapMeta(
                        firstMissingSequence: 3_000, missingFrameCount: 15_000,
                        firstMissingSampleIndex: 60 * rate, origin: "watch")
                ] : [],
            closeReason: .rotated, transcriptionState: .complete)
    }

    /// A row as the extractor wrote it before v15: a located quote, no wall time.
    private func legacyFollowUp(
        _ id: String, segment: String?, start: Int64?, end: Int64? = nil, archived: Bool = false
    ) async throws {
        try await followUps.upsertExtracted(
            FollowUp(
                id: id, text: id, done: false, sourceConversationId: "conv",
                sourceSegmentId: segment, createdAtMs: 1, sourceStartMs: start,
                sourceEndMs: end, archivedAtMs: archived ? 2 : nil))
    }

    private func candidate(
        _ id: String, segment: String, start: Int64, end: Int64,
        state: FollowUpCandidateState = .pending
    ) async throws {
        try await candidates.save(
            FollowUpCandidate(
                id: id, conversationId: "conv", segmentId: segment, task: id, startMs: start,
                endMs: end, createdAtMs: 1, state: state))
    }

    private func wall(_ id: String) async throws -> SegmentWallRange? {
        try await followUps.load(id: id)?.sourceWall
    }

    private func candidateWall(_ id: String) async throws -> SegmentWallRange? {
        try await candidates.list(conversationId: "conv").first { $0.id == id }?.sourceWall
    }

    @Test func fillsFollowUpsAndPendingCandidatesFromTheSegmentsClock() async throws {
        try await legacyFollowUp("exact", segment: "seg-a", start: 120_000, end: 123_500)
        try await legacyFollowUp("rough", segment: "seg-b", start: 120_000)
        try await legacyFollowUp("filed", segment: "seg-a", start: 30_000, archived: true)
        try await candidate("pending", segment: "seg-a", start: 120_000, end: 123_500)
        try await candidate("kept", segment: "seg-a", start: 120_000, end: 123_500, state: .kept)

        let metas = ["seg-a": Self.meta("seg-a"), "seg-b": Self.meta("seg-b", recordsTheGap: false)]
        let outcome = try await FollowUpWallTimeFill(db: db).run(metaOf: { metas[$0] })

        #expect(outcome == .init(followUps: 3, candidates: 1, segmentGone: 0))
        // Exact clock: the recorded gap before the quote moves it five minutes later.
        let exact = SegmentWallRange(
            startMs: Self.startWallMs + 420_000, endMs: Self.startWallMs + 423_500,
            isApproximate: false)
        #expect(try await wall("exact") == exact)
        #expect(
            try await wall("exact")
                == SegmentMediaClock.wallRange(
                    ofMediaStartMs: 120_000, endMs: 123_500, in: Self.meta("seg-a")),
            "the same helper extraction uses")
        // Inexact clock: left on the media clock, and said to be approximate. No end: a moment.
        #expect(
            try await wall("rough")
                == SegmentWallRange(
                    startMs: Self.startWallMs + 120_000, endMs: Self.startWallMs + 120_000,
                    isApproximate: true))
        // Archived rows are filled too: restoring one should not lose its place.
        #expect(try await wall("filed") != nil)
        #expect(try await candidateWall("pending") == exact)
        #expect(try await candidateWall("kept") == nil, "a decided candidate is never read again")
    }

    @Test func leavesRowsWithNothingToComputeFromAlone() async throws {
        try await followUps.add(text: "Mine")  // hand-written: no segment, no offset
        try await legacyFollowUp("untimed", segment: "seg-a", start: nil)  // no diarized turn
        try await legacyFollowUp("gone", segment: "seg-gone", start: 5_000)

        let asked = Recorder()
        let outcome = try await FollowUpWallTimeFill(db: db).run(metaOf: {
            asked.append($0)
            return $0 == "seg-a" ? Self.meta("seg-a") : nil
        })

        #expect(outcome == .init(followUps: 0, candidates: 0, segmentGone: 1))
        #expect(asked.values == ["seg-gone"], "only rows that need a time are looked at")
        #expect(try await wall("untimed") == nil)
        #expect(try await wall("gone") == nil, "no segment, no clock, no guess")
        #expect(try await followUps.list(scope: .open, nowMs: 0).allSatisfy { $0.sourceWall == nil })
    }

    @Test func isIdempotentAndASecondRunDoesNothing() async throws {
        try await legacyFollowUp("f1", segment: "seg-a", start: 120_000, end: 123_500)
        try await candidate("c1", segment: "seg-a", start: 120_000, end: 123_500)
        let fill = FollowUpWallTimeFill(db: db)
        let first = try await fill.run(metaOf: { _ in Self.meta("seg-a") })
        #expect(first.filled == 2)
        let filled = try await wall("f1")

        let asked = Recorder()
        let changesBefore = try await db.writer.write { $0.totalChangesCount }
        let second = try await fill.run(metaOf: {
            asked.append($0)
            return Self.meta("seg-a", recordsTheGap: false)  // would now compute differently
        })
        let changesAfter = try await db.writer.write { $0.totalChangesCount }

        #expect(second == .init())
        #expect(asked.values.isEmpty, "nothing to fill: no segment is even looked up")
        #expect(changesAfter == changesBefore, "and nothing is written")
        #expect(try await wall("f1") == filled)
    }

    @Test func aRowWhoseSegmentIsGoneIsSkippedEveryRunAndNeverWritten() async throws {
        try await legacyFollowUp("gone", segment: "seg-gone", start: 5_000)
        let fill = FollowUpWallTimeFill(db: db)
        for _ in 0..<2 {
            let changesBefore = try await db.writer.write { $0.totalChangesCount }
            let outcome = try await fill.run(metaOf: { _ in nil })
            let changesAfter = try await db.writer.write { $0.totalChangesCount }
            #expect(outcome == .init(followUps: 0, candidates: 0, segmentGone: 1))
            #expect(changesAfter == changesBefore)
        }
    }

    /// Extraction or curation may write the same row between the fill's read and its write. The
    /// fill must never overwrite a value it did not compute, nor time a quote that has moved.
    @Test func aRowChangedUnderneathTheFillIsNotOverwritten() async throws {
        try await legacyFollowUp("moved", segment: "seg-a", start: 120_000)
        try await legacyFollowUp("written", segment: "seg-a", start: 120_000)
        let theirs = SegmentWallRange(startMs: 1, endMs: 2, isApproximate: false)
        let followUps = self.followUps
        let outcome = try await FollowUpWallTimeFill(db: db).run(metaOf: { _ in
            // Runs after the read and before the write.
            try? await followUps.upsertExtracted(
                FollowUp(
                    id: "moved", text: "moved", done: false, sourceConversationId: "conv",
                    sourceSegmentId: "seg-a", createdAtMs: 1, sourceStartMs: 200_000))
            try? await followUps.upsertExtracted(
                FollowUp(
                    id: "written", text: "written", done: false, sourceConversationId: "conv",
                    sourceSegmentId: "seg-a", createdAtMs: 1, sourceStartMs: 120_000,
                    sourceWall: theirs))
            return Self.meta("seg-a")
        })
        #expect(outcome.followUps == 0)
        #expect(try await wall("moved") == nil, "left for the next run, at its new location")
        #expect(try await wall("written") == theirs)
    }

    /// O(rows needing it): the fill's read is served by the partial index, not a table scan.
    @Test func theReadUsesThePartialIndex() async throws {
        let plan = try await db.reader.read { d in
            try Row.fetchAll(
                d, sql: "EXPLAIN QUERY PLAN " + FollowUpWallTimeFill.followUpsNeedingItSQL
            ).map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("follow_ups_wall_unfilled") }, "\(plan)")
    }
}

/// Records values from a `@Sendable` closure.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.withLock { _values } }
    func append(_ value: String) { lock.withLock { _values.append(value) } }
}
