import Foundation
import Intelligence
import Transcription

// What Settings · Transcription & AI says about the LOCAL half of each axis: whether this phone
// can run it, and — only where the answer changes what the person gets — what that costs them.
//
// An extension on `Copy` (still the one approved catalog) in its own file, the way
// `Copy+Uploads.swift` already extends `Copy.Settings.TranscriptionAI`.
//
// Rules this copy is written to:
//
// - **Say which of the three it is.** `SystemLanguageModel.availability` distinguishes hardware
//   that never will, a switch that is off, and a download that is running. Collapsing those into
//   "not available" would leave two of the three people with nothing to do about it.
// - **Only where it matters.** Every sentence below is conditional on the mode actually
//   depending on the thing it describes. A phone that cannot run Apple Intelligence, in Cloud
//   only, is not told about it — nothing is missing there.
// - **Describe, do not warn.** Keeping everything on the phone is a legitimate choice, so its
//   price is stated in the same register as any other setting: no red, no exclamation, no
//   paragraph. Same stance as `Copy+OnboardingProcessing.onDeviceAiNote`, which is the
//   onboarding half of this same fact.
// - **Never contradict Storage & Privacy.** `Copy+PrivacyStance.swift` says a `localFirst`
//   configuration uploads "when the on-device engine cannot finish it". The lines here name the
//   case where that is happening to EVERY recording — a sharper version of the same truth, never
//   a different one.

extension Copy.Settings.TranscriptionAI {

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Naming the cloud things "cloud"
    // ─────────────────────────────────────────────────────────────────────────

    /// Replaces "Model". The row picks the OpenAI model and nothing else, and in the two mixed
    /// modes it sat two rows below "Local model" with no way to tell them apart — which is
    /// exactly what was reported. The pair now reads "Local model" / "Cloud model": the same
    /// noun, and the word that distinguishes them comes first in both.
    /// Renamed again with the second remote provider: the row only ever picks an OpenAI model,
    /// and beside "Remote provider" the word "Cloud" no longer said which cloud.
    static let cloudModel = "OpenAI model"

    /// The AI card's readiness row. "On this phone" rather than "On-device model" — the same
    /// vocabulary `Copy.OnboardingProcessing.aiOnPhone` uses for this axis, and the person chose
    /// private processing, not a component.
    static let onThisPhone = "On this phone"

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: The AI readiness row's value
    // ─────────────────────────────────────────────────────────────────────────

    /// Lowercase, in the same register as "not set" and "not installed" on the rows above it.
    static func onDeviceAiValue(_ readiness: OnDeviceAiReadiness) -> String {
        switch readiness {
        case .ready: return "ready"
        // Matches "not available here" on the local-model row: the same shape of answer about
        // the same kind of fact.
        case .notSupported: return "not supported here"
        case .switchedOff: return "off in iOS Settings"
        case .preparing: return "getting ready"
        }
    }

    /// One line under the AI card, or nil when there is nothing worth saying.
    ///
    /// Nil for a ready model, nil when the mode does not use the on-device model at all, and nil
    /// in Remote first — where OpenAI is the primary path, the row's own value already says the
    /// fallback is missing, and a sentence about a fallback would be the loudest thing on a card
    /// that is working.
    ///
    /// `remoteName` is whichever remote provider is configured — OpenAI, or on iOS 27 Apple
    /// Private Cloud Compute — so the Local-first sentence names where the text actually goes.
    static func onDeviceAiNote(
        mode: AiProcessingMode, readiness: OnDeviceAiReadiness,
        remoteName: String = Copy.Privacy.remoteAi
    ) -> String? {
        guard mode.usesOnDeviceModel, !readiness.isReady else { return nil }
        switch mode {
        case .localOnly:
            // The consequence, then what to do — because in Local only the router has nowhere
            // else to go, so this is the difference between "runs here" and "runs here if it
            // can". Named after what the person loses, not after the framework.
            switch readiness {
            case .notSupported:
                return "Apple Intelligence doesn’t run on this iPhone, so summaries, notes and "
                    + "answers stay empty in Local only."
            case .switchedOff:
                return "Apple Intelligence is off in iOS Settings, so nothing is written until "
                    + "it’s turned on."
            case .preparing:
                return "Apple Intelligence is still getting ready. Summaries and answers start "
                    + "once it is."
            case .ready:
                return nil
            }
        case .localFirst:
            // Sharper than the Storage & Privacy qualifier, and in the same direction: that
            // screen says text goes to OpenAI "when the on-device model cannot do a job", and
            // right now that is every job. A model that is still downloading gets the temporary
            // wording — "unavailable" would be true today and wrong tomorrow.
            return readiness == .preparing
                ? "Until Apple Intelligence is ready, every summary, note, and answer is written "
                    + "by \(remoteName)."
                : "With Apple Intelligence unavailable, every summary, note, and answer is "
                    + "written by \(remoteName)."
        case .remoteFirst, .remoteOnly:
            return nil
        }
    }

    /// The footer on the AI **Mode** picker — the screen where the choice is actually made.
    ///
    /// Present only when this phone cannot do the local half, and phrased around what Local only
    /// would produce rather than around the option the reader should pick: preventing the choice
    /// would be wrong (switching Apple Intelligence on, or letting a download finish, fixes two
    /// of the three cases, and "everything stays on this phone" is a legitimate thing to want),
    /// so the honest move is to make the consequence visible at the moment of choosing.
    static func aiModeChoiceFooter(_ readiness: OnDeviceAiReadiness) -> String? {
        switch readiness {
        case .ready:
            return nil
        case .notSupported:
            return "Apple Intelligence doesn’t run on this iPhone. In Local only, summaries, "
                + "notes, and answers stay empty."
        case .switchedOff:
            return "Apple Intelligence is off in iOS Settings. Until it’s on, Local only writes "
                + "nothing."
        case .preparing:
            return "Apple Intelligence is still getting ready. Local only has nothing to write "
                + "with until it is."
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: The transcription half
    // ─────────────────────────────────────────────────────────────────────────

    /// One line under the transcription card, or nil.
    ///
    /// The "Local model" row already reports the engine's own state ("not installed · Apple
    /// Speech", "downloading · 44%", "not available here"). What it cannot say is the
    /// CONSEQUENCE, and the consequence depends on the mode: in Local only nothing is
    /// transcribed at all, while in Local first every recording is uploaded instead.
    static func localTranscriptionNote(
        mode: TranscriptionMode,
        readiness: OnDeviceTranscriptionReadiness,
        cloudProvider: String
    ) -> String? {
        guard mode.usesOnDeviceEngine, !readiness.isReady else { return nil }
        // A download in flight needs no sentence: the row is showing its progress, and it will
        // simply start working.
        guard case .needsModel(let appleSpeechUnsupported) = readiness else { return nil }
        switch mode {
        case .localOnly:
            return appleSpeechUnsupported
                ? "iOS has no speech model for this phone’s language, so nothing is transcribed "
                    + "until you download one in Local model."
                : "No speech model is installed, so nothing is transcribed until you download "
                    + "one in Local model."
        case .localFirst:
            return "With no speech model installed, every recording goes to \(cloudProvider)."
        case .remoteFirst, .remoteOnly:
            return nil
        }
    }

    /// The **Local model** screen's notice for the case `fallbackNotice` cannot describe: the
    /// selection is not downloaded AND iOS has no system speech model to stand in, so no engine
    /// is running at all. Naming Apple Speech there would be the same silent substitution the
    /// notice exists to remove, one level down.
    static func noFallbackNotice(_ name: String) -> String {
        "\(name) isn’t downloaded, and iOS has no speech model to stand in, so nothing is "
            + "transcribed on this phone. Tap it to download."
    }

    /// The same fact with the download already running — "tap it" would point at something that
    /// has started.
    static func noFallbackNoticeInProgress(_ name: String) -> String {
        "Nothing is transcribed on this phone until \(name) finishes downloading."
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: The screen footer
    // ─────────────────────────────────────────────────────────────────────────

    /// What the existing footer ("Set both Modes to “Local only” …") becomes once both modes
    /// already ARE Local only: instructions for something the reader has done.
    ///
    /// What this screen controls and nothing more. It used to be the Privacy stance's
    /// "Everything stays on this phone", which is false whenever older audio moves to iCloud
    /// Drive — a setting this screen does not hold; the Privacy screen says that part.
    static let everythingLocalFooter = "Transcription and AI both run on this phone."
}
