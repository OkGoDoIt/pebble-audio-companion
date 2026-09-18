import Foundation
import Intelligence
import Transcription

// Apple Private Cloud Compute as a remote AI provider (iOS 27).
//
// Everything the app says about it, in one file: its name where data goes, the Settings rows,
// the onboarding sub-choice, and the two failures only it has. Rules this copy follows:
//
// - **Name it the way Apple does, in full, where data goes.** "Apple Private Cloud Compute" is
//   the destination in the privacy stance and the Settings footer — never "Apple" (which the
//   on-device model also is) and never "PCC".
// - **State the trade, not a pitch.** No key and no account; Apple's no-retention guarantee is
//   Apple's claim and is attributed to them; a daily allowance that runs out is a fact about
//   the service, said in the same register as "not set" on a key row.
// - **A used-up allowance is never an alert.** It is a line on the row, and a sentence in the
//   note dock when a job did not finish. It comes back by itself; the copy says when.
// - **Not available for this build is a calm state.** The provisioning profile does not carry
//   the entitlement, and the honest sentence is that this build cannot use it — not an error.

extension Copy.Privacy {
    /// The destination named in the stance and the Settings-root footer when the remote AI
    /// provider is Private Cloud Compute. Same role as `remoteAi` ("OpenAI").
    static let applePrivateCloud = "Apple Private Cloud Compute"

    /// The destination for a given remote provider — the one place the two names are chosen
    /// between, so a stance and a Settings row cannot disagree about where text goes.
    static func remoteAiName(for provider: RemoteAiProvider) -> String {
        switch provider {
        case .openAi: return remoteAi
        case .applePrivateCloud: return applePrivateCloud
        }
    }
}

// ─── Why a generation did not finish ─────────────────────────────────────────

extension Copy.AiFailure {
    /// The daily allowance is used up. Says it comes back and that the on-device model is not
    /// involved — the two things a person would otherwise wonder.
    static let usageLimit =
        "Apple Private Cloud Compute has used up its daily allowance. It comes back tomorrow; "
        + "Apple Intelligence on this iPhone isn't affected."

    /// Apple's cloud content filter declined the material. Its own sentence because the
    /// on-device one names the on-device model.
    static let cloudContentRefused =
        "Apple Private Cloud Compute declined to work on this recording."
}

// ─── The fallback disclosure (Storage & Privacy) ─────────────────────────────

extension Copy.Privacy {
    /// The clause after "AI is running on this iPhone right now:" when Private Cloud Compute's
    /// allowance is what stopped it. Present tense, no key to check.
    static let usageLimitCause = "the cloud model's daily allowance is used up until it resets."
}
