import Foundation
import Receiver
import WireProtocol

// What the watch actually said when it refused this phone — in the shape a person can act on.
//
// The wire protocol is precise about refusal: `AUTH_RESULT` carries an `AuthStatus`, `REVOKED`
// carries a `RevokeReason`, `ERROR` carries a `ProtocolErrorCode`, and the Info characteristic
// states the version range the watch will speak. All four were decoded and thrown away, so a
// receiver the watch had de-authorized looped connect → authorize → resync forever behind the
// word "Connecting…" — with nothing on screen, nothing in Diagnostics and nothing in the
// support report to say why.
//
// The split is the one `ApiKeyCheckOutcome` and `TranscriptionFailureKind` already use: a
// taxonomy of causes, deduplicated to the point where two causes stop implying different next
// actions, and never a raw code or the protocol's own words. (The copy lives in `StatusCopy`
// rather than the app's `Copy.swift` only because the status card is rendered from this target
// and the kit cannot import the app — `Copy.WatchLink` re-exports these constants so the
// catalog stays single-sourced, exactly as `Copy.Status` does.)

/// Why the watch is refusing this phone, as one cause with one next move.
public enum WatchLinkFault: Sendable, Equatable, CaseIterable {
    /// The watch is bound to a DIFFERENT receiver. In practice the common one: reinstalling the
    /// app mints a new receiver id, and the watch keeps the old binding until it is told to let
    /// go. Only the watch can release it, which is why the copy names the on-watch step.
    case boundToAnotherPhone

    /// This phone WAS authorized and no longer is — the binding was cleared on the watch, or the
    /// watch is rejecting our messages as unauthorized. Re-consent on the watch fixes it.
    case authorizationRemoved

    /// This phone released the binding itself (Forget Watch). Not a fault so much as a state the
    /// user must be told they are in, because the reconnect loop looks identical from outside.
    case releasedByThisPhone

    /// Background Audio is switched off on the watch. Deliberate; needs a deliberate restart.
    case captureOffOnWatch

    /// The watch speaks a newer protocol than this build of the app understands.
    case appTooOldForWatch

    /// The watch's firmware is older than this app can speak to.
    case watchFirmwareTooOld

    /// A version disagreement where the watch never told us which side is behind.
    case versionMismatch

    /// The watch reported a fault of its own (internal error, or its service is in `error`).
    case watchTrouble

    /// The watch could not make sense of what this app sent — an app-side defect, not anything
    /// the user did or can fix.
    case appSentSomethingUnexpected

    /// The watch refused and gave a code this build does not know. The honest answer, not a
    /// guess: newer firmware may add refusal codes, and inventing advice for them would be worse
    /// than admitting we do not have any.
    case unknown

    /// True when the watch is the only place this can be resolved — the app can retry forever
    /// and never get further on its own. Drives whether a surface offers a retry at all.
    public var needsWatchAction: Bool {
        switch self {
        case .boundToAnotherPhone, .authorizationRemoved, .captureOffOnWatch,
            .releasedByThisPhone:
            return true
        case .appTooOldForWatch, .watchFirmwareTooOld, .versionMismatch, .watchTrouble,
            .appSentSomethingUnexpected, .unknown:
            return false
        }
    }
}

// MARK: - Classification

extension WatchLinkFault {
    /// The fault a denial `AuthStatus` describes, or nil when the status is not a denial.
    public static func from(authStatusRaw raw: Int) -> WatchLinkFault? {
        guard raw >= 0, raw <= Int(UInt8.max), let status = AuthStatus(rawValue: UInt8(raw)) else {
            return .unknown
        }
        switch status {
        case .ok, .pendingUserConsent: return nil
        case .deniedMismatch: return .boundToAnotherPhone
        case .deniedDisabled: return .captureOffOnWatch
        // "Invalid" is the watch saying our request itself did not hold together. There is
        // nothing for the user in that distinction, so it joins the watch-side trouble bucket.
        case .invalid: return .watchTrouble
        }
    }

    /// The fault a `REVOKED` reason describes.
    public static func from(revokeReasonRaw raw: Int) -> WatchLinkFault {
        guard raw >= 0, raw <= Int(UInt8.max), let reason = RevokeReason(rawValue: UInt8(raw))
        else { return .unknown }
        switch reason {
        case .userOnWatch: return .authorizationRemoved
        // The watch bound someone else in our place: the same situation, and the same fix, as a
        // mismatch at authorization time.
        case .replaced: return .boundToAnotherPhone
        case .appRequested: return .releasedByThisPhone
        }
    }

    /// The fault an `ERROR` message describes. `info` disambiguates a version complaint into
    /// which side is behind — the watch states its range in the Info characteristic, so when we
    /// have read one we can say "update the app" or "update the watch" instead of shrugging.
    public static func from(
        protocolError error: ErrorMessage,
        info: InfoSnapshot? = nil,
        protoVersion: Int = ProtocolConstants.protocolVersion
    ) -> WatchLinkFault {
        switch error.errorCode {
        case .some(.malformedMessage): return .appSentSomethingUnexpected
        case .some(.unauthorized): return .authorizationRemoved
        case .some(.internal): return .watchTrouble
        case .some(.unsupportedVersion):
            return versionFault(info: info, protoVersion: protoVersion) ?? .versionMismatch
        case .none: return .unknown
        }
    }

    /// Version negotiation against the watch's advertised range, or nil when they overlap.
    ///
    /// This is the one refusal the phone can see coming: the Info read happens before the first
    /// AUTH_REQUEST, so an incompatible pair is knowable at handshake time rather than after a
    /// silent rejection.
    public static func versionFault(
        info: InfoSnapshot?,
        protoVersion: Int = ProtocolConstants.protocolVersion
    ) -> WatchLinkFault? {
        guard let info, info.protocolMin <= info.protocolMax else { return nil }
        if protoVersion < info.protocolMin { return .appTooOldForWatch }
        if protoVersion > info.protocolMax { return .watchFirmwareTooOld }
        return nil
    }

    /// The whole picture: session state, the last `ERROR` the watch sent, and the Info snapshot.
    /// Nil when nothing is wrong — a connected, authorized, streaming link has no fault, and a
    /// stale error from a previous connection must not haunt a working one.
    ///
    /// `.pendingConsent` / `.pendingEnable` are deliberately fault-free: the watch is waiting on
    /// the person, which is progress, not a refusal.
    public static func classify(
        state: ReceiverSessionState,
        protocolError: ErrorMessage? = nil,
        info: InfoSnapshot? = nil,
        watchServiceStateRaw: Int? = nil,
        protoVersion: Int = ProtocolConstants.protocolVersion
    ) -> WatchLinkFault? {
        switch state {
        case .authorized, .streaming, .pendingConsent, .pendingEnable:
            return nil
        case .denied(let statusRaw):
            return from(authStatusRaw: statusRaw)
        case .revoked(let reasonRaw):
            return from(revokeReasonRaw: reasonRaw)
        case .disconnected, .connecting, .authorizing, .connectionFailed:
            // The silent-loop case. The session never reaches `.denied` when the watch answers
            // with ERROR and drops the link, so the only trace of the refusal is the error the
            // last connection recorded — which is exactly what nothing was reading.
            if let protocolError {
                return from(protocolError: protocolError, info: info, protoVersion: protoVersion)
            }
            if let versionFault = versionFault(info: info, protoVersion: protoVersion) {
                return versionFault
            }
            if let watchServiceStateRaw, watchServiceStateRaw >= 0,
                watchServiceStateRaw <= Int(UInt8.max),
                ServiceState(rawValue: UInt8(watchServiceStateRaw)) == .error
            {
                return .watchTrouble
            }
            return nil
        }
    }
}

// MARK: - Copy

extension WatchLinkFault {
    /// The card headline: what is true, in the user's words.
    public var headline: String {
        switch self {
        case .boundToAnotherPhone: return StatusCopy.boundElsewhere
        case .authorizationRemoved: return StatusCopy.linkAuthorizationRemoved
        case .releasedByThisPhone: return StatusCopy.linkReleasedByThisPhone
        case .captureOffOnWatch: return StatusCopy.watchAudioOff
        case .appTooOldForWatch: return StatusCopy.linkAppTooOld
        case .watchFirmwareTooOld: return StatusCopy.linkWatchTooOld
        case .versionMismatch: return StatusCopy.linkVersionMismatch
        case .watchTrouble: return StatusCopy.watchNeedsAttention
        case .appSentSomethingUnexpected: return StatusCopy.linkAppSentSomethingUnexpected
        case .unknown: return StatusCopy.linkUnknownRefusal
        }
    }

    /// One calm sentence that ends where the reader's next move is.
    public var detail: String {
        switch self {
        case .boundToAnotherPhone: return StatusCopy.boundElsewhereLine
        case .authorizationRemoved: return StatusCopy.linkAuthorizationRemovedLine
        case .releasedByThisPhone: return StatusCopy.linkReleasedByThisPhoneLine
        case .captureOffOnWatch: return StatusCopy.watchAudioOffRestartLine
        case .appTooOldForWatch: return StatusCopy.linkAppTooOldLine
        case .watchFirmwareTooOld: return StatusCopy.linkWatchTooOldLine
        case .versionMismatch: return StatusCopy.linkVersionMismatchLine
        case .watchTrouble: return StatusCopy.watchNeedsAttentionLine
        case .appSentSomethingUnexpected: return StatusCopy.linkAppSentSomethingUnexpectedLine
        case .unknown: return StatusCopy.linkUnknownRefusalLine
        }
    }

    /// The same verdict in two or three words, for a Diagnostics row's trailing value.
    public var shortReason: String {
        switch self {
        case .boundToAnotherPhone: return StatusCopy.Row.boundToAnotherPhone
        case .authorizationRemoved: return StatusCopy.Row.authorizationRemoved
        case .releasedByThisPhone: return StatusCopy.Row.releasedByThisPhone
        case .captureOffOnWatch: return StatusCopy.Row.captureOffOnWatch
        case .appTooOldForWatch: return StatusCopy.Row.appTooOldForWatch
        case .watchFirmwareTooOld: return StatusCopy.Row.watchFirmwareTooOld
        case .versionMismatch: return StatusCopy.Row.versionMismatch
        case .watchTrouble: return StatusCopy.Row.watchTrouble
        case .appSentSomethingUnexpected: return StatusCopy.Row.appSentSomethingUnexpected
        case .unknown: return StatusCopy.Row.unknown
        }
    }

    /// The card's one action. Every fault the user can act on offers one; the two that are ours
    /// to fix (a malformed request, an unrecognised refusal) offer the support report instead of
    /// a retry button that would only spin.
    public var action: StatusAction? {
        switch self {
        case .boundToAnotherPhone, .authorizationRemoved, .releasedByThisPhone:
            return .tryAgain
        case .captureOffOnWatch:
            return .start
        case .appTooOldForWatch, .watchFirmwareTooOld, .versionMismatch, .watchTrouble,
            .appSentSomethingUnexpected, .unknown:
            return .troubleshoot
        }
    }

    /// Dot colour. A refusal that stops audio outright is a problem; one the person can clear on
    /// the watch is attention.
    public var dot: StatusDot {
        switch self {
        case .captureOffOnWatch: return .neutral
        case .boundToAnotherPhone, .authorizationRemoved, .releasedByThisPhone, .watchTrouble:
            return .attention
        case .appTooOldForWatch, .watchFirmwareTooOld, .versionMismatch,
            .appSentSomethingUnexpected, .unknown:
            return .problem
        }
    }

    /// The status-card family this fault belongs to.
    public var family: StatusFamily {
        self == .captureOffOnWatch ? .notRecording : .needsAttention
    }

    /// The full status card for this fault.
    public var statusModel: StatusModel {
        StatusModel(family: family, headline: headline, detail: detail, dot: dot, action: action)
    }
}

// MARK: - Diagnostics

extension WatchLinkFault {
    /// The Diagnostics/support-report line. Plain language, no code — the raw bytes belong in
    /// Detailed Logs, which is the one surface allowed to speak protocol.
    public var diagnosticLine: String { "\(headline) — \(detail)" }
}

/// The raw refusal, for Detailed Logs and the support report's technical tail ONLY. Protocol
/// vocabulary is allowed here and nowhere else; a reader pasting this into a bug report needs
/// the number, and the sentence above it is what the user was shown.
public func watchLinkFaultTrace(
    protocolError: ErrorMessage?,
    info: InfoSnapshot?,
    protoVersion: Int = ProtocolConstants.protocolVersion
) -> String? {
    var parts: [String] = []
    if let protocolError {
        let name = protocolError.errorCode.map { String(describing: $0) } ?? "unrecognised"
        parts.append(
            "ERROR code \(protocolError.errorCodeRaw) (\(name)) detail \(protocolError.detail)")
    }
    if let info {
        parts.append(
            "watch protocol \(info.protocolMin)–\(info.protocolMax), app speaks \(protoVersion)")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}
