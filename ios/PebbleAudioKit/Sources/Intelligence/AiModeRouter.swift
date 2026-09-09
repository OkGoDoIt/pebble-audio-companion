import Foundation
import Transcription

// Port of `core/ai/.../AiModeRouter.kt`.

/// Local/remote AI routing for transcript processing.
///
/// Semantics intentionally match the transcription router: Only modes never fall back; First
/// modes try the preferred provider and then fall back to the other provider for ordinary
/// provider failures. Cancellation and explicit consent failures are never swallowed —
/// **ConsentRequired NEVER falls back** (plan Part 4.5).
public final class AiModeRouter: @unchecked Sendable {
    private let local: AiProvider?
    private let remote: AiProvider?
    private let mode: @Sendable () -> AiProcessingMode

    private let lock = NSLock()
    private var _lastSuccessfulMode: AiProcessingMode?
    private var _lastFallback: ProcessingFallback?

    public var lastSuccessfulMode: AiProcessingMode? {
        lock.withLock { _lastSuccessfulMode }
    }

    /// Whether a "first" mode is currently being served by its fallback, and why. Nil when the
    /// preferred provider is working. Same contract as the transcription router's — see
    /// `ProcessingFallback` in the Transcription module, which owns the rules for both axes so
    /// the disclosure cannot mean two different things depending on which one it came from.
    public var lastFallback: ProcessingFallback? {
        lock.withLock { _lastFallback }
    }

    public init(
        local: AiProvider?,
        remote: AiProvider?,
        mode: @escaping @Sendable () -> AiProcessingMode
    ) {
        self.local = local
        self.remote = remote
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

    public func run(_ request: AiRunRequest) async throws -> RoutedAiResult {
        let result: RoutedAiResult
        /// Set only where a fallback actually produced the result; every other path clears it.
        var fallback: ProcessingFallback?
        switch mode() {
        case .localOnly:
            result = try await runProvider(local, role: "local", request, modeUsed: .localOnly)

        case .remoteOnly:
            result = try await runProvider(remote, role: "remote", request, modeUsed: .remoteOnly)

        case .localFirst:
            do {
                result = try await runProvider(
                    local, role: "local", request, modeUsed: .localFirst)
            } catch let error where error.isNeverSwallowed {
                throw error
            } catch {
                result = try await runProvider(
                    remote, role: "remote", request, modeUsed: .remoteOnly, suppressed: error)
                fallback = ProcessingFallback(
                    direction: .localToCloud, cause: .classify(Self.message(of: error)))
            }

        case .remoteFirst:
            do {
                result = try await runProvider(
                    remote, role: "remote", request, modeUsed: .remoteFirst)
            } catch let error where error.isNeverSwallowed {
                throw error
            } catch {
                result = try await runProvider(
                    local, role: "local", request, modeUsed: .localOnly, suppressed: error)
                fallback = ProcessingFallback(
                    direction: .cloudToLocal, cause: .classify(Self.message(of: error)))
            }
        }
        lock.withLock {
            _lastSuccessfulMode = result.modeUsed
            _lastFallback = fallback
        }
        return result
    }

    /// The failed path's message, in the shape `ProcessingFallbackCause.classify` reads: our own
    /// thrown literals, a parenthesised HTTP status, or the `URLError` marker. `AiError` carries
    /// no `LocalizedError` conformance, so its three cases are spelled out rather than left to
    /// `localizedDescription` (which would print "The operation couldn't be completed").
    private static func message(of error: Error) -> String? {
        guard let aiError = error as? AiError else { return storedFailureMessage(error) }
        switch aiError {
        case .providerUnavailable(let providerId), .consentRequired(let providerId):
            return "provider unavailable: \(providerId)"
        case .providerFailed(let message, let underlying):
            // A network failure is the one cause worth naming separately, and it arrives
            // wrapped: `storedFailureMessage` stamps the marker `classify` looks for.
            if let underlying, underlying is URLError { return storedFailureMessage(underlying) }
            return message
        }
    }

    private func runProvider(
        _ provider: AiProvider?,
        role: String,
        _ request: AiRunRequest,
        modeUsed: AiProcessingMode,
        suppressed: Error? = nil
    ) async throws -> RoutedAiResult {
        guard let provider, await provider.isAvailable() else {
            // The KMP router attached `suppressed` via addSuppressed; the fixed Swift seam's
            // case has no underlying slot, so the primary error is dropped on this path.
            throw AiError.providerUnavailable(providerId: provider?.id ?? role)
        }
        let providerResult: AiProviderResult
        do {
            providerResult = try await provider.run(request)
        } catch {
            throw Self.chainingSuppressed(error, suppressed)
        }
        return RoutedAiResult(
            text: providerResult.text,
            modeUsed: modeUsed,
            providerId: provider.id,
            modelUsed: providerResult.modelUsed,
            inputTokens: providerResult.inputTokens,
            outputTokens: providerResult.outputTokens
        )
    }

    /// Kotlin `addSuppressed` equivalent: the fallback's failure carries the primary path's
    /// error where the seam has a slot for it (`providerFailed.underlying`).
    private static func chainingSuppressed(_ error: Error, _ suppressed: Error?) -> Error {
        guard let suppressed else { return error }
        if let aiError = error as? AiError,
            case .providerFailed(let message, let underlying) = aiError,
            underlying == nil
        {
            return AiError.providerFailed(message, underlying: suppressed)
        }
        return error
    }
}

extension Error {
    /// Errors a First mode must re-throw instead of falling back: cancellation and explicit
    /// consent failures.
    fileprivate var isNeverSwallowed: Bool {
        if self is CancellationError { return true }
        if let aiError = self as? AiError, case .consentRequired = aiError { return true }
        return false
    }
}
