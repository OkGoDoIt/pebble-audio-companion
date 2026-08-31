import Foundation

// Port of `core/transcription/.../TranscriptionModeRouter.kt`.

/// Router outcome with `modeUsed` provenance (which path actually produced the text).
public struct RoutedTranscription: Sendable, Equatable {
    public let text: String

    /// The mode that actually produced this result: equal to the configured mode when the
    /// primary path succeeded, or the fallback's "-Only" mode when it didn't (matching
    /// CactusTranscriptionService's modeUsed semantics).
    public let modeUsed: TranscriptionMode
    public let providerId: String
    public let modelUsed: String?
    public let segments: [TranscriptSegment]
    public let words: [TranscriptWord]

    public init(
        text: String,
        modeUsed: TranscriptionMode,
        providerId: String,
        modelUsed: String?,
        segments: [TranscriptSegment] = [],
        words: [TranscriptWord] = []
    ) {
        self.text = text
        self.modeUsed = modeUsed
        self.providerId = providerId
        self.modelUsed = modelUsed
        self.segments = segments
        self.words = words
    }
}

/// Four-mode local/remote router; the routing/fallback semantics are ported from
/// mobileapp's CactusTranscriptionService.localTranscribe():
///
/// - LocalOnly / RemoteOnly: use exactly that provider, no fallback.
/// - LocalFirst: try local; on failure (except cancellation and no-speech) fall back to
///   remote with modeUsed = RemoteOnly.
/// - RemoteFirst: try remote; on failure fall back to local with modeUsed = LocalOnly.
/// - NoSpeechDetected is a valid result, never a reason to fall back.
///
/// The KMP router received one cold (replayable) `Flow<ByteArray>`; the Swift provider seam
/// consumes single-use `AsyncThrowingStream`s, so the router takes a stream FACTORY and builds
/// a fresh stream per provider attempt — the fallback must not receive a half-consumed stream.
public final class TranscriptionModeRouter: @unchecked Sendable {
    public typealias PcmChunksFactory = @Sendable () async throws -> AsyncThrowingStream<Data, Error>

    private let local: TranscriptionProvider?
    private let remote: TranscriptionProvider?

    /// Reports the outcome of every actual *remote* attempt so the app can surface cloud
    /// health (a silent local fallback otherwise hides that the cloud is failing).
    /// `CloudConnectivityResult.ok` on success or no-speech (the cloud was reached);
    /// `CloudConnectivityResult.failed` when the remote provider threw. Never fired for
    /// purely-local routes.
    private let onRemoteOutcome: @Sendable (CloudConnectivityResult) -> Void
    private let mode: @Sendable () -> TranscriptionMode

    private let lock = NSLock()
    private var _lastSuccessfulMode: TranscriptionMode?

    public var lastSuccessfulMode: TranscriptionMode? {
        lock.withLock { _lastSuccessfulMode }
    }

    public init(
        local: TranscriptionProvider?,
        remote: TranscriptionProvider?,
        onRemoteOutcome: @escaping @Sendable (CloudConnectivityResult) -> Void = { _ in },
        mode: @escaping @Sendable () -> TranscriptionMode
    ) {
        self.local = local
        self.remote = remote
        self.onRemoteOutcome = onRemoteOutcome
        self.mode = mode
    }

    public func isAvailable() async -> Bool {
        switch mode() {
        case .localOnly:
            return await local?.isAvailable() == true
        case .remoteOnly:
            return await remote?.isAvailable() == true
        case .localFirst, .remoteFirst:
            if await local?.isAvailable() == true { return true }
            return await remote?.isAvailable() == true
        }
    }

    public func transcribe(
        pcmChunks: @escaping PcmChunksFactory, sampleRateHz: Int
    ) async throws -> RoutedTranscription {
        let result: RoutedTranscription
        switch mode() {
        case .localOnly:
            result = try await runProvider(
                local, role: "local", pcmChunks: pcmChunks, sampleRateHz: sampleRateHz,
                modeUsed: .localOnly)

        case .remoteOnly:
            result = try await reportingRemote {
                try await self.runProvider(
                    self.remote, role: "remote", pcmChunks: pcmChunks,
                    sampleRateHz: sampleRateHz, modeUsed: .remoteOnly)
            }

        case .localFirst:
            do {
                result = try await runProvider(
                    local, role: "local", pcmChunks: pcmChunks, sampleRateHz: sampleRateHz,
                    modeUsed: .localFirst)
            } catch let error where error is CancellationError || error.isNoSpeechDetected {
                throw error
            } catch {
                result = try await reportingRemote {
                    try await self.runProvider(
                        self.remote, role: "remote", pcmChunks: pcmChunks,
                        sampleRateHz: sampleRateHz, modeUsed: .remoteOnly, suppressed: error)
                }
            }

        case .remoteFirst:
            do {
                result = try await reportingRemote {
                    try await self.runProvider(
                        self.remote, role: "remote", pcmChunks: pcmChunks,
                        sampleRateHz: sampleRateHz, modeUsed: .remoteFirst)
                }
            } catch let error where error is CancellationError || error.isNoSpeechDetected {
                throw error
            } catch {
                result = try await runProvider(
                    local, role: "local", pcmChunks: pcmChunks, sampleRateHz: sampleRateHz,
                    modeUsed: .localOnly, suppressed: error)
            }
        }
        lock.withLock { _lastSuccessfulMode = result.modeUsed }
        return result
    }

    /// Runs a remote attempt and reports its outcome via `onRemoteOutcome`. No-speech counts
    /// as a reachable cloud (Ok); any other throw is reported Failed and re-thrown so the
    /// caller's fallback/error handling is unchanged.
    private func reportingRemote(
        _ block: () async throws -> RoutedTranscription
    ) async throws -> RoutedTranscription {
        do {
            let result = try await block()
            onRemoteOutcome(.ok(detail: nil))
            return result
        } catch let error where error is CancellationError {
            throw error
        } catch let error where error.isNoSpeechDetected {
            onRemoteOutcome(.ok(detail: nil))
            throw error
        } catch {
            onRemoteOutcome(
                .failed(message: transcriptionErrorMessage(error) ?? "Cloud transcription failed."))
            throw error
        }
    }

    private func runProvider(
        _ provider: TranscriptionProvider?,
        role: String,
        pcmChunks: PcmChunksFactory,
        sampleRateHz: Int,
        modeUsed: TranscriptionMode,
        suppressed: Error? = nil
    ) async throws -> RoutedTranscription {
        guard let provider, await provider.isAvailable() else {
            // The KMP router attached `suppressed` to ProviderUnavailable via addSuppressed;
            // the fixed Swift seam's case has no underlying slot, so the primary error is
            // dropped on this path (it was already reported via onRemoteOutcome when remote).
            throw TranscriptionError.providerUnavailable(providerId: provider?.id ?? role)
        }
        do {
            let result = try await provider.transcribe(
                pcmChunks: pcmChunks(), sampleRateHz: sampleRateHz)
            return RoutedTranscription(
                text: result.text,
                modeUsed: modeUsed,
                providerId: result.providerId,
                modelUsed: result.modelUsed,
                segments: result.segments,
                words: result.words
            )
        } catch let error where error is CancellationError {
            throw error
        } catch {
            throw Self.chainingSuppressed(error, suppressed)
        }
    }

    /// Kotlin `addSuppressed` equivalent: the fallback's failure carries the primary path's
    /// error where the seam has a slot for it (`transcriptionFailed.underlying`).
    private static func chainingSuppressed(_ error: Error, _ suppressed: Error?) -> Error {
        guard let suppressed else { return error }
        if let transcriptionError = error as? TranscriptionError,
            case .transcriptionFailed(let message, let underlying) = transcriptionError,
            underlying == nil
        {
            return TranscriptionError.transcriptionFailed(message, underlying: suppressed)
        }
        return error
    }
}

/// Best user-facing message for an error, mirroring Kotlin's `Throwable.message` (nil when the
/// error carries no message of its own).
func transcriptionErrorMessage(_ error: Error) -> String? {
    if let transcriptionError = error as? TranscriptionError {
        switch transcriptionError {
        case .noSpeechDetected(let reason):
            return reason
        case .providerUnavailable(let providerId):
            return "provider unavailable: \(providerId)"
        case .transcriptionFailed(let message, _):
            return message
        }
    }
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        return description
    }
    return nil
}

extension Error {
    fileprivate var isNoSpeechDetected: Bool {
        if let transcriptionError = self as? TranscriptionError,
            case .noSpeechDetected = transcriptionError
        {
            return true
        }
        return false
    }
}
