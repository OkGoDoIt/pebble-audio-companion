import Foundation

// What the two "first" modes actually did on their last job, so the app can say it out loud.
//
// WHY THIS EXISTS
//
// "Local first" and "Remote first" are preferences, not guarantees: each tries its preferred
// engine and quietly uses the other one when that fails. Quietly is the problem. Someone who
// chose Local first because they would rather their audio stayed on the phone has, in the
// failure case, had a recording uploaded — and until now NOTHING anywhere in the app said so.
// The privacy screen could only speak in the conditional ("a recording is uploaded only when
// the on-device engine cannot finish it"), because that is all it had.
//
// The routers already know. They just threw it away: `lastSuccessfulMode` records that the
// fallback ran, and the error that caused it was chained into the result and dropped. So this
// is the smallest honest addition — one value per router, written under the lock that already
// exists, no clock, no timer, no observation, no I/O. It is read on demand by a Settings screen.
//
// SEMANTICS, and they are the whole design:
//
//   • Set ONLY when a fallback actually produced the result.
//   • CLEARED the moment the preferred engine succeeds again. That is what makes it "in force
//     now" rather than "happened once" — a First mode retries its preferred path on every
//     single job (neither router carries sticky state), so a transient failure disappears from
//     the UI by itself as soon as it stops happening. Nothing has to expire it.
//   • Never set by an "Only" mode: those have no fallback to disclose.
//   • Not set when BOTH paths fail. Nothing ran; that is a failure, and failures are Diagnostics'
//     job. Claiming a fallback is in use when nothing succeeded would be a new wrong statement.

/// Which way a "first" mode fell back.
public enum ProcessingFallbackDirection: String, Sendable, Equatable, CaseIterable {
    /// Configured Local first; the work was done in the cloud. The privacy-relevant direction:
    /// data left the phone that, in the healthy case, would not have.
    case localToCloud
    /// Configured Remote first; the work was done on device. Not a privacy event — a quality
    /// one, and the reason answers "why did this get worse?".
    case cloudToLocal
}

/// Why the preferred path did not do the job, in the coarse vocabulary a person can act on.
///
/// Deliberately coarser than `TranscriptionFailureKind`: this is one short clause inside a
/// sentence about where data is going, not a diagnostic. The fine-grained reason is already on
/// the Diagnostics screen, where someone who wants it will look.
public enum ProcessingFallbackCause: String, Sendable, Equatable, CaseIterable {
    /// The preferred engine or provider could not run at all — a language model that is not
    /// installed, no API key, a provider not selected.
    case notAvailable
    /// The request never reached the provider.
    case noConnection
    /// It was reached and refused: a rejected key, no permission, a quota.
    case notAccepted
    /// It ran and failed.
    case failed

    /// Classifies the error message the preferred path failed with.
    ///
    /// Reuses `TranscriptionFailureKind.classify`, which already recognises our own thrown
    /// literals, parenthesised HTTP statuses and the `URLError` marker — and is used by the AI
    /// router too, because those three shapes are provider-agnostic. Anything unrecognised is
    /// `.failed`, never a guess.
    public static func classify(_ message: String?) -> ProcessingFallbackCause {
        switch TranscriptionFailureKind.classify(message) {
        case .notConfigured, .modelMissing:
            return .notAvailable
        case .noConnection:
            return .noConnection
        case .keyRejected, .keyNotPermitted, .rateLimited:
            return .notAccepted
        case .providerTrouble, .providerRefusedAudio, .timedOut, .recordingTooLong,
            .localEngineFailed, .audioUnreadable, .unknown:
            return .failed
        }
    }
}

/// One router's current fallback state. Absent (nil) is the healthy case.
public struct ProcessingFallback: Sendable, Equatable {
    public var direction: ProcessingFallbackDirection
    public var cause: ProcessingFallbackCause

    public init(direction: ProcessingFallbackDirection, cause: ProcessingFallbackCause) {
        self.direction = direction
        self.cause = cause
    }
}
