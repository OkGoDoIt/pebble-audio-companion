import Intelligence

// The one place an AI failure becomes words — the twin of `TranscriptionFailureKind+Copy.swift`,
// built the same way and for the same reason (B20).
//
// It exists because the note dock was rendering `AiError.providerFailed`'s message verbatim. Two
// things were wrong with that, and the user hit both at once on a four-hour conversation:
//
//  1. The message was about the WRONG PROVIDER. They had remote AI on; the cloud call failed
//     first; the on-device fallback then failed too; and the router surfaced the fallback's
//     sentence — "On-device AI generation failed" — while the cloud cause, the only actionable
//     fact in the whole event, was dropped. `AiModeRouter` now leads with the primary and
//     carries the fallback underneath, and `AiFailure` classifies both.
//  2. It was developer prose. `OpenAiChatAiProvider` splices up to 240 bytes of OpenAI's own
//     response body into its message; on a 401 that body is the request and a partly-redacted
//     key. The kit classifies, the app writes the sentence, and the raw text goes only to the
//     flight recorder.
//
// Vocabulary rules, matching `Copy+NoteJobs.swift`: say what happened and what to do about it,
// in the user's words; never an error code; never blame the reader; and where the app genuinely
// does not know, say that rather than dressing a guess up as a diagnosis.

extension Copy {
    enum AiFailure {
        // ── Configuration ────────────────────────────────────────────────────
        // Reused rather than re-typed: the note dock already had exactly these two sentences
        // approved, and two copies of one sentence is how a catalog starts saying two different
        // things about one situation.
        static let notConfigured = Copy.NoteJobs.providerUnavailable
        static let consentRequired = Copy.NoteJobs.consentRequired

        // ── The cloud provider ───────────────────────────────────────────────
        // Each names the screen the fix is on, because "check your settings" with no destination
        // is the same as no advice at all.
        static let keyRejected =
            "Your OpenAI key was not accepted. Check it in Transcription & AI."
        static let keyNotPermitted =
            "Your OpenAI key does not have access to this model. Pick another in "
            + "Transcription & AI."
        static let rateLimited =
            "OpenAI is rate limiting this account, or it is out of credit. Try again later."
        static let providerTrouble =
            "OpenAI had a problem with this request. Nothing here is yours to fix — try again."
        static let timedOut = "The request took too long and was given up on. Try again."
        static let noConnection =
            "This needs a connection and there wasn't one. It will work once you're back online."

        // ── The on-device model ──────────────────────────────────────────────
        /// Deliberately does not promise Apple Intelligence will be back — it may be a model
        /// still installing, a device that has paused it, or Low Power Mode.
        static let modelUnavailable =
            "Apple Intelligence isn't ready on this device right now. Turning off Low Power Mode "
            + "can help; cloud AI works either way."
        /// The one a long recording lands on. It names both ways out, and it never implies the
        /// recording is at fault.
        static let tooLongForDevice =
            "This is longer than on-device AI can read in one go. Turn on cloud AI in "
            + "Transcription & AI, or ask for a shorter note."
        static let contentRefused =
            "On-device AI declined to work on this recording. Cloud AI has different rules."
        static let modelBusy = "On-device AI is busy. Try again in a moment."

        // ── Neither ──────────────────────────────────────────────────────────
        static let emptyAnswer = "The model answered with nothing. Try again."
        static let unknown = "Something went wrong. Detailed Logs in Diagnostics has the detail."

        // ── The fallback clause ──────────────────────────────────────────────
        // Appended when a First mode's OTHER provider also failed. A separate sentence rather
        // than a longer first one: the primary is what the reader acts on, and this exists so
        // the app is not silently hiding that it tried twice.
        static let alsoTriedOnDevice = "On-device AI didn't manage it either."
        static let alsoTriedCloud = "Cloud AI didn't manage it either."

        /// Argument order is the reading order: the cause first, the fallback's clause second.
        static func sentence(primary: String, then fallback: String) -> String {
            "\(primary) \(fallback)"
        }
    }
}

extension AiFailureKind {
    /// One sentence: what happened, and what — if anything — the reader should do about it.
    var reason: String {
        switch self {
        case .notConfigured: return Copy.AiFailure.notConfigured
        case .consentRequired: return Copy.AiFailure.consentRequired
        case .keyRejected: return Copy.AiFailure.keyRejected
        case .keyNotPermitted: return Copy.AiFailure.keyNotPermitted
        case .rateLimited: return Copy.AiFailure.rateLimited
        case .providerTrouble: return Copy.AiFailure.providerTrouble
        case .timedOut: return Copy.AiFailure.timedOut
        case .noConnection: return Copy.AiFailure.noConnection
        case .modelUnavailable: return Copy.AiFailure.modelUnavailable
        case .modelBusy: return Copy.AiFailure.modelBusy
        case .tooLongForDevice: return Copy.AiFailure.tooLongForDevice
        case .contentRefused: return Copy.AiFailure.contentRefused
        case .emptyAnswer: return Copy.AiFailure.emptyAnswer
        case .unknown: return Copy.AiFailure.unknown
        }
    }
}

extension AiFailure {
    /// The whole sentence a person reads: the primary cause, plus a short clause when the
    /// fallback provider also failed.
    ///
    /// The fallback clause is deliberately not a second diagnosis. Two provider errors in one
    /// sub-line is a wall, and the second one is rarely actionable — if the cloud rejected your
    /// key, what Apple Intelligence then did about it is not what you need to know.
    var reason: String {
        guard let fallback else { return kind.reason }
        switch fallback.origin {
        case .onDevice:
            return Copy.AiFailure.sentence(
                primary: kind.reason, then: Copy.AiFailure.alsoTriedOnDevice)
        case .cloud:
            return Copy.AiFailure.sentence(
                primary: kind.reason, then: Copy.AiFailure.alsoTriedCloud)
        }
    }
}
