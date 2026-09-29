import Foundation
import Transcription

// Optional seams a provider can offer beyond `AiProvider`, for the one situation the fixed seam
// cannot describe: an account that has told us to stop.
//
// `AiProvider` has `isAvailable()` and `run(_:)`, and nothing that says WHY a provider is
// unavailable or lets anything check whether that has changed. The transcription side met the
// same wall (`TranscriptionAvailabilityExplaining`) when its cloud account ran dry; these are
// the AI twins, kept optional so every existing provider and test double is untouched.

/// A provider that can say why it reports itself unavailable.
public protocol AiUnavailabilityExplaining: Sendable {
    /// A message shaped for `AiFailure.classify` / `TranscriptionFailureKind.classify` — our own
    /// words with a parenthesised status ("out of credit (402)") — or nil when the provider is
    /// available or has nothing specific to say.
    func unavailabilityReason() async -> String?
}

/// A remote provider whose account can be put on hold, and checked on the hold's schedule.
public protocol AiAccountProbing: Sendable {
    /// Runs one cheap account check when the hold says one is due; nil when nothing was due
    /// (no hold, not yet time, no consent). Updates the hold with what it found.
    func probeHeldAccountIfDue(foreground: Bool) async -> CloudAccountProbeOutcome?
}
