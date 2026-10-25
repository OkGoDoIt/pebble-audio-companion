import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

@testable import CompanionRuntime

/// The drain re-asks whether it may carry on between tasks. A charger pass that was allowed to
/// start ran a 21-segment local backlog for eight minutes after the cable came out on
/// 2026-09-18, because the policy was only read at the top of the pass.
@Suite struct DrainQueuePolicyTests {
    private final class CountingProvider: TranscriptionProvider, @unchecked Sendable {
        let id = "local"
        private let lock = NSLock()
        private var count = 0
        var transcribed: Int { lock.withLock { count } }

        func isAvailable() async -> Bool { true }

        func transcribe(
            pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
        ) async throws -> TranscriptionResult {
            lock.withLock { count += 1 }
            return TranscriptionResult(text: "hello", providerId: id, modelUsed: "model")
        }
    }

    private func makeService(
        segments: Int
    ) throws -> (TranscriptionService, CountingProvider) {
        let (service, provider, _) = try makeServiceWithQueue(segments: segments)
        return (service, provider)
    }

    private func makeServiceWithQueue(
        segments: Int
    ) throws -> (TranscriptionService, CountingProvider, TranscriptionQueue) {
        let clock = TestClock()
        let db = try AppDatabase.inMemory()
        let root = Fixture.temporaryDirectory("drain")
        let queue = TranscriptionQueue(database: db, nowMs: { clock.nowMs })
        for index in 0..<segments { try queue.enqueue("seg-\(index)") }
        let provider = CountingProvider()
        let processor = TranscriptionProcessor(
            queue: queue,
            router: TranscriptionModeRouter(local: provider, remote: nil, mode: { .localOnly }),
            pcmSource: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(Data([1, 2, 3, 4]))
                    continuation.finish()
                }
            }
        )
        let service = TranscriptionService(
            queue: queue,
            processor: processor,
            transcriptStore: FileTranscriptStore(root: root, nowMs: { clock.nowMs }),
            store: SegmentStore(root: root, nowMs: { clock.nowMs }),
            database: db,
            settings: RuntimeSettingsBox(RuntimeSettingsSnapshot(captureIntent: .active)),
            clock: clock
        )
        return (service, provider, queue)
    }

    /// A task left `Running` by work that died is picked up by the next drain — it used to wait
    /// for the next process launch (four segments sat 16-20 hours on 2026-09-18).
    @Test func aDrainPicksUpATaskOrphanedAsRunning() async throws {
        let (service, provider, queue) = try makeServiceWithQueue(segments: 1)
        try queue.markRunning("seg-0")
        _ = try await service.drainQueue()
        #expect(provider.transcribed == 1)
        #expect(try queue.load("seg-0")?.state == .complete)
    }

    @Test func aDrainStopsAtTheNextTaskOnceItMayNotContinue() async throws {
        let (service, provider) = try makeService(segments: 5)
        let allowed = Counter(limit: 2)

        let processed = try await service.drainQueue(shouldContinue: { allowed.tick() })

        #expect(processed)
        // The policy said no after the second task; the third never ran.
        #expect(provider.transcribed == 2)
    }

    @Test func aDrainThatMayAlwaysContinueEmptiesTheQueue() async throws {
        let (service, provider) = try makeService(segments: 3)
        _ = try await service.drainQueue()
        #expect(provider.transcribed == 3)
    }

    /// `shouldContinue` answers true `limit - 1` times, then false forever.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        private let limit: Int
        init(limit: Int) { self.limit = limit }
        func tick() -> Bool { lock.withLock { asked += 1; return asked < limit } }
    }
}
