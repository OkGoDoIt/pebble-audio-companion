import AppDB
import Foundation
import Intelligence
import SegmentStore
import Testing
import Transcription

@testable import CompanionRuntime

/// A launch with no new audio changes no conversation.
///
/// G17, 2026-10-23 to 10-26: nearly every relaunch logged "conversations reconciled: 17
/// superseded", "withdrew 41 titles written about other audio", then "9 superseded" a few
/// seconds later, and queued an archive batch of a couple of hundred items. The first regroup
/// of a launch came from the Spotlight donation (`grouping()` with nothing cached), before the
/// pipeline's first audio-content pass had read the saved verdicts back into the mask; grouped
/// without the mask, transcriber loops and lyrics counted as speech and the conversations they
/// decide were cut differently, then cut back once the mask was loaded. Replayed on the
/// 2026-10-26 16:45 backup: 18 superseded, then 9.
@Suite("launch regroup")
struct LaunchRegroupTests {
    final class NoProvider: AiProvider, @unchecked Sendable {
        let id = "none"
        func isAvailable() async -> Bool { false }
        func run(_ request: AiRunRequest) async throws -> AiProviderResult {
            throw AiError.providerUnavailable(providerId: "none")
        }
    }

    /// Thirty minutes: five of talk, twenty of the transcriber repeating itself, five of talk.
    static func talkLoopTalk() -> [Transcription.TranscriptSegment] {
        var turns: [Transcription.TranscriptSegment] = []
        func talk(_ minute: Int) {
            for part in 0..<4 {
                let start = Int64(minute) * 60_000 + Int64(part) * 15_000
                turns.append(
                    Transcription.TranscriptSegment(
                        text: (0..<25).map { "m\(minute)p\(part)w\($0)" }.joined(separator: " "),
                        startMs: start, endMs: start + 12_000))
            }
        }
        for minute in 0..<5 { talk(minute) }
        for minute in 5..<25 {
            turns.append(
                Transcription.TranscriptSegment(
                    text: Array(repeating: "Yeah.", count: 400).joined(separator: " "),
                    startMs: Int64(minute) * 60_000, endMs: Int64(minute) * 60_000 + 60_000))
        }
        for minute in 25..<30 { talk(minute) }
        return turns
    }

    /// One launch's services, wired as `AppComposition` wires them: a fresh mask, an
    /// audio-content service reading the shared store, and the enrichment service that groups.
    private func launch(
        _ fixture: RuntimeFixture, turns: [Transcription.TranscriptSegment]
    ) throws -> (audioContent: AudioContentService, enrichment: EnrichmentService) {
        let clock = fixture.clock
        let store = fixture.store
        let audioContent = AudioContentService(
            listSegments: { await store.listSegments() },
            speechTimingsOf: { _ in turns },
            transcriptVersionOf: { _ in "v1" },
            store: AudioContentStore(db: fixture.database),
            nowMs: { clock.nowMs })
        let provider = NoProvider()
        let enrichment = EnrichmentService(
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
            store: store,
            database: fixture.database,
            pauseJournal: fixture.pauseJournal,
            transcriptOf: { id in
                SegmentTranscript(
                    segmentId: id, text: turns.map(\.text).joined(separator: " "),
                    modeUsed: .localOnly, providerId: "fake", createdAtMs: 1, segments: turns)
            },
            liveTextOf: { _ in nil },
            speechTimingsOf: { _ in turns },
            clock: clock,
            audioContentMask: audioContent.mask,
            audioContentStore: AudioContentStore(db: fixture.database),
            loadAudioContent: { try await audioContent.loadSaved() })
        return (audioContent, enrichment)
    }

    private func stored(_ fixture: RuntimeFixture) async throws -> [GroupedConversation] {
        try await fixture.database.reader.read { try ConversationGrouper.fetchAll($0) }
    }

    @Test("the first regroup of a launch, wherever it comes from, keeps the stored grouping")
    func relaunchKeepsTheGrouping() async throws {
        let fixture = try RuntimeFixture()
        // Received as it was recorded, and grouped an hour later.
        await fixture.clock.advance(by: 1_756_512_000_000 + 30 * 60_000)
        let segmentId = try await Fixture.writeSegment(into: fixture.store, frames: 90_000)
        await fixture.clock.advance(by: 3_600_000)
        try await fixture.store.updateTranscriptionState(segmentId, .complete)
        let turns = Self.talkLoopTalk()

        // The session before: classified, then grouped, as the pipeline orders them.
        let before = try launch(fixture, turns: turns)
        #expect(try await before.audioContent.classifyPass())
        #expect(!before.audioContent.mask.speechRanges(segmentId).isEmpty)
        try await before.enrichment.regroupPass()
        let grouping = try await stored(fixture)
        // The loop is not speech, so twenty minutes of it end the first conversation.
        #expect(grouping.count >= 2)

        // Relaunch. The first thing to ask for the grouping is a read — the launch-time Spotlight
        // donation goes through the same seam — before any audio-content pass has run.
        let after = try launch(fixture, turns: turns)
        _ = await after.enrichment.conversationIds(containing: segmentId)
        #expect(try await stored(fixture).map(\.id) == grouping.map(\.id))
        #expect(try await stored(fixture).map(\.members) == grouping.map(\.members))

        // Then the pipeline's own pass: nothing to classify, nothing that moves.
        #expect(try await after.audioContent.classifyPass() == false)
        #expect(try await after.enrichment.regroupPass() == false)
        #expect(try await stored(fixture).map(\.members) == grouping.map(\.members))
    }
}
