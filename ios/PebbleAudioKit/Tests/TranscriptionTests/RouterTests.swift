import Foundation
import Testing

@testable import Transcription

// Port of `core/transcription/src/commonTest/.../TranscriptionModeRouterTest.kt` — all 16
// cases, same names.

private final class FakeProvider: TranscriptionProvider, @unchecked Sendable {
    let id: String
    var available: Bool
    var error: Error?

    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(_ id: String, available: Bool = true, error: Error? = nil) {
        self.id = id
        self.available = available
        self.error = error
    }

    func isAvailable() async -> Bool { available }

    func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        lock.withLock { _calls += 1 }
        if let error { throw error }
        return TranscriptionResult(text: "text-\(id)", providerId: id, modelUsed: "model-\(id)")
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcomes: [CloudConnectivityResult] = []
    var outcomes: [CloudConnectivityResult] { lock.withLock { _outcomes } }
    func append(_ outcome: CloudConnectivityResult) {
        lock.withLock { _outcomes.append(outcome) }
    }
}

@Suite struct RouterTests {

    private let pcm: TranscriptionModeRouter.PcmChunksFactory = {
        pcmStream([Data(count: 320)])
    }

    private func router(
        _ local: FakeProvider?,
        _ remote: FakeProvider?,
        _ mode: TranscriptionMode
    ) -> TranscriptionModeRouter {
        TranscriptionModeRouter(local: local, remote: remote, mode: { mode })
    }

    @Test func remoteFirst_reportsOkOnRemoteSuccess() async throws {
        let outcomes = OutcomeBox()
        let router = TranscriptionModeRouter(
            local: FakeProvider("local"),
            remote: FakeProvider("remote"),
            onRemoteOutcome: { outcomes.append($0) },
            mode: { .remoteFirst }
        )
        _ = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(outcomes.outcomes.count == 1)
        #expect(outcomes.outcomes[0].isOk)
    }

    @Test func remoteFirst_reportsFailedThenFallsBackToLocal() async throws {
        let outcomes = OutcomeBox()
        let router = TranscriptionModeRouter(
            local: FakeProvider("local"),
            remote: FakeProvider(
                "remote", error: TranscriptionError.transcriptionFailed("boom")),
            onRemoteOutcome: { outcomes.append($0) },
            mode: { .remoteFirst }
        )
        let result = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        // The cloud failure is reported (so the app can surface it) even though the user still
        // gets a transcript via the silent local fallback.
        #expect(outcomes.outcomes.count == 1)
        #expect(outcomes.outcomes[0].isFailed)
        #expect(result.modeUsed == .localOnly)
        #expect(result.providerId == "local")
    }

    @Test func localOnly_neverReportsCloudOutcome() async throws {
        let outcomes = OutcomeBox()
        let router = TranscriptionModeRouter(
            local: FakeProvider("local"),
            remote: FakeProvider("remote"),
            onRemoteOutcome: { outcomes.append($0) },
            mode: { .localOnly }
        )
        _ = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(outcomes.outcomes.isEmpty)
    }

    @Test func localOnly_usesLocal_neverRemote() async throws {
        let local = FakeProvider("local")
        let remote = FakeProvider("remote")
        let result = try await router(local, remote, .localOnly)
            .transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(result.modeUsed == .localOnly)
        #expect(result.providerId == "local")
        #expect(result.modelUsed == "model-local")
        #expect(remote.calls == 0)
    }

    @Test func localOnly_unavailable_throwsWithoutFallback() async {
        let local = FakeProvider("local", available: false)
        let remote = FakeProvider("remote")
        do {
            _ = try await router(local, remote, .localOnly)
                .transcribe(pcmChunks: pcm, sampleRateHz: 16000)
            Issue.record("expected ProviderUnavailable")
        } catch TranscriptionError.providerUnavailable(_) {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(remote.calls == 0)
    }

    @Test func remoteOnly_failure_doesNotFallBackToLocal() async {
        let local = FakeProvider("local")
        let remote = FakeProvider(
            "remote", error: TranscriptionError.transcriptionFailed("boom"))
        do {
            _ = try await router(local, remote, .remoteOnly)
                .transcribe(pcmChunks: pcm, sampleRateHz: 16000)
            Issue.record("expected TranscriptionFailed")
        } catch TranscriptionError.transcriptionFailed(_, _) {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(local.calls == 0)
    }

    @Test func localFirst_primarySuccess_keepsConfiguredModeUsed() async throws {
        let local = FakeProvider("local")
        let remote = FakeProvider("remote")
        let result = try await router(local, remote, .localFirst)
            .transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(result.modeUsed == .localFirst)
        #expect(result.providerId == "local")
        #expect(remote.calls == 0)
    }

    @Test func localFirst_localFails_fallsBackWithRemoteOnlyProvenance() async throws {
        let local = FakeProvider("local", error: TranscriptionError.transcriptionFailed("oom"))
        let remote = FakeProvider("remote")
        let r = router(local, remote, .localFirst)
        let result = try await r.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(result.modeUsed == .remoteOnly, "fallback provenance must say RemoteOnly")
        #expect(result.providerId == "remote")
        #expect(r.lastSuccessfulMode == .remoteOnly)
    }

    @Test func localFirst_nonExceptionProviderFailure_fallsBackToRemote() async throws {
        let local = FakeProvider("local", error: AssertionError("native boundary failed"))
        let remote = FakeProvider("remote")
        let result = try await router(local, remote, .localFirst)
            .transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(result.modeUsed == .remoteOnly)
        #expect(result.providerId == "remote")
    }

    @Test func localFirst_localUnavailable_fallsBackToRemote() async throws {
        let remote = FakeProvider("remote")
        let result = try await router(
            FakeProvider("local", available: false), remote, .localFirst
        ).transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(result.modeUsed == .remoteOnly)
        #expect(remote.calls == 1)
    }

    @Test func localFirst_bothFail_throws() async {
        let local = FakeProvider("local", error: TranscriptionError.transcriptionFailed("a"))
        let remote = FakeProvider("remote", error: TranscriptionError.transcriptionFailed("b"))
        do {
            _ = try await router(local, remote, .localFirst)
                .transcribe(pcmChunks: pcm, sampleRateHz: 16000)
            Issue.record("expected TranscriptionFailed")
        } catch TranscriptionError.transcriptionFailed(_, _) {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func remoteFirst_remoteFails_fallsBackWithLocalOnlyProvenance() async throws {
        let local = FakeProvider("local")
        let remote = FakeProvider(
            "remote", error: TranscriptionError.transcriptionFailed("net"))
        let result = try await router(local, remote, .remoteFirst)
            .transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(result.modeUsed == .localOnly)
        #expect(result.providerId == "local")
    }

    @Test func remoteFirst_remoteSuccess_keepsConfiguredModeUsed() async throws {
        let local = FakeProvider("local")
        let remote = FakeProvider("remote")
        let result = try await router(local, remote, .remoteFirst)
            .transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(result.modeUsed == .remoteFirst)
        #expect(local.calls == 0)
    }

    @Test func noSpeech_isAResult_notAFallbackTrigger() async {
        let local = FakeProvider(
            "local", error: TranscriptionError.noSpeechDetected("silence"))
        let remote = FakeProvider("remote")
        do {
            _ = try await router(local, remote, .localFirst)
                .transcribe(pcmChunks: pcm, sampleRateHz: 16000)
            Issue.record("expected NoSpeechDetected")
        } catch TranscriptionError.noSpeechDetected(_) {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(remote.calls == 0, "no-speech must not trigger remote fallback")
    }

    @Test func cancellation_propagatesWithoutFallback() async {
        let local = FakeProvider("local", error: CancellationError())
        let remote = FakeProvider("remote")
        await #expect(throws: CancellationError.self) {
            _ = try await router(local, remote, .localFirst)
                .transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        }
        #expect(remote.calls == 0)
    }

    @Test func availabilityMatrix() async {
        let up = FakeProvider("up")
        let down = FakeProvider("down", available: false)

        #expect(await router(up, down, .localOnly).isAvailable())
        #expect(await router(down, up, .localOnly).isAvailable() == false)
        #expect(await router(down, up, .remoteOnly).isAvailable())
        #expect(await router(up, down, .remoteOnly).isAvailable() == false)
        #expect(await router(down, up, .localFirst).isAvailable())
        #expect(await router(up, down, .remoteFirst).isAvailable())
        #expect(await router(down, down, .localFirst).isAvailable() == false)
        #expect(await router(nil, nil, .remoteFirst).isAvailable() == false)
    }
}
