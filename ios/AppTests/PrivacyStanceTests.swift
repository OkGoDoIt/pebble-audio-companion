import CompanionRuntime
import Foundation
import Intelligence
import Testing
import Transcription

// The privacy stance is the one piece of copy in this app where being out of date is not a
// cosmetic problem: it is a promise about a microphone. `Copy.Privacy.stance` is therefore a pure
// function of the transcription and AI modes, and this suite pins every configuration of it.
//
// The specific drift these tests exist to prevent:
//
// - a stance that says "stays on this phone" while a cloud provider is configured (the exact
//   defect that was fixed on the Settings root, where the footer was a hard-coded promise);
// - a stance that treats "Local first" as a guarantee — it is a preference, and both routers
//   fall back to the network on almost any failure;
// - the stance and `Copy.Privacy.dataFlow` (the Settings-root one-liner) disagreeing about
//   whether anything leaves at all.
@Suite("privacy stance") @MainActor
struct PrivacyStanceTests {

    // MARK: - Helpers

    /// The four modes that matter for the stance, as the two "only" endpoints — the
    /// unambiguous configurations, where the sentence must be exact.
    private func inputs(
        transcription: TranscriptionMode,
        ai: AiProcessingMode,
        stt: String?,
        remoteAi: String?
    ) -> Copy.Privacy.StanceInputs {
        Copy.Privacy.StanceInputs(
            transcriptionMode: transcription,
            aiMode: ai,
            cloudTranscriptionDestination: stt,
            remoteAiDestination: remoteAi
        )
    }

    /// A real `AppSettings` on a throwaway defaults suite, so the tests exercise the REAL
    /// mode → destination derivation (`cloudTranscriptionDestination` / `remoteAiDestination`)
    /// rather than a second copy of it written here. Nothing touches the Keychain: `init` reads
    /// only defaults, and no test below asks for an API key.
    /// One suite name per call: Swift Testing runs these in parallel, and two tests clearing the
    /// same defaults domain while the other is writing it is a flake waiting to happen.
    private func makeSettings() -> AppSettings {
        let suite = "privacy-stance-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults, keychain: KeychainStore(service: "tests.unused"))
    }

    /// Every transcription × AI mode pair. Sixteen, not four: the four combinations the product
    /// talks about are (local, cloud) × (local, cloud), and each half of that has two mode
    /// spellings on each side.
    private static let allModePairs: [(TranscriptionMode, AiProcessingMode)] = {
        var pairs: [(TranscriptionMode, AiProcessingMode)] = []
        for transcription in TranscriptionMode.allCases {
            for ai in AiProcessingMode.allCases { pairs.append((transcription, ai)) }
        }
        return pairs
    }()

    // MARK: - The four combinations, stated exactly

    /// 1 of 4 — nothing leaves. The only configuration allowed to say so.
    @Test func localOnlyEverywhereSaysNothingIsSent() {
        let stance = Copy.Privacy.stance(
            for: inputs(transcription: .localOnly, ai: .localOnly, stt: nil, remoteAi: nil)
        )

        #expect(stance.isFullyLocal)
        #expect(stance.headline == "Everything stays on this phone")
        #expect(stance.summary.contains("No recording, transcript or note is sent to any service"))
        // Nothing to qualify and nothing a provider could still be holding.
        #expect(stance.qualifiers.isEmpty)
        #expect(stance.deletionNote == nil)
    }

    /// 2 of 4 — audio goes out, text does not. The mixed case the stance exists for.
    @Test func cloudTranscriptionWithLocalAiSendsAudioOnly() {
        let stance = Copy.Privacy.stance(
            for: inputs(transcription: .remoteOnly, ai: .localOnly, stt: "Soniox", remoteAi: nil)
        )

        #expect(!stance.isFullyLocal)
        #expect(stance.headline == "Audio goes to Soniox")
        #expect(stance.summary.contains("Recordings are sent to Soniox"))
        #expect(stance.summary.contains("written on this iPhone"))
        // Must not name a text destination, because there is not one.
        #expect(!stance.summary.contains("OpenAI"))
        #expect(stance.deletionNote != nil)
    }

    /// 3 of 4 — the other mixed case: raw audio never leaves, transcripts do. This is the one
    /// the user asked for by name ("audio is being transcribed locally so raw audio never
    /// leaves your phone, however transcription text is sent to your chosen cloud AI provider").
    @Test func localTranscriptionWithCloudAiKeepsAudioOnThePhone() {
        let stance = Copy.Privacy.stance(
            for: inputs(transcription: .localOnly, ai: .remoteOnly, stt: nil, remoteAi: "OpenAI")
        )

        #expect(!stance.isFullyLocal)
        #expect(stance.headline == "Only text goes to OpenAI")
        #expect(stance.summary.contains("the audio itself never leaves it"))
        #expect(stance.summary.contains("sent to OpenAI"))
        // About You rides along on remote AI runs; the stance says so rather than leaving it to
        // the About You screen alone.
        #expect(stance.summary.contains("About You"))
        #expect(stance.deletionNote != nil)
    }

    /// 4 of 4 — both halves in the cloud, two different providers, both named.
    @Test func cloudTranscriptionAndCloudAiNameBothDestinations() {
        let stance = Copy.Privacy.stance(
            for: inputs(
                transcription: .remoteOnly, ai: .remoteOnly, stt: "Soniox", remoteAi: "OpenAI")
        )

        #expect(!stance.isFullyLocal)
        #expect(stance.headline == "Audio goes to Soniox, text to OpenAI")
        #expect(stance.summary.contains("Soniox"))
        #expect(stance.summary.contains("OpenAI"))
    }

    /// One provider doing both jobs is one name, not the same name twice — the same collapse
    /// `Copy.Privacy.destinations` performs for the Settings-root footer.
    @Test func oneProviderDoingBothJobsIsNamedOnce() {
        let stance = Copy.Privacy.stance(
            for: inputs(
                transcription: .remoteOnly, ai: .remoteOnly, stt: "OpenAI", remoteAi: "OpenAI")
        )

        #expect(stance.headline == "Audio and text go to OpenAI")
        #expect(!stance.headline.contains("OpenAI, "))
    }

    // MARK: - "Local first" is a preference, not a promise

    /// `TranscriptionModeRouter.localFirst` rethrows only `CancellationError` and "no speech";
    /// every other local failure — `providerUnavailable` from an uninstalled language model
    /// included — re-reads the segment and uploads it. A stance that let "Local first" read as
    /// "audio stays here" would be a false promise, so the mode has to be qualified out loud.
    @Test func localFirstTranscriptionIsQualifiedNotPromised() throws {
        let stance = Copy.Privacy.stance(
            for: inputs(transcription: .localFirst, ai: .localOnly, stt: "Soniox", remoteAi: nil)
        )

        #expect(!stance.isFullyLocal)
        let qualifier = try #require(stance.qualifiers.first)
        #expect(qualifier.contains("Local first"))
        #expect(qualifier.contains("uploaded only when"))
        #expect(qualifier.contains("not installed"))
    }

    /// `OnDeviceAiProvider` refuses every structured-output request, and both `FollowUpWorker`
    /// and `FollowUpCurator` tag all of theirs — so in AI "Local first" follow-up detection
    /// reaches the remote provider on every single run, not occasionally. The copy says
    /// "always", because that is what the router does.
    /// Renamed from `localFirstAiAdmitsFollowUpsAlwaysGoOut`. On-device follow-ups landed, so
    /// "always … for finding follow-ups" became false on any device with Apple Intelligence.
    /// What still has to be admitted is the fallback itself.
    @Test func localFirstAiAdmitsTextCanStillLeave() throws {
        let stance = Copy.Privacy.stance(
            for: inputs(transcription: .localOnly, ai: .localFirst, stt: nil, remoteAi: "OpenAI")
        )

        let qualifier = try #require(stance.qualifiers.first)
        #expect(qualifier.contains("Local first"))
        #expect(qualifier.contains("Text still goes"))
        #expect(!qualifier.contains("always"), "on-device follow-ups made that word false")
    }

    /// The "only" modes are unambiguous — the summary has already said everything goes out —
    /// so they get no qualifier. A sentence explaining a fallback that cannot happen is noise,
    /// and noise is what makes people stop reading the paragraph that matters.
    @Test func theOnlyModesAreNotQualified() {
        let stance = Copy.Privacy.stance(
            for: inputs(
                transcription: .remoteOnly, ai: .remoteOnly, stt: "Soniox", remoteAi: "OpenAI")
        )
        #expect(stance.qualifiers.isEmpty)
    }

    /// The default install is Cloud first on both halves, and that IS qualified: "first" means
    /// there is a fallback, and the user should not have to infer which way round it runs.
    @Test func theDefaultCloudFirstConfigurationIsQualified() {
        let settings = makeSettings()
        let stance = settings.privacyStance

        #expect(settings.transcriptionMode == .remoteFirst)
        #expect(settings.aiMode == .remoteFirst)
        #expect(stance.qualifiers.count == 2)
        #expect(stance.qualifiers[0].contains("Cloud first"))
        #expect(stance.qualifiers[1].contains("Remote first"))
    }

    // MARK: - Invariants across every configuration

    /// The invariant that makes this screen safe to ship: across all sixteen mode pairs, a
    /// destination that exists is always named, and "fully local" is claimed only when both
    /// halves really are local-only.
    @Test func everyConfigurationNamesWhatItSends() {
        let settings = makeSettings()

        for (transcription, ai) in Self.allModePairs {
            settings.transcriptionMode = transcription
            settings.aiMode = ai
            let stance = settings.privacyStance

            let stt = settings.cloudTranscriptionDestination
            let remoteAi = settings.remoteAiDestination

            #expect(
                stance.isFullyLocal == (stt == nil && remoteAi == nil),
                "isFullyLocal disagrees with the destinations for \(transcription)/\(ai)")

            if let stt {
                #expect(
                    stance.summary.contains(stt),
                    "\(transcription)/\(ai) sends audio to \(stt) without naming it")
            }
            if let remoteAi {
                #expect(
                    stance.summary.contains(remoteAi),
                    "\(transcription)/\(ai) sends text to \(remoteAi) without naming it")
            }
            // A provider that has been sent something may still be holding it, so the deletion
            // note is shown exactly when there is something it cannot reach.
            #expect((stance.deletionNote != nil) == !stance.isFullyLocal)
        }
    }

    /// The stance and the Settings-root one-liner are two lengths of the same statement. If they
    /// could disagree about whether anything leaves, one of the two screens would be lying.
    @Test func theStanceAgreesWithTheSettingsRootFooter() {
        let settings = makeSettings()

        for (transcription, ai) in Self.allModePairs {
            settings.transcriptionMode = transcription
            settings.aiMode = ai

            let footer = Copy.Privacy.dataFlow(
                transcription: settings.cloudTranscriptionDestination,
                ai: settings.remoteAiDestination
            )
            let staysHere = footer == "Recordings and transcripts stay on this phone."

            #expect(
                staysHere == settings.privacyStance.isFullyLocal,
                "footer and stance disagree for \(transcription)/\(ai)")
        }
    }

    /// Only `localOnly` on both sides is airtight — `localFirst` reaches the network as a
    /// fallback, which is why `cloudTranscriptionEnabled` / `remoteAiEnabled` are
    /// `!= .localOnly` rather than `== .remoteAnything`. Pinned here so a future "make Local
    /// first mean local" refactor has to come past this test.
    @Test func onlyLocalOnlyOnBothSidesIsFullyLocal() {
        let settings = makeSettings()

        for (transcription, ai) in Self.allModePairs {
            settings.transcriptionMode = transcription
            settings.aiMode = ai
            let expected = transcription == .localOnly && ai == .localOnly
            #expect(settings.privacyStance.isFullyLocal == expected)
        }
    }

    /// The provider name in the stance is the one the user actually picked, not a constant.
    @Test func theStanceFollowsTheChosenCloudProvider() {
        let settings = makeSettings()
        settings.transcriptionMode = .remoteOnly
        settings.aiMode = .localOnly

        settings.cloudTranscriptionProvider = .soniox
        #expect(settings.privacyStance.headline == "Audio goes to Soniox")

        settings.cloudTranscriptionProvider = .openAi
        #expect(settings.privacyStance.headline == "Audio goes to OpenAI")
    }

    // MARK: - The fixed half

    /// The standing commitments are shown in every configuration, and none of them may quietly
    /// become configuration-dependent.
    @Test func theCommitmentsAreTheSameInEveryConfiguration() {
        let settings = makeSettings()

        for (transcription, ai) in Self.allModePairs {
            settings.transcriptionMode = transcription
            settings.aiMode = ai
            #expect(settings.privacyStance.commitments == Copy.Privacy.commitments)
        }
    }

    /// The one blanket claim this copy deliberately does NOT make.
    ///
    /// The app bundles a third-party speech engine for the downloadable models, and that binary
    /// carries its own HTTP stack — so "nothing else ever phones home" could not be verified
    /// from source and is not printed. If someone adds it later, this fails and they have to go
    /// and check the binary first.
    @Test func noCommitmentClaimsNothingElseEverConnects() {
        for commitment in Copy.Privacy.commitments {
            let lowered = commitment.lowercased()
            #expect(!lowered.contains("nothing else"))
            #expect(!lowered.contains("no other network"))
            #expect(!lowered.contains("never connects"))
        }
    }
}
