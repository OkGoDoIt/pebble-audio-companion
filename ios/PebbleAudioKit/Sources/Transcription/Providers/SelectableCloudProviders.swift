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

    public init(
        selected: @escaping @Sendable () -> CloudProvider,
        openAi: any TranscriptionProvider,
        soniox: any TranscriptionProvider
    ) {
        self.selected = selected
        self.openAi = openAi
        self.soniox = soniox
    }

    public var id: String { active().id }

    public func isAvailable() async -> Bool {
        await active().isAvailable()
    }

    public func transcribe(
        pcmChunks: AsyncThrowingStream<Data, Error>,
        sampleRateHz: Int
    ) async throws -> TranscriptionResult {
        try await active().transcribe(pcmChunks: pcmChunks, sampleRateHz: sampleRateHz)
    }

    /// The selected backend, when it supports background upload.
    public var activeUploadCapable: (any CloudUploadCapable)? {
        active() as? any CloudUploadCapable
    }

    public func uploadPlan(wav: Data, sampleRateHz: Int) async -> CloudUploadPlan? {
        await activeUploadCapable?.uploadPlan(wav: wav, sampleRateHz: sampleRateHz)
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

    public init(
        selected: @escaping @Sendable () -> CloudProvider,
        openAi: any StreamingTranscriptionProvider,
        soniox: any StreamingTranscriptionProvider
    ) {
        self.selected = selected
        self.openAi = openAi
        self.soniox = soniox
    }

    public var id: String { active().id }

    public func isAvailable() async -> Bool {
        await active().isAvailable()
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
