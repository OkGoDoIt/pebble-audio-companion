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

    /// A barely-shorter answer is refused however long the source is: the ceiling scales, the
    /// "meaningfully shorter" rule does not.
    @Test func anAnswerThatBarelyShortensAMonsterDigestIsRefused() {
        let source = String(repeating: "x", count: 2000)
        let short = String(repeating: "y", count: 1_400)  // 70% — under the ratio, over half
        #expect(!RecapCondenser.isUsable(short, source: source))
    }

    /// The ceiling is `mediumParagraphCharacters` OR half the source, whichever is larger. A
    /// flat 520 refused a 60% cut of a runaway digest — and, because a refusal stamps the day
    /// as attempted, left that day showing the essay for good.
    @Test func aBigCutOfARunawayDigestIsAcceptedEvenAboveTheMediumParagraphBound() {
        let source = String(repeating: "x", count: 2000)
        let short = String(repeating: "y", count: 800)
        #expect(short.count > RecapCondenser.mediumParagraphCharacters)
        #expect(RecapCondenser.isUsable(short, source: source))
    }

    /// An ordinary digest keeps the flat bound: half of 700 is 350, and the medium paragraph is
    /// the floor, so a 600-character "shortening" of it is still refused.
    @Test func anOrdinaryDigestKeepsTheMediumParagraphFloor() {
        let source = String(repeating: "x", count: 700)
        #expect(!RecapCondenser.isUsable(String(repeating: "y", count: 600), source: source))
        #expect(RecapCondenser.isUsable(String(repeating: "y", count: 400), source: source))
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

    /// The candidate query took the eight newest long days whatever their state, so once eight
    /// were condensed the older ones were never offered again (09-05, 09-07…09-10 in the backup).
    @Test func condensedDaysDoNotHideOlderOnesFromTheCondensePass() async throws {
        let store = DailyRecapStore(db: try AppDatabase.inMemory())
        let long = String(repeating: "A long afternoon went into the redesign. ", count: 20)
        for day in 1...10 {
            let key = String(format: "2026-09-%02d", day)
            try await store.save(DailyRecap(dateKey: key, text: long + key))
            if day > 2 {
                try await store.saveCondensation(
                    dateKey: key, sourceText: long + key, shortText: "Short.")
            }
        }
        let candidates = try await store.longestFirstCandidates(
            minCharacters: RecapCondenser.mediumParagraphCharacters,
            limit: DailyRecapEngine.condensationCandidateDepth)
        #expect(candidates.map(\.dateKey) == ["2026-09-02", "2026-09-01"])
    }

    /// End to end: ten long days, the newest eight already condensed — the pass reaches the
    /// two older ones instead of stopping at the eight it has already done.
    @Test func theCondensePassReachesOlderLongDays() async throws {
        let harness = CondenseHarness()
        let (engine, store) = try makeEngine(harness)
        for day in 1...10 {
            let key = String(format: "2026-08-%02d", day)
            try await store.save(DailyRecap(dateKey: key, text: longDigest(key)))
            if day > 2 {
                try await store.saveCondensation(
                    dateKey: key, sourceText: longDigest(key), shortText: "Short.")
            }
        }
        harness.queueCondenseReply("Short enough.")
        harness.queueCondenseReply("Short enough.")
        try await engine.refreshDigests()
        #expect(try await store.load(dateKey: "2026-08-02")?.shortText == "Short enough.")
        #expect(try await store.load(dateKey: "2026-08-01")?.shortText == "Short enough.")
    }
}

/// The condense prompt used to ask for "about 60 words" with no limit while the acceptance rule
/// refused anything over `max(520, source / 2)` or 0.75× the source — the model aimed at one
/// number and was judged against another, and ~43% of condensations were refused.
@Suite struct RecapCondensePromptTests {
    @Test func thePromptStatesTheExactCeilingTheAnswerIsJudgedAgainst() {
        for source in [600, 1_000, 1_900, 4_000] {
            let ceiling = RecapCondenser.acceptanceCeiling(sourceCharacters: source)
            let prompt = RecapCondenser.prompt(forSourceCharacters: source)
            #expect(prompt.systemPrompt.contains("HARD LIMIT: \(ceiling) characters"))
            #expect(prompt.id == RecapCondenser.prompt.id)
            // The ceiling IS the acceptance rule: an answer at it is usable, one past it is not.
            let sourceText = String(repeating: "x", count: source)
            #expect(
                RecapCondenser.isUsable(String(repeating: "y", count: ceiling), source: sourceText))
            #expect(
                !RecapCondenser.isUsable(
                    String(repeating: "y", count: ceiling + 1), source: sourceText))
        }
    }

    @Test func theCondenseCallCarriesTheCeilingForItsOwnDigest() async throws {
        let digest = longDigest()
        let box = RequestBox()
        _ = try await RecapCondenser.condense(
            DailyRecap(dateKey: "2026-08-30", text: digest),
            run: { request in
                box.set(request)
                return RoutedAiResult(
                    text: "Short.", modeUsed: .localOnly, providerId: "fake", modelUsed: nil,
                    inputTokens: nil, outputTokens: nil)
            },
            nowMs: 0)
        let ceiling = RecapCondenser.acceptanceCeiling(
            sourceCharacters: RecapCondenser.normalized(digest).count)
        #expect(box.request?.prompt.systemPrompt.contains("HARD LIMIT: \(ceiling) characters") == true)
    }
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _request: AiRunRequest?
    var request: AiRunRequest? { lock.withLock { _request } }
    func set(_ request: AiRunRequest) { lock.withLock { _request = request } }
}
