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
            firstSampleIndex: 0, lastSampleIndexExclusive: 600 * rate,
            headReceivedAtMs: startWallMs + 600_000, frameCount: 15_000,
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

    /// Wall times stored before recordings were placed by their arrival are re-placed once
    /// (`follow-ups-wall-replace-v1`): this recording arrived 15 minutes after its sample clock
    /// said, so its follow-up moves 15 minutes (less the delivery time) later. One whose
    /// recording is gone keeps its time; neither is looked at again.
    @Test func storedWallTimesAreRePlacedOnceByTheArrivalClock() async throws {
        let lag: Int64 = 900_000
        var lagging = Self.meta("seg-a")
        lagging.receivedAtMs = Self.startWallMs + lag
        lagging.headReceivedAtMs = Self.startWallMs + 600_000 + lag
        let old = SegmentWallRange(startMs: Self.startWallMs + 30_000, endMs: Self.startWallMs + 30_000, isApproximate: false)
        for (id, segment) in [("moved", "seg-a"), ("orphan", "seg-gone")] {
            try await followUps.upsertExtracted(
                FollowUp(
                    id: id, text: id, done: false, sourceConversationId: "conv",
                    sourceSegmentId: segment, createdAtMs: 1, sourceStartMs: 30_000,
                    sourceEndMs: nil, sourceWall: old))
        }
        try await db.writer.write { try FollowUpWallTimeFill.listForReplacement($0) }

        let fill = FollowUpWallTimeFill(db: db)
        let metas = ["seg-a": lagging]
        _ = try await fill.run(metaOf: { metas[$0] })
        let shift = lag - SegmentMeta.deliveryMs
        #expect(try await wall("moved")?.startMs == old.startMs + shift)
        #expect(try await wall("orphan") == old)
        let listed = try await db.reader.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM follow_up_wall_replace") ?? -1
        }
        #expect(listed == 0)
        #expect(try await fill.run(metaOf: { metas[$0] }) == FollowUpWallTimeFill.Outcome())
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

// MARK: - Placement

@Suite struct FollowUpPlacementTests {
    private static let segmentId = "seg-1788193000000-00000001-7"
    private static let span: Range<Int64> = 1_788_192_900_000..<1_788_193_800_000

    private func row(
        origin: FollowUpOrigin = .ai, segment: String? = segmentId,
        wall: SegmentWallRange? = nil, createdAtMs: Int64 = 1_799_999_999_999
    ) -> FollowUp {
        FollowUp(
            id: "f", text: "t", done: false, sourceConversationId: nil, sourceSegmentId: segment,
            createdAtMs: createdAtMs, origin: origin, sourceWall: wall)
    }

    private func place(_ row: FollowUp, exists: Bool = true) -> FollowUpPlacement? {
        FollowUpPlacement.placement(of: row) { id in
            exists && id == Self.segmentId ? Self.span : nil
        }
    }

    @Test func aStoredWallTimeIsTheMoment() {
        let exact = SegmentWallRange(startMs: 1_788_193_420_000, endMs: 1_788_193_423_500, isApproximate: false)
        #expect(place(row(wall: exact)) == .moment(1_788_193_420_000, isApproximate: false))
        let rough = SegmentWallRange(startMs: 5, endMs: 6, isApproximate: true)
        #expect(place(row(wall: rough)) == .moment(5, isApproximate: true))
        // It outlives the segment: that is what storing it is for.
        #expect(place(row(wall: exact), exists: false) == .moment(1_788_193_420_000, isApproximate: false))
        #expect(place(row(wall: exact))?.isApproximate == false)
        #expect(place(row(wall: rough))?.isApproximate == true)
    }

    @Test func noWallTimeButTheSegmentExistsIsItsSpan() {
        #expect(place(row()) == .span(Self.span))
        #expect(place(row())?.isApproximate == true)
        // A hand-written item attached to a recording is about that recording.
        #expect(place(row(origin: .user)) == .span(Self.span))
    }

    @Test func aGoneSegmentLeavesTheDayItsIdCarries() {
        #expect(place(row(), exists: false) == .dayOnly(approximateMs: 1_788_193_000_000))
        #expect(place(row(origin: .user), exists: false) == .dayOnly(approximateMs: 1_788_193_000_000))
    }

    @Test func aHandWrittenItemWithNoSegmentIsTheDayItWasWritten() {
        #expect(
            place(row(origin: .user, segment: nil, createdAtMs: 1_790_000_000_000))
                == .dayOnly(approximateMs: 1_790_000_000_000))
    }

    /// `createdAtMs` is when extraction ran: never a placement for an extracted row.
    @Test func anExtractedRowIsNeverPlacedByWhenExtractionRan() {
        #expect(place(row(segment: nil)) == nil)
        #expect(place(row(segment: "seg-1"), exists: false) == nil)
        #expect(place(row(origin: .user, segment: "seg-1"), exists: false) == nil)
    }

    @Test func onlyTheStoresIdShapeCarriesATime() {
        let parse = FollowUpPlacement.receivedAtMs(ofSegmentId:)
        #expect(parse("seg-1788193000000-00000001-7") == 1_788_193_000_000)
        #expect(parse("seg-1000000000000-x") == 1_000_000_000_000)
        #expect(parse("seg-9999999999999-x") == 9_999_999_999_999)
        for malformed in [
            "", "seg-", "seg-1", "seg-1-2-3", "seg-abc-1", "seg-178819300000-1",  // 12 digits
            "seg-17881930000000-1",  // 14 digits
            "seg-1788193000000",  // no separator after the time
            "seg-1788193000000_1", "seg-178819300000x-1", "seg--1788193000000-1",
            "xseg-1788193000000-1", "SEG-1788193000000-1", "seg-+788193000000-1",
            "seg-١٧٨٨١٩٣٠٠٠٠٠٠-1",  // Arabic-Indic digits: digits, but not ASCII
            "conv-1788193000000-1",
        ] {
            #expect(parse(malformed) == nil, "\(malformed)")
        }
    }
}

// MARK: - History's window read

@Suite struct HistoryFollowUpWindowTests {
    private let db: AppDatabase
    private let followUps: FollowUpStore

    init() throws {
        db = try AppDatabase.inMemory()
        followUps = FollowUpStore(db: db)
    }

    /// A day: 2026-09-01 00:00 to 2026-09-02 00:00 UTC.
    private static let day: Range<Int64> = 1_788_220_800_000..<1_788_307_200_000
    private static let noon: Int64 = 1_788_264_000_000
    private static let now: Int64 = 1_788_300_000_000

    private static func segment(receivedAt ms: Int64, _ n: Int = 1) -> String {
        "seg-\(ms)-00000001-\(n)"
    }

    private func insert(
        _ id: String, origin: FollowUpOrigin = .ai, segment: String? = nil,
        wallAt: Int64? = nil, createdAtMs: Int64 = 1, done: Bool = false,
        snoozedUntil: Int64? = nil, archived: Bool = false
    ) async throws {
        try await db.writer.write { d in
            try d.execute(
                sql: """
                    INSERT INTO follow_ups
                        (id, text, done, sourceSegmentId, createdAtMs, snoozedUntilMs,
                         archivedAtMs, origin, sourceWallStartMs, sourceWallEndMs,
                         sourceWallApproximate)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id, id, done, segment, createdAtMs, snoozedUntil, archived ? 2 : nil,
                    origin.rawValue, wallAt, wallAt.map { $0 + 1_000 }, wallAt.map { _ in false },
                ])
        }
    }

    private func ids(segmentIds: [String] = [], window: Range<Int64> = day) async throws -> [String] {
        try await followUps.history(inWallWindow: window, segmentIds: segmentIds).map(\.id)
    }

    @Test func aWallTimeInTheWindowCountsAndTheEdgesAreHalfOpen() async throws {
        try await insert("noon", wallAt: Self.noon)
        try await insert("first-ms", wallAt: Self.day.lowerBound)
        try await insert("last-ms", wallAt: Self.day.upperBound - 1)
        try await insert("next-day", wallAt: Self.day.upperBound)
        try await insert("day-before", wallAt: Self.day.lowerBound - 1)
        #expect(Set(try await ids()) == ["noon", "first-ms", "last-ms"])
    }

    /// Plan 7.5: open and done count, snoozed counts as open, archived never.
    @Test func archivedIsLeftOutAndDoneAndSnoozedAreKept() async throws {
        try await insert("open", wallAt: Self.noon)
        try await insert("done", wallAt: Self.noon + 1, done: true)
        try await insert("snoozed", wallAt: Self.noon + 2, snoozedUntil: Self.now + 1)
        try await insert("archived", wallAt: Self.noon + 3, archived: true)
        try await insert(
            "archived-by-segment", segment: Self.segment(receivedAt: Self.noon), archived: true)
        try await insert(
            "archived-by-hand", origin: .user, createdAtMs: Self.noon, archived: true)

        let records = try await followUps.history(
            inWallWindow: Self.day, segmentIds: [Self.segment(receivedAt: Self.noon)])
        // Open first, then done, each by time.
        #expect(records.map(\.id) == ["open", "snoozed", "done"])
        #expect(records.first { $0.id == "snoozed" }?.isSnoozed(at: Self.now) == true)
        #expect(records.first { $0.id == "done" }?.done == true)
    }

    @Test func noWallTimeCountsThroughTheWindowsRecordings() async throws {
        let before = Self.segment(receivedAt: Self.day.lowerBound - 60_000)  // straddles midnight
        try await insert("in-list", segment: before)
        try await insert("not-in-list", segment: Self.segment(receivedAt: 1_700_000_000_000))
        // A known moment outside the window wins over its segment being listed.
        try await insert("placed-elsewhere", segment: before, wallAt: Self.day.lowerBound - 30_000)
        #expect(Set(try await ids(segmentIds: [before])) == ["in-list"])
    }

    /// Rule 3's rows — segment gone, no wall time — are found by the time in their id.
    @Test func noWallTimeCountsThroughTheReceiveTimeInTheSegmentId() async throws {
        try await insert("gone", segment: Self.segment(receivedAt: Self.noon))
        try await insert("gone-edge", segment: Self.segment(receivedAt: Self.day.lowerBound))
        try await insert("gone-next-day", segment: Self.segment(receivedAt: Self.day.upperBound))
        try await insert("not-an-id-time", segment: "seg-1")
        try await insert("twelve-digits", segment: "seg-178826400000-1")
        #expect(Set(try await ids()) == ["gone", "gone-edge"])

        let records = try await followUps.history(inWallWindow: Self.day, segmentIds: [])
        let placed = Dictionary(
            uniqueKeysWithValues: records.map {
                ($0.id, FollowUpPlacement.placement(of: $0) { _ in nil })
            })
        #expect(placed["gone"] == .dayOnly(approximateMs: Self.noon))
        #expect(placed["gone-edge"] == .dayOnly(approximateMs: Self.day.lowerBound))
    }

    @Test func aHandWrittenItemCountsOnTheDayItWasWritten() async throws {
        try await insert("mine", origin: .user, createdAtMs: Self.noon)
        try await insert("mine-yesterday", origin: .user, createdAtMs: Self.day.lowerBound - 1)
        // Extraction ran today on something said last week: createdAtMs is not when it was said.
        try await insert("extracted-today", createdAtMs: Self.noon)
        // Hand-written about a recording: counted through the recording, not the day typed.
        try await insert(
            "mine-about-a-recording", origin: .user,
            segment: Self.segment(receivedAt: 1_700_000_000_000), createdAtMs: Self.noon)
        #expect(try await ids() == ["mine"])
    }

    /// SQLite binds at most 32,766 parameters (999 before 3.32); the ids are one JSON parameter.
    @Test func aLargeIdListIsOneParameter() async throws {
        let many = (0..<40_000).map { Self.segment(receivedAt: 1_600_000_000_000, $0) }
        try await insert("last-of-many", segment: many.last)
        try await insert("middle-of-many", segment: many[20_000])
        #expect(Set(try await ids(segmentIds: many)) == ["last-of-many", "middle-of-many"])
    }

    @Test func anEmptyWindowOrListFindsNothingItShouldNot() async throws {
        try await insert("noon", wallAt: Self.noon)
        #expect(try await ids(window: Self.noon..<Self.noon).isEmpty)
    }

    @Test func theIdRangeSortsLikeTheTimesItHolds() {
        let range = FollowUpStore.segmentIdRange(receivedIn: Self.day)
        #expect(range.contains(Self.segment(receivedAt: Self.day.lowerBound)))
        #expect(range.contains(Self.segment(receivedAt: Self.day.upperBound - 1)))
        #expect(!range.contains(Self.segment(receivedAt: Self.day.upperBound)))
        #expect(!range.contains(Self.segment(receivedAt: Self.day.lowerBound - 1)))
        // The domain's ends: nothing breaks for a window past what thirteen digits hold.
        let everything = FollowUpStore.segmentIdRange(receivedIn: -5..<Int64.max)
        #expect(everything.contains("seg-0000000000000-1"))
        #expect(everything.contains("seg-9999999999999-1"))
    }

    /// Every branch is an index read: nothing scans the table.
    @Test func noBranchScansTheTable() async throws {
        let plan = try await db.reader.read { d in
            try Row.fetchAll(
                d, sql: "EXPLAIN QUERY PLAN " + FollowUpStore.historySQL,
                arguments: ["start": 0, "end": 1, "ids": "[]", "idFrom": "a", "idTo": "b"]
            ).map { $0["detail"] as String }
        }
        let scans = plan.filter {
            $0.hasPrefix("SCAN follow_ups") || $0.hasPrefix("SCAN TABLE follow_ups")
        }
        #expect(scans.isEmpty, "\(plan)")
        #expect(plan.contains { $0.contains("follow_ups_wall") }, "\(plan)")
        #expect(plan.contains { $0.contains("follow_ups_segment") }, "\(plan)")
        #expect(plan.contains { $0.contains("follow_ups_open") }, "\(plan)")
    }

    /// From the read to the line History draws.
    @Test func aRecordBecomesItsLine() async throws {
        try await insert("rough", wallAt: Self.noon, snoozedUntil: Self.now + 1)
        let record = try #require(
            try await followUps.history(inWallWindow: Self.day, segmentIds: []).first)
        let placement = try #require(FollowUpPlacement.placement(of: record) { _ in nil })
        #expect(placement == .moment(Self.noon, isApproximate: false))
        #expect(
            record.line(placement: placement, nowMs: Self.now)
                == HistoryFollowUpLine(
                    id: "rough", text: "rough", done: false, isSnoozed: true, isApproximate: false))
    }
}
