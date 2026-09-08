import AppDB
import Foundation
import Testing
import Transcription

@testable import Intelligence

// The optional semantic layer. What these pin, in order of how badly getting them wrong would
// hurt: it does nothing without a provider, it never splits on its own initiative, one call
// covers the whole batch, and every failure mode leaves the recording as one conversation.

private final class ScriptedBoundaryProvider: AiProvider, @unchecked Sendable {
    let id = "scripted"
    private let lock = NSLock()
    private var _response: String
    private var _error: Error?
    private var _requests: [AiRunRequest] = []
    private var _available = true

    init(response: String, error: Error? = nil, available: Bool = true) {
        _response = response
        _error = error
        _available = available
    }

    var response: String {
        get { lock.withLock { _response } }
        set { lock.withLock { _response = newValue } }
    }
    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    var requests: [AiRunRequest] { lock.withLock { _requests } }
    var runCount: Int { lock.withLock { _requests.count } }

    func isAvailable() async -> Bool { lock.withLock { _available } }

    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        let error: Error? = lock.withLock {
            _requests.append(request)
            return _error
        }
        if let error { throw error }
        return AiProviderResult(text: response, modelUsed: "scripted-model")
    }
}

private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

private func candidate(
    _ id: String, quietMinutes: Int64 = 12, lossFraction: Double = 0, atMs: Int64 = 1_000
) -> BoundaryCandidate {
    BoundaryCandidate(
        newStartSegmentId: id, previousEndSegmentId: "prev-\(id)", atMs: atMs,
        quietMs: quietMinutes * 60_000, lossFraction: lossFraction,
        lastSpokenSegmentId: "spoke-before-\(id)", nextSpokenSegmentId: "spoke-after-\(id)")
}

private func transcript(_ segmentId: String, _ text: String) -> SegmentTranscript {
    SegmentTranscript(
        segmentId: segmentId, text: text, modeUsed: .localOnly, providerId: "test",
        createdAtMs: 0)
}

private let texts: [String: String] = [
    "spoke-before-a": "and then we can ship it on Friday, I think.",
    "spoke-after-a": "Cuatro tacos, por favor. Y una cerveza.",
    "spoke-before-b": "so the migration is the last piece.",
    "spoke-after-b": "right, back to the migration then.",
]

private func router(_ provider: ScriptedBoundaryProvider) -> AiModeRouter {
    AiModeRouter(local: provider, remote: nil, mode: { .localOnly })
}

@Suite struct BoundaryReviewerTests {

    private func store() throws -> BoundaryReviewStore {
        BoundaryReviewStore(db: try AppDatabase.inMemory())
    }

    @Test func withNoRouterItDoesNothingAtAll() async throws {
        let reviews = try store()
        let reviewer = BoundaryReviewer(reviews: reviews, router: nil, nowMs: { 0 })
        let written = try await reviewer.review(candidates: [candidate("a")]) {
            BoundaryReviewer.context(for: $0, transcriptOf: { transcript($0, texts[$0] ?? "") })
        }
        #expect(written == 0)
        #expect(try await reviews.all().isEmpty)
    }

    @Test func withAnUnavailableProviderItDoesNothingAndRecordsNothing() async throws {
        let reviews = try store()
        let provider = ScriptedBoundaryProvider(response: "{}", available: false)
        let reviewer = BoundaryReviewer(
            reviews: reviews, router: router(provider), nowMs: { 0 })
        #expect(
            try await reviewer.review(candidates: [candidate("a")]) {
                BoundaryReviewer.context(for: $0, transcriptOf: { transcript($0, texts[$0] ?? "") })
            } == 0)
        #expect(provider.runCount == 0)
    }

    @Test func oneCallCarriesTheWholeBatchAndBothVerdictsAreStored() async throws {
        let reviews = try store()
        let provider = ScriptedBoundaryProvider(
            response: """
                {"boundaries":[
                  {"id":"a","newConversation":true,"reason":"different people, different language"},
                  {"id":"b","newConversation":false}
                ]}
                """)
        let reviewer = BoundaryReviewer(
            reviews: reviews, router: router(provider), nowMs: { 42 })
        let candidates = [candidate("a"), candidate("b")]
        let written = try await reviewer.review(candidates: candidates) {
            BoundaryReviewer.context(for: $0, transcriptOf: { transcript($0, texts[$0] ?? "") })
        }
        #expect(written == 2)
        #expect(provider.runCount == 1)

        let stored = try await reviews.all()
        #expect(stored["a"]?.isBoundary == true)
        #expect(stored["a"]?.reason == "different people, different language")
        #expect(stored["b"]?.isBoundary == false)
        // A "same conversation" verdict carries no reason: there is nothing to explain.
        #expect(stored["b"]?.reason == nil)
        #expect(stored["a"]?.createdAtMs == 42)

        // Only the confirmed one becomes a split, and only for the quiet it was judged on.
        #expect(try await reviews.splits(matching: candidates) == ["a"])
        // And it is not asked about again.
        #expect(try await reviews.unreviewed(candidates).isEmpty)
    }

    @Test func theRequestCarriesTheWordsEitherSideAndHowLongTheSilenceWas() async throws {
        let reviews = try store()
        let provider = ScriptedBoundaryProvider(response: #"{"boundaries":[]}"#)
        let reviewer = BoundaryReviewer(
            reviews: reviews, router: router(provider), nowMs: { 0 })
        _ = try await reviewer.review(candidates: [candidate("a", quietMinutes: 14)]) {
            BoundaryReviewer.context(for: $0, transcriptOf: { transcript($0, texts[$0] ?? "") })
        }
        let body = provider.requests[0].transcripts[0].text
        #expect(body.contains("14 minutes with nothing said"))
        #expect(body.contains("ship it on Friday"))
        #expect(body.contains("Cuatro tacos"))
        // Structured output is demanded, so a provider that cannot enforce a schema refuses
        // rather than answering in prose (the lesson `requiresStructuredOutput` exists for).
        #expect(provider.requests[0].metadata[AiRunRequest.requiresStructuredOutputKey] == "1")
    }

    @Test func aStretchThatIsMostlyMissingAudioIsDescribedAsSuch() async throws {
        let reviews = try store()
        let provider = ScriptedBoundaryProvider(response: #"{"boundaries":[]}"#)
        let reviewer = BoundaryReviewer(
            reviews: reviews, router: router(provider), nowMs: { 0 })
        _ = try await reviewer.review(candidates: [candidate("a", lossFraction: 0.9)]) {
            BoundaryReviewer.context(for: $0, transcriptOf: { transcript($0, texts[$0] ?? "") })
        }
        #expect(
            provider.requests[0].transcripts[0].text
                .contains("most of it audio the app never received"))
    }

    @Test func aFailedOrUnparseableCallLeavesTheRecordingWhole() async throws {
        let reviews = try store()
        let provider = ScriptedBoundaryProvider(response: "", error: Boom())
        let reviewer = BoundaryReviewer(
            reviews: reviews, router: router(provider), nowMs: { 0 })
        let read: (BoundaryCandidate) -> BoundaryReviewContext? = {
            BoundaryReviewer.context(for: $0, transcriptOf: { transcript($0, texts[$0] ?? "") })
        }
        #expect(try await reviewer.review(candidates: [candidate("a")], contextFor: read) == 0)
        // Nothing recorded ⇒ nothing stuck: the next pass asks again.
        #expect(try await reviews.all().isEmpty)
        #expect(try await reviews.unreviewed([candidate("a")]).count == 1)

        provider.error = nil
        provider.response = "I think the second one is a new conversation, probably."
        #expect(try await reviewer.review(candidates: [candidate("a")], contextFor: read) == 0)
        #expect(try await reviews.all().isEmpty)
    }

    @Test func aVerdictForAnIdNobodyAskedAboutIsDiscarded() async throws {
        let reviews = try store()
        let provider = ScriptedBoundaryProvider(
            response: #"{"boundaries":[{"id":"somewhere-else","newConversation":true}]}"#)
        let reviewer = BoundaryReviewer(
            reviews: reviews, router: router(provider), nowMs: { 0 })
        #expect(
            try await reviewer.review(candidates: [candidate("a")]) {
                BoundaryReviewer.context(for: $0, transcriptOf: { transcript($0, texts[$0] ?? "") })
            } == 0)
        #expect(try await reviews.all().isEmpty)
    }

    @Test func aCandidateWithNothingToReadIsNotSentAtAll() async throws {
        let reviews = try store()
        let provider = ScriptedBoundaryProvider(response: #"{"boundaries":[]}"#)
        let reviewer = BoundaryReviewer(
            reviews: reviews, router: router(provider), nowMs: { 0 })
        #expect(
            try await reviewer.review(candidates: [candidate("a")], contextFor: { _ in nil }) == 0)
        #expect(provider.runCount == 0)
    }

    @Test func theContextPrefersTheMembersThatActuallyHoldWords() {
        // A candidate's silence usually swallows whole rotations, so the members touching the
        // join have no text. Reading them instead of the members holding the surrounding speech
        // would have handed the model two empty strings.
        let subject = candidate("a")
        let context = BoundaryReviewer.context(for: subject) { id in
            id == "prev-a" || id == "a" ? transcript(id, "") : transcript(id, texts[id] ?? "")
        }
        #expect(context?.before.contains("ship it on Friday") == true)
        #expect(context?.after.contains("Cuatro tacos") == true)
    }

    @Test func theParserTakesJsonOutOfProseAndFences() {
        let fenced = """
            Sure — here you go:
            ```json
            {"boundaries":[{"id":"x","newConversation":true,"reason":"new people"}]}
            ```
            """
        #expect(
            BoundaryVerdictParser.parse(raw: fenced)
                == [BoundaryVerdictParser.Verdict(id: "x", isBoundary: true, reason: "new people")])
        #expect(BoundaryVerdictParser.parse(raw: "no json here") == nil)
        // An empty but well-formed answer is a valid answer: nothing is a boundary.
        #expect(BoundaryVerdictParser.parse(raw: #"{"boundaries":[]}"#) == [])
    }
}
