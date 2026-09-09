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
    /// Where an AI failure goes so a person can find it afterwards.
    ///
    /// It went nowhere before. Pulling the flight recorder off the device for the reported bug
    /// turned up link, session, heartbeat and cloud *transcription* lines and not one AI or
    /// note-job line — there was no way to diagnose a failed note from the device at all, which
    /// is why "it says on-device but I have remote on" could not be taken any further. This is
    /// the same `RuntimeLog` sink the pipeline writes to (wired in `AppComposition`), so the
    /// lines land in Detailed Logs and in `diagnostics/companion.log` with everything else.
    ///
    /// Counters and classified kinds only — see `AiFailureLog`. Never transcript text.
    private let log: @Sendable (String) -> Void

    private let lock = NSLock()
    private var _lastSuccessfulMode: AiProcessingMode?
    private var _lastFallback: ProcessingFallback?
    /// Log conflation state — see `record(signature:line:)`.
    private var _lastFailureSignature: String?
    private var _repeatedFailures = 0

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
        mode: @escaping @Sendable () -> AiProcessingMode,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.local = local
        self.remote = remote
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

    public func run(_ request: AiRunRequest) async throws -> RoutedAiResult {
        let mode = mode()
        do {
            let (result, fallback) = try await route(request, mode: mode)
            lock.withLock {
                _lastSuccessfulMode = result.modeUsed
                _lastFallback = fallback
            }
            flushRepeats()
            return result
        } catch is CancellationError {
            // The user stopped it. Not a failure, and not worth a line in a 400-line ring.
            throw CancellationError()
        } catch {
            let failure = AiFailure.classify(error)
            record(
                signature:
                    "\(request.prompt.id)|\(failure.kind.rawValue)|\(failure.fallback?.kind.rawValue ?? "-")",
                line: AiFailureLog.line(
                    templateId: request.prompt.id,
                    mode: mode,
                    providerId: Self.chosenProviderId(mode: mode, local: local, remote: remote),
                    origin: Self.chosenOrigin(mode: mode),
                    error: error
                ))
            throw error
        }
    }

    // MARK: - Logging without flooding

    /// Writes one failure line, conflating consecutive identical failures into a count.
    ///
    /// A broken key or a paused Apple Intelligence does not fail one job, it fails every job: an
    /// enrichment backlog is 145 conversations, and 145 copies of one line would push everything
    /// else out of the 400-line ring the Detailed Logs screen tails. So the same
    /// template + cause + fallback in a row is counted, and the count goes out when the
    /// situation changes — which is the moment it becomes information.
    private func record(signature: String, line: @autoclosure () -> String) {
        let (isNew, pending): (Bool, String?) = lock.withLock {
            if _lastFailureSignature == signature {
                _repeatedFailures += 1
                return (false, nil)
            }
            let previous = summaryOfRepeatsLocked()
            _lastFailureSignature = signature
            _repeatedFailures = 0
            return (true, previous)
        }
        if let pending { log(pending) }
        if isNew { log(line()) }
    }

    /// A run that succeeded closes the streak: the count goes out, and the next failure of the
    /// same kind is reported afresh rather than silently folded into a streak that ended.
    private func flushRepeats() {
        let pending: String? = lock.withLock {
            let summary = summaryOfRepeatsLocked()
            _lastFailureSignature = nil
            _repeatedFailures = 0
            return summary
        }
        if let pending { log(pending) }
    }

    /// Caller holds `lock`.
    private func summaryOfRepeatsLocked() -> String? {
        guard _repeatedFailures > 0, let signature = _lastFailureSignature else { return nil }
        return "ai failed: \(signature) — and \(_repeatedFailures) more the same"
    }

    private func route(
        _ request: AiRunRequest, mode: AiProcessingMode
    ) async throws -> (RoutedAiResult, ProcessingFallback?) {
        switch mode {
        case .localOnly:
            return (try await runProvider(local, role: .onDevice, request, modeUsed: .localOnly), nil)

        case .remoteOnly:
            return (try await runProvider(remote, role: .cloud, request, modeUsed: .remoteOnly), nil)

        case .localFirst:
            do {
                return (
                    try await runProvider(local, role: .onDevice, request, modeUsed: .localFirst),
                    nil
                )
            } catch let error where error.isNeverSwallowed {
                throw error
            } catch {
                let result = try await runProvider(
                    remote, role: .cloud, request, modeUsed: .remoteOnly, suppressed: error)
                // Set only where the fallback actually PRODUCED the result — a fallback that
                // also failed throws above and never reaches here, so a successful fallback's
                // calm disclosure can never be mistaken for an error.
                return (
                    result,
                    ProcessingFallback(
                        direction: .localToCloud, cause: .classify(Self.message(of: error)))
                )
            }

        case .remoteFirst:
            do {
                return (
                    try await runProvider(remote, role: .cloud, request, modeUsed: .remoteFirst),
                    nil
                )
            } catch let error where error.isNeverSwallowed {
                throw error
            } catch {
                let result = try await runProvider(
                    local, role: .onDevice, request, modeUsed: .localOnly, suppressed: error)
                return (
                    result,
                    ProcessingFallback(
                        direction: .cloudToLocal, cause: .classify(Self.message(of: error)))
                )
            }
        }
    }

    /// The provider the user's MODE chose — the one whose failure is the headline.
    private static func chosenProviderId(
        mode: AiProcessingMode, local: AiProvider?, remote: AiProvider?
    ) -> String {
        switch mode {
        case .localOnly, .localFirst: return local?.id ?? "on-device"
        case .remoteOnly, .remoteFirst: return remote?.id ?? "cloud"
        }
    }

    private static func chosenOrigin(mode: AiProcessingMode) -> AiFailureOrigin {
        switch mode {
        case .localOnly, .localFirst: return .onDevice
        case .remoteOnly, .remoteFirst: return .cloud
        }
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
        role: AiFailureOrigin,
        _ request: AiRunRequest,
        modeUsed: AiProcessingMode,
        suppressed: Error? = nil
    ) async throws -> RoutedAiResult {
        guard let provider, await provider.isAvailable() else {
            // THE PRIMARY WINS. This guard used to throw `providerUnavailable` naming the
            // FALLBACK and drop `suppressed` on the floor — so a person on Remote first whose
            // key had been rejected, on a phone with no Apple Intelligence, was told "No AI
            // provider is available. Check Transcription & AI in Settings", where they would
            // find remote AI switched on and correctly configured as far as the screen knew.
            // The rejected key was the only actionable fact in the event and it was the one
            // thing thrown away.
            if let suppressed { throw suppressed }
            throw AiError.providerUnavailable(providerId: provider?.id ?? role.rawValue)
        }
        let providerResult: AiProviderResult
        do {
            providerResult = try await provider.run(request)
        } catch {
            throw Self.leadingWithPrimary(
                primary: suppressed, fallbackFailure: error,
                fallbackOrigin: role, fallbackProviderId: provider.id)
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

    /// Both providers were tried and both failed: what escapes is the PRIMARY failure, with the
    /// fallback's carried underneath as `AiFallbackFailure`.
    ///
    /// This is the inverse of what the router did before. The old `chainingSuppressed` surfaced
    /// the fallback's message and tucked the primary into `providerFailed.underlying` — and only
    /// when that slot happened to be free, which for an on-device failure it never is, because
    /// the provider has already chained the platform error there. So on Remote first, a cloud
    /// failure followed by an on-device failure surfaced "On-device AI generation failed" and
    /// the cloud cause vanished entirely. The user's word for it was that the message was about
    /// the wrong provider, and it was.
    ///
    /// The fallback is not discarded — `AiFailure.classify` reads it back out as secondary
    /// detail, so the dock can add "the on-device fallback did not work either" underneath. It
    /// is just never the headline.
    static func leadingWithPrimary(
        primary: Error?,
        fallbackFailure: Error,
        fallbackOrigin: AiFailureOrigin,
        fallbackProviderId: String
    ) -> Error {
        guard let primary else { return fallbackFailure }
        let carried = AiFallbackFailure(
            origin: fallbackOrigin, providerId: fallbackProviderId, error: fallbackFailure)
        switch primary as? AiError {
        case .providerFailed(let message, _):
            return AiError.providerFailed(message, underlying: carried)
        case .providerUnavailable(let providerId):
            // `providerUnavailable` has no slot to carry anything, and rewriting it into
            // `providerFailed` would change how every caller classifies it (a missing provider
            // is a configuration problem, not a run that went wrong). The primary still wins;
            // the fallback's detail is what is given up, and it is the less useful half.
            return AiError.providerUnavailable(providerId: providerId)
        case .consentRequired, .none:
            // A non-`AiError` primary (a `URLError` thrown straight out of the transport) keeps
            // its own type so `AiFailure.classify` can read it; consent never reaches here.
            return primary
        }
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
