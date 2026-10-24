import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription
@testable import Intelligence

private actor MomentProvider: AiProvider {
    nonisolated let id = "moment-test"
    var requests: [AiRunRequest] = []
    func isAvailable() async -> Bool { true }
    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        requests.append(request)
        return AiProviderResult(text: #"{"summary":"Return the book","suggestions":[{"kind":"reminder","text":"Return the book to Sam"}]}"#,
                                modelUsed: "test")
    }
}

@Suite struct MomentReviewWorkerTests {
    static let start: Int64 = 1_788_000_000_000

    private func meta(open: Bool = false) -> SegmentMeta {
        SegmentMeta(segmentId: "seg", streamId: 1, protocolVersion: 1, codecIdRaw: 1,
            channels: 1, frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800,
            frameDurationMs: 20, startTimeMs: UInt64(Self.start), startMonotonicMs: 1,
            receivedAtMs: Self.start, firstSampleIndex: 0, lastSampleIndexExclusive: 16_000 * 180,
            frameCount: 9_000, closeReason: open ? nil : .rotated, transcriptionState: .complete)
    }

    private static func transcript() -> SegmentTranscript {
        SegmentTranscript(segmentId: "seg", text: "earlier return later", modeUsed: .localOnly,
            providerId: "local", createdAtMs: 0, segments: [
                TranscriptSegment(text: "Unrelated earlier speech", startMs: 0, endMs: 5_000),
                TranscriptSegment(text: "Return the book to Sam", startMs: 20_000, endMs: 70_000),
                TranscriptSegment(text: "Unrelated later speech", startMs: 140_000, endMs: 150_000)
            ])
    }

    @Test func contextIntersectsLongTurnsAndRespectsConversationPieces() {
        let input = EnrichmentConversation(conversationId: "conv", isOpen: false, members: [meta()],
            pieces: [ConversationMember(segmentId: "seg", startMediaMs: 10_000, endMediaMs: 100_000)])
        let context = MomentReviewWorker.excerpts(at: Self.start + 80_000, conversations: [input]) {
            Self.transcript().piece($0)
        }
        #expect(context.ready)
        #expect(context.excerpts.map(\.text) == ["Return the book to Sam"])
        let open = EnrichmentConversation(conversationId: "live", isOpen: true, members: [meta(open: true)])
        #expect(!MomentReviewWorker.excerpts(at: Self.start + 80_000, conversations: [open]) {
            Self.transcript().piece($0)
        }.ready)
    }

    @Test func reviewRunsOnceAndOnlySuggestsWithoutCreatingAReminder() async throws {
        let db = try AppDatabase.inMemory()
        let store = MomentStore(db: db)
        let provider = MomentProvider()
        let worker = MomentReviewWorker(store: store,
            router: AiModeRouter(local: provider, remote: nil, mode: { .localOnly }),
            nowMs: { Self.start + 200_000 })
        try await store.add(Moment(id: "mark", wallMs: Self.start + 80_000, onAudioClock: true,
                                   createdAtMs: Self.start + 81_000))
        let input = EnrichmentConversation(conversationId: "conv", isOpen: false, members: [meta()])
        #expect(try await worker.run(conversations: [input]) { Self.transcript().piece($0) })
        #expect(!(try await worker.run(conversations: [input]) { Self.transcript().piece($0) }))
        #expect(await provider.requests.count == 1)
        let saved = try await store.moments(fromWallMs: Self.start, to: Self.start + 300_000)
        #expect(saved.first?.review?.suggestions.first?.kind == "reminder")
        #expect(try await FollowUpStore(db: db).list(scope: .open).isEmpty)
    }

    @Test func invalidActionsAreRejectedAndNoActionIsValid() throws {
        let review = try MomentReviewWorker.parse(#"{"summary":"An interesting story","suggestions":[{"kind":"send_email","text":"Send it"}]}"#)
        #expect(review.suggestions.isEmpty)
        #expect(throws: (any Error).self) { try MomentReviewWorker.parse("I scheduled it.") }
    }
}
