import Foundation
import Testing

@testable import Transcription

// `TranscriptionModeRouter.lastFallback` — the value Settings discloses when a "first" mode is
// being carried by its fallback.
//
// The rules being pinned here are the ones the disclosure's honesty rests on:
//
//   • it is set ONLY when the fallback actually produced the result,
//   • it is CLEARED as soon as the preferred path succeeds again (this is what makes the line
//     on screen "in force now" rather than "happened once"), and
//   • an "Only" mode never sets it, because it has no fallback to disclose.
//
// The cause is asserted through the real classifier rather than a stub, because the sentence a
// person reads ("not available on this iPhone" vs "could not finish the last one") is chosen
// from it — a mapping that drifts turns the disclosure into a new wrong statement.

private final class CUFakeProvider: TranscriptionProvider, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var _available: Bool
    private var _error: Error?

    var available: Bool {
        get { lock.withLock { _available } }
        set { lock.withLock { _available = newValue } }
    }
    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    init(_ id: String, available: Bool = true, error: Error? = nil) {
        self.id = id
        self._available = available
        self._error = error
    }

    func isAvailable() async -> Bool { available }

    func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>, sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        if let error { throw error }
        return TranscriptionResult(text: "text-\(id)", providerId: id, modelUsed: "model-\(id)")
    }
}

@Suite("CU · transcription fallback disclosure")
struct CUProcessingFallbackTests {

    private let pcm: TranscriptionModeRouter.PcmChunksFactory = {
        pcmStream([Data(count: 320)])
    }

    // MARK: The healthy case says nothing

    @Test func localFirstSucceedingLocallyDisclosesNothing() async throws {
        let router = TranscriptionModeRouter(
            local: CUFakeProvider("local"), remote: CUFakeProvider("remote"),
            mode: { .localFirst })
        _ = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(router.lastFallback == nil)
    }

    @Test func remoteFirstSucceedingRemotelyDisclosesNothing() async throws {
        let router = TranscriptionModeRouter(
            local: CUFakeProvider("local"), remote: CUFakeProvider("remote"),
            mode: { .remoteFirst })
        _ = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(router.lastFallback == nil)
    }

    /// An "Only" mode has no fallback, so it can never have one to disclose — including after a
    /// mode change, which is why this asserts nil rather than "unchanged".
    @Test func onlyModesNeverRecordAFallback() async throws {
        for mode in [TranscriptionMode.localOnly, .remoteOnly] {
            let router = TranscriptionModeRouter(
                local: CUFakeProvider("local"), remote: CUFakeProvider("remote"),
                mode: { mode })
            _ = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
            #expect(router.lastFallback == nil, "\(mode)")
        }
    }

    // MARK: Local first → the cloud

    /// The privacy case: the on-device language model is not installed, so every recording is
    /// being uploaded. `providerUnavailable` is what the router itself throws for it.
    @Test func localFirstFallingBackToCloudRecordsNotAvailable() async throws {
        let router = TranscriptionModeRouter(
            local: CUFakeProvider("local", available: false),
            remote: CUFakeProvider("remote"),
            mode: { .localFirst })
        _ = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(
            router.lastFallback
                == ProcessingFallback(direction: .localToCloud, cause: .notAvailable))
    }

    /// The engine ran and threw: a different sentence, because "not available" would be wrong.
    @Test func localFirstFallingBackAfterAnEngineFailureRecordsFailed() async throws {
        let router = TranscriptionModeRouter(
            local: CUFakeProvider(
                "local",
                error: TranscriptionError.transcriptionFailed("On-device transcription failed")),
            remote: CUFakeProvider("remote"),
            mode: { .localFirst })
        _ = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(router.lastFallback?.direction == .localToCloud)
        #expect(router.lastFallback?.cause == .failed)
    }

    // MARK: Remote first → this phone

    @Test func remoteFirstFallingBackOnNoConnectionRecordsNoConnection() async throws {
        let router = TranscriptionModeRouter(
            local: CUFakeProvider("local"),
            remote: CUFakeProvider("remote", error: URLError(.notConnectedToInternet)),
            mode: { .remoteFirst })
        _ = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(
            router.lastFallback
                == ProcessingFallback(direction: .cloudToLocal, cause: .noConnection))
    }

    /// A rejected key is the one cloud cause with an action attached, so it must not collapse
    /// into the generic "the last request failed".
    @Test func remoteFirstFallingBackOnARejectedKeyRecordsNotAccepted() async throws {
        let router = TranscriptionModeRouter(
            local: CUFakeProvider("local"),
            remote: CUFakeProvider(
                "remote",
                error: TranscriptionError.transcriptionFailed("Soniox poll failed (401): denied")),
            mode: { .remoteFirst })
        _ = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(
            router.lastFallback
                == ProcessingFallback(direction: .cloudToLocal, cause: .notAccepted))
    }

    // MARK: Recovery clears it — the property the UI depends on

    /// "Keep trying to solve the local problem and switch back when possible": the router
    /// re-tries the preferred path on every job, and the disclosure has to disappear with it.
    /// Without this the line would be permanent after one bad minute.
    @Test func recoveryOnThePreferredPathClearsTheDisclosure() async throws {
        let local = CUFakeProvider("local", available: false)
        let router = TranscriptionModeRouter(
            local: local, remote: CUFakeProvider("remote"), mode: { .localFirst })

        _ = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(router.lastFallback?.direction == .localToCloud)

        local.available = true
        _ = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        #expect(router.lastFallback == nil)
    }

    /// Both paths down: nothing ran, so there is no fallback to claim. The previous state is
    /// left alone rather than replaced with a story about a run that never happened.
    @Test func aRunThatFailsEntirelyLeavesThePreviousStateAlone() async throws {
        let remote = CUFakeProvider("remote")
        let router = TranscriptionModeRouter(
            local: CUFakeProvider("local", available: false), remote: remote,
            mode: { .localFirst })
        _ = try await router.transcribe(pcmChunks: pcm, sampleRateHz: 16000)
        let after = router.lastFallback

        remote.available = false
        await #expect(throws: (any Error).self) {
            _ = try await router.transcribe(pcmChunks: self.pcm, sampleRateHz: 16000)
        }
        #expect(router.lastFallback == after)
    }

    // MARK: The classifier the sentence is chosen from

    @Test func causeClassification() {
        #expect(ProcessingFallbackCause.classify("provider unavailable: local") == .notAvailable)
        #expect(
            ProcessingFallbackCause.classify("Failed to initialize local model") == .notAvailable)
        #expect(ProcessingFallbackCause.classify("OpenAI said (429): slow down") == .notAccepted)
        #expect(ProcessingFallbackCause.classify("OpenAI said (403): nope") == .notAccepted)
        #expect(ProcessingFallbackCause.classify("network request failed (-1009)") == .noConnection)
        #expect(ProcessingFallbackCause.classify("Soniox poll failed (500)") == .failed)
        // No message at all is `.failed`, never a guess at something more specific.
        #expect(ProcessingFallbackCause.classify(nil) == .failed)
    }
}
