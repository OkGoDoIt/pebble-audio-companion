import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

@testable import Intelligence

// Follow-ups were dated in the phone's CURRENT zone. A conversation recorded in Tokyo and read
// after the flight home to New York had its "Friday" resolved — and its "recorded" day told to
// the model — in New York. The zone the audio was recorded in (Q16) is the one its words mean.

private final class Replier: AiProvider, @unchecked Sendable {
    let id = "replier"
    private let reply: String
    private let lock = NSLock()
    private var _bodies: [String] = []
    init(_ reply: String) { self.reply = reply }
    var bodies: [String] { lock.withLock { _bodies } }
    func isAvailable() async -> Bool { true }
    func run(_ request: AiRunRequest) async throws -> AiProviderResult {
        lock.withLock { _bodies.append(request.transcripts.first?.text ?? "") }
        return AiProviderResult(text: reply, modelUsed: "m")
    }
}

private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
private let newYork = TimeZone(identifier: "America/New_York")!

private func startOfDay(_ iso: String, in zone: TimeZone) -> Int64 {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd"
    return Int64(formatter.date(from: iso)!.timeIntervalSince1970 * 1000)
}

@Suite("Follow-ups — dated in the zone the words were recorded in")
struct FollowUpRecordedZoneTests {
    // 2026-09-03 23:00 UTC = Friday 08:00 in Tokyo, Thursday 19:00 in New York.
    private let recordedAt: Int64 = 1_788_476_400_000

    @Test func extractionDatesAConversationInItsRecordedZone() async throws {
        let db = try AppDatabase.inMemory()
        let candidates = FollowUpCandidateStore(db: db)
        let provider = Replier(
            #"{"items":[{"task":"Send Dana the lease","quote":"I will send Dana the lease by Friday.","ifForgotten":"she cannot sign","dueDate":"2026-09-11","confidence":"high"}]}"#)
        let worker = FollowUpWorker(
            candidates: candidates, state: try FollowUpExtractionStore(db: db),
            router: AiModeRouter(local: provider, remote: nil, mode: { .localOnly }),
            nowMs: { self.recordedAt + 3_600_000 },
            timeZone: { newYork })
        let meta = SegmentMeta(
            segmentId: "seg-1", streamId: 1, protocolVersion: 1, codecIdRaw: 1, channels: 1,
            frameSamples: 320, sampleRateHz: 16_000, bitRateBps: 9_800, frameDurationMs: 20,
            startTimeMs: UInt64(recordedAt), startMonotonicMs: 1, receivedAtMs: recordedAt,
            closeReason: .rotated, transcriptionState: .complete, recordedTimeZone: "Asia/Tokyo")
        let text =
            String(repeating: "We talked about the move and the paperwork. ", count: 8)
            + "I will send Dana the lease by Friday."

        _ = try await worker.extract(
            [EnrichmentConversation(conversationId: "conv-1", isOpen: false, members: [meta])],
            transcriptOf: {
                SegmentTranscript(
                    segmentId: $0, text: text, modeUsed: .localOnly, providerId: "t",
                    createdAtMs: 0)
            })

        // Told to the model as Friday morning in Tokyo, not Thursday evening in New York.
        #expect(provider.bodies.first?.contains("Recorded: Friday, 2026-09-04 at 8:00 AM") == true)
        let due = try #require(try await candidates.list(conversationId: "conv-1").first?.dueAtMs)
        #expect(due == startOfDay("2026-09-11", in: tokyo))
        #expect(due != startOfDay("2026-09-11", in: newYork))
    }

    @Test func curationDatesACandidateInItsRecordingsZone() async throws {
        let db = try AppDatabase.inMemory()
        let candidates = FollowUpCandidateStore(db: db)
        try await candidates.save(
            FollowUpCandidate(
                id: "c1", conversationId: "conv-1", segmentId: "seg-tokyo", task: "Call Dana",
                quote: "I will call Dana on Friday.", why: "she waits",
                createdAtMs: recordedAt, recordedAtMs: recordedAt))
        let provider = Replier(
            #"{"decisions":[{"index":1,"decision":"keep","reason":"real","task":"","priority":"normal","dueDate":"2026-09-11"}]}"#)
        let curator = FollowUpCurator(
            candidates: candidates, followUps: FollowUpStore(db: db),
            router: AiModeRouter(local: provider, remote: nil, mode: { .localOnly }),
            nowMs: { self.recordedAt + 3_600_000 },
            timeZone: { newYork },
            recordedZoneOf: { $0 == "seg-tokyo" ? tokyo : nil })

        let written = try await curator.curate()

        #expect(written.first?.dueAtMs == startOfDay("2026-09-11", in: tokyo))
        #expect(provider.bodies.first?.contains("recorded: Friday, 2026-09-04") == true)
    }
}
