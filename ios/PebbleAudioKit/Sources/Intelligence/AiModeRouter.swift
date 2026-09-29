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
    /// Admits a fallback line the first time and then at most every ten minutes per template and
    /// cause — the transcription router's discipline, for the same reason: a primary that is
    /// down is down for every queued job.
    private let fallbackLogGate: RepeatingLogGate

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
        log: @escaping @Sendable (String) -> Void = { _ in },
        fallbackLogGate: RepeatingLogGate = RepeatingLogGate()
    ) {
        self.local = local
        self.remote = remote
        self.mode = mode
        self.log = log
        self.fallbackLogGate = fallbackLogGate
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
        } catch _ where Task.isCancelled {
            // The same, in `URLSession`'s words (`URLError(.cancelled)`): callers check for
            // `CancellationError`, and a cancelled pass must not be recorded as a cloud failure.
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
                noteFallbackAnswered(
                    request, mode: mode, primary: .onDevice,
                    primaryId: local?.id ?? AiFailureOrigin.onDevice.rawValue, error: error,
                    result: result)
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
            } catch let error
                where AiInputPolicy.requiresWholeInput(templateId: request.prompt.id)
                && Self.interruptedInFlight(error)
            {
                // A whole-input request — a recap, an Ask over a range, an Extended summary —
                // that the cloud accepted and then timed out or lost the connection on is not
                // handed to the on-device model. Its input was sized for the cloud; the phone
                // would refuse it (`AiInputPolicy`) after doing the work of building it, and a
                // big request is exactly the one most likely to time out. The cloud's own
                // failure is the answer, and the caller retries it later.
                throw error
            } catch {
                let result = try await runProvider(
                    local, role: .onDevice, request, modeUsed: .localOnly, suppressed: error)
                noteFallbackAnswered(
                    request, mode: mode, primary: .cloud,
                    primaryId: remote?.id ?? AiFailureOrigin.cloud.rawValue, error: error,
                    result: result)
                return (
                    result,
                    ProcessingFallback(
                        direction: .cloudToLocal, cause: .classify(Self.message(of: error)))
                )
            }
        }
    }

    /// Writes a line when a First mode's fallback ANSWERED — the one outcome that used to leave
    /// no trace at all.
    ///
    /// A failure was always logged (`record`), but a fallback that succeeded wrote nothing: the
    /// primary's error was reduced to `ProcessingFallback`'s four-way cause and dropped. That is
    /// the transcription side's ten-day silent-engine failure in AI form — a Remote-first user
    /// whose cloud calls all failed got every title from the on-device model, and nothing on the
    /// device said so or why. The line carries the classified kind and a bounded, key-redacted
    /// prefix of the primary's own message (`AiFailureLog.detail`), never transcript text; it is
    /// gated per template and cause so a backlog of 145 conversations writes it once, then a
    /// count.
    private func noteFallbackAnswered(
        _ request: AiRunRequest, mode: AiProcessingMode, primary: AiFailureOrigin,
        primaryId: String, error: Error, result: RoutedAiResult
    ) {
        let kind = AiFailure.kind(of: error)
        guard
            let repeats = fallbackLogGate.admit(
                "\(request.prompt.id)|\(primary.rawValue)|\(kind.rawValue)")
        else { return }
        let fallback: AiFailureOrigin = primary == .cloud ? .onDevice : .cloud
        var line =
            "ai fallback: \(request.prompt.id) mode=\(mode.rawValue) "
            + "\(primary.rawValue)=\(primaryId) failed (\(kind.rawValue)): "
            + "\(AiFailureLog.detail(of: error).prefix(Self.fallbackDetailChars)); "
            + "answered by \(fallback.rawValue)=\(result.providerId)"
        if result.inputTruncated { line += " from a cut input (provisional)" }
        if repeats > 0 { line += " [\(repeats) more like it since the last line]" }
        log(line)
    }

    /// Enough of the primary's message to tell a 401 from a 429 from an outage; the full body
    /// runs to kilobytes and the ring holds 400 lines.
    static let fallbackDetailChars = 200

    /// A cloud request that was sent and then did not come back: timed out, lost its
    /// connection, or cancelled under it (the system suspending the app mid-request).
    static func interruptedInFlight(_ error: Error) -> Bool {
        let interrupted: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cancelled]
        if let urlError = error as? URLError { return interrupted.contains(urlError.code) }
        if case .providerFailed(_, let underlying)? = error as? AiError,
            let urlError = underlying as? URLError
        {
            return interrupted.contains(urlError.code)
        }
        return AiFailure.kind(of: error) == .timedOut
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
            // A provider that is unavailable for a REASON — an account on hold, a 429 still in
            // force — says so, and the reason is what escapes: "out of credit (402)" is a thing a
            // person can fix, "no AI provider is available" sends them to a Settings screen where
            // everything looks configured.
            if let provider,
                let reason = await (provider as? AiUnavailabilityExplaining)?.unavailabilityReason()
            {
                throw AiError.providerFailed(reason)
            }
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
            outputTokens: providerResult.outputTokens,
            inputTruncated: providerResult.inputTruncated,
            // `suppressed` is set exactly when this provider is standing in for a primary that
            // failed — the one fact a caller needs to tell provisional work from finished work.
            viaFallback: suppressed != nil
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

// MARK: - What each slot can be handed

extension AiModeRouter {
    /// Characters of transcript the LOCAL slot may be handed in one call — what
    /// `AskBudget.forMode(_:modelId:onDeviceMaxInputChars:)` should be given for the two local
    /// modes. Nil when there is no local provider, or it cannot say; the caller then uses
    /// `OnDeviceAiProvider.defaultMaxInputChars`, exactly as before. See `AiInputWindowReporting`.
    public func localInputChars() async -> Int? {
        guard let reporting = local as? AiInputWindowReporting else { return nil }
        return await reporting.inputChars()
    }

    /// The REMOTE slot's context window in tokens — what `AskBudget.forContext(tokens:)` should
    /// be given for the two remote modes when it is non-nil. Nil when the remote provider is
    /// OpenAI (its window comes from `AiModels` by model id, as today), or there is none.
    public func remoteContextTokens() async -> Int? {
        guard let reporting = remote as? AiInputWindowReporting else { return nil }
        return await reporting.contextTokens()
    }

    /// The same question as `firstCallInputChars` for a STRUCTURED call (follow-up
    /// extraction). The on-device follow-up sift reads a conversation whole and cuts it itself,
    /// so the local modes impose nothing; a remote slot that reports its window (Apple Private
    /// Cloud Compute's 32K tokens, where a four-hour conversation does not fit) is held to it;
    /// OpenAI's catalog windows are far above any conversation. Nil means "no limit beyond the
    /// caller's own".
    public func firstStructuredCallInputChars() async -> Int? {
        switch mode() {
        case .localOnly, .localFirst:
            return nil
        case .remoteOnly, .remoteFirst:
            guard let tokens = await remoteContextTokens() else { return nil }
            return AskBudget.forContext(tokens: tokens).transcriptChars
        }
    }

    /// Characters of transcript the provider that runs FIRST in the current mode can be handed
    /// in one call — what a planner sizes a request by before it exists. The local modes ask
    /// the on-device slot (`localInputChars`); the remote modes ask the remote slot's window
    /// (Apple Private Cloud Compute reports one) or, for OpenAI, the catalog's window for
    /// `remoteModelId`. The same numbers Ask plans against, with the same headroom.
    ///
    /// A fallback is NOT sized for: it refuses a whole-input request it cannot read whole
    /// (`AiInputPolicy`) rather than being handed something it quietly cuts.
    public func firstCallInputChars(remoteModelId: String?) async -> Int {
        switch mode() {
        case .localOnly, .localFirst:
            return await localInputChars() ?? OnDeviceAiProvider.defaultMaxInputChars
        case .remoteOnly, .remoteFirst:
            if let tokens = await remoteContextTokens() {
                return AskBudget.forContext(tokens: tokens).transcriptChars
            }
            return AskBudget.forModel(id: remoteModelId).transcriptChars
        }
    }
}

// MARK: - A remote account on hold

extension AiModeRouter {
    /// Checks the remote provider's held account when its hold says a check is due — and only
    /// in a mode that can use the cloud at all: a Local-only user's parked OpenAI account is not
    /// worth a request. Nil when nothing was due. See `OpenAiChatAiProvider.probeHeldAccountIfDue`.
    @discardableResult
    public func probeHeldRemoteAccountIfDue(foreground: Bool) async -> CloudAccountProbeOutcome? {
        guard mode() != .localOnly, let probing = remote as? AiAccountProbing else { return nil }
        return await probing.probeHeldAccountIfDue(foreground: foreground)
    }
}

extension Error {
    /// Errors a First mode must re-throw instead of falling back: cancellation and explicit
    /// consent failures.
    ///
    /// Cancellation includes the shape `URLSession` gives it — `URLError(.cancelled)` rather
    /// than `CancellationError` — whenever the task running the router has been cancelled. A
    /// pass cancelled mid-request (the app backgrounded, the loop restarted) used to take that
    /// for an ordinary cloud failure and start the on-device model on its way out.
    fileprivate var isNeverSwallowed: Bool {
        if self is CancellationError { return true }
        if let aiError = self as? AiError, case .consentRequired = aiError { return true }
        if Task.isCancelled { return true }
        return false
    }
}
