import Foundation
import Transcription

// Why an AI run did not produce anything, in the shape a person can act on — and, when a First
// mode tried both providers, WHICH of the two failures is the one worth telling them about.
//
// The reported case that produced this file: a four-hour conversation, Remote first, "Extended
// summary didn't finish — On-device AI generation failed". Every word of that sub-line was about
// the provider the user had NOT chosen. Remote had failed first; the on-device fallback then
// failed too; the router surfaced the fallback's message and the remote cause never reached a
// screen or a log. Whatever OpenAI actually said — a rejected key, a rate limit, an outage — was
// the only actionable fact in the whole event, and it was the one thing thrown away.
//
// So the rule this file exists to enforce is: **the primary failure is the headline, the
// fallback's is a trailing clause.** `AiModeRouter` throws the primary's message with the
// fallback's error wrapped in `AiFallbackFailure` underneath it, and everything that reports a
// failure classifies here rather than reading either message.
//
// The split follows `TranscriptionFailureKind`, deliberately and for the same reason (B20): the
// kit returns a taxonomy and no prose, the app owns the words
// (`App/DesignSystem/Copy+AiFailure.swift`), and one vocabulary serves every surface. That
// mattered here beyond tidiness — the note dock was rendering `AiError.providerFailed`'s message
// verbatim, and the cloud provider splices up to 240 bytes of OpenAI's response body into it. On
// a 401 that body is the request and a partially-redacted key.

/// Which provider a failure came from. `AiFailureKind` implies this for most cases; it is
/// carried explicitly only where it does not (a fallback clause has to name the right one).
public enum AiFailureOrigin: String, Sendable, Equatable, CaseIterable {
    case cloud
    case onDevice
}

/// What an AI run hit. Coarser than the provider's own message on purpose: this is what the
/// person is told, so every case has to be something they can either act on or safely ignore.
public enum AiFailureKind: String, Sendable, Equatable, CaseIterable {
    /// No provider was usable at all — nothing selected, no key, consent off.
    case notConfigured
    /// Cloud AI is switched off, or was never agreed to. Never falls back (plan Part 4.5).
    case consentRequired
    /// 401 — the provider did not accept the key.
    case keyRejected
    /// 403 — a real key without permission for this model.
    case keyNotPermitted
    /// 429 — throttled. Busy, not broke: see `accountOutOfFunds`.
    case rateLimited
    /// The provider's account has no money left. The one kind on this axis the user can fix
    /// completely, in a minute, from their provider's billing page.
    case accountOutOfFunds
    /// 5xx, or the provider reported an error of its own. Nothing here is the user's to fix.
    case providerTrouble
    /// The provider accepted the job and never finished it.
    case timedOut
    /// The request never reached the provider.
    case noConnection
    /// Apple Intelligence is not ready to run right now — still loading, the system has taken
    /// the model's assets back, or the device is in a state (Low Power Mode) that pauses it.
    case modelUnavailable
    /// The on-device model is there and throttled: too many generations in flight, or the
    /// system rate-limiting us. Distinct from `modelUnavailable` because the advice differs —
    /// this one really does clear on its own.
    case modelBusy
    /// The request cannot fit the on-device context window, whatever we truncate. This is the
    /// case an Extended summary of a long recording lands in, and it is a fact about the
    /// recording's length rather than a fault.
    case tooLongForDevice
    /// A CLOUD model's window cannot hold a request whose template must read all of it — a
    /// day's recap or an Ask over a range on Apple Private Cloud Compute (`AiInputPolicy`). Its
    /// own case because `tooLongForDevice`'s sentence sends a person to cloud AI, which is what
    /// they are already using.
    case tooLongForModel
    /// The model's own content filter declined this material.
    case contentRefused
    /// The provider answered, with nothing in it.
    case emptyAnswer
    /// Apple Private Cloud Compute's per-person daily allowance is used up. Not `rateLimited`
    /// (that is throttling, and it clears in minutes) and not `accountOutOfFunds` (there is
    /// nothing to pay): it comes back by itself, and the on-device model is not affected.
    case usageLimit
    /// Apple Private Cloud Compute's content filter declined this material. Its own case
    /// because `contentRefused`'s sentence names the on-device model, and a refusal from
    /// Apple's cloud told in those words would be the wrong-provider headline again.
    case cloudContentRefused
    /// Something we have no better word for. The honest answer, not a guess.
    case unknown
}

extension AiFailureKind {
    /// True when the failure is about THIS input — it would fail the same way on the next pass
    /// with nothing else changed: too long for the model, declined by a content filter, an
    /// answer with nothing in it, a reply that was not the agreed shape, or something we cannot
    /// name. Only these may spend a job's attempt budget.
    ///
    /// Everything else is the world: no network, a busy or broke account, a model still
    /// loading, a provider switched off. The enrichment and follow-up budgets used to count
    /// those too — three attempts, no time between them, nothing that ever reset them — so an
    /// afternoon offline or one rate-limited minute cost a conversation its title for good.
    /// Those failures now back off in time instead, and never use up the budget.
    public var blamesTheInput: Bool {
        switch self {
        case .tooLongForDevice, .tooLongForModel, .contentRefused, .cloudContentRefused,
            .emptyAnswer, .unknown:
            return true
        case .notConfigured, .consentRequired, .keyRejected, .keyNotPermitted, .rateLimited,
            .accountOutOfFunds, .providerTrouble, .timedOut, .noConnection, .modelUnavailable,
            .modelBusy, .usageLimit:
            return false
        }
    }
}

/// The fallback provider's own failure, carried under the primary's in
/// `AiError.providerFailed(_:underlying:)`.
///
/// A distinct type because that slot has two meanings: a PROVIDER chains the platform error it
/// caught there (a `URLError`, a Foundation Models error), while the ROUTER chains the failure
/// of the provider that stepped in. Sniffing the difference out of a message is how the wrong
/// half ends up on screen, which is the bug this whole file is about.
public struct AiFallbackFailure: Error, @unchecked Sendable {
    /// Which provider stepped in and also failed.
    public let origin: AiFailureOrigin
    public let providerId: String
    public let error: Error

    public init(origin: AiFailureOrigin, providerId: String, error: Error) {
        self.origin = origin
        self.providerId = providerId
        self.error = error
    }
}

/// A classified AI failure: the headline, plus the fallback's failure when there was one.
public struct AiFailure: Sendable, Equatable {
    /// The failure of the provider the user's mode CHOSE. This is what they are told.
    public let kind: AiFailureKind
    /// Set only when a First mode's fallback ran and also failed. Secondary detail — a trailing
    /// clause, never the headline.
    public let fallback: Detail?

    public struct Detail: Sendable, Equatable {
        public let origin: AiFailureOrigin
        public let kind: AiFailureKind

        public init(origin: AiFailureOrigin, kind: AiFailureKind) {
            self.origin = origin
            self.kind = kind
        }
    }

    public init(kind: AiFailureKind, fallback: Detail? = nil) {
        self.kind = kind
        self.fallback = fallback
    }

    // MARK: - Stable literals
    //
    // The on-device markers below are matched by `classify`, exactly as
    // `TranscriptionFailureKind` matches our own thrown literals — which is what makes that
    // classifier stable, and what makes this one stable too. They are also the text that lands
    // in the flight recorder, so they are written to be read by a person, not parsed by one.

    /// `OnDeviceAiProvider` throws messages containing these.
    public enum Marker {
        public static let modelUnavailable = "on-device model is not available"
        public static let modelBusy = "on-device model is busy"
        public static let tooLongForDevice = "too long for on-device AI"
        public static let contentRefused = "declined this recording"
        public static let emptyAnswer = "empty completion"
        /// Appended to any on-device failure that happened while Low Power Mode was on. It
        /// classifies as `modelUnavailable` because that is both true and the same advice: the
        /// model would not run, and there is one switch the person can flip.
        public static let lowPower = "Low Power Mode is on"
        public static let deviceGenerationFailed = "on-device AI generation failed"
        /// `ApplePrivateCloudAiProvider` throws messages containing this. The literal is owned
        /// by `ProcessingFallbackCause` so the fallback disclosure reads the same one.
        public static let usageLimit = ProcessingFallbackCause.usageLimitMarker
        /// Also `ApplePrivateCloudAiProvider`'s. Not a superstring of `contentRefused`, and
        /// checked before it, so the two cannot be confused.
        public static let cloudContentRefused = "declined to work on this request"
        /// Either cloud provider's refusal of a whole-input template that does not fit. Owned
        /// by `AiInputPolicy`, which writes it.
        public static let tooLongForModel = AiInputPolicy.tooLongForModelMarker
    }

    // MARK: - Classification

    /// Classifies whatever `AiModeRouter.run` or a provider threw.
    ///
    /// Cancellation is NOT a failure and is not represented here — callers check for it first
    /// (the note dock says "Stopped.", the workers return without recording an attempt).
    public static func classify(_ error: Error) -> AiFailure {
        AiFailure(kind: kind(of: error), fallback: detail(of: error))
    }

    /// The fallback half, if the router attached one.
    private static func detail(of error: Error) -> Detail? {
        guard let aiError = error as? AiError,
            case .providerFailed(_, let underlying) = aiError,
            let carried = underlying as? AiFallbackFailure
        else { return nil }
        return Detail(origin: carried.origin, kind: kind(of: carried.error))
    }

    /// One error's own kind, ignoring anything chained under it.
    public static func kind(of error: Error) -> AiFailureKind {
        if let aiError = error as? AiError {
            switch aiError {
            case .consentRequired:
                return .consentRequired
            case .providerUnavailable:
                return .notConfigured
            case .providerFailed(let message, let underlying):
                // The Private Cloud Compute markers first: before the shared taxonomy, which
                // would read a limit as a rate limit or — worse — as an account out of money,
                // and before the on-device markers, whose sentences name the wrong provider.
                if let specific = cloudKind(in: message) { return specific }
                if let specific = onDeviceKind(in: message) { return specific }
                let classified = fromTranscriptionTaxonomy(message)
                if classified != .unknown { return classified }
                // A provider that chained the platform error it caught rather than spelling it
                // into the message — the network case, which is worth naming.
                if let underlying, !(underlying is AiFallbackFailure) {
                    return kind(of: underlying)
                }
                return .unknown
            }
        }
        if error is URLError {
            return fromTranscriptionTaxonomy(storedFailureMessage(error))
        }
        if let carried = error as? AiFallbackFailure { return kind(of: carried.error) }
        return .unknown
    }

    /// `ApplePrivateCloudAiProvider`'s literals, and the cloud providers' shared refusal of a
    /// request too long to read whole.
    private static func cloudKind(in message: String) -> AiFailureKind? {
        let text = message.lowercased()
        if text.contains(Marker.usageLimit.lowercased()) { return .usageLimit }
        if text.contains(Marker.cloudContentRefused.lowercased()) { return .cloudContentRefused }
        if text.contains(Marker.tooLongForModel.lowercased()) { return .tooLongForModel }
        return nil
    }

    /// The on-device literals. Checked BEFORE the shared taxonomy: "the on-device model is not
    /// available" would otherwise be read as `provider unavailable` → `notConfigured`, which
    /// sends a person to a Settings screen where nothing is wrong.
    private static func onDeviceKind(in message: String) -> AiFailureKind? {
        // Both sides lowercased: the markers are written the way they read in a sentence
        // ("on-device AI"), and a case-sensitive `contains` against a lowercased message is a
        // silent no-match — the exact way a specific cause decays back into "Something went
        // wrong".
        let text = message.lowercased()
        func has(_ marker: String) -> Bool { text.contains(marker.lowercased()) }
        if has(Marker.tooLongForDevice) { return .tooLongForDevice }
        if has(Marker.modelUnavailable) { return .modelUnavailable }
        if has(Marker.modelBusy) { return .modelBusy }
        if has(Marker.contentRefused) { return .contentRefused }
        if has(Marker.emptyAnswer) { return .emptyAnswer }
        // Before `deviceGenerationFailed`, which is the "we do not know" marker: an unexplained
        // failure on a phone in Low Power Mode is not fully unexplained, and "turn that off" is
        // the one thing a person can do about it.
        if has(Marker.lowPower) { return .modelUnavailable }
        if has(Marker.deviceGenerationFailed) { return .unknown }
        return nil
    }

    /// The shapes both axes share — HTTP statuses, the `URLError` marker, timeouts. Reusing
    /// `TranscriptionFailureKind.classify` rather than copying its rules is the same decision
    /// `ProcessingFallbackCause` made, and for the same reason: a second copy drifts.
    private static func fromTranscriptionTaxonomy(_ message: String) -> AiFailureKind {
        switch TranscriptionFailureKind.classify(message) {
        case .keyRejected: return .keyRejected
        case .keyNotPermitted: return .keyNotPermitted
        case .rateLimited: return .rateLimited
        case .accountOutOfFunds: return .accountOutOfFunds
        case .providerTrouble, .providerRefusedAudio: return .providerTrouble
        case .timedOut: return .timedOut
        case .noConnection: return .noConnection
        case .notConfigured: return .notConfigured
        case .modelMissing: return .modelUnavailable
        // `recordingTooLong` here means an upload limit, which no AI call has; `localEngineFailed`
        // and `audioUnreadable` are transcription-only. None of them can arise on this axis, and
        // guessing at one would be worse than saying we do not know.
        case .recordingTooLong, .localEngineFailed, .audioUnreadable, .unknown:
            return .unknown
        }
    }
}

// MARK: - The diagnostic line

/// What an AI failure writes to the flight recorder.
///
/// Its own type because the constraint is unusual: this is the one place where the raw provider
/// message IS wanted (a 401's body says whether the key is wrong or the account is out of
/// credit, and there was previously no way to learn that from a device), while transcript text
/// must never appear. So the line carries the template id, the mode, the provider ids and the
/// two classified kinds — never the prompt, never an excerpt, never the answer.
public enum AiFailureLog {
    /// One line, in the runtime log's house style: lowercase, colon-separated, counters and
    /// state rather than prose.
    public static func line(
        templateId: String,
        mode: AiProcessingMode,
        providerId: String,
        origin: AiFailureOrigin,
        error: Error
    ) -> String {
        let failure = AiFailure.classify(error)
        var line = "ai failed: \(templateId) mode=\(mode.rawValue) "
            + "\(origin.rawValue)=\(providerId) \(failure.kind.rawValue)"
        if let fallback = failure.fallback {
            line += " (fallback \(fallback.origin.rawValue): \(fallback.kind.rawValue))"
        }
        // Low Power Mode is not a separate field: `OnDeviceAiProvider` puts it in the message it
        // throws (it is what a person is told, not only what we record), and `detail` carries
        // the message through verbatim.
        line += " — \(detail(of: error))"
        return line
    }

    /// The developer-facing tail. Bounded: OpenAI's error bodies run to kilobytes, and the ring
    /// this lands in holds 400 lines total.
    static func detail(of error: Error) -> String {
        let text: String
        if let aiError = error as? AiError {
            switch aiError {
            case .providerUnavailable(let id): text = "provider unavailable: \(id)"
            case .consentRequired(let id): text = "consent required: \(id)"
            case .providerFailed(let message, let underlying):
                var composed = message
                if let carried = underlying as? AiFallbackFailure {
                    composed += " | fallback \(carried.providerId): \(detail(of: carried.error))"
                } else if let underlying {
                    composed += " | \(underlying)"
                }
                text = composed
            }
        } else {
            text = storedFailureMessage(error)
        }
        return redactingKeys(String(text.prefix(400)))
    }

    /// Removes anything shaped like an API key before the line reaches the log.
    ///
    /// The raw provider body is the reason this tail exists — a 401's body is the only thing that
    /// says whether the key is wrong or the account is out of credit — but on a 401 that body
    /// also quotes the key back, and this log is a file the user exports and sends to somebody.
    /// OpenAI redacts its middle; nothing guarantees the next provider will. Runs only on a
    /// failure, over at most 400 characters.
    static func redactingKeys(_ text: String) -> String {
        text.replacingOccurrences(
            of: "sk-[A-Za-z0-9_\\-]{6,}", with: "sk-***", options: .regularExpression)
    }
}
