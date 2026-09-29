import AudioCodec
import Foundation

// Port of `core/transcription/.../SelectableCloudTranscriptionProvider.kt` and
// `SelectableStreamingTranscriptionProvider.kt`.

/// The cloud speech-to-text backends the user can choose between. Raw values match the Kotlin
/// enum names — the setting and the durable upload-job records persist them by name.
public enum CloudProvider: String, Sendable, CaseIterable, Codable {
    case openAi = "OpenAi"
    case soniox = "Soniox"
}

/// A `TranscriptionProvider` that delegates to whichever cloud backend the user has selected, so
/// the rest of the pipeline (router, processor, live transcriber) stays provider-agnostic. The
/// active provider is resolved per call from `selected`, so changing the setting takes effect
/// immediately without rebuilding the runtime.
public final class SelectableCloudTranscriptionProvider: TranscriptionProvider, CloudUploadCapable {
    private let selected: @Sendable () -> CloudProvider
    private let openAi: any TranscriptionProvider
    private let soniox: any TranscriptionProvider
    /// Stops audio going to a provider whose account has refused (see `CloudAccountHold`). Every
    /// door audio leaves by consults it: this provider's `isAvailable`/`transcribe`, the
    /// background uploader's `submitPending` (via `isSendingHeld`), and the live socket (via
    /// the streaming provider, which shares the same hold).
    public let hold: CloudAccountHold?

    public init(
        selected: @escaping @Sendable () -> CloudProvider,
        openAi: any TranscriptionProvider,
        soniox: any TranscriptionProvider,
        hold: CloudAccountHold? = nil
    ) {
        self.selected = selected
        self.openAi = openAi
        self.soniox = soniox
        self.hold = hold
    }

    public var id: String { active().id }

    /// False while the selected provider is on hold: the queue then parks cloud-only work at no
    /// cost, and first modes use their other engine, until the hold lifts.
    public func isAvailable() async -> Bool {
        guard !isSendingHeld else { return false }
        return await active().isAvailable()
    }

    /// True while nothing may be sent to the selected provider.
    public var isSendingHeld: Bool {
        hold?.active(for: selected()) != nil
    }

    public func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>,
        sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        let provider = selected()
        if let held = hold?.active(for: provider) {
            throw TranscriptionError.transcriptionFailed(CloudAccountHold.pausedMessage(held))
        }
        do {
            let result = try await backend(provider).transcribe(
                pcmChunks: pcmChunks, sampleRateHz: sampleRateHz)
            hold?.noteSuccess(provider: provider)
            return result
        } catch let error where error is CancellationError {
            throw error
        } catch {
            noteOutcome(error, provider: provider)
            throw error
        }
    }

    /// Feeds a real attempt's failure to the hold. Every path that talks to a provider reports
    /// here — the synchronous transcribe above, and the background uploader's steps — so it does
    /// not matter which door a refusal came through.
    public func noteOutcome(_ error: Error, provider: CloudProvider) {
        hold?.noteFailure(storedFailureMessage(error), provider: provider)
    }

    /// `noteOutcome` for a failure that only exists as a stored message (a background upload's
    /// transport-level error).
    public func noteFailureMessage(_ message: String, provider: CloudProvider) {
        hold?.noteFailure(message, provider: provider)
    }

    /// A background upload finished for `provider`: the account is taking work.
    public func noteSuccess(provider: CloudProvider) {
        hold?.noteSuccess(provider: provider)
    }

    /// One second of silence sent to `provider` PAST the hold — the cheapest request that is
    /// still a real transcription, which is the only kind of request that can say whether the
    /// account will pay for one (a key check such as `GET /v1/transcriptions` answers 200 for an
    /// empty account). A few kilobytes and a second of billed audio.
    ///
    /// Updates the hold with what it found: accepted lifts it, a refusal backs it off further,
    /// anything else reschedules it without escalating.
    @discardableResult
    public func probeAccount(_ provider: CloudProvider) async -> CloudAccountProbeOutcome {
        let silence = Data(count: 16_000 * 2)
        let pcm = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(silence)
            continuation.finish()
        }
        let outcome: CloudAccountProbeOutcome
        do {
            _ = try await backend(provider).transcribe(pcmChunks: pcm, sampleRateHz: 16_000)
            outcome = .accepted
        } catch TranscriptionError.noSpeechDetected {
            // The provider transcribed it and found nothing — which it only does for an account
            // that pays for transcription.
            outcome = .accepted
        } catch TranscriptionError.providerUnavailable {
            outcome = .inconclusive("not configured")
        } catch let error where error is CancellationError {
            outcome = .inconclusive("cancelled")
        } catch {
            let message = storedFailureMessage(error)
            let kind = TranscriptionFailureKind.classify(message)
            outcome =
                CloudAccountHold.holdingKinds.contains(kind)
                ? .refused(kind) : .inconclusive(String(message.prefix(200)))
        }
        switch outcome {
        case .accepted: hold?.noteSuccess(provider: provider)
        case .refused(let kind):
            // `trip` first: a probe run with no hold in force (Test Connection) starts one.
            if hold?.trip(kind, provider: provider) == false {
                hold?.recordRefusedProbe(provider: provider, kind: kind)
            }
        case .inconclusive: hold?.recordInconclusiveProbe(provider: provider)
        }
        return outcome
    }

    /// The selected backend, when it supports background upload. Still answered while the
    /// provider is on hold — in-flight jobs must be able to finish; it is `submitPending` that
    /// refuses to START uploads (`isSendingHeld`).
    public var activeUploadCapable: (any CloudUploadCapable)? {
        active() as? any CloudUploadCapable
    }

    /// The active backend's container, or WAV when nothing can upload — the floor, so a caller
    /// reading this never picks a format that has no chance of being sent.
    public var uploadFormat: CloudAudioFormat {
        activeUploadCapable?.uploadFormat ?? .wav
    }

    public func uploadPlan(audio: CloudAudioBody, sampleRateHz: Int) async -> CloudUploadPlan? {
        await activeUploadCapable?.uploadPlan(audio: audio, sampleRateHz: sampleRateHz)
    }

    public func onUploadResponse(httpStatus: Int, body: String) async throws -> CloudUploadStep {
        guard let capable = activeUploadCapable else {
            throw TranscriptionError.transcriptionFailed(
                "active cloud provider does not support upload"
            )
        }
        return try await capable.onUploadResponse(httpStatus: httpStatus, body: body)
    }

    public func completeControlPlane(controlState: String) async throws -> TranscriptionResult {
        guard let capable = activeUploadCapable else {
            throw TranscriptionError.transcriptionFailed(
                "active cloud provider does not support upload"
            )
        }
        return try await capable.completeControlPlane(controlState: controlState)
    }

    /// The currently selected cloud backend, for state keyed by provider.
    public func selectedProvider() -> CloudProvider {
        selected()
    }

    /// The upload driver for a specific backend, so in-flight jobs finish on their original
    /// provider even if the selection changed mid-flight.
    public func capable(_ provider: CloudProvider) -> (any CloudUploadCapable)? {
        backend(provider) as? any CloudUploadCapable
    }

    /// The concrete backend for `provider` (for connectivity checks and other keyed lookups).
    public func backend(_ provider: CloudProvider) -> any TranscriptionProvider {
        switch provider {
        case .openAi: return openAi
        case .soniox: return soniox
        }
    }

    private func active() -> any TranscriptionProvider {
        backend(selected())
    }
}

/// Real-time streaming provider that delegates to the user-selected cloud backend, so the live
/// transcriber stays provider-agnostic (mirrors `SelectableCloudTranscriptionProvider` for the
/// batch path). The active backend is resolved per call from `selected`.
public final class SelectableStreamingTranscriptionProvider: StreamingTranscriptionProvider {
    private let selected: @Sendable () -> CloudProvider
    private let openAi: any StreamingTranscriptionProvider
    private let soniox: any StreamingTranscriptionProvider
    /// The same hold the batch provider uses: a live socket into an account that refuses is
    /// audio sent for nothing, reconnected into again on every open of the app.
    private let hold: CloudAccountHold?

    public init(
        selected: @escaping @Sendable () -> CloudProvider,
        openAi: any StreamingTranscriptionProvider,
        soniox: any StreamingTranscriptionProvider,
        hold: CloudAccountHold? = nil
    ) {
        self.selected = selected
        self.openAi = openAi
        self.soniox = soniox
        self.hold = hold
    }

    public var id: String { active().id }

    /// False while the selected provider is on hold — the live transcriber then treats the socket
    /// as unconfigured (no cloud-health failure, the on-device preview takes the segment).
    public func isAvailable() async -> Bool {
        guard hold?.active(for: selected()) == nil else { return false }
        return await active().isAvailable()
    }

    /// A live session failed for an account reason: put the provider on hold for every path.
    public func noteFailureKind(_ kind: TranscriptionFailureKind) {
        hold?.trip(kind, provider: selected())
    }

    public func transcribeStream(
        pcm: AsyncThrowingStream<Data, Error>,
        sampleRateHz: Int
    ) -> AsyncThrowingStream<StreamingTranscriptUpdate, Error> {
        active().transcribeStream(pcm: pcm, sampleRateHz: sampleRateHz)
    }

    private func active() -> any StreamingTranscriptionProvider {
        switch selected() {
        case .openAi: return openAi
        case .soniox: return soniox
        }
    }
}

extension SelectableCloudTranscriptionProvider: TranscriptionAvailabilityExplaining {
    public func unavailabilityReason() async -> String? {
        hold?.active(for: selected()).map(CloudAccountHold.pausedMessage)
    }
}
