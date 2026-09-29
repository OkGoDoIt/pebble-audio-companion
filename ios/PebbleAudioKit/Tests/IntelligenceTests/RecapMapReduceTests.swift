import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

@testable import Intelligence

// The daily recap, when the day is bigger than one call — and when the provider fails.
//
// 2026-09-22 and 09-23: ~232,000 and ~285,000 characters of transcript, handed in one call to
// the on-device model (Remote first, cloud down), which read the first ~8,000 and wrote a recap
// of the morning that was saved as covering 51 and 45 recordings and settled forever. And when
// both providers failed, the whole day went out again on every pass, because the debounce is
// keyed on the last SUCCESS.

private final class DayHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _segments: [SegmentMeta] = []
    private var _texts: [String: String] = [:]
    private var _requests: [AiRunRequest] = []
    private var _failure: Error?
    private var _truncate = false
    private var _reads = 0

    let clock = TestWallClock(ms: atUtc(2026, 9, 22, 23, 0))

    var requests: [AiRunRequest] { lock.withLock { _requests } }
    var reads: Int { lock.withLock { _reads } }
    var segments: [SegmentMeta] { lock.withLock { _segments } }

    func fail(with error: Error?) { lock.withLock { _failure = error } }
    func truncate(_ value: Bool) { lock.withLock { _truncate = value } }

    func add(_ id: String, at ms: Int64, text: String) {
        lock.withLock {
            _segments.append(makeIntelligenceSegment(id: id, startTimeMs: ms, transcribed: true))
            _texts[id] = text
        }
    }

    func text(_ id: String) -> String? {
        lock.withLock {
            _reads += 1
            return _texts[id]
        }
    }

    func run(_ request: AiRunRequest) throws -> RoutedAiResult {
        try lock.withLock {
            _requests.append(request)
            if let _failure { throw _failure }
            let label =
                request.prompt.userPrompt.contains("consecutive parts")
                ? "Merged recap \(_requests.count)." : "Part recap \(_requests.count)."
            return RoutedAiResult(
                text: label, modeUsed: .localOnly, providerId: "fake", modelUsed: "fake-model",
                inputTokens: nil, outputTokens: nil, inputTruncated: _truncate)
        }
    }
}

private struct NeverTransport: HttpTransport {
    func execute(_ request: HttpTransportRequest) async throws -> HttpTransportResponse {
        HttpTransportResponse(status: 500, text: "")
    }
}

private let dailySummary = AiPromptTemplate(
    id: "daily-summary", title: "Daily summary",
    systemPrompt: "Summarize the day.", userPrompt: "Use transcripts.")

private func words(_ count: Int, _ marker: String = "w") -> String {
    (0..<count).map { "\(marker)\($0)" }.joined(separator: " ")
}

@Suite("Daily recap — map-reduce, failure backoff, cancellation")
struct RecapMapReduceTests {
    private func engine(
        _ harness: DayHarness, capacity: Int?, maxCalls: Int = 50
    ) throws -> (DailyRecapEngine, DailyRecapStore) {
        let store = DailyRecapStore(db: try AppDatabase.inMemory(), nowMs: { harness.clock.now })
        let sizing: (@Sendable () async -> Int?)? =
            capacity.map { value in { @Sendable in value } }
        let engine = DailyRecapEngine(
            listSegments: { harness.segments },
            transcriptTextOf: { harness.text($0) },
            store: store,
            run: { try harness.run($0) },
            prompt: dailySummary,
            fallbackTimeZoneID: "UTC",
            nowMs: { harness.clock.now },
            maxGenerationsPerRefresh: maxCalls,
            singleCallCapacityChars: sizing)
        return (engine, store)
    }

    /// Six recordings of ~1,200 characters against a 2,000-character model: pieces that each
    /// fit, then one merge over the partial recaps, and a digest that covers all six.
    @Test func aDayTooBigForOneCallIsRecappedInPiecesAndMerged() async throws {
        let harness = DayHarness()
        for index in 0..<6 {
            harness.add(
                "seg-\(index)", at: atUtc(2026, 9, 22, 8 + index, 0), text: words(200, "s\(index)w"))
        }
        let (engine, store) = try engine(harness, capacity: 2_000)

        try await engine.refreshDigests()

        let requests = harness.requests
        let budget = DailyRecapEngine.chunkBudget(capacity: 2_000, userPrompt: "Use transcripts.")
        let maps = requests.filter { !$0.prompt.userPrompt.contains("consecutive parts") }
        let merges = requests.filter { $0.prompt.userPrompt.contains("consecutive parts") }
        #expect(maps.count >= 3)
        for map in maps {
            #expect(DailyRecapEngine.renderedChars(map.transcripts) <= budget)
        }
        // Every word of the day went to exactly one piece, in order.
        #expect(
            maps.flatMap(\.transcripts).map(\.segmentId).uniquedInOrder()
                == (0..<6).map { "seg-\($0)" })
        #expect(merges.count == 1)
        let merged = try #require(merges.first?.transcripts.first?.text)
        #expect(merged.contains("Recordings from 2026-09-22 08:00"))
        #expect(merged.contains("Part recap 1."))
        // The merge keeps the daily summary's id: same output budget, same whole-input rule.
        #expect(merges.first?.prompt.id == "daily-summary")

        let saved = try #require(try await store.load(dateKey: "2026-09-22"))
        #expect(saved.text.hasPrefix("Merged recap"))
        #expect(saved.segmentIds == (0..<6).map { "seg-\($0)" })
    }

    @Test func aDayThatFitsIsStillOneCall() async throws {
        let harness = DayHarness()
        harness.add("seg-1", at: atUtc(2026, 9, 22, 9, 0), text: words(50))
        harness.add("seg-2", at: atUtc(2026, 9, 22, 10, 0), text: words(50))
        let (engine, _) = try engine(harness, capacity: 50_000)
        try await engine.refreshDigests()
        #expect(harness.requests.count == 1)
    }

    /// A fifteen-minute recording is ~13,000 characters — more than the iOS 26 model takes at
    /// once — so one recording can itself be cut into parts. The digest names it once.
    @Test func aRecordingLongerThanAPieceIsSplitAndNamedOnce() async throws {
        let harness = DayHarness()
        harness.add("seg-long", at: atUtc(2026, 9, 22, 9, 0), text: words(1_500))
        let (engine, store) = try engine(harness, capacity: 2_000)
        try await engine.refreshDigests()
        let maps = harness.requests.filter { !$0.prompt.userPrompt.contains("consecutive parts") }
        #expect(maps.count > 1)
        #expect(maps.allSatisfy { $0.transcripts.allSatisfy { $0.segmentId == "seg-long" } })
        #expect(try await store.load(dateKey: "2026-09-22")?.segmentIds == ["seg-long"])
    }

    /// A long day on the on-device model is dozens of calls. They are spread over refreshes,
    /// and a piece already recapped is never sent again.
    @Test func aLongDaySpreadsOverRefreshesWithoutRecappingAPieceTwice() async throws {
        let harness = DayHarness()
        for index in 0..<8 {
            harness.add(
                "seg-\(index)", at: atUtc(2026, 9, 22, 8 + index, 0), text: words(200, "s\(index)w"))
        }
        let (engine, store) = try engine(harness, capacity: 2_000, maxCalls: 2)

        var refreshes = 0
        while try await store.load(dateKey: "2026-09-22") == nil, refreshes < 20 {
            try await engine.refreshDigests()
            refreshes += 1
            #expect(harness.requests.count <= 2 * refreshes)
        }
        #expect(try await store.load(dateKey: "2026-09-22") != nil)
        #expect(refreshes > 1)
        // No piece was asked about twice.
        let bodies = harness.requests.map { $0.transcripts.map(\.text).joined() }
        #expect(Set(bodies).count == bodies.count)
    }

    // MARK: Never saved from a cut input

    @Test func aResultAProviderCutIsNeverSaved() async throws {
        let harness = DayHarness()
        harness.add("seg-1", at: atUtc(2026, 9, 22, 9, 0), text: words(100))
        harness.truncate(true)
        let (engine, store) = try engine(harness, capacity: nil)
        await #expect(throws: RecapGenerationFailed.self) { try await engine.refreshDigests() }
        #expect(try await store.load(dateKey: "2026-09-22") == nil)
    }

    // MARK: A failing provider is not re-sent the day on every pass

    @Test func aFailedDayWaitsOutABackoffAndTheFailureIsReported() async throws {
        let harness = DayHarness()
        harness.add("seg-1", at: atUtc(2026, 9, 22, 9, 0), text: words(100))
        harness.fail(with: AiError.providerFailed("OpenAI responses request failed (503): busy"))
        let (engine, store) = try engine(harness, capacity: nil)

        do {
            try await engine.refreshDigests()
            Issue.record("expected the failure to reach the caller")
        } catch let failure as RecapGenerationFailed {
            #expect(failure.dateKey == "2026-09-22")
            #expect(failure.kind == .providerTrouble)
            // What the pipeline's health records: the classified kind, no provider body.
            #expect(!failure.description.contains("busy"))
        }
        #expect(harness.requests.count == 1)

        // Every pass inside the backoff costs nothing.
        for _ in 0..<5 {
            harness.clock.advance(byMs: 60_000)
            try await engine.refreshDigests()
        }
        #expect(harness.requests.count == 1)

        // Thirty minutes, then sixty.
        harness.clock.advance(byMs: DailyRecapEngine.firstFailureBackoffMs)
        _ = try? await engine.refreshDigests()
        #expect(harness.requests.count == 2)
        harness.clock.advance(byMs: DailyRecapEngine.firstFailureBackoffMs)
        try await engine.refreshDigests()
        #expect(harness.requests.count == 2)

        // An AI settings change resets it at once, and a success clears it.
        harness.fail(with: nil)
        await engine.resetFailureBackoff()
        try await engine.refreshDigests()
        #expect(harness.requests.count == 3)
        #expect(try await store.load(dateKey: "2026-09-22") != nil)
    }

    @Test func theBackoffDoublesToSixHours() {
        #expect(DailyRecapEngine.failureBackoffMs(afterFailures: 1) == 30 * 60_000)
        #expect(DailyRecapEngine.failureBackoffMs(afterFailures: 2) == 60 * 60_000)
        #expect(DailyRecapEngine.failureBackoffMs(afterFailures: 10) == 6 * 60 * 60_000)
    }

    // MARK: Cheap gates first

    /// Inside the 30-minute debounce, a day with new recordings is decided by the clock alone:
    /// its transcripts are not opened until the debounce says a regeneration is allowed.
    @Test func theDebounceIsCheckedBeforeAnyTranscriptIsRead() async throws {
        let harness = DayHarness()
        harness.add("seg-1", at: atUtc(2026, 9, 22, 9, 0), text: words(100))
        let (engine, _) = try engine(harness, capacity: nil)
        try await engine.refreshDigests()
        #expect(harness.requests.count == 1)

        harness.add("seg-2", at: atUtc(2026, 9, 22, 10, 0), text: words(100))
        let before = harness.reads
        for _ in 0..<5 { try await engine.refreshDigests() }
        #expect(harness.reads == before, "no transcript read inside the debounce")
        #expect(harness.requests.count == 1)

        harness.clock.advance(byMs: 30 * 60_000)
        try await engine.refreshDigests()
        #expect(harness.requests.count == 2)
    }

    // MARK: Cancellation

    /// The refresh runs in a serialization task that did not inherit the caller's cancellation,
    /// so a cancelled pass waited for the whole day's recap anyway.
    @Test func aCancelledRefreshStopsInsteadOfFinishingTheDay() async throws {
        let store = DailyRecapStore(db: try AppDatabase.inMemory())
        let segment = makeIntelligenceSegment(
            id: "seg-1", startTimeMs: atUtc(2026, 9, 22, 9, 0), transcribed: true)
        let engine = DailyRecapEngine(
            listSegments: { [segment] },
            transcriptTextOf: { _ in "We planned the launch." },
            store: store,
            run: { _ in
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return RoutedAiResult(
                    text: "late", modeUsed: .localOnly, providerId: "fake", modelUsed: nil,
                    inputTokens: nil, outputTokens: nil)
            },
            prompt: dailySummary,
            fallbackTimeZoneID: "UTC",
            nowMs: { atUtc(2026, 9, 22, 23, 0) })
        let started = ContinuousClock.now
        let refresh = Task { try await engine.refreshDigests() }
        try await Task.sleep(nanoseconds: 50_000_000)
        refresh.cancel()
        let outcome = await refresh.result
        #expect(ContinuousClock.now - started < .seconds(5))
        if case .success = outcome { Issue.record("expected the cancellation to surface") }
        #expect(try await store.load(dateKey: "2026-09-22") == nil)
    }

    // MARK: Who the day is sized for

    /// The provider that runs FIRST sizes the pieces: the on-device model's own figure in the
    /// local modes; the remote window (Private Cloud Compute reports one) or the model catalog
    /// in the remote ones.
    @Test func theFirstProviderInTheModeSizesTheDay() async throws {
        struct Silent: OnDeviceLanguageModel {
            let id = "silent"
            func availability() async -> OnDeviceAvailability { .available }
            func generate(instructions: String, prompt: String, maxOutputTokens: Int?)
                async throws -> String
            { "ok" }
        }
        let local = OnDeviceAiProvider(model: Silent())
        let openAi = OpenAiChatAiProvider(
            transport: NeverTransport(), apiKey: { "sk-x" }, remoteConsent: { true })

        let localFirst = AiModeRouter(local: local, remote: openAi, mode: { .localFirst })
        #expect(
            await localFirst.firstCallInputChars(remoteModelId: "gpt-5.6-luna")
                == OnDeviceAiProvider.defaultMaxInputChars)

        let remoteFirst = AiModeRouter(local: local, remote: openAi, mode: { .remoteFirst })
        #expect(
            await remoteFirst.firstCallInputChars(remoteModelId: "gpt-5.6-luna")
                == AskBudget.forModel(id: "gpt-5.6-luna").transcriptChars)
    }
}
