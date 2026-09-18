import Foundation
import Intelligence
import SearchKit
import Transcription

// The privacy stance for Settings · Storage & Privacy, plus that screen's destructive
// confirmation. `Copy.swift` already owns the one-line version of this
// (`Copy.Privacy.dataFlow`, on the Settings root); this is the same fact told at length, from
// the same inputs, so the two cannot disagree.
//
// Rules this copy is written to (they are why it reads the way it does):
//
// - **Derived, never asserted.** Every sentence about where data goes is a function of the
//   modes. There is no configuration in which this screen states a promise the pipeline is not
//   actually keeping — which is the failure mode the Settings-root footer was rewritten to fix.
// - **Only claims that were checked against the code.** Each `commitment` below cites what was
//   verified. A claim that could not be verified is not printed; see the note on third-party
//   engines at the foot of this file.
// - **No scare-mongering and no marketing.** Cloud transcription is a legitimate choice, so it
//   is described, not warned about, and the stance carries no red. State it once, calmly.

extension Copy.Privacy {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Inputs
    // ─────────────────────────────────────────────────────────────────────────

    /// Everything the stance is derived from. Deliberately a plain value: the wording is then a
    /// pure function, so `PrivacyStanceTests` can pin all four combinations without a database,
    /// a keychain or a running app.
    struct StanceInputs: Equatable {
        var transcriptionMode: TranscriptionMode
        var aiMode: AiProcessingMode
        /// `AppSettings.cloudTranscriptionDestination` — the provider audio is sent to, nil when
        /// transcription is Local only. Same predicate the providers are gated on.
        var cloudTranscriptionDestination: String?
        /// `AppSettings.remoteAiDestination` — nil in AI Local only.
        var remoteAiDestination: String?

        init(
            transcriptionMode: TranscriptionMode,
            aiMode: AiProcessingMode,
            cloudTranscriptionDestination: String?,
            remoteAiDestination: String?
        ) {
            self.transcriptionMode = transcriptionMode
            self.aiMode = aiMode
            self.cloudTranscriptionDestination = cloudTranscriptionDestination
            self.remoteAiDestination = remoteAiDestination
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Output
    // ─────────────────────────────────────────────────────────────────────────

    struct Stance: Equatable {
        /// Short, factual, and specific enough to be worth reading on its own.
        var headline: String
        /// Nothing reaches any service in this configuration.
        var isFullyLocal: Bool
        /// The stance itself: what happens to the audio, then what happens to the text.
        var summary: String
        /// Sentences the "first" modes need, because "Local first" is a preference, not a
        /// guarantee, and a stance that let it read as one would be the lie this file exists to
        /// avoid. Empty in the two `only` configurations, which need no qualification.
        var qualifiers: [String]
        /// The part that does not depend on configuration.
        var commitments: [String]
        /// What deleting can and cannot reach. Nil when nothing has been sent anywhere.
        var deletionNote: String?
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Derivation
    // ─────────────────────────────────────────────────────────────────────────

    static func stance(for inputs: StanceInputs) -> Stance {
        let stt = inputs.cloudTranscriptionDestination
        let ai = inputs.remoteAiDestination

        let headline: String
        let summary: String

        switch (stt, ai) {
        case (nil, nil):
            headline = "Everything stays on this phone"
            summary =
                "Transcription and AI both run on this iPhone. No recording, transcript or note "
                + "is sent to any service."

        case (let stt?, nil):
            headline = "Audio goes to \(stt)"
            summary =
                "Recordings are sent to \(stt) to be transcribed. Summaries, notes and answers "
                + "are then written on this iPhone, so the text does not go on anywhere else."

        case (nil, let ai?):
            headline = "Only text goes to \(ai)"
            summary =
                "Recordings are transcribed on this iPhone, so the audio itself never leaves it. "
                + "Transcript text, and everything in About You — including names imported from "
                + "Contacts and Calendar — is sent to \(ai) "
                + "to write summaries, notes and answers."

        case (let stt?, let ai?) where stt == ai:
            headline = "Audio and text go to \(stt)"
            summary =
                "Recordings are sent to \(stt) to be transcribed. The transcript text, and "
                + "everything in About You — including names imported from Contacts and Calendar — "
                + "goes back to \(stt) to write "
                + "summaries, notes and answers."

        case (let stt?, let ai?):
            headline = "Audio goes to \(stt), text to \(ai)"
            summary =
                "Recordings are sent to \(stt) to be transcribed. The transcript text, and "
                + "everything in About You — including names imported from Contacts and Calendar — "
                + "is then sent to \(ai) to write "
                + "summaries, notes and answers."
        }

        var qualifiers: [String] = []
        if stt != nil, let line = transcriptionQualifier(inputs.transcriptionMode) {
            qualifiers.append(line)
        }
        if let ai, let line = aiQualifier(inputs.aiMode, destination: ai) {
            qualifiers.append(line)
        }

        return Stance(
            headline: headline,
            isFullyLocal: stt == nil && ai == nil,
            summary: summary,
            qualifiers: qualifiers,
            commitments: commitments,
            deletionNote: (stt == nil && ai == nil) ? nil : deletionNote
        )
    }

    /// Why "Local first" is qualified and "Local only" is not.
    ///
    /// `TranscriptionModeRouter.localFirst` re-reads the whole segment and hands it to the cloud
    /// provider on ANY local failure except cancellation and "no speech" — and
    /// `providerUnavailable` (the on-device language assets simply not being installed) is one of
    /// those failures. So in Local first a recording really can be uploaded, and the one thing
    /// this screen must never do is imply otherwise. `Copy.Privacy.dataFlow` already collapses
    /// the mode to "cloud is reachable" for the same reason; this says out loud when it happens.
    private static func transcriptionQualifier(_ mode: TranscriptionMode) -> String? {
        switch mode {
        case .localOnly:
            // Unreachable while `cloudTranscriptionDestination` is non-nil; the switch is total
            // so a new mode cannot silently pick up the wrong sentence.
            return nil
        case .remoteOnly:
            return nil
        case .localFirst:
            return "Transcription is set to Local first, so a recording is uploaded only when "
                + "the on-device engine cannot finish it — including when its language model is "
                + "not installed."
        case .remoteFirst:
            return "Transcription is set to Cloud first, so every recording is uploaded; the "
                + "on-device engine is the fallback when that fails."
        }
    }

    /// The AI half.
    ///
    /// This paragraph used to say something stronger and it is no longer true, which is worth
    /// recording: `OnDeviceAiProvider.run` refused every request tagged `requiresStructuredOutput`,
    /// and both follow-up workers tag all of theirs, so Local first sent follow-up detection to the
    /// remote provider *every single time*. On-device structured output now works, so a device with
    /// Apple Intelligence answers it locally and the fallback is what its name says: a fallback.
    ///
    /// What stays true, and is what the qualifier below has to admit, is that `localFirst` still
    /// reaches the remote provider whenever the on-device model cannot do a job — so text can
    /// still leave, just no longer always.
    private static func aiQualifier(_ mode: AiProcessingMode, destination: String) -> String? {
        switch mode {
        case .localOnly:
            return nil
        case .remoteOnly:
            return nil
        case .localFirst:
            // The "always the case for finding follow-ups" tail was true when the on-device
            // provider refused every structured request. It now proposes follow-ups locally on a
            // device with Apple Intelligence, so the sentence stops there — a privacy claim that
            // over-states what leaves is still a wrong claim, even in the safe direction.
            return "AI is set to Local first, so most of it runs on this iPhone. Text still goes "
                + "to \(destination) when the on-device model cannot do a job."
        case .remoteFirst:
            return "AI is set to Remote first, so \(destination) does the work; the on-device "
                + "model is the fallback when that fails."
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: The part that never changes
    // ─────────────────────────────────────────────────────────────────────────

    /// Five sentences, each one checked against the code before it was written here.
    ///
    /// 1. Verified: the only package dependency is GRDB (a local SQLite wrapper); there is no
    ///    analytics, crash-reporting or attribution SDK; the entitlements file contains App
    ///    Groups and nothing else — no CloudKit, no push, no iCloud container; and there is no
    ///    first-party endpoint anywhere in the tree. `DiagnosticsService` records in its own
    ///    header that report content "is never included".
    /// 2. Verified: the complete outbound host list from source is the two transcription
    ///    providers, OpenAI for AI, and Hugging Face for a model download the user starts (a
    ///    plain GET that uploads nothing).
    /// 3. Verified: `FlightRecorder` writes to `Application Support/audio-companion/diagnostics`,
    ///    and the ONLY readers of `export()`/`exportFile()` are two `ShareLink`s on the
    ///    Diagnostics screen, which cannot fire without a tap. Every logging call site was
    ///    checked for transcript text; none passes any.
    /// 4. Verified: nothing in the tree sets `isExcludedFromBackup`, so the spool, the database
    ///    and the transcripts are in the phone's normal backups. Saying so is not a warning —
    ///    it is the difference between "on this phone" and "only on this phone".
    /// 5. Verified: the only system index written is `CSSearchableIndex.default()` (Core
    ///    Spotlight, an on-device index by Apple's documentation), every write to it goes
    ///    through `CoreSpotlightIndexer`, and that indexer applies `SystemSearchVisibility` on
    ///    every pass (`SpotlightVisibilityGate`) — so what it holds is exactly what the row on
    ///    this screen says. The sentence stops at the index: what Siri does with an index it is
    ///    allowed to read is Apple's policy, not this app's, and is not claimed here.
    ///
    /// Deliberately ABSENT: any sentence of the form "nothing else ever phones home". The app
    /// bundles a third-party speech engine for the downloadable models and that binary carries
    /// its own HTTP stack, so the blanket version of that claim could not be verified from
    /// source — and an unverified promise is exactly what this screen must not print.
    static let commitments = [
        "This app has no account and no server of its own. Nothing you record, transcribe or "
            + "write is sent to its developer, and none of it is used for training, advertising "
            + "or profiling.",
        "Your recordings and transcripts are never sold or shared. They go only where this "
            + "screen says they go.",
        "Diagnostic logs stay on this phone. They hold no audio and no transcript text, and are "
            + "only ever shared if you send them yourself from Diagnostics.",
        "Recordings, transcripts and notes are stored in this app on your iPhone, and are "
            + "included in the iPhone's usual backups.",
        "Spotlight's index of your recordings is kept on this iPhone by iOS. What goes into "
            + "it — nothing, titles and summaries, or everything — is your choice on this screen.",
    ]

    /// Required by the UX plan §17: the app must say what deletion can and cannot reach.
    static let deletionNote =
        "Deleting recordings here removes them from this iPhone. What a provider keeps after "
        + "processing is governed by that provider, not by this app."
}

// ─── The bridge from the settings the pipeline reads ─────────────────────────

extension AppSettings {
    /// The stance for the CURRENT configuration.
    ///
    /// It reads `cloudTranscriptionDestination` / `remoteAiDestination` — the same two derived
    /// properties the Settings-root footer and the About You explainer use, which in turn read
    /// the same `cloudTranscriptionEnabled` / `remoteAiEnabled` predicates the providers are
    /// gated on. One rule, four surfaces: the privacy copy cannot drift away from the pipeline
    /// without the pipeline changing too.
    ///
    /// Both are computed from the OBSERVED stored properties, not from the `@ObservationIgnored`
    /// runtime mirror, so a view reading this re-derives it when the modes change.
    var privacyStance: Copy.Privacy.Stance {
        Copy.Privacy.stance(
            for: Copy.Privacy.StanceInputs(
                transcriptionMode: transcriptionMode,
                aiMode: aiMode,
                cloudTranscriptionDestination: cloudTranscriptionDestination,
                remoteAiDestination: remoteAiDestination
            )
        )
    }
}

// ─── The Storage & Privacy screen's other added copy ─────────────────────────

extension Copy.Settings.Storage {
    /// Heading for the fixed half of the stance, which sits at the foot of the screen with the
    /// legal footnote. The live, configuration-dependent half is the card at the top, where
    /// someone opening "the privacy page" looks first.
    static let privacySection = "Privacy"

    /// The delete-all confirmation. It used to be a titleless sheet whose single button repeated
    /// the row's own label, so the sheet said nothing at all about a permanent, un-undoable
    /// delete of every recording on the phone.
    static let deleteAllTitle = "Delete all recordings?"
    static let deleteAllMessage =
        "Every recording, transcript, note and follow-up on this iPhone is deleted. This cannot "
        + "be undone. Recording itself is not turned off."
    static let deleteAllConfirm = "Delete All Recordings"

    // ─── "Siri & Spotlight can see" ───────────────────────────────────────────
    //
    // The one privacy CONTROL on the screen. It decides what the app hands the system's search
    // index — which Spotlight searches and, on iOS 27, Siri reasons over. Written so the row
    // reads as a plain statement of fact in every position ("Siri & Spotlight can see ·
    // Everything") and the picker explains each choice once, without alarm.

    static let systemSearch = "Siri & Spotlight can see"

    static func systemSearchLabel(_ visibility: SystemSearchVisibility) -> String {
        switch visibility {
        case .off: return "Off"
        case .summaries: return "Titles and summaries"
        case .full: return "Everything"
        }
    }

    /// Under the row on the Storage & Privacy screen.
    static let systemSearchFooter =
        "The search index is kept on this iPhone by iOS, never on a server. Spotlight searches "
        + "it, and on iOS 27 Siri answers from it. Search inside the app always has the full "
        + "text, whatever you choose here."

    /// Under the three choices.
    static let systemSearchChoiceFooter =
        "Off keeps everything out of the system index. Titles and summaries shares each "
        + "conversation's title, AI summary, tags and dates, note titles, and each day's recap. "
        + "Everything also shares transcripts and note bodies, so Spotlight and Siri can match "
        + "the words that were said. Changing this rewrites the index."
}
