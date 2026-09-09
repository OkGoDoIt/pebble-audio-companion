import Foundation
import Transcription

// "We are using the cloud provider, and here is why" — the sentence the four processing modes
// have never said out loud.
//
// ─── WHAT THE MODES PROMISE ──────────────────────────────────────────────────
//
//   Local only    everything on this phone; if it fails, it fails. Nothing to disclose.
//   Local first   try on device, use the cloud rather than fail — and go back the moment the
//                 device can do it again.
//   Remote first  the cloud for quality, the device rather than fail. Intermittent, never a
//                 permanent downgrade.
//   Remote only   the cloud, retried. Never local. Nothing to disclose.
//
// The routers implement all four correctly, and neither carries sticky state: every job re-tries
// the preferred path first, so "keep trying and switch back when possible" is already true. The
// missing half was that the two "first" modes never told anyone when the fallback was carrying
// the work. A Local-first user whose on-device language model is not installed has had every
// recording uploaded, silently, for as long as that is true.
//
// ─── WHY IT LIVES ON STORAGE & PRIVACY ───────────────────────────────────────
//
// Diagnostics was the other candidate and is the wrong one. Diagnostics answers "something looks
// broken, what is it?" — you go there having already noticed. The whole point of this disclosure
// is to reach someone who has NOT noticed, because from the outside a Local-first fallback looks
// like nothing at all: the transcripts arrive, they are if anything better, and the only thing
// that changed is that the audio left the phone.
//
// Storage & Privacy is where that person is: it is the screen someone opens to ask where their
// data goes, and its stance card is written to a rule (`Copy+PrivacyStance.swift`) that this
// makes true rather than merely careful — "there is no configuration in which this screen states
// a promise the pipeline is not actually keeping". The card's Local-first qualifier already says
// a recording is uploaded "only when the on-device engine cannot finish it". That is a
// conditional. While a fallback is in force the honest tense is the present one, and this is the
// present-tense line, sitting directly under the conditional it completes.
//
// It is not a banner and it does not nag: it is one line, inside a card, on a screen you have to
// navigate to, and it disappears by itself the moment the preferred path works again — the
// routers clear `lastFallback` on their next success, so nothing has to expire or dismiss it.
//
// Two directions, two different kinds of fact, both worth one line:
//   • local → cloud  a privacy event. Data is leaving that normally would not.
//   • cloud → local  a quality event. Nothing left; the answer may just be less good, and this
//                    is the only place that says why. Kept because "Remote first" promises the
//                    downgrade is temporary, and a promise nobody can check is not one.

extension Copy.Privacy {

    /// One axis's disclosure, ready to render. Nil is the healthy case and the common one.
    struct FallbackNotice: Equatable, Identifiable {
        /// Stable across redraws; also what the tests key on.
        var id: String
        /// The whole disclosure, one sentence: what is happening, then why.
        var text: String
    }

    /// The live half of the stance: what the pipeline is doing RIGHT NOW, as against what the
    /// configuration allows.
    ///
    /// Pure by construction — the two `ProcessingFallback` values in, sentences out — so every
    /// combination is pinned in `ProcessingFallbackDisclosureTests` without a database, a
    /// keychain, a network or a running pipeline.
    ///
    /// - Parameters:
    ///   - transcription: `TranscriptionModeRouter.lastFallback`.
    ///   - ai: `AiModeRouter.lastFallback`.
    ///   - cloudTranscriptionDestination: the provider name, so the sentence can be specific
    ///     about where audio went. Nil (Local only) makes the transcription notice unreachable.
    ///   - remoteAiDestination: the same for text.
    static func fallbackNotices(
        transcription: ProcessingFallback?,
        ai: ProcessingFallback?,
        cloudTranscriptionDestination: String?,
        remoteAiDestination: String?
    ) -> [FallbackNotice] {
        var notices: [FallbackNotice] = []
        if let transcription,
            let text = sentence(
                transcription, axis: .transcription,
                destination: cloudTranscriptionDestination)
        {
            notices.append(FallbackNotice(id: "transcription", text: text))
        }
        if let ai,
            let text = sentence(ai, axis: .ai, destination: remoteAiDestination)
        {
            notices.append(FallbackNotice(id: "ai", text: text))
        }
        return notices
    }

    /// Which pipeline the notice is about. The two read differently enough that one sentence
    /// with a noun substituted in would be worse than two.
    private enum Axis { case transcription, ai }

    /// One sentence: the present-tense fact, then the cause, then nothing else.
    ///
    /// Returns nil when the destination is unknown. That is not defensive coding — a fallback
    /// recorded against a mode that cannot reach the cloud means the configuration changed after
    /// the job ran, and the safe reading of a stale record is silence, not a claim about where
    /// audio went.
    private static func sentence(
        _ fallback: ProcessingFallback, axis: Axis, destination: String?
    ) -> String? {
        switch fallback.direction {
        case .localToCloud:
            guard let destination else { return nil }
            let head: String
            switch axis {
            case .transcription: head = "Recordings are going to \(destination) right now"
            case .ai: head = "Text is going to \(destination) right now"
            }
            return "\(head): \(localCause(fallback.cause, axis: axis))"
        case .cloudToLocal:
            guard destination != nil else { return nil }
            let head: String
            switch axis {
            case .transcription: head = "Transcription is running on this iPhone right now"
            case .ai: head = "AI is running on this iPhone right now"
            }
            return "\(head): \(cloudCause(fallback.cause))"
        }
    }

    /// Why the on-device engine could not do it. Written as a fact about the phone, not as an
    /// apology, and never with an error string spliced in (anti-goal B20).
    private static func localCause(_ cause: ProcessingFallbackCause, axis: Axis) -> String {
        let engine: String
        switch axis {
        case .transcription: engine = "on-device engine"
        case .ai: engine = "on-device model"
        }
        switch cause {
        case .notAvailable:
            return "the \(engine) is not available on this iPhone."
        case .failed, .noConnection, .notAccepted:
            // The last three are cloud-shaped causes; on the local path only `.failed` is
            // really reachable, and lumping them together beats inventing three sentences for
            // states that cannot happen.
            return "the \(engine) could not finish the last one."
        }
    }

    /// Why the cloud could not do it.
    private static func cloudCause(_ cause: ProcessingFallbackCause) -> String {
        switch cause {
        case .notAvailable:
            return "the provider is not set up."
        case .noConnection:
            return "the last request could not reach it."
        case .notAccepted:
            return "the provider turned the last request down — check the key and the account."
        case .failed:
            return "the last request failed."
        }
    }
}

// ─── The bridge from the routers ─────────────────────────────────────────────

extension Copy.Privacy.FallbackNotice {
    /// The notices for the CURRENT configuration and the CURRENT router state.
    ///
    /// Deliberately a plain function of two snapshots rather than an observable: `lastFallback`
    /// changes at most once per transcribed segment or AI job — minutes apart — and this is read
    /// while a settings screen is on screen. Anything that streamed it would be a subscription
    /// held open all day to deliver nothing.
    @MainActor
    static func current(
        _ settings: AppSettings, _ source: any ProcessingModeSource
    ) -> [Copy.Privacy.FallbackNotice] {
        Copy.Privacy.fallbackNotices(
            transcription: source.transcriptionFallback,
            ai: source.aiFallback,
            cloudTranscriptionDestination: settings.cloudTranscriptionDestination,
            remoteAiDestination: settings.remoteAiDestination
        )
    }
}
