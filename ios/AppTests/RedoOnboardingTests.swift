import CompanionRuntime
import Foundation
import Intelligence
import Receiver
import Testing
import Transcription

// Settings · Diagnostics → "Redo onboarding".
//
// This suite exists to stop one specific thing happening: the row quietly becoming a data-loss
// button. It is one line of code today (`onboardingComplete = false`) and the whole value of it
// is everything it does NOT do — so the assertions are mostly negative, and they are written as
// an explicit inventory rather than "and nothing else changed", because "nothing else" is what
// a future edit would silently redefine.
//
// The second half pins the other half of "you cannot come out worse than you went in": a re-run
// that the person walks through without changing anything must leave the processing modes
// byte-identical. Onboarding's cards can only express `.localOnly` and `.remoteFirst`, while
// Settings offers all four modes of each axis, so "write what the selected card means" is not
// good enough on a second pass.
@Suite("redo onboarding") @MainActor
struct RedoOnboardingTests {

    // MARK: - Helpers

    /// Every UserDefaults key `AppSettings` owns, by its ON-DISK name. Listed here rather than
    /// read from the (private) `AppSettings.Keys` on purpose: the point of the suite is to
    /// notice when the set of things a reset touches changes, and a list that derives itself
    /// from the code under test cannot notice anything.
    private static let settingsKeys = [
        "capture_intent",
        // Present only while an onboarding run has capture switched on provisionally; a re-run
        // must not leave one behind, and reopening the gate must not write one.
        "onboarding_capture_restore",
        "capture_pause_resume_at_ms",
        "capture_pause_remind_at_ms",
        "transcription_mode",
        "background_catch_up",
        "local_transcription_model",
        "cloud_transcription_provider",
        "ai_mode",
        "ai_model",
        "automatic_wav_export",
        "onboarding_complete",
        "retention_days",
        "retention_max_bytes",
        "transcripts_configured",
        "loss_alerts_enabled",
    ]

    private struct Fixture {
        let settings: AppSettings
        let defaults: UserDefaults
        let suite: String
    }

    /// A real `AppSettings` on a throwaway defaults suite — the real writes, the real property
    /// observers. One suite per call: Swift Testing runs these in parallel.
    private func makeFixture() -> Fixture {
        let suite = "redo-onboarding-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(
            defaults: defaults, keychain: KeychainStore(service: "tests.redo.\(UUID().uuidString)")
        )
        return Fixture(settings: settings, defaults: defaults, suite: suite)
    }

    /// A finished, opinionated install: someone who has been using the app for a while and
    /// whose settings are all away from their defaults. Anything a reset touches will show.
    private func makeConfiguredInstall() -> Fixture {
        let fixture = makeFixture()
        let settings = fixture.settings
        settings.onboardingComplete = true
        settings.captureIntent = .active
        settings.transcriptionMode = .localOnly
        settings.aiMode = .remoteFirst
        settings.transcriptsConfigured = true
        settings.cloudTranscriptionProvider = .openAi
        settings.localTranscriptionModelId = "parakeet-tdt-0.6b-v3-int8"
        settings.aiModel = "gpt-5.6-luna-test"
        settings.retentionDays = 90
        settings.retentionMaxBytes = AppSettings.retentionLimitOptions.last ?? 0
        settings.automaticWavExportEnabled = true
        settings.lossAlertsEnabled = true
        settings.backgroundCatchUp = .always
        return fixture
    }

    private func snapshot(_ defaults: UserDefaults) -> [String: String] {
        var values: [String: String] = [:]
        for key in Self.settingsKeys {
            if let value = defaults.object(forKey: key) {
                values[key] = String(describing: value)
            }
        }
        return values
    }

    // MARK: - What it resets: exactly one thing

    /// THE test. Reopening the gate may change `onboarding_complete` and nothing else.
    @Test func reopeningTheGateWritesExactlyOneKey() {
        let fixture = makeConfiguredInstall()
        let before = snapshot(fixture.defaults)

        OnboardingRerun.reopen(fixture.settings)

        let after = snapshot(fixture.defaults)
        let changed = Set(
            Self.settingsKeys.filter { before[$0] != after[$0] }
        )
        #expect(changed == ["onboarding_complete"])
        #expect(!fixture.settings.onboardingComplete)
    }

    /// The same statement made against whatever keys actually exist, so a key added to
    /// `AppSettings` after this file was written is still covered. Guarded, because
    /// `persistentDomain` is allowed to answer with nothing for a suite in some hosts and an
    /// empty-versus-empty comparison would pass without asserting anything.
    @Test func nothingOutsideTheKnownKeysMovesEither() {
        let fixture = makeConfiguredInstall()
        guard let before = fixture.defaults.persistentDomain(forName: fixture.suite),
            !before.isEmpty
        else { return }

        OnboardingRerun.reopen(fixture.settings)

        let after = fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]
        let changed = Set(
            Set(before.keys).union(after.keys).filter {
                String(describing: before[$0]) != String(describing: after[$0])
            }
        )
        #expect(changed == ["onboarding_complete"])
    }

    /// The inventory, spelled out. Every one of these is something a person would be upset to
    /// lose, and every one of them is something a careless "reset" would take.
    @Test func everySettingTheUserChoseSurvives() {
        let fixture = makeConfiguredInstall()
        let settings = fixture.settings

        OnboardingRerun.reopen(settings)

        // Step 3's answer: kept, because the flow now re-opens ON it rather than asking from
        // scratch. Clearing `transcriptsConfigured` here would also drop Today into
        // "Transcripts are off" for the duration of the re-run.
        #expect(settings.transcriptionMode == .localOnly)
        #expect(settings.aiMode == .remoteFirst)
        #expect(settings.transcriptsConfigured)
        #expect(settings.cloudTranscriptionProvider == .openAi)
        #expect(settings.localTranscriptionModelId == "parakeet-tdt-0.6b-v3-int8")
        #expect(settings.aiModel == "gpt-5.6-luna-test")

        // Capture is opt-in and can be recording RIGHT NOW. A reset that switched it off would
        // end a recording to re-show a screen.
        #expect(settings.captureIntent == .active)

        // Storage, retention and the loss alert have nothing to do with onboarding at all.
        #expect(settings.retentionDays == 90)
        #expect(settings.retentionMaxBytes == AppSettings.retentionLimitOptions.last)
        #expect(settings.automaticWavExportEnabled)
        #expect(settings.lossAlertsEnabled)
        #expect(settings.backgroundCatchUp == .always)
    }

    /// The Keychain is where the API keys live — and, load-bearingly, the receiver id the WATCH
    /// has stored a hash of. Losing that id is losing the binding: the watch would refuse this
    /// phone until someone ran Forget Receiver on it. Best-effort, because a test host without
    /// a usable keychain cannot write in the first place; the assertion runs only if the setup
    /// write succeeded.
    @Test func keychainSecretsAndTheWatchBindingSurvive() {
        let fixture = makeConfiguredInstall()
        let settings = fixture.settings
        let wroteReceiver = settings.keychain.set("receiver-id-under-test", for: .receiverId)
        let wroteKey = settings.setApiKey("sk-test-abcdefgh", for: .openAi)

        OnboardingRerun.reopen(settings)

        if wroteReceiver {
            #expect(settings.keychain.string(for: .receiverId) == "receiver-id-under-test")
        }
        if wroteKey {
            #expect(settings.hasApiKey(for: .openAi))
        }
        settings.keychain.remove(.receiverId)
        settings.removeApiKey(for: .openAi)
    }

    /// The row's footer is the only thing telling a person what the button will do, so the
    /// promise is pinned next to the behaviour that has to keep it — including the one thing a
    /// re-run genuinely changes, which is capture. `LiveWatchPairingSource` sets
    /// `captureIntent = .active` the moment step 1's Connect Watch is tapped, so someone who
    /// had capture off comes out of a completed re-run with it on. A row that listed only the
    /// reassurances would be the misleading half of the truth.
    @Test func theFooterNamesWhatSurvivesAndWhatChanges() {
        let footer = Copy.Settings.Diagnostics.redoOnboardingFooter
        #expect(footer.contains("Recordings"))
        #expect(footer.contains("keys"))
        #expect(footer.contains("watch pairing"))
        #expect(footer.contains("capture"))
        // "Reset" was the old DEBUG label, and next to "Delete All Data" it reads like erasure.
        #expect(!Copy.Settings.Diagnostics.redoOnboarding.lowercased().contains("reset"))
    }

    // MARK: - A second pass cannot silently change where data goes

    private func makeModel() -> OnboardingViewModel {
        OnboardingViewModel(source: MockWatchPairingSource())
    }

    /// A fresh install still opens on "In the cloud" — the artboard's default — because that is
    /// what its stored defaults already mean. Seeding must not change the first run.
    @Test func aFreshInstallStillOpensOnTheCloudCard() {
        let fixture = makeFixture()
        let model = makeModel()

        model.seed(from: fixture.settings)

        #expect(model.choice == .cloud)
        #expect(model.transcriptsPlace == .inCloud)
        #expect(model.aiPlace == .inCloud)
    }

    /// …and finishing it still configures transcripts, which is the one write that MUST happen
    /// on an otherwise untouched first pass.
    @Test func aFreshInstallStillEndsUpConfigured() {
        let fixture = makeFixture()
        let model = makeModel()
        model.seed(from: fixture.settings)
        model.phase = .transcripts

        model.continueFromProcessing(settings: fixture.settings)

        #expect(fixture.settings.transcriptsConfigured)
        #expect(fixture.settings.transcriptionMode == .remoteFirst)
        #expect(fixture.settings.aiMode == .remoteFirst)
    }

    /// Every stored configuration opens on the card that describes it. The `.later` case is the
    /// interesting one: it writes the same modes as "On this phone" and is told apart only by
    /// `transcriptsConfigured`.
    @Test func theFlowOpensOnTheAnswerAlreadyStored() {
        struct Case {
            var transcription: TranscriptionMode
            var ai: AiProcessingMode
            var configured: Bool
            var choice: ProcessingChoice
            var transcriptsPlace: ProcessingPlace
            var aiPlace: ProcessingPlace
        }
        let cases = [
            Case(
                transcription: .localOnly, ai: .localOnly, configured: true,
                choice: .onPhone, transcriptsPlace: .onPhone, aiPlace: .onPhone),
            Case(
                transcription: .localOnly, ai: .localOnly, configured: false,
                choice: .later, transcriptsPlace: .onPhone, aiPlace: .onPhone),
            Case(
                transcription: .remoteFirst, ai: .remoteFirst, configured: true,
                choice: .cloud, transcriptsPlace: .inCloud, aiPlace: .inCloud),
            Case(
                transcription: .localOnly, ai: .remoteFirst, configured: true,
                choice: .mixed, transcriptsPlace: .onPhone, aiPlace: .inCloud),
            Case(
                transcription: .remoteFirst, ai: .localOnly, configured: true,
                choice: .mixed, transcriptsPlace: .inCloud, aiPlace: .onPhone),
            // The modes onboarding cannot express still land on the card that tells the truth
            // about where data goes: anything but `.localOnly` can reach the cloud.
            Case(
                transcription: .localFirst, ai: .remoteOnly, configured: true,
                choice: .cloud, transcriptsPlace: .inCloud, aiPlace: .inCloud),
            Case(
                transcription: .remoteOnly, ai: .localFirst, configured: true,
                choice: .cloud, transcriptsPlace: .inCloud, aiPlace: .inCloud),
        ]

        for testCase in cases {
            let fixture = makeFixture()
            fixture.settings.transcriptionMode = testCase.transcription
            fixture.settings.aiMode = testCase.ai
            fixture.settings.transcriptsConfigured = testCase.configured

            let model = makeModel()
            model.seed(from: fixture.settings)

            #expect(model.choice == testCase.choice)
            #expect(model.transcriptsPlace == testCase.transcriptsPlace)
            #expect(model.aiPlace == testCase.aiPlace)
        }
    }

    /// THE regression test for the re-run. `.localFirst` and `.remoteOnly` are reachable from
    /// Settings and unreachable from onboarding's cards, so a re-run that collapsed the seeded
    /// card back onto its own vocabulary would move this person onto a different pipeline
    /// without them touching anything or being told.
    @Test func walkingThroughUnchangedKeepsModesOnboardingCannotExpress() {
        let fixture = makeFixture()
        fixture.settings.transcriptionMode = .localFirst
        fixture.settings.aiMode = .remoteOnly
        fixture.settings.transcriptsConfigured = true
        fixture.settings.onboardingComplete = true

        OnboardingRerun.reopen(fixture.settings)
        let model = makeModel()
        model.seed(from: fixture.settings)
        model.phase = .transcripts
        model.continueFromProcessing(settings: fixture.settings)

        #expect(fixture.settings.transcriptionMode == .localFirst)
        #expect(fixture.settings.aiMode == .remoteOnly)
        #expect(fixture.settings.transcriptsConfigured)
    }

    /// The same guarantee for the ordinary case: someone on "On this phone" who re-runs and
    /// changes nothing is still on "On this phone" — never nudged into the cloud by the card
    /// this screen used to pre-select.
    @Test func walkingThroughUnchangedKeepsAPrivateSetupPrivate() {
        let fixture = makeFixture()
        fixture.settings.transcriptionMode = .localOnly
        fixture.settings.aiMode = .localOnly
        fixture.settings.transcriptsConfigured = true

        let model = makeModel()
        model.seed(from: fixture.settings)
        model.phase = .transcripts
        model.continueFromProcessing(settings: fixture.settings)

        #expect(fixture.settings.privacyStance.isFullyLocal)
        #expect(fixture.settings.cloudTranscriptionDestination == nil)
        #expect(fixture.settings.remoteAiDestination == nil)
        // No key screen, so the flow finished on its own.
        #expect(fixture.settings.onboardingComplete)
    }

    /// "Later" stays undecided when it is confirmed as-is: `transcriptsConfigured` must not be
    /// flipped true just for walking past the question a second time.
    @Test func confirmingLaterLeavesItUndecided() {
        let fixture = makeFixture()
        fixture.settings.transcriptionMode = .localOnly
        fixture.settings.aiMode = .localOnly
        fixture.settings.transcriptsConfigured = false

        let model = makeModel()
        model.seed(from: fixture.settings)
        #expect(model.choice == .later)
        model.phase = .transcripts
        model.continueFromProcessing(settings: fixture.settings)

        #expect(!fixture.settings.transcriptsConfigured)
    }

    /// Preserving the stored modes must not become "the re-run cannot change anything". A
    /// deliberate change writes, exactly as a first pass does.
    @Test func aDeliberateChangeStillWrites() {
        let fixture = makeFixture()
        fixture.settings.transcriptionMode = .localFirst
        fixture.settings.aiMode = .localOnly
        fixture.settings.transcriptsConfigured = true

        let model = makeModel()
        model.seed(from: fixture.settings)
        model.phase = .transcripts
        model.choice = .onPhone
        model.transcriptsPlace = .onPhone
        model.aiPlace = .onPhone
        model.continueFromProcessing(settings: fixture.settings)

        #expect(fixture.settings.transcriptionMode == .localOnly)
        #expect(fixture.settings.aiMode == .localOnly)
    }

    /// Someone who had everything local and deliberately moves to the cloud gets the cloud —
    /// the preservation rule keys on the ANSWER being unchanged, not on the modes being exotic.
    @Test func movingFromLocalToCloudIsHonoured() {
        let fixture = makeFixture()
        fixture.settings.transcriptionMode = .localOnly
        fixture.settings.aiMode = .localOnly
        fixture.settings.transcriptsConfigured = true

        let model = makeModel()
        model.seed(from: fixture.settings)
        model.phase = .transcripts
        model.choice = .cloud
        model.transcriptsPlace = .inCloud
        model.aiPlace = .inCloud
        model.continueFromProcessing(settings: fixture.settings)

        #expect(fixture.settings.transcriptionMode == .remoteFirst)
        #expect(fixture.settings.aiMode == .remoteFirst)
        #expect(fixture.settings.cloudTranscriptionDestination != nil)
    }

    /// The stance shown under the selected card describes the modes that will actually be
    /// written — not the card's own approximation of them. A `.localFirst` install confirming
    /// its answer must not be shown the "every recording is uploaded" sentence.
    @Test func theStanceShownDescribesTheModesThatWillBeWritten() {
        let fixture = makeFixture()
        fixture.settings.transcriptionMode = .localFirst
        fixture.settings.aiMode = .remoteFirst
        fixture.settings.transcriptsConfigured = true

        let model = makeModel()
        model.seed(from: fixture.settings)
        let applied = model.appliedPlan(with: fixture.settings)
        let previewed = fixture.settings.privacyStance(
            transcriptionMode: applied.transcriptionMode, aiMode: applied.aiMode
        )

        model.phase = .transcripts
        model.continueFromProcessing(settings: fixture.settings)

        #expect(previewed == fixture.settings.privacyStance)
    }

    /// Seeding happens once. Re-entering step 1 (backing out of pairing and starting again)
    /// must not throw away a card the person has since chosen.
    @Test func seedingDoesNotOverwriteAChoiceAlreadyMade() {
        let fixture = makeFixture()
        let model = makeModel()
        model.seed(from: fixture.settings)
        model.choice = .onPhone

        model.seed(from: fixture.settings)

        #expect(model.choice == .onPhone)
    }
}
