import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

@testable import Intelligence

// When a follow-up was said, on the wall clock (`sourceWall`), written where the quote is
// located and carried from candidate to follow-up by curation.
//
// The recording in these tests is ten minutes of wall time holding five minutes of audio: the
// watch withheld 60 s..360 s (one gap record of 300 s). The quote is spoken 120 s into the
// STORED audio, which is past the gap, so on the wall clock it was said at 420 s — five minutes
// later than the media offset reads. With the gap record present the clock is exact; without
// it the records do not account for the missing five minutes, the clock is inexact, and the
// offset is left on the media clock and marked approximate.

private final class OneAnswerProvider: AiProvider, @unchecked Sendable {
    let id = "one-answer"
    private let response: String
    init(response: String) { self.response = response }
    func isAvailable() async -> Bool { true }
    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        AiProviderResult(text: response, modelUsed: "scripted-model")
    }
}

@Suite struct FollowUpWallTimeTests {
    private let clock = TestWallClock(ms: 1_788_193_751_778)
    private let db: AppDatabase
    private let candidates: FollowUpCandidateStore
    private let followUps: FollowUpStore
    private let state: FollowUpExtractionStore

    /// The recording's first sample, on the wall clock.
    private static let startWallMs: Int64 = 1_788_193_000_000
    private static let rate: UInt64 = 16_000

    init() throws {
        let db = try AppDatabase.inMemory()
        self.db = db
        candidates = FollowUpCandidateStore(db: db)
        followUps = FollowUpStore(db: db)
        state = try FollowUpExtractionStore(db: db)
    }

    /// Ten minutes of wall time, five minutes of frames. `recordsTheGap` decides whether the
    /// missing five minutes are accounted for — which is all `SegmentMediaClock.isExact` asks.
    private func meta(_ segmentId: String, recordsTheGap: Bool) -> SegmentMeta {
        SegmentMeta(
            segmentId: segmentId, streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: UInt32(Self.rate), bitRateBps: 9_800,
            frameDurationMs: 20, startTimeMs: UInt64(Self.startWallMs), startMonotonicMs: 1,
            receivedAtMs: Self.startWallMs + 600_000,
            firstSampleIndex: 0, lastSampleIndexExclusive: 600 * Self.rate,
            frameCount: 15_000,
            gaps: recordsTheGap
                ? [
                    GapMeta(
                        firstMissingSequence: 3_000, missingFrameCount: 15_000,
                        firstMissingSampleIndex: 60 * Self.rate, origin: "watch")
                ] : [],
            closeReason: .rotated, transcriptionState: .complete)
    }

    private static let text =
        String(repeating: "We talked about the week and what is left to do. ", count: 5)
        + "I got to take Theo at 7:00. "
        + String(repeating: "Then the conversation moved on to other things. ", count: 5)

    private func transcript(_ segmentId: String, timed: Bool) -> SegmentTranscript {
        SegmentTranscript(
            segmentId: segmentId, text: Self.text, modeUsed: .localOnly, providerId: "local",
            createdAtMs: 0,
            segments: timed
                ? [
                    TranscriptSegment(
                        text: String(
                            repeating: "We talked about the week and what is left to do. ",
                            count: 5),
                        startMs: 0, endMs: 30_000, speaker: "1"),
                    TranscriptSegment(
                        text: "I got to take Theo at 7:00.", startMs: 120_000, endMs: 123_500,
                        speaker: "2"),
                    TranscriptSegment(
                        text: String(
                            repeating: "Then the conversation moved on to other things. ",
                            count: 5),
                        startMs: 200_000, endMs: 260_000, speaker: "1"),
                ] : [])
    }

    private static let oneItem = """
        {"items": [
          {"task": "Take Theo to the airport at 7:00",
           "quote": "I got to take Theo at 7:00.",
           "ifForgotten": "Theo misses his ride", "dueDate": "", "confidence": "high"}
        ]}
        """

    private func extract(recordsTheGap: Bool, timed: Bool = true) async throws -> FollowUpCandidate? {
        let clock = self.clock
        let worker = FollowUpWorker(
            candidates: candidates, state: state,
            router: AiModeRouter(
                local: OneAnswerProvider(response: Self.oneItem), remote: nil,
                mode: { .localOnly }),
            nowMs: { clock.now },
            timeZone: { TimeZone(identifier: "America/New_York")! })
        let conversation = EnrichmentConversation(
            conversationId: "conv-1", isOpen: false,
            members: [meta("seg-1788193000000-00000001-1", recordsTheGap: recordsTheGap)])
        let written = try await worker.extract(
            [conversation], transcriptOf: { self.transcript($0, timed: timed) })
        #expect(written == 1)
        return try await candidates.list(conversationId: "conv-1").first
    }

    // MARK: Extraction

    @Test func anExactClockPutsTheQuoteWhereItWasSaid() async throws {
        let candidate = try #require(try await extract(recordsTheGap: true))
        #expect(candidate.startMs == 120_000, "the media offset is unchanged")
        #expect(
            candidate.sourceWall
                == SegmentWallRange(
                    startMs: Self.startWallMs + 420_000, endMs: Self.startWallMs + 423_500,
                    isApproximate: false))
    }

    @Test func anInexactClockKeepsTheMediaOffsetAndSaysSo() async throws {
        let candidate = try #require(try await extract(recordsTheGap: false))
        #expect(
            candidate.sourceWall
                == SegmentWallRange(
                    startMs: Self.startWallMs + 120_000, endMs: Self.startWallMs + 123_500,
                    isApproximate: true))
    }

    /// No diarized turn to time the quote by: the recording is known, the moment is not, and no
    /// time is invented for it.
    @Test func aQuoteWithNoTimedTurnGetsNoWallTime() async throws {
        let candidate = try #require(try await extract(recordsTheGap: true, timed: false))
        #expect(candidate.segmentId == "seg-1788193000000-00000001-1")
        #expect(candidate.startMs == nil)
        #expect(candidate.sourceWall == nil)
    }

    /// The same helper `source(of:)` uses, so History and the player agree to the millisecond.
    @Test func theStoredTimeIsTheSharedHelpersAnswer() async throws {
        let candidate = try #require(try await extract(recordsTheGap: true))
        let meta = meta("seg-1788193000000-00000001-1", recordsTheGap: true)
        #expect(
            candidate.sourceWall
                == SegmentMediaClock.wallRange(ofMediaStartMs: 120_000, endMs: 123_500, in: meta))
    }

    // MARK: Curation

    @Test func curationCarriesTheWallTimeOntoTheFollowUp() async throws {
        let original = try #require(try await extract(recordsTheGap: false))
        let clock = self.clock
        let curator = FollowUpCurator(
            candidates: candidates, followUps: followUps,
            router: AiModeRouter(
                local: OneAnswerProvider(
                    response: """
                        {"decisions":[{"index":1,"decision":"keep","reason":"dated",
                        "task":"","priority":"normal","dueDate":""}]}
                        """),
                remote: nil, mode: { .localOnly }),
            nowMs: { clock.now },
            timeZone: { TimeZone(identifier: "America/New_York")! },
            titleOf: { _ in nil })
        let written = try await curator.curate()
        #expect(written.map(\.sourceWall) == [original.sourceWall])
        let stored = try #require(try await followUps.load(id: original.id))
        #expect(stored.sourceWall == original.sourceWall)
        #expect(stored.sourceWall?.isApproximate == true, "the flag travels with the times")
        #expect(stored.sourceStartMs == 120_000)
    }
}
