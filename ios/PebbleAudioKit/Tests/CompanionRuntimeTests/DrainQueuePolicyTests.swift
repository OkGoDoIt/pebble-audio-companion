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
        var afterTask: (@Sendable () async throws -> Void)?
        var transcribed: Int { lock.withLock { count } }

        func isAvailable() async -> Bool { true }

        func transcribe(
            pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
        ) async throws -> TranscriptionResult {
            lock.withLock { count += 1 }
            try await afterTask?()
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

    @Test func aForegroundBudgetLeavesTheRemainderForTheNextPass() async throws {
        let (service, provider) = try makeService(segments: 5)
        #expect(try await service.drainQueue(maximumTasks: 2))
        #expect(provider.transcribed == 2)
        #expect(try await service.drainQueue())
        #expect(provider.transcribed == 5)
    }

    /// Voices get a turn behind an ASR backlog only when they could run: enabled, and on a
    /// charger. On battery they wait for one, so transcription is not held back for them.
    @Test(arguments: [(false, true), (true, true), (true, false)])
    func composedRuntimeYieldsASRBacklogToVoiceOnlyWhenItCanRun(_ enabled: Bool, _ plugged: Bool) async throws {
        let provider = CountingProvider()
        let counts = CallRecorder()
        let fixture = try RuntimeFixture(localTranscriptionProvider: provider,
            withVoiceRecognition: true, observeStage: { stage in
                if stage == .recognizeVoices { counts.record(String(provider.transcribed)) }
            })
        fixture.foreground.devicePower = DevicePowerSnapshot(isPluggedIn: plugged)
        for index in 0..<3 { try fixture.queue.enqueue("queued-\(index)") }
        try await VoiceIdentityStore(db: fixture.database).setMode(enabled ? .local : .off)
        await fixture.runtime.start()
        #expect(await waitUntil { !counts.calls.isEmpty })
        await fixture.runtime.stop()
        #expect(counts.calls.first == (enabled && plugged ? "1" : "3"))
    }

    @Test func enablingVoicesDuringASRDrainYieldsAtTheNextTaskBoundary() async throws {
        let provider = CountingProvider()
        let counts = CallRecorder()
        let fixture = try RuntimeFixture(localTranscriptionProvider: provider,
            withVoiceRecognition: true, observeStage: { stage in
                if stage == .recognizeVoices { counts.record(String(provider.transcribed)) }
            })
        fixture.foreground.devicePower = DevicePowerSnapshot(isPluggedIn: true)
        provider.afterTask = { [weak fixture] in
            guard let fixture else { return }
            try await VoiceIdentityStore(db: fixture.database).setMode(.local)
            fixture.runtime.notifyVoiceConfigurationChanged()
        }
        for index in 0..<3 { try fixture.queue.enqueue("queued-\(index)") }
        await fixture.runtime.start()
        #expect(await waitUntil { !counts.calls.isEmpty })
        await fixture.runtime.stop()
        #expect(counts.calls.first == "1")
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
