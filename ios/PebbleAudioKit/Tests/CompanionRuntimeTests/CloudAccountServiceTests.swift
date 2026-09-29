import AppDB
import Foundation
import SegmentStore
import Testing
import Transcription

@testable import CompanionRuntime

/// The service side of the cloud account hold: Test Connection checks the account and not just
/// the key, a held account is checked again on its schedule from the passes that actually run,
/// and a relaunch puts the hold back on the cloud row.
@Suite struct CloudAccountServiceTests {
    private final class Batch: TranscriptionProvider, @unchecked Sendable {
        let id = "soniox"
        private let lock = NSLock()
        private var failure: Error?
        private var count = 0
        init(failure: Error?) { self.failure = failure }
        var calls: Int { lock.withLock { count } }
        func fail(with error: Error?) { lock.withLock { failure = error } }
        func isAvailable() async -> Bool { true }
        func transcribe(
            pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
        ) async throws -> TranscriptionResult {
            for try await _ in pcmChunks {}
            let error = lock.withLock { () -> Error? in
                count += 1
                return failure
            }
            if let error { throw error }
            return TranscriptionResult(text: "hi", providerId: id, modelUsed: "m")
        }
    }

    /// A key check that passes whatever the account holds — Soniox's `GET /v1/transcriptions`.
    private struct KeyAccepted: CloudConnectivityCheck {
        func checkConnectivity() async -> CloudConnectivityResult { .ok(detail: "Soniox connected") }
    }

    private static let refused = TranscriptionError.transcriptionFailed(
        "Soniox create transcription failed (402): Organization balance exhausted")

    private struct Rig {
        let clock: TestClock
        let hold: CloudAccountHold
        let batch: Batch
        let health: CloudHealthMonitor
        let service: TranscriptionService
    }

    private func rig(
        failure: Error?, mode: TranscriptionMode = .localFirst, hold existing: CloudAccountHold? = nil
    ) throws -> Rig {
        let clock = TestClock()
        let hold =
            existing ?? CloudAccountHold(fileURL: nil, apiKey: { _ in "key" }, nowMs: { clock.nowMs })
        let batch = Batch(failure: failure)
        let cloud = SelectableCloudTranscriptionProvider(
            selected: { .soniox }, openAi: Batch(failure: nil), soniox: batch, hold: hold)
        let db = try AppDatabase.inMemory()
        let root = Fixture.temporaryDirectory("cloud-account")
        let queue = TranscriptionQueue(database: db, nowMs: { clock.nowMs })
        let processor = TranscriptionProcessor(
            queue: queue,
            router: TranscriptionModeRouter(local: nil, remote: cloud, mode: { mode }),
            pcmSource: { _ in AsyncThrowingStream { $0.finish() } }
        )
        let health = CloudHealthMonitor(nowMs: { clock.nowMs })
        let service = TranscriptionService(
            queue: queue,
            processor: processor,
            transcriptStore: FileTranscriptStore(root: root, nowMs: { clock.nowMs }),
            store: SegmentStore(root: root, nowMs: { clock.nowMs }),
            settings: RuntimeSettingsBox(
                RuntimeSettingsSnapshot(
                    captureIntent: .active, transcriptionMode: mode,
                    cloudTranscriptionProvider: .soniox)),
            clock: clock,
            cloudHealth: health,
            connectivityCheck: KeyAccepted(),
            cloudAccounts: cloud,
            cloudFailureText: { "shown: \(TranscriptionFailureKind.classify($0).rawValue)" }
        )
        return Rig(clock: clock, hold: hold, batch: batch, health: health, service: service)
    }

    /// The key is fine and the account is empty: Test Connection says so (and holds), where it used
    /// to say "connected" on the strength of the key alone.
    @Test func testConnectionChecksTheAccountNotJustTheKey() async throws {
        let rig = try rig(failure: Self.refused)
        await rig.service.testCloudConnection()
        #expect(rig.health.state.status == .failed)
        #expect(rig.health.state.message == "shown: accountOutOfFunds")
        #expect(rig.hold.active(for: .soniox) != nil)

        // Topped up: the next Test Connection lifts the hold at once.
        rig.batch.fail(with: TranscriptionError.noSpeechDetected("Soniox returned no speech"))
        await rig.service.testCloudConnection()
        #expect(rig.health.state.status == .ok)
        #expect(rig.hold.active(for: .soniox) == nil)
    }

    /// The receive-only background pass (the only pass a phone off the charger runs) checks a held
    /// account on its schedule, and not before.
    @Test func aHeldAccountIsCheckedOnItsScheduleAndNotBefore() async throws {
        let rig = try rig(failure: Self.refused)
        rig.hold.trip(.accountOutOfFunds, provider: .soniox)

        await rig.clock.advance(by: 14 * 60_000)
        await rig.service.submitPendingToUploader()
        #expect(rig.batch.calls == 0)

        await rig.clock.advance(by: 60_000)
        await rig.service.submitPendingToUploader()
        #expect(rig.batch.calls == 1)
        #expect(rig.hold.active(for: .soniox)?.refusedProbes == 1)

        // Topped up in between: the next due check (30 min later) lifts it.
        rig.batch.fail(with: nil)
        await rig.clock.advance(by: 30 * 60_000)
        _ = try await rig.service.reconsiderDisabled(foreground: false)
        #expect(rig.batch.calls == 2)
        #expect(rig.hold.active(for: .soniox) == nil)
        #expect(rig.health.state.status == .ok)
    }

    /// On-device only means the cloud is never contacted — not even to check an old hold.
    @Test func localOnlyNeverChecksTheCloud() async throws {
        let rig = try rig(failure: Self.refused, mode: .localOnly)
        rig.hold.trip(.accountOutOfFunds, provider: .soniox)
        await rig.clock.advance(by: 7 * 60 * 60_000)
        _ = try await rig.service.reconsiderDisabled(foreground: true)
        await rig.service.submitPendingToUploader()
        #expect(rig.batch.calls == 0)
    }

    /// The hold outlives the process; cloud health does not. A relaunch puts it back on the row.
    @Test func aRelaunchPutsTheHoldBackOnTheCloudRow() async throws {
        let first = try rig(failure: Self.refused)
        first.hold.trip(.accountOutOfFunds, provider: .soniox)
        let relaunched = try rig(failure: Self.refused, hold: first.hold)
        #expect(relaunched.health.state.status != .failed)
        try await relaunched.service.recoverOnStart()
        #expect(relaunched.health.state.status == .failed)
        #expect(relaunched.health.state.message == "shown: accountOutOfFunds")
    }

    @Test func onlyAChangeThatCouldRescueATranscriptionChangesTheRecoveryKey() {
        let base = RuntimeSettingsSnapshot(captureIntent: .active)
        var capture = base
        capture.captureIntent = .paused
        var ai = base
        ai.aiMode = .localOnly
        var retention = base
        retention.retentionDays = 7
        #expect(capture.transcriptionRecoveryKey == base.transcriptionRecoveryKey)
        #expect(ai.transcriptionRecoveryKey == base.transcriptionRecoveryKey)
        #expect(retention.transcriptionRecoveryKey == base.transcriptionRecoveryKey)

        var mode = base
        mode.transcriptionMode = .localOnly
        var model = base
        model.localTranscriptionModelId = "parakeet-tdt-0.6b-v3-coreai"
        var provider = base
        provider.cloudTranscriptionProvider = .openAi
        var network = base
        network.cloudUploadNetwork = base.cloudUploadNetwork == .wifiOnly ? .anyNetwork : .wifiOnly
        for changed in [mode, model, provider, network] {
            #expect(changed.transcriptionRecoveryKey != base.transcriptionRecoveryKey)
        }
    }
}
