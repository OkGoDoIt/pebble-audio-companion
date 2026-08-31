import Foundation

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

    public var lastSuccessfulMode: AiProcessingMode? {
        lock.withLock { _lastSuccessfulMode }
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
            }
        }
        lock.withLock { _lastSuccessfulMode = result.modeUsed }
        return result
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
