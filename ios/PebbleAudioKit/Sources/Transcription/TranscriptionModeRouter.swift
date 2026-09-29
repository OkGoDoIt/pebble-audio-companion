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
    /// The flight recorder. A "first" mode whose preferred engine fails says so here — gated by
    /// `logGate`, because the same failure recurs on every queued segment.
    private let log: @Sendable (String) -> Void
    private let logGate = RepeatingLogGate()

    private let lock = NSLock()
    private var _lastSuccessfulMode: TranscriptionMode?
    private var _lastFallback: ProcessingFallback?

    public var lastSuccessfulMode: TranscriptionMode? {
        lock.withLock { _lastSuccessfulMode }
    }

    /// Whether a "first" mode is currently being served by its fallback, and why. Nil when the
    /// preferred path is working (or when the mode has no fallback). See `ProcessingFallback`
    /// for the set/clear rules — this is the value Settings discloses.
    public var lastFallback: ProcessingFallback? {
        lock.withLock { _lastFallback }
    }

    public init(
        local: TranscriptionProvider?,
        remote: TranscriptionProvider?,
        onRemoteOutcome: @escaping @Sendable (CloudConnectivityResult) -> Void = { _ in },
        mode: @escaping @Sendable () -> TranscriptionMode,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.local = local
        self.remote = remote
        self.onRemoteOutcome = onRemoteOutcome
        self.mode = mode
        self.log = log
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
        // Set only where a fallback actually produced the result; every other path clears it.
        // Assigned before the throwing calls below can escape, so a run that fails outright
        // leaves the previous state alone rather than inventing one — see `ProcessingFallback`.
        var fallback: ProcessingFallback?
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
                // An unavailable cloud (no key, consent off, an account on hold) was never
                // attempted, so it must not reach cloud health as a failed attempt: the primary's
                // failure is the whole story. See `runProvider` for the same rule.
                guard let remote, await remote.isAvailable() else {
                    noteFallback(from: "on-device", to: nil, error)
                    if error.isProviderUnavailable {
                        throw TranscriptionError.providerUnavailable(providerId: remote?.id ?? "remote")
                    }
                    throw error
                }
                noteFallback(from: "on-device", to: "cloud", error)
                result = try await reportingRemote {
                    try await self.runProvider(
                        self.remote, role: "remote", pcmChunks: pcmChunks,
                        sampleRateHz: sampleRateHz, modeUsed: .remoteOnly, suppressed: error,
                        primaryRole: "on-device", fallbackRole: "cloud")
                }
                // `storedFailureMessage`, not `transcriptionErrorMessage`: it is the exact string
                // the queue persists as `lastError`, and `classify` is written against that
                // shape (our own literals, parenthesised HTTP statuses, the `URLError` marker).
                fallback = ProcessingFallback(
                    direction: .localToCloud,
                    cause: .classify(storedFailureMessage(error)))
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
                noteFallback(
                    from: "cloud", to: await local?.isAvailable() == true ? "on-device" : nil, error)
                result = try await runProvider(
                    local, role: "local", pcmChunks: pcmChunks, sampleRateHz: sampleRateHz,
                    modeUsed: .localOnly, suppressed: error,
                    primaryRole: "cloud", fallbackRole: "on-device")
                // A cloud that was never tried because it is unavailable says why when it can
                // (a paused account is "not accepted", not "not configured").
                fallback = ProcessingFallback(
                    direction: .cloudToLocal,
                    cause: .classify(await explained(error, by: remote)))
            }
        }
        lock.withLock {
            _lastSuccessfulMode = result.modeUsed
            _lastFallback = fallback
        }
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
        suppressed: Error? = nil,
        primaryRole: String = "",
        fallbackRole: String = ""
    ) async throws -> RoutedTranscription {
        guard let provider, await provider.isAvailable() else {
            // A fallback that cannot run leaves the PRIMARY's failure as the whole story. It used
            // to be dropped here for a bare `providerUnavailable` of the fallback, which (1) hid a
            // real engine failure behind "nothing was usable" and (2) parked the task as Disabled,
            // to be un-parked and re-failed on every pass because the primary still reported
            // itself available.
            if let suppressed, !suppressed.isProviderUnavailable { throw suppressed }
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
            guard let suppressed else { throw error }
            throw Self.combining(
                primary: suppressed, primaryRole: primaryRole,
                fallback: error, fallbackRole: fallbackRole)
        }
    }

    /// The error for a job where the preferred engine failed and the fallback then failed too.
    ///
    /// Both failures are kept, PRIMARY FIRST: "<primary's stored message> [then <fallback role>:
    /// <fallback's stored message>]". The primary leads because it is the engine the user chose
    /// to rely on, and `TranscriptionFailureKind.classify` reads only the part before
    /// `fallbackMarker`, so the reason a surface shows is the primary's. This replaced keeping the
    /// fallback's message alone, which is how a Local-first user saw ten days of "out of credit"
    /// while the thing actually broken — the on-device model — was named nowhere.
    ///
    /// Not combined: a fallback that found no speech (a valid result), and a fallback that was
    /// unavailable after all (its `transcribe` said so), where the primary's error stands alone.
    static func combining(
        primary: Error, primaryRole: String, fallback: Error, fallbackRole: String
    ) -> Error {
        if fallback.isNoSpeechDetected { return fallback }
        if fallback.isProviderUnavailable {
            return primary.isProviderUnavailable ? fallback : primary
        }
        return TranscriptionError.transcriptionFailed(
            storedFailureMessage(primary) + TranscriptionFailureKind.fallbackMarker
                + "\(fallbackRole): \(storedFailureMessage(fallback))]",
            underlying: fallback
        )
    }

    /// Writes the fallback to the flight recorder — the first time, and then at most once per
    /// `RepeatingLogGate` interval while the same kind of failure keeps recurring.
    /// `fallback` nil means there is nothing to fall back to right now.
    private func noteFallback(from primary: String, to fallback: String?, _ error: Error) {
        let message = storedFailureMessage(error)
        let kind = TranscriptionFailureKind.classify(message)
        let next = fallback.map { "trying \($0)" } ?? "no fallback available"
        guard let repeats = logGate.admit("\(primary)->\(next):\(kind.rawValue)") else {
            return
        }
        log(
            "transcription: \(primary) failed (\(kind.rawValue)): \(message.prefix(200)); \(next)"
                + (repeats > 0 ? " [\(repeats) more like it since the last line]" : "")
        )
    }

    /// The stored message for `error`, or — when it only says the provider was unavailable — the
    /// provider's own account of why, if it has one.
    private func explained(_ error: Error, by provider: TranscriptionProvider?) async -> String {
        if error.isProviderUnavailable,
            let reason = await (provider as? any TranscriptionAvailabilityExplaining)?
                .unavailabilityReason()
        {
            return reason
        }
        return storedFailureMessage(error)
    }
}

/// A provider that can say why it reports itself unavailable, for the surfaces that disclose a
/// fallback. Optional on purpose: the fixed `TranscriptionProvider` seam has no slot for it.
public protocol TranscriptionAvailabilityExplaining: Sendable {
    /// A stored-failure-shaped message (so `TranscriptionFailureKind.classify` can read it), or
    /// nil when the provider is available or has nothing specific to say.
    func unavailabilityReason() async -> String?
}

/// Admits a repeating log line the first time and then at most once per `intervalMs`, reporting
/// how many repeats it held back in between.
///
/// Public because the AI router needs the same discipline for the same reason: a fallback that
/// happens once happens on every queued job, and a flight-recorder ring of 400 lines cannot hold
/// 145 copies of one sentence.
public final class RepeatingLogGate: @unchecked Sendable {
    private let intervalMs: Int64
    private let nowMs: @Sendable () -> Int64
    private let lock = NSLock()
    private var entries: [String: (lastMs: Int64, held: Int)] = [:]

    public init(
        intervalMs: Int64 = 10 * 60_000,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.intervalMs = intervalMs
        self.nowMs = nowMs
    }

    /// nil when the line should be held back; otherwise the number of repeats held back since
    /// the key was last admitted.
    public func admit(_ key: String) -> Int? {
        let now = nowMs()
        return lock.withLock {
            if let entry = entries[key], now - entry.lastMs < intervalMs {
                entries[key] = (entry.lastMs, entry.held + 1)
                return nil
            }
            let held = entries[key]?.held ?? 0
            entries[key] = (now, 0)
            return held
        }
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

    fileprivate var isProviderUnavailable: Bool {
        if let transcriptionError = self as? TranscriptionError,
            case .providerUnavailable = transcriptionError
        {
            return true
        }
        return false
    }
}
