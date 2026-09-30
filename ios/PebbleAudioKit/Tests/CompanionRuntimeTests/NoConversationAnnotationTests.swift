import AppDB
import Foundation
import Intelligence
import SegmentStore
import Testing
import Transcription

@testable import CompanionRuntime

/// A conversation that holds no conversation is not the AI's to title (Roger, 2026-09-30:
/// "Brief Mention of Weather", five words after a long quiet stretch).
@Suite("no-conversation annotations")
struct NoConversationAnnotationTests {
    final class CountingProvider: AiProvider, @unchecked Sendable {
        let id = "counting"
        let lock = NSLock()
        var runs = 0
        func isAvailable() async -> Bool { true }
        func run(_ request: AiRunRequest) async throws -> AiProviderResult {
            lock.withLock { runs += 1 }
            return AiProviderResult(text: "TITLE: The roof\nSUMMARY: About the roof.\nTAGS: roof")
        }
    }

    private func enrichment(
        _ fixture: RuntimeFixture, provider: CountingProvider, mask: AudioContentMask,
        transcript: @escaping @Sendable (String) -> SegmentTranscript?
    ) throws -> EnrichmentService {
        let clock = fixture.clock
        return EnrichmentService(
            worker: EnrichmentWorker(
                annotations: fixture.annotations,
                router: AiModeRouter(local: provider, remote: nil, mode: { .localOnly }),
                nowMs: { clock.nowMs }),
            followUps: FollowUpWorker(
                candidates: FollowUpCandidateStore(db: fixture.database),
                state: try FollowUpExtractionStore(db: fixture.database),
                router: nil, nowMs: { clock.nowMs }),
            curator: FollowUpCurator(
                candidates: FollowUpCandidateStore(db: fixture.database),
                followUps: FollowUpStore(db: fixture.database), router: nil,
                nowMs: { clock.nowMs }),
            annotations: fixture.annotations,
            store: fixture.store,
            database: fixture.database,
            pauseJournal: fixture.pauseJournal,
            transcriptOf: transcript,
            liveTextOf: { _ in nil },
            clock: clock,
            audioContentMask: mask,
            audioContentStore: AudioContentStore(db: fixture.database))
    }

    @Test("it gets a plain stand-in instead of an AI title, and is handed back once it holds talk")
    func standInThenWithdrawn() async throws {
        let fixture = try RuntimeFixture()
        let segmentId = try await Fixture.writeSegment(into: fixture.store, frames: 3_000)
        try await fixture.store.updateTranscriptionState(segmentId, .complete)
        let provider = CountingProvider()
        let mask = AudioContentMask()
        let words = String(repeating: "and then we talked about the roof and the gutters. ", count: 20)
        let transcript = SegmentTranscript(
            segmentId: segmentId, text: words, modeUsed: .localOnly, providerId: "fake",
            createdAtMs: 1)
        let enrichment = try enrichment(fixture, provider: provider, mask: mask) { _ in transcript }
        try await enrichment.regroupPass()

        // Classified as holding no conversation: a stand-in, no AI call.
        mask.setHolds(segmentId, false)
        let changed = try await enrichment.enrichPass()
        #expect(changed.count == 1)
        let standIn = try #require(try await fixture.annotations.load(changed[0]))
        #expect(standIn.title == AudioContentPresentation.noConversationTitle)
        #expect(standIn.providerId == AudioContentPresentation.providerId)
        #expect(standIn.tags.isEmpty && standIn.isFinal)
        #expect(provider.lock.withLock { provider.runs } == 0)
        // Settled: a second pass changes nothing and calls nothing.
        #expect(try await enrichment.enrichPass().isEmpty)
        #expect(provider.lock.withLock { provider.runs } == 0)

        // A correction (or a new transcript) says it holds talk: the stand-in goes and the AI
        // titles it.
        mask.setHolds(segmentId, true)
        let retitled = try await enrichment.enrichPass()
        #expect(retitled.contains(changed[0]))
        #expect(provider.lock.withLock { provider.runs } == 1)
        #expect(try await fixture.annotations.load(changed[0])?.title == "The roof")
    }

    @Test("an unclassified member keeps the conversation with the AI, as before")
    func unclassifiedIsUntouched() async throws {
        let fixture = try RuntimeFixture()
        let segmentId = try await Fixture.writeSegment(into: fixture.store, frames: 3_000)
        try await fixture.store.updateTranscriptionState(segmentId, .complete)
        let provider = CountingProvider()
        let words = String(repeating: "and then we talked about the roof and the gutters. ", count: 20)
        let transcript = SegmentTranscript(
            segmentId: segmentId, text: words, modeUsed: .localOnly, providerId: "fake",
            createdAtMs: 1)
        let enrichment = try enrichment(fixture, provider: provider, mask: AudioContentMask()) { _ in
            transcript
        }
        try await enrichment.regroupPass()
        let changed = try await enrichment.enrichPass()
        #expect(changed.count == 1)
        #expect(try await fixture.annotations.load(changed[0])?.title == "The roof")
    }

    @Test("the stand-in names what was heard only when every worded stretch agrees")
    func standInSummary() {
        func span(_ descriptor: String?, words: Int, by decider: String) -> SegmentAudioContentSpan {
            SegmentAudioContentSpan(
                segmentId: "s", index: 0, startMs: 0, endMs: 60_000, mediaStartMs: 0,
                mediaEndMs: 60_000, kind: .noConversation, descriptor: descriptor,
                confidence: 0.95, decidedBy: decider, version: 3, wordCount: words)
        }
        let quiet = span(nil, words: 0, by: AudioContentDecider.noSpeech)
        let few = span(AudioContentDescriptor.fewWords, words: 5, by: AudioContentDecider.wordRate)
        let music = span(AudioContentDescriptor.music, words: 180, by: AudioContentDecider.contentJudge)
        let tv = span(nil, words: 400, by: AudioContentDecider.contentJudge)
        typealias P = AudioContentPresentation
        #expect(P.summary(for: [quiet]) == P.noWordsSummary)
        #expect(P.summary(for: [quiet, few]) == P.fewWordsSummary)
        #expect(P.summary(for: [quiet, music, music]) == P.musicSummary)
        // An hour of television is not "a few words", and it is not named.
        #expect(P.summary(for: [tv]) == P.otherSummary)
        #expect(P.summary(for: [music, few]) == P.otherSummary)
    }
}
