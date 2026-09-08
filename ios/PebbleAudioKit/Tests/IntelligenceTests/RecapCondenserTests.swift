import AppDB
import Foundation
import Testing

@testable import Intelligence

// The condensed Today recap (session: "the 'today so far' section sometimes gets pretty long").
//
// Two things are being pinned here, and they are the two ways this feature can go wrong:
//
//   • THE THRESHOLD. A short digest must cost no second AI call at all, and a condensation
//     that is not meaningfully shorter must be refused rather than shown — a "summary" the
//     same height as its source is the original with facts missing.
//   • THE CACHE. The pass runs once per digest, keyed on a fingerprint of that digest, so a
//     pipeline pass every few seconds does not become an AI call every few seconds — and a
//     REGENERATED digest can never keep the summary of the text it replaced.

/// Segment-free engine harness: these suites drive the condense pass over digests that are
/// already in the store, so nothing needs a spool.
private final class CondenseHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _digestReplies: [String] = []
    private var _condenseReplies: [String] = []
    private var _requests: [AiRunRequest] = []
    private var _failCondense = false

    let clock = TestWallClock(ms: atUtc(2026, 8, 30, 12, 0))

    var requests: [AiRunRequest] { lock.withLock { _requests } }
    var condenseRequests: [AiRunRequest] {
        requests.filter { $0.prompt.id == RecapCondenser.prompt.id }
    }

    func queueCondenseReply(_ text: String) {
        lock.withLock { _condenseReplies.append(text) }
    }

    func failCondense(_ value: Bool) { lock.withLock { _failCondense = value } }

    func run(_ request: AiRunRequest) throws -> RoutedAiResult {
        try lock.withLock {
            _requests.append(request)
            if request.prompt.id == RecapCondenser.prompt.id {
                if _failCondense { throw AiError.providerUnavailable(providerId: "fake") }
                let reply = _condenseReplies.isEmpty ? "Short." : _condenseReplies.removeFirst()
                return result(reply)
            }
            let reply = _digestReplies.isEmpty ? "Digest." : _digestReplies.removeFirst()
            return result(reply)
        }
    }

    private func result(_ text: String) -> RoutedAiResult {
        RoutedAiResult(
            text: text, modeUsed: .localOnly, providerId: "fake", modelUsed: "fake-model",
            inputTokens: nil, outputTokens: nil)
    }
}

/// A digest comfortably over `mediumParagraphCharacters`, in the shape a real overrun takes.
private func longDigest(_ marker: String = "A") -> String {
    let sentence =
        "\(marker) long stretch of the afternoon went into the redesign, and the conversation "
        + "kept circling back to how the onboarding should read. "
    return String(repeating: sentence, count: 5)
}

private let shortDigest = "Quiet morning. You worked through the redesign after lunch."

@Suite struct RecapCondenserThresholdTests {

    @Test func aDigestTheLengthTheDigestPromptAsksForIsLeftAlone() {
        #expect(!RecapCondenser.needsCondensing(shortDigest))
        // Right at the shape `AiPromptTemplates.dailySummary` asks for: four concise sentences.
        let fourSentences = String(repeating: "Something happened at about that time today. ", count: 4)
        #expect(fourSentences.count < RecapCondenser.mediumParagraphCharacters)
        #expect(!RecapCondenser.needsCondensing(fourSentences))
    }

    @Test func aDigestThatOverranIsCondensed() {
        #expect(longDigest().count > RecapCondenser.mediumParagraphCharacters)
        #expect(RecapCondenser.needsCondensing(longDigest()))
    }

    @Test func lineBreaksDoNotCountTowardsTheThreshold() {
        // Measured by what it says, not how it was wrapped: a digest padded to the threshold
        // with newlines is still a short digest.
        let padded = shortDigest + String(repeating: "\n", count: 600)
        #expect(!RecapCondenser.needsCondensing(padded))
    }

    @Test func aCondensationThatIsNotShorterIsRefused() {
        let source = longDigest()
        // Same text back: the classic "shortened" answer that shortens nothing.
        #expect(!RecapCondenser.isUsable(source, source: source))
        // Barely shorter — still a wall of text, so the card keeps the original.
        let barely = String(source.prefix(Int(Double(source.count) * 0.9)))
        #expect(!RecapCondenser.isUsable(barely, source: source))
    }

    @Test func aCondensationInsideTheMediumParagraphBoundIsAccepted() {
        let source = longDigest()
        let short = "Redesign work all afternoon; the onboarding wording is still open."
        #expect(RecapCondenser.isUsable(short, source: source))
    }

    @Test func anEmptyAnswerIsNeverUsable() {
        #expect(!RecapCondenser.isUsable("   \n ", source: longDigest()))
    }

    @Test func aShortAnswerThatIsStillOverTheBoundIsRefused() {
        // 40% shorter, but still longer than a medium paragraph: it would not fix the card.
        let source = String(repeating: "x", count: 2000)
        let short = String(repeating: "y", count: 800)
        #expect(Double(short.count) <= Double(source.count) * RecapCondenser.minimumShorteningRatio)
        #expect(!RecapCondenser.isUsable(short, source: source))
    }
}

@Suite struct RecapCondenserCacheTests {

    @Test func theFingerprintIsStableAndTextSensitive() {
        let text = longDigest()
        #expect(RecapCondenser.fingerprint(text) == RecapCondenser.fingerprint(text))
        #expect(RecapCondenser.fingerprint(text) != RecapCondenser.fingerprint(text + "."))
        #expect(RecapCondenser.fingerprint("") != RecapCondenser.fingerprint(" "))
    }

    @Test func aStoredCondensationIsShownOnlyForTheDigestItWasMadeFrom() {
        let text = longDigest()
        let matched = DailyRecap(
            dateKey: "2026-08-30", text: text, shortText: "Short.",
            shortOfHash: RecapCondenser.fingerprint(text))
        #expect(RecapCondenser.condensation(of: matched) == "Short.")

        // The digest was regenerated and the short form was not cleared: showing it would put
        // a summary of superseded text on the card with nothing on screen saying so.
        var stale = matched
        stale.text = longDigest("B")
        #expect(RecapCondenser.condensation(of: stale) == nil)
    }

    @Test func aCompletedAttemptThatProducedNothingIsNotRetried() {
        let text = longDigest()
        let attempted = DailyRecap(
            dateKey: "2026-08-30", text: text, shortText: nil,
            shortOfHash: RecapCondenser.fingerprint(text))
        #expect(!RecapCondenser.needsPass(attempted))
        #expect(RecapCondenser.condensation(of: attempted) == nil)
    }

    @Test func aShortDigestNeverNeedsAPass() {
        #expect(!RecapCondenser.needsPass(DailyRecap(dateKey: "2026-08-30", text: shortDigest)))
    }

    @Test func aRegeneratedDigestNeedsAFreshPass() {
        let text = longDigest()
        var recap = DailyRecap(
            dateKey: "2026-08-30", text: text, shortText: "Short.",
            shortOfHash: RecapCondenser.fingerprint(text))
        #expect(!RecapCondenser.needsPass(recap))
        recap.text = longDigest("B")
        #expect(RecapCondenser.needsPass(recap))
    }
}

@Suite struct RecapCondensationPassTests {
    private func makeEngine(_ harness: CondenseHarness) throws -> (DailyRecapEngine, DailyRecapStore) {
        let db = try AppDatabase.inMemory()
        let store = DailyRecapStore(db: db, nowMs: { harness.clock.now })
        let engine = DailyRecapEngine(
            listSegments: { [] },
            transcriptTextOf: { _ in nil },
            store: store,
            run: { try harness.run($0) },
            prompt: AiPromptTemplate(
                id: "daily-summary", title: "Daily Summary",
                systemPrompt: "Summarize the day.", userPrompt: "Use transcripts."),
            fallbackTimeZoneID: "UTC",
            nowMs: { harness.clock.now })
        return (engine, store)
    }

    @Test func aLongDigestIsCondensedOnceAndThenLeftAlone() async throws {
        let harness = CondenseHarness()
        let (engine, store) = try makeEngine(harness)
        let text = longDigest()
        try await store.save(DailyRecap(dateKey: "2026-08-30", text: text))
        harness.queueCondenseReply("Redesign all afternoon; onboarding wording still open.")

        try await engine.refreshDigests()
        #expect(harness.condenseRequests.count == 1)
        let saved = try await store.load(dateKey: "2026-08-30")
        #expect(saved?.shortText == "Redesign all afternoon; onboarding wording still open.")
        #expect(saved?.shortOfHash == RecapCondenser.fingerprint(text))
        // The digest itself is untouched — the pushed detail and the index still hold it whole.
        #expect(saved?.text == text)
        #expect(RecapCondenser.condensation(of: saved!) != nil)

        // The pipeline runs this pass every few seconds. It must not become an AI call every
        // few seconds.
        try await engine.refreshDigests()
        try await engine.refreshDigests()
        #expect(harness.condenseRequests.count == 1)
    }

    @Test func aShortDigestIsNeverSentToTheModel() async throws {
        let harness = CondenseHarness()
        let (engine, store) = try makeEngine(harness)
        try await store.save(DailyRecap(dateKey: "2026-08-30", text: shortDigest))

        try await engine.refreshDigests()

        #expect(harness.condenseRequests.isEmpty)
        #expect(try await store.load(dateKey: "2026-08-30")?.shortOfHash == nil)
    }

    @Test func regeneratingTheDigestClearsItsShortFormAndCondensesAgain() async throws {
        let harness = CondenseHarness()
        let (engine, store) = try makeEngine(harness)
        try await store.save(DailyRecap(dateKey: "2026-08-30", text: longDigest()))
        harness.queueCondenseReply("First short form.")
        try await engine.refreshDigests()
        #expect(try await store.load(dateKey: "2026-08-30")?.shortText == "First short form.")

        // What `DailyRecapEngine.performRefresh` does when a late transcript lands: it saves a
        // freshly built `DailyRecap`, which carries no short form.
        let newText = longDigest("B")
        try await store.save(DailyRecap(dateKey: "2026-08-30", text: newText))
        #expect(try await store.load(dateKey: "2026-08-30")?.shortText == nil)

        harness.queueCondenseReply("Second short form.")
        try await engine.refreshDigests()
        let saved = try await store.load(dateKey: "2026-08-30")
        #expect(saved?.shortText == "Second short form.")
        #expect(saved?.shortOfHash == RecapCondenser.fingerprint(newText))
        #expect(harness.condenseRequests.count == 2)
    }

    @Test func anAnswerThatIsNotShorterIsRecordedAsAnAttemptAndNotRetried() async throws {
        let harness = CondenseHarness()
        let (engine, store) = try makeEngine(harness)
        let text = longDigest()
        try await store.save(DailyRecap(dateKey: "2026-08-30", text: text))
        harness.queueCondenseReply(text)  // the model handed the digest straight back

        try await engine.refreshDigests()
        let saved = try await store.load(dateKey: "2026-08-30")
        #expect(saved?.shortText == nil, "an answer that is not shorter is never shown")
        #expect(saved?.shortOfHash == RecapCondenser.fingerprint(text), "but it IS an attempt")

        try await engine.refreshDigests()
        #expect(harness.condenseRequests.count == 1)
    }

    @Test func aProviderFailureLeavesTheDayRetryable() async throws {
        let harness = CondenseHarness()
        let (engine, store) = try makeEngine(harness)
        try await store.save(DailyRecap(dateKey: "2026-08-30", text: longDigest()))
        harness.failCondense(true)

        try await engine.refreshDigests()
        // Nothing stamped: an afternoon without connectivity must not strand the day on its
        // long form forever.
        #expect(try await store.load(dateKey: "2026-08-30")?.shortOfHash == nil)

        harness.failCondense(false)
        harness.queueCondenseReply("It worked the second time.")
        try await engine.refreshDigests()
        #expect(try await store.load(dateKey: "2026-08-30")?.shortText == "It worked the second time.")
    }

    @Test func aCondensationIsNeverWrittenOverANewerDigest() async throws {
        // The guard inside `saveCondensation`: the AI call is slow, and a late transcript can
        // regenerate the digest while it is in flight.
        let db = try AppDatabase.inMemory()
        let store = DailyRecapStore(db: db)
        let original = longDigest()
        try await store.save(DailyRecap(dateKey: "2026-08-30", text: original))
        try await store.save(DailyRecap(dateKey: "2026-08-30", text: longDigest("B")))

        try await store.saveCondensation(
            dateKey: "2026-08-30", sourceText: original, shortText: "Summary of the OLD text.")

        let saved = try await store.load(dateKey: "2026-08-30")
        #expect(saved?.shortText == nil)
        #expect(saved?.text == longDigest("B"))
    }

    @Test func onlyABoundedNumberOfDaysAreCondensedPerPass() async throws {
        // A freshly migrated library is due for every long day it holds. This pass runs inline
        // in the processing pass, so it drains newest-day-first instead of monopolising it.
        let harness = CondenseHarness()
        let (engine, store) = try makeEngine(harness)
        for day in ["2026-08-26", "2026-08-27", "2026-08-28", "2026-08-29", "2026-08-30"] {
            try await store.save(DailyRecap(dateKey: day, text: longDigest()))
        }
        for _ in 0..<5 { harness.queueCondenseReply("Short enough.") }

        try await engine.refreshDigests()
        #expect(harness.condenseRequests.count == DailyRecapEngine.defaultMaxCondensationsPerRefresh)
        // Newest first, so the day a person is actually looking at is fixed on the first pass.
        #expect(try await store.load(dateKey: "2026-08-30")?.shortText == "Short enough.")
        #expect(try await store.load(dateKey: "2026-08-26")?.shortText == nil)

        try await engine.refreshDigests()
        try await engine.refreshDigests()
        #expect(try await store.load(dateKey: "2026-08-26")?.shortText == "Short enough.")
    }
}
