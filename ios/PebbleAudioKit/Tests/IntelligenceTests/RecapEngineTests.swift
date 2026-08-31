import Foundation
import Testing
import AppDB
import SegmentStore

@testable import Intelligence

// Port of `app/src/commonTest/.../DailyRecapEngineTest.kt` (6 cases) plus the digest-donation
// behavior from TranscriptIndexDonatorTest (`redonatingSameDayReplacesTheDigest…`), plus the
// plan-6.4 recorded-zone rule that supersedes KMP's currentSystemDefault timeLabels.

/// Mutable segment/transcript world + AI recorder shared across @Sendable engine closures.
private final class RecapHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _segments: [SegmentMeta] = []
    private var _transcripts: [String: String] = [:]
    private var _requests: [AiRunRequest] = []

    let clock: TestWallClock

    init(clockMs: Int64) {
        clock = TestWallClock(ms: clockMs)
    }

    var segments: [SegmentMeta] { lock.withLock { _segments } }
    var requests: [AiRunRequest] { lock.withLock { _requests } }

    func addSegment(_ id: String, startMs: Int64, text: String?) {
        lock.withLock {
            _segments.append(
                makeIntelligenceSegment(id: id, startTimeMs: startMs, transcribed: text != nil))
            if let text { _transcripts[id] = text }
        }
    }

    func addSegment(_ id: String, startMs: Int64, text: String?, tz: String?) {
        lock.withLock {
            _segments.append(
                makeIntelligenceSegment(
                    id: id, startTimeMs: startMs, transcribed: text != nil,
                    recordedTimeZone: tz))
            if let text { _transcripts[id] = text }
        }
    }

    func removeSegment(_ id: String) {
        lock.withLock { _segments.removeAll { $0.segmentId == id } }
    }

    func transcript(_ id: String) -> String? {
        lock.withLock { _transcripts[id] }
    }

    /// The RecordingAiProvider: records requests, answers "Recap <n>".
    func run(_ request: AiRunRequest) -> RoutedAiResult {
        lock.withLock {
            _requests.append(request)
            return RoutedAiResult(
                text: "Recap \(_requests.count)", modeUsed: .localOnly, providerId: "fake",
                modelUsed: "fake-model", inputTokens: nil, outputTokens: nil)
        }
    }
}

private let dailySummaryPrompt = AiPromptTemplate(
    id: "daily-summary", title: "Daily Summary",
    systemPrompt: "Summarize the day.", userPrompt: "Use transcripts.")

@Suite struct RecapEngineTests {
    private func makeEngine(
        _ harness: RecapHarness,
        onRecapSaved: @escaping @Sendable (DailyRecap) async -> Void = { _ in }
    ) throws -> (DailyRecapEngine, DailyRecapStore) {
        let db = try AppDatabase.inMemory()
        let store = DailyRecapStore(db: db, nowMs: { harness.clock.now })
        let engine = DailyRecapEngine(
            listSegments: { harness.segments },
            transcriptTextOf: { harness.transcript($0) },
            store: store,
            run: { harness.run($0) },
            prompt: dailySummaryPrompt,
            onRecapSaved: onRecapSaved,
            fallbackTimeZoneID: "UTC",
            nowMs: { harness.clock.now })
        return (engine, store)
    }

    @Test func logicalDayRollsOverAtFiveAm() {
        #expect(LogicalDay.dateKey(forMs: atUtc(2026, 8, 30, 4, 59), timeZoneID: "UTC") == "2026-08-29")
        #expect(LogicalDay.dateKey(forMs: atUtc(2026, 8, 30, 5, 0), timeZoneID: "UTC") == "2026-08-30")
        #expect(LogicalDay.dateKey(forMs: atUtc(2026, 8, 29, 23, 59), timeZoneID: "UTC") == "2026-08-29")
    }

    @Test func groupsPostMidnightSegmentsIntoPreviousLogicalDay() async throws {
        let harness = RecapHarness(clockMs: atUtc(2026, 8, 29, 12, 0))
        harness.addSegment(
            "seg-evening", startMs: atUtc(2026, 8, 29, 21, 0), text: "Talked about the trip.")
        harness.addSegment(
            "seg-night", startMs: atUtc(2026, 8, 30, 1, 30), text: "Late movie discussion.")
        harness.clock.now = atUtc(2026, 8, 30, 2, 0)
        let (engine, store) = try makeEngine(harness)

        try await engine.refreshDigests()

        #expect(harness.requests.count == 1)
        let digest = try await store.load(dateKey: "2026-08-29")
        #expect(digest != nil)
        #expect(digest?.segmentIds == ["seg-evening", "seg-night"])
        #expect(try await store.load(dateKey: "2026-08-30") == nil)
        let excerpts = harness.requests[0].transcripts
        #expect(excerpts.map(\.segmentId) == ["seg-evening", "seg-night"])
        #expect(excerpts.first?.timeLabel == "2026-08-29 21:00")
    }

    @Test func refreshesWhenNewTranscriptArrivesAfterDebounce() async throws {
        let harness = RecapHarness(clockMs: atUtc(2026, 8, 29, 12, 0))
        let saves = SavedRecaps()
        let (engine, store) = try makeEngine(harness) { await saves.append($0) }
        harness.addSegment("seg-1", startMs: atUtc(2026, 8, 29, 9, 0), text: "Morning standup.")
        harness.clock.now = atUtc(2026, 8, 29, 9, 30)
        try await engine.refreshDigests()
        #expect(harness.requests.count == 1)
        #expect(await saves.all.count == 1)
        let firstCreatedAt = harness.clock.now

        // A new transcript inside the half-hour debounce window does not rerun the AI yet.
        harness.addSegment("seg-2", startMs: atUtc(2026, 8, 29, 9, 40), text: "Coffee chat.")
        harness.clock.now = firstCreatedAt + 10 * 60 * 1000
        try await engine.refreshDigests()
        #expect(harness.requests.count == 1)

        // Once the debounce expires the digest regenerates and covers both segments.
        harness.clock.now = firstCreatedAt + 31 * 60 * 1000
        try await engine.refreshDigests()
        #expect(harness.requests.count == 2)
        let recap = try await store.load(dateKey: "2026-08-29")
        #expect(recap?.segmentIds == ["seg-1", "seg-2"])
        #expect(recap?.text == "Recap 2")
        // The callback receives the stored digest itself, and a same-day regeneration keeps
        // the same dateKey — downstream index donation must upsert "day-<dateKey>".
        let saved = await saves.all
        #expect(saved.map(\.dateKey) == ["2026-08-29", "2026-08-29"])
        #expect(saved.last?.text == "Recap 2")
    }

    @Test func doesNotRegenerateWithoutNewContent() async throws {
        let harness = RecapHarness(clockMs: atUtc(2026, 8, 29, 12, 0))
        let (engine, _) = try makeEngine(harness)
        harness.addSegment("seg-1", startMs: atUtc(2026, 8, 29, 9, 0), text: "Morning standup.")
        try await engine.refreshDigests()
        #expect(harness.requests.count == 1)

        harness.clock.advance(byMs: 2 * 60 * 60 * 1000)
        try await engine.refreshDigests()
        #expect(harness.requests.count == 1)

        // A pending (untranscribed) segment is not new content either.
        harness.addSegment("seg-2", startMs: atUtc(2026, 8, 29, 11, 0), text: nil)
        harness.clock.advance(byMs: 60 * 60 * 1000)
        try await engine.refreshDigests()
        #expect(harness.requests.count == 1)
    }

    @Test func retentionDeletedSegmentsDoNotChurnTheDigest() async throws {
        let harness = RecapHarness(clockMs: atUtc(2026, 8, 29, 12, 0))
        let (engine, store) = try makeEngine(harness)
        harness.addSegment("seg-1", startMs: atUtc(2026, 8, 29, 9, 0), text: "Morning standup.")
        harness.addSegment("seg-2", startMs: atUtc(2026, 8, 29, 10, 0), text: "Planning session.")
        try await engine.refreshDigests()
        #expect(harness.requests.count == 1)

        harness.removeSegment("seg-1")
        harness.clock.advance(byMs: 2 * 60 * 60 * 1000)
        try await engine.refreshDigests()
        #expect(harness.requests.count == 1)
        #expect(try await store.load(dateKey: "2026-08-29")?.segmentIds == ["seg-1", "seg-2"])
    }

    @Test func eachLogicalDayGetsItsOwnDigestNewestFirst() async throws {
        let harness = RecapHarness(clockMs: atUtc(2026, 8, 29, 12, 0))
        harness.addSegment("seg-old", startMs: atUtc(2026, 8, 28, 14, 0), text: "Older meeting.")
        harness.addSegment("seg-new", startMs: atUtc(2026, 8, 29, 9, 0), text: "Newer meeting.")
        harness.clock.now = atUtc(2026, 8, 29, 10, 0)
        let (engine, store) = try makeEngine(harness)

        try await engine.refreshDigests()

        #expect(harness.requests.count == 2)
        // The current logical day is generated first: it backs the visible Today recap.
        #expect(harness.requests[0].transcripts.count == 1)
        #expect(harness.requests[0].transcripts[0].segmentId == "seg-new")
        #expect(try await store.load(dateKey: "2026-08-28") != nil)
        #expect(try await store.load(dateKey: "2026-08-29") != nil)
    }

    /// Digest donation: regenerations of the same day land on the same index document id
    /// (`day-<dateKey>`), replacing instead of accumulating (TranscriptIndexDonatorTest).
    @Test func redonatingSameDayReplacesTheDigestInsteadOfAccumulating() async throws {
        let harness = RecapHarness(clockMs: atUtc(2026, 8, 29, 12, 0))
        let index = FakeRecapIndex()
        let (engine, _) = try makeEngine(harness) { recap in
            await index.upsert(id: RecapIndex.documentId(dateKey: recap.dateKey), text: recap.text)
        }

        harness.addSegment("seg-1", startMs: atUtc(2026, 8, 29, 9, 0), text: "Morning recap talk.")
        harness.clock.now = atUtc(2026, 8, 29, 9, 30)
        try await engine.refreshDigests()

        harness.addSegment("seg-2", startMs: atUtc(2026, 8, 29, 18, 0), text: "Evening recap talk.")
        harness.clock.now = atUtc(2026, 8, 29, 19, 0)
        try await engine.refreshDigests()

        // Two donations, one surviving document, newest text wins.
        #expect(await index.donationIds == ["day-2026-08-29", "day-2026-08-29"])
        let docs = await index.documents
        #expect(docs.count == 1)
        #expect(docs["day-2026-08-29"] == "Recap 2")
    }

    /// Plan 6.4 (supersedes KMP currentSystemDefault): day grouping and excerpt timeLabels use
    /// the segment's RECORDED zone, not the engine's fallback zone.
    @Test func timeLabelsAndDayKeysUseTheSegmentsRecordedZone() async throws {
        let harness = RecapHarness(clockMs: atUtc(2026, 8, 30, 12, 0))
        // 20:00 UTC on Aug 29 is exactly 05:00 Aug 30 in Tokyo — the Tokyo logical day rolls.
        harness.addSegment(
            "seg-tokyo", startMs: atUtc(2026, 8, 29, 20, 0), text: "Tokyo breakfast notes.",
            tz: "Asia/Tokyo")
        let (engine, store) = try makeEngine(harness)  // fallback zone is UTC

        try await engine.refreshDigests()

        #expect(try await store.load(dateKey: "2026-08-30") != nil)
        #expect(try await store.load(dateKey: "2026-08-29") == nil)
        #expect(harness.requests[0].transcripts[0].timeLabel == "2026-08-30 05:00")
    }
}

/// Collects onRecapSaved fan-outs.
private actor SavedRecaps {
    private var recaps: [DailyRecap] = []
    var all: [DailyRecap] { recaps }
    func append(_ recap: DailyRecap) { recaps.append(recap) }
}

/// Dictionary-backed stand-in for the search index's digest documents.
private actor FakeRecapIndex {
    private(set) var documents: [String: String] = [:]
    private(set) var donationIds: [String] = []

    func upsert(id: String, text: String) {
        documents[id] = text
        donationIds.append(id)
    }
}
