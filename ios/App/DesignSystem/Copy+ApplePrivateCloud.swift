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

// ─── Settings · Transcription & AI ───────────────────────────────────────────

extension Copy.Settings.TranscriptionAI {
    /// The row that picks which cloud the AI axis uses. The same words as the transcription
    /// card's "Cloud provider" (Soniox / OpenAI) so the two cards read as one system, and
    /// "cloud" on purpose: Apple Private Cloud Compute is Apple's cloud, not this phone.
    /// "Provider", not "model": the model (GPT-5.6 Luna…) is the OpenAI row below this one.
    static let remoteModel = "Cloud provider"

    /// The readiness row's title when the remote is Apple's. Short form here, the way the
    /// on-device row is "On this phone"; the full name is in the footer and the stance.
    static let applePrivateCloudRow = "Apple Private Cloud"

    /// The name of each option on the Remote model screen.
    static func remoteModelName(_ provider: RemoteAiProvider) -> String {
        switch provider {
        case .openAi: return Copy.Privacy.remoteAi
        case .applePrivateCloud: return Copy.Privacy.applePrivateCloud
        }
    }

    /// The Remote model screen's footer: the trade, attributed where it is a claim.
    static let remoteModelFooter =
        "AI runs in one of two places: on this phone (Apple's built-in model), or in the cloud. "
        + "The Mode row decides which goes first; this row picks which cloud. OpenAI uses your "
        + "own key and account, and the model you choose below. Apple Private Cloud Compute is "
        + "Apple's cloud: no key, Apple runs its model on its own servers, which it says keep "
        + "nothing after the request, and each person gets a daily allowance."

    /// The readiness row's value — lowercase, in the register of "not set" and "ready" above it.
    /// The allowance is folded in only when the model is otherwise ready: "used up" on a phone
    /// that cannot use it at all would be two facts fighting for one line.
    static func applePrivateCloudValue(
        _ readiness: ApplePrivateCloudReadiness, quota: ApplePrivateCloudQuotaState
    ) -> String {
        switch readiness {
        case .ready:
            switch quota {
            case .usedUp: return "daily allowance used up"
            case .nearlyUsedUp: return "ready · near today's allowance"
            case .fine, .unknown: return "ready"
            }
        case .notSupported: return "not supported here"
        case .notReady: return "not ready"
        case .notEnabledForThisBuild: return "not available for this build"
        case .unsupportedOs: return "needs iOS 27"
        }
    }

    /// One line under the AI card about Private Cloud Compute, or nil when nothing needs saying.
    ///
    /// Present only where the mode depends on it, and only for the states that change what the
    /// person gets. The allowance line is a sentence with a time, never an alert; the build line
    /// is a plain fact about this build. In Remote first the on-device model carries the work
    /// meanwhile, and the sentence says so rather than leaving a person to wonder whether
    /// anything is being written.
    static func applePrivateCloudNote(
        mode: AiProcessingMode,
        readiness: ApplePrivateCloudReadiness,
        quota: ApplePrivateCloudQuotaState
    ) -> String? {
        guard mode.usesCloudProvider else { return nil }
        let meanwhile: String
        switch mode {
        case .remoteOnly:
            meanwhile = "Summaries, notes, and answers wait until it is."
        case .remoteFirst, .localFirst:
            meanwhile = "Apple Intelligence on this iPhone writes them meanwhile."
        case .localOnly:
            return nil
        }
        switch readiness {
        case .ready:
            switch quota {
            case .usedUp(let resetsAt):
                let when = resetsAt.map { " It comes back \(Self.resetPhrase($0))." } ?? ""
                return "Apple Private Cloud Compute's daily allowance is used up.\(when) "
                    + meanwhile
            case .nearlyUsedUp:
                return "Apple Private Cloud Compute is close to today's allowance."
            case .fine, .unknown:
                return nil
            }
        case .notSupported:
            return "Apple Private Cloud Compute doesn't run on this iPhone. " + meanwhile
        case .notReady:
            return "Apple Private Cloud Compute isn't ready — it needs Apple Intelligence on "
                + "and an Apple Account signed in. " + meanwhile
        case .notEnabledForThisBuild:
            return "This build of the app isn't enabled for Apple Private Cloud Compute. "
                + meanwhile
        case .unsupportedOs:
            return "Apple Private Cloud Compute needs iOS 27. " + meanwhile
        }
    }

    /// The button under the note when Apple offers a way to ask for more.
    static let requestHigherAllowance = "Ask Apple for a higher allowance"

    /// "at 9:00 AM" today, or "tomorrow at 9:00 AM", in the phone's own zone. Kept relative
    /// because the row is read now, not filed.
    static func resetPhrase(_ date: Date, now: Date = Date(), calendar: Calendar = .current)
        -> String
    {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
            calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return "tomorrow at \(time)"
        }
        return "on \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

// ─── Onboarding · the cloud sub-choice ───────────────────────────────────────

extension Copy.OnboardingProcessing {
    /// The small header over the two options under "In the cloud". A label, not a question:
    /// the question was answered by the card.
    static let remoteModelChoice = "Notes & AI by"

    /// Verified: `OpenAiChatAiProvider` needs the person's key and consent, nothing else.
    static let remoteOpenAiBody = "Your own key and account."

    /// Verified: `ApplePrivateCloudAiProvider` needs consent and no key; the allowance is
    /// `PrivateCloudComputeLanguageModel.quotaUsage`'s, per person; the retention claim is
    /// Apple's and is attributed to Apple.
    static let remoteApplePrivateCloudBody =
        "No key. Apple's servers, which Apple says keep nothing. A daily allowance."

    /// The "In the cloud" AI card's body once the sub-choice exists beneath it: it can no longer
    /// name OpenAI as the writer.
    static let aiInCloudBodyWithChoice =
        "A cloud model writes summaries, notes, follow-ups and answers. Pick which below."
}
