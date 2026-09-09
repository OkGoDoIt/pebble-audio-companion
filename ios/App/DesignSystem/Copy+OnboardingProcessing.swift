import CompanionRuntime
import Foundation
import Intelligence
import Transcription

// Onboarding step 3 — the one question that decides where a person's words are processed.
//
// The bug this file exists to fix: the step used to ask only about TRANSCRIPTION, and its
// "On this phone — Private." card set `transcriptionMode = .localOnly` and nothing else. `aiMode`
// stayed at its `.remoteFirst` default, so someone who deliberately picked the private option had
// every transcript, summary, follow-up and About You block sent to OpenAI anyway. A card that
// says "on this phone" while half the pipeline uploads is the exact failure `Copy+PrivacyStance`
// was written against, one screen earlier.
//
// Rules this copy follows (they are why it reads the way it does):
//
// - **The card names the trade; the STANCE names where data goes.** Nothing in this file states
//   or paraphrases where a recording ends up. That sentence has one source — `Copy.Privacy.stance`
//   — and onboarding renders it derived from the very modes the choice is about to write, so a
//   card and the Settings screen cannot disagree.
// - **Only claims checked against the code.** Every factual assertion below cites what was
//   verified; see the per-string notes.
// - **The cost is stated where the choice is made.** On-device AI cannot do structured output at
//   all, so choosing it means no follow-ups — said once, plainly, next to the option, not
//   discovered three weeks later by a person wondering why the list is empty.
extension Copy {
    enum OnboardingProcessing {

        // ─────────────────────────────────────────────────────────────────────
        // MARK: The question (replaces `Copy.Onboarding.transcriptsTitle`)
        // ─────────────────────────────────────────────────────────────────────

        /// Names BOTH outputs. The old title ("Where should transcripts happen?") named one axis
        /// while the screen was silently deciding two.
        static let title = "Where should transcripts and notes be made?"

        // ─── The three presets ───────────────────────────────────────────────

        static let onPhoneTitle = "On this phone"
        /// Verified: the local engine is Apple Speech (present on every iOS 26 phone, nothing to
        /// download — `LocalModelCatalog.defaultModelId`) or a model the user downloads; neither
        /// needs an account or a key. "Less accurate" is the honest reason anyone picks the cloud.
        static let onPhoneBody = "No key and no account. Transcripts are rougher than the cloud's."

        static let cloudTitle = "In the cloud"
        /// Verified: `speakerLabelsEnabled` is literally `cloudTranscriptionEnabled`, so speaker
        /// names are a real, exclusive consequence of cloud transcription — worth naming, because
        /// it is the difference people actually notice.
        static let cloudBody =
            "The most accurate transcripts, with speaker names, and every AI feature works. "
            + "You add a provider key."

        static let laterTitle = "Later"
        /// Verified: "Later" leaves `transcriptsConfigured` false, and both Today's status card
        /// (`LiveTodayDataSource`) and the widget (`AppComposition`) render `Copy.Status
        /// .transcriptsOff` from exactly that flag while capture is meant to be running. It
        /// opened with "Choose later." — the card's own title.
        static let laterBody = "Today shows that transcripts are off until you choose."

        // ─── The quiet way to the two-axis screen ────────────────────────────

        /// Deliberately a plain tint button under the cards rather than a fourth card: mixing the
        /// axes is a real and reasonable setup (local transcripts so audio never leaves, cloud AI
        /// for good summaries) but it is not the question most people want asked.
        static let setSeparately = "Set transcripts and AI separately"

        // ─────────────────────────────────────────────────────────────────────
        // MARK: The two-axis screen
        // ─────────────────────────────────────────────────────────────────────

        /// Named for the button that opens it, so the two read as one action.
        static let detailTitle = "Set them separately"
        // `detailLine` ("These are two separate jobs, and they can run in different places.")
        // is gone: two headed sections with two options each is the same statement, made by
        // the layout.

        static let transcriptsSection = "Transcripts"
        static let aiSection = "Notes & AI"

        /// Back to the three cards (B15: the affordance names the actual parent step — the short
        /// name of the question, since its title is a whole sentence).
        static let backToProcessing = "Transcripts & AI"

        /// The card that appears on the question screen once a mix is set, so the answer is
        /// always visible where the question is. Restates the two SELECTIONS, not where data
        /// goes — that stays the derived stance directly underneath.
        static func mixedSummary(transcripts: ProcessingPlace, ai: ProcessingPlace) -> String {
            "Transcripts \(place(transcripts)), AI \(place(ai))."
        }

        private static func place(_ place: ProcessingPlace) -> String {
            switch place {
            case .onPhone: return "on this phone"
            case .inCloud: return "in the cloud"
            }
        }

        // Transcription axis.
        static let transcriptsOnPhone = "On this phone"
        /// Verified: `LocalModelCatalog.defaultModelId` is Apple Speech, and the catalog offers
        /// downloadable engines; a selected-but-missing model transcribes with Apple Speech
        /// meanwhile rather than stalling.
        static let transcriptsOnPhoneBody = "Apple Speech, or a model you download. No key needed."
        static let transcriptsInCloud = "In the cloud"
        /// Verified: `CloudProvider` has exactly these two cases, and speaker labels are gated on
        /// cloud transcription.
        static let transcriptsInCloudBody = "Soniox or OpenAI. Sharper, and it names the speakers."

        // AI axis.
        static let aiOnPhone = "On this phone"
        /// Verified: the local `AiProvider` is `OnDeviceAiProvider` over Apple's Foundation
        /// Models (`FoundationModelsLanguageModel`).
        static let aiOnPhoneBody = "Apple Intelligence writes summaries and answers."
        static let aiInCloud = "In the cloud"
        /// Verified: `Copy.Privacy.remoteAi` is "OpenAI" — the single remote AI provider
        /// (`OpenAiChatAiProvider`) every AI mode routes to.
        static let aiInCloudBody = "OpenAI writes summaries, notes, follow-ups and answers."

        // ─────────────────────────────────────────────────────────────────────
        // MARK: What on-device AI costs
        // ─────────────────────────────────────────────────────────────────────

        /// Shown wherever the pending choice would leave `aiMode == .localOnly`.
        ///
        /// Both halves were checked in the kit, and both are surprising enough that finding them
        /// out by accident would feel like the app broke:
        ///
        /// 1. Follow-ups ARE found here, and they are not as good. `OnDeviceAiProvider` no
        ///    longer refuses structured output outright — Apple's guided generation can hold a
        ///    schema, so `FoundationModelsStructured.swift` produces the same JSON the cloud
        ///    path does. What it cannot do is judge: measured over twenty hand-labelled
        ///    conversations from real capture, it returned four items where a careful reader
        ///    finds eight, and it never proposes a due date, because every date it produced was
        ///    the recording's own day stamped on everything. The sentence below says "fewer"
        ///    and "no dates" for that reason. It used to say follow-ups were not proposed at
        ///    all, which was true when it was written.
        /// 2. `FoundationModelsLanguageModel.availability()` reports `.available` only when Apple
        ///    Intelligence is enabled on a device that supports it; anything else makes the
        ///    provider unavailable, and in `.localOnly` the router has nowhere else to go — so on
        ///    such a device NOTHING the AI writes appears: no summary, no recap, no Ask answer
        ///    (conversation rows fall back to transcript snippets rather than breaking). Saying so
        ///    is not a warning, it is the difference between "runs here" and "runs here if it can".
        ///
        /// Deliberately NOT phrased as a warning and deliberately not coloured: keeping everything
        /// on the phone is a legitimate, respectable choice, and this is its price list.
        static let onDeviceAiNote =
            "Summaries and answers need Apple Intelligence on this iPhone. Follow-ups are found "
            + "here too — fewer of them, and without due dates."

        // ─────────────────────────────────────────────────────────────────────
        // MARK: Key hand-off — ask for what this combination actually needs
        // ─────────────────────────────────────────────────────────────────────

        /// Titles. The key screen used to always ask for both providers; a person who chose local
        /// transcripts plus cloud AI was being asked for a transcription key they will never use.
        static let keysTitleBoth = Copy.Onboarding.addProviderKey
        static let keysTitleAiOnly = "Add your OpenAI key"

        /// Cloud transcription (whether or not the AI is also remote): both providers transcribe,
        /// so both rows are offered and the sentence says how to pick.
        static let keysLineTranscriptionOnly = "Soniox and OpenAI both transcribe."
        /// Local transcripts, remote AI: OpenAI is the only provider involved, so it is the only
        /// row — and the line says what stays empty without it rather than nagging.
        static let keysLineAiOnly =
            "Summaries, notes, follow-ups and answers are written by OpenAI. Without its key "
            + "those stay empty."

        /// The per-row "what this provider is for" line. `Copy.Onboarding.sonioxRole` /
        /// `openAiRole` cover the both-jobs case; these two are the narrowed versions.
        static let openAiRoleTranscriptionOnly = "transcription"
        static let openAiRoleAiOnly = "summaries, notes and answers"
    }
}

// ─── Stating a stance BEFORE it is committed ─────────────────────────────────

extension AppSettings {
    /// The stance a proposed pair of modes *would* produce, without writing them yet.
    ///
    /// Onboarding has to show the consequence of a card before the card is applied — settings
    /// must not be half-written by someone who is still reading the options, and backing out of
    /// step 3 must leave nothing behind. So the pending modes are passed in, and everything else
    /// (which cloud provider, which remote AI) comes from the same settings the committed
    /// `privacyStance` reads.
    ///
    /// The destinations are derived through `RuntimeSettingsSnapshot`'s own
    /// `cloudTranscriptionEnabled` / `remoteAiEnabled` — the predicates the PROVIDERS are gated
    /// on, and the same two `AppSettings.cloudTranscriptionDestination` /
    /// `remoteAiDestination` use. That is deliberate: this must not become a second rule about
    /// when data leaves, only a second set of *inputs* to the one rule about how to say it.
    func privacyStance(
        transcriptionMode: TranscriptionMode, aiMode: AiProcessingMode
    ) -> Copy.Privacy.Stance {
        let modes = RuntimeSettingsSnapshot(transcriptionMode: transcriptionMode, aiMode: aiMode)
        return Copy.Privacy.stance(
            for: Copy.Privacy.StanceInputs(
                transcriptionMode: transcriptionMode,
                aiMode: aiMode,
                cloudTranscriptionDestination: modes.cloudTranscriptionEnabled
                    ? cloudTranscriptionProvider.displayName : nil,
                remoteAiDestination: modes.remoteAiEnabled ? Copy.Privacy.remoteAi : nil
            )
        )
    }
}
