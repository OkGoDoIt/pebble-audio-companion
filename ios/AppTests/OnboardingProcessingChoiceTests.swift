import CompanionRuntime
import Foundation
import Intelligence
import Testing
import Transcription

// Onboarding step 3 writes the two settings that decide whether a person's recordings and
// transcripts leave their phone. This suite pins, for EVERY choice the flow offers, the exact
// `(transcriptionMode, aiMode)` pair it writes and the privacy stance that results.
//
// The bug it exists to prevent, in the shape it actually shipped in:
// `continueFromTranscripts` set `transcriptionMode = .localOnly` for the card labelled "On this
// phone — Private." and never touched `aiMode`, which stayed at its `.remoteFirst` default. So
// the private option produced local audio and every transcript, summary, follow-up and About You
// block sent to OpenAI. `onPhoneKeepsEverythingOnThePhone` below is the assertion that would
// have caught it: it asserts on the STANCE, which is derived from both modes, not on the one
// mode the old code remembered to set.
@Suite("onboarding processing choice") @MainActor
struct OnboardingProcessingChoiceTests {

    // MARK: - Helpers

    /// A real `AppSettings` on a throwaway defaults suite, so the tests exercise the REAL
    /// settings writes and the REAL mode → destination derivation rather than a second copy of
    /// either. One suite name per call: Swift Testing runs these in parallel.
    private func makeSettings() -> AppSettings {
        let suite = "onboarding-processing-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults, keychain: KeychainStore(service: "tests.unused"))
    }

    private func makeModel() -> OnboardingViewModel {
        OnboardingViewModel(source: MockWatchPairingSource())
    }

    /// Runs step 3 exactly as the screens do: pick, then Continue.
    @discardableResult
    private func answer(
        _ choice: ProcessingChoice,
        transcripts: ProcessingPlace = .inCloud,
        ai: ProcessingPlace = .inCloud,
        settings: AppSettings
    ) -> OnboardingViewModel {
        let model = makeModel()
        model.phase = .transcripts
        model.choice = choice
        model.transcriptsPlace = transcripts
        model.aiPlace = ai
        model.continueFromProcessing(settings: settings)
        return model
    }

    // MARK: - The three presets, pinned to the pair they write

    /// THE regression test. "On this phone" must set BOTH axes, and the stance derived from the
    /// settings it wrote must be the one configuration allowed to say nothing leaves.
    @Test func onPhoneKeepsEverythingOnThePhone() {
        let settings = makeSettings()
        answer(.onPhone, settings: settings)

        #expect(settings.transcriptionMode == .localOnly)
        // The line the original bug never wrote.
        #expect(settings.aiMode == .localOnly)
        #expect(settings.transcriptsConfigured)

        // Derived, not asserted: this is the same stance Settings · Storage & Privacy shows.
        #expect(settings.privacyStance.isFullyLocal)
        #expect(settings.privacyStance.headline == "Everything stays on this phone")
        #expect(settings.cloudTranscriptionDestination == nil)
        #expect(settings.remoteAiDestination == nil)
    }

    /// Someone redoing onboarding with older audio in iCloud Drive: step 3's "On this phone"
    /// card is not "Everything stays on this phone", and its dot is not the green one, exactly
    /// as the Privacy screen counts iCloud Drive as a place (`PrivacyModel`).
    @Test func onPhoneWithOlderAudioInICloudSaysWhereTheAudioGoes() {
        let settings = makeSettings()
        settings.coldStorageEnabled = true
        let pending = settings.privacyStance(transcriptionMode: .localOnly, aiMode: .localOnly)
        #expect(!pending.isFullyLocal)
        #expect(pending.headline == "Older audio goes to your iCloud Drive")
        #expect(!pending.summary.contains("any service"))
        #expect(pending.qualifiers.contains { $0.contains("iCloud Drive") })
        // The committed stance agrees with the pending one.
        answer(.onPhone, settings: settings)
        #expect(settings.privacyStance == pending)
    }

    @Test func cloudSendsBothAndSaysSo() {
        let settings = makeSettings()
        answer(.cloud, settings: settings)

        #expect(settings.transcriptionMode == .remoteFirst)
        #expect(settings.aiMode == .remoteFirst)
        #expect(settings.transcriptsConfigured)

        let stance = settings.privacyStance
        #expect(!stance.isFullyLocal)
        #expect(settings.remoteAiDestination == Copy.Privacy.remoteAi)
        #expect(settings.cloudTranscriptionDestination != nil)
        // Both "first" modes are qualified — neither is a guarantee, and the stance says so.
        #expect(stance.qualifiers.count == 2)
    }

    /// "Later" must fail CLOSED. It used to leave both modes at their `.remoteFirst` defaults,
    /// so someone who explicitly declined to choose was configured to upload.
    @Test func laterFailsClosedAndLeavesTheQuestionOpen() {
        let settings = makeSettings()
        answer(.later, settings: settings)

        #expect(settings.transcriptionMode == .localOnly)
        #expect(settings.aiMode == .localOnly)
        // The only difference from "On this phone": the Q14 question is still unanswered, which
        // is what Today's "Transcripts are off" card reads.
        #expect(!settings.transcriptsConfigured)
        #expect(settings.privacyStance.isFullyLocal)
    }

    // MARK: - The two-axis screen: all four combinations reachable and honest

    /// All four, spelled out rather than derived, so the table itself is the specification: this
    /// is the list a reviewer checks against `ProcessingPlace`'s mode mapping.
    @Test func mixedWritesBothAxesForEveryCombination() {
        let cases:
            [(ProcessingPlace, ProcessingPlace, TranscriptionMode, AiProcessingMode)] = [
                (.onPhone, .onPhone, .localOnly, .localOnly),
                (.onPhone, .inCloud, .localOnly, .remoteFirst),
                (.inCloud, .onPhone, .remoteFirst, .localOnly),
                (.inCloud, .inCloud, .remoteFirst, .remoteFirst),
            ]
        for (transcripts, ai, expectedTranscription, expectedAi) in cases {
            let settings = makeSettings()
            answer(.mixed, transcripts: transcripts, ai: ai, settings: settings)

            #expect(settings.transcriptionMode == expectedTranscription)
            #expect(settings.aiMode == expectedAi)
            #expect(settings.transcriptsConfigured)
        }
    }

    /// The combination onboarding could not previously express at all, and the one with the most
    /// interesting stance: the audio never leaves, the text does.
    @Test func localTranscriptsWithCloudAiSaysOnlyTextLeaves() {
        let settings = makeSettings()
        answer(.mixed, transcripts: .onPhone, ai: .inCloud, settings: settings)

        let stance = settings.privacyStance
        #expect(!stance.isFullyLocal)
        #expect(stance.headline == "Only text goes to \(Copy.Privacy.remoteAi)")
        #expect(settings.cloudTranscriptionDestination == nil)
    }

    @Test func cloudTranscriptsWithLocalAiSaysOnlyAudioLeaves() {
        let settings = makeSettings()
        answer(.mixed, transcripts: .inCloud, ai: .onPhone, settings: settings)

        let stance = settings.privacyStance
        let provider = settings.cloudTranscriptionProvider.displayName
        #expect(!stance.isFullyLocal)
        #expect(stance.headline == "Audio goes to \(provider)")
        #expect(settings.remoteAiDestination == nil)
    }

    // MARK: - No offered choice may promise privacy it cannot keep

    /// Neither "first" mode is a guarantee: `TranscriptionModeRouter.localFirst` uploads the
    /// segment on any local failure except cancellation and no-speech (a missing on-device
    /// language model is one of those), and `AiModeRouter.localFirst` reaches the remote provider
    /// for any request the on-device provider declines — which, since it gained structured
    /// output, means a model without structured generation or a shape it does not know, rather
    /// than every structured request. Fewer occasions, same guarantee: none. So no choice in this
    /// flow may write one.
    @Test func noChoiceWritesAFirstModeThatCouldStillUpload() {
        for choice in ProcessingChoice.allCases {
            for transcripts in ProcessingPlace.allCases {
                for ai in ProcessingPlace.allCases {
                    let plan = ProcessingPlan.plan(
                        for: choice, transcripts: transcripts, ai: ai)
                    #expect(plan.transcriptionMode != .localFirst)
                    #expect(plan.aiMode != .localFirst)
                }
            }
        }
    }

    /// Whatever a choice sets, the words must be true afterwards: every plan that reads as
    /// "on this phone" on both axes must produce a fully-local stance, and no other plan may.
    @Test func stanceAgreesWithTheModesForEveryOfferedPlan() {
        let settings = makeSettings()
        for choice in ProcessingChoice.allCases {
            for transcripts in ProcessingPlace.allCases {
                for ai in ProcessingPlace.allCases {
                    let plan = ProcessingPlan.plan(for: choice, transcripts: transcripts, ai: ai)
                    let stance = settings.privacyStance(
                        transcriptionMode: plan.transcriptionMode, aiMode: plan.aiMode)
                    let nothingLeaves =
                        plan.transcriptionMode == .localOnly && plan.aiMode == .localOnly
                    #expect(stance.isFullyLocal == nothingLeaves)
                    // A configuration that sends has something a provider may still hold.
                    #expect((stance.deletionNote == nil) == nothingLeaves)
                }
            }
        }
    }

    /// The uncommitted preview and the committed reading are the same function of the same
    /// inputs — a preview that could disagree with what Settings shows afterwards would be the
    /// original bug in a new place.
    @Test func previewedStanceMatchesTheOneWrittenSettingsProduce() {
        for choice in ProcessingChoice.allCases {
            for transcripts in ProcessingPlace.allCases {
                for ai in ProcessingPlace.allCases {
                    let settings = makeSettings()
                    let plan = ProcessingPlan.plan(for: choice, transcripts: transcripts, ai: ai)
                    let previewed = settings.privacyStance(
                        transcriptionMode: plan.transcriptionMode, aiMode: plan.aiMode)
                    answer(choice, transcripts: transcripts, ai: ai, settings: settings)
                    #expect(previewed == settings.privacyStance)
                }
            }
        }
    }

    // MARK: - The key hand-off asks for what the combination needs, and nothing else

    @Test func bothLocalNeedsNoKeyScreenAndFinishesOnboarding() {
        let settings = makeSettings()
        let model = answer(.onPhone, settings: settings)

        #expect(!model.plan.needsAnyKey)
        #expect(model.phase == .transcripts)  // never pushed to the key screen
        #expect(settings.onboardingComplete)
    }

    @Test func laterNeedsNoKeyScreenEither() {
        let settings = makeSettings()
        let model = answer(.later, settings: settings)

        #expect(!model.plan.needsAnyKey)
        #expect(settings.onboardingComplete)
    }

    /// Cloud AI alone still needs the OpenAI key — and must NOT ask for a transcription key the
    /// configuration will never read.
    @Test func cloudAiAloneAsksOnlyForTheAiKey() {
        let settings = makeSettings()
        let model = answer(.mixed, transcripts: .onPhone, ai: .inCloud, settings: settings)

        #expect(model.phase == .cloudKey)
        #expect(model.plan.needsAiKey)
        #expect(!model.plan.needsTranscriptionKey)
        #expect(!settings.onboardingComplete)  // the key screen finishes it
    }

    /// Cloud transcription alone needs a transcription key (Soniox or OpenAI) and no AI key.
    @Test func cloudTranscriptionAloneAsksOnlyForATranscriptionKey() {
        let settings = makeSettings()
        let model = answer(.mixed, transcripts: .inCloud, ai: .onPhone, settings: settings)

        #expect(model.phase == .cloudKey)
        #expect(model.plan.needsTranscriptionKey)
        #expect(!model.plan.needsAiKey)
    }

    @Test func fullCloudAsksForBoth() {
        let settings = makeSettings()
        let model = answer(.cloud, settings: settings)

        #expect(model.phase == .cloudKey)
        #expect(model.plan.needsTranscriptionKey)
        #expect(model.plan.needsAiKey)
    }

    // MARK: - The on-device-AI price list is attached to exactly the plans that pay it

    /// AI "Local only" has a price list, and every plan that lands there must carry it.
    ///
    /// It is no longer "no follow-ups at all": `OnDeviceAiProvider` runs the structured shapes it
    /// knows, so follow-ups ARE proposed on a device with Apple Intelligence — fewer of them, and
    /// never with a due date (see `Copy.OnboardingProcessing.onDeviceAiNote`, which records the
    /// measurement). And on a device without Apple Intelligence, `.localOnly` leaves the router
    /// nowhere to go, so nothing the AI writes appears at all. Both halves are surprising, which
    /// is exactly why the note has to be attached to every plan that pays for them.
    @Test func onDeviceAiNoteAppearsExactlyWhenAiIsLocalOnlyAndChosen() {
        for choice in ProcessingChoice.allCases {
            for transcripts in ProcessingPlace.allCases {
                for ai in ProcessingPlace.allCases {
                    let plan = ProcessingPlan.plan(for: choice, transcripts: transcripts, ai: ai)
                    #expect(plan.isOnDeviceAi == (plan.aiMode == .localOnly))
                    // Shown for every deliberate local-AI answer…
                    if choice != .later {
                        #expect(plan.showsOnDeviceAiCost == plan.isOnDeviceAi)
                    }
                }
            }
        }
        // …and never on "Later", which lands on the same modes without anyone choosing them.
        let later = ProcessingPlan.plan(for: .later, transcripts: .onPhone, ai: .onPhone)
        #expect(later.isOnDeviceAi)
        #expect(!later.showsOnDeviceAiCost)
    }

    // MARK: - Navigation: no dead ends, no silently changed answers

    /// Opening the two-axis screen from a preset and backing straight out must restore that
    /// exact preset. "Later" is the case that matters: its modes are identical to "On this
    /// phone", so collapsing on modes alone would turn an undecided person into a decided one.
    @Test func backingOutOfTheDetailScreenUnchangedRestoresThePreset() {
        for preset in ProcessingChoice.presets {
            let model = makeModel()
            model.phase = .transcripts
            model.choice = preset
            model.openProcessingDetail()
            #expect(model.phase == .processingDetail)
            #expect(model.choice == .mixed)

            model.backToProcessing()
            #expect(model.phase == .transcripts)
            #expect(model.choice == preset)
        }
    }

    /// Changing an axis to something a card can express collapses onto that card; a genuine mix
    /// stays `.mixed`, which is what makes the question screen render its summary card.
    @Test func changedAxesCollapseOntoTheCardThatMatches() {
        let model = makeModel()
        model.choice = .onPhone
        model.openProcessingDetail()
        model.aiPlace = .inCloud
        model.backToProcessing()
        #expect(model.choice == .mixed)

        model.openProcessingDetail()
        model.transcriptsPlace = .inCloud
        model.backToProcessing()
        #expect(model.choice == .cloud)
    }

    /// The key screen's back affordance names the screen it will actually return to (B15).
    @Test func keyScreenReturnsToWhicheverScreenSentItThere() {
        let settings = makeSettings()

        let fromCards = answer(.cloud, settings: settings)
        #expect(fromCards.cloudKeyBackLabel == Copy.OnboardingProcessing.backToProcessing)
        fromCards.backFromCloudKey()
        #expect(fromCards.phase == .transcripts)

        let fromDetail = makeModel()
        fromDetail.phase = .transcripts
        fromDetail.choice = .onPhone
        fromDetail.openProcessingDetail()
        fromDetail.aiPlace = .inCloud
        fromDetail.continueFromProcessing(settings: makeSettings())
        #expect(fromDetail.phase == .cloudKey)
        #expect(fromDetail.cloudKeyBackLabel == Copy.OnboardingProcessing.detailTitle)
        fromDetail.backFromCloudKey()
        #expect(fromDetail.phase == .processingDetail)
    }

    /// Seeding: the detail screen opens on the places the current card already implies, so it
    /// can never contradict the card the person just tapped.
    @Test func detailScreenOpensSeededFromTheCurrentChoice() {
        let cloud = makeModel()
        cloud.choice = .cloud
        cloud.openProcessingDetail()
        #expect(cloud.transcriptsPlace == .inCloud)
        #expect(cloud.aiPlace == .inCloud)

        let onPhone = makeModel()
        onPhone.choice = .onPhone
        onPhone.openProcessingDetail()
        #expect(onPhone.transcriptsPlace == .onPhone)
        #expect(onPhone.aiPlace == .onPhone)
    }

    // MARK: - The cloud sub-choice (iOS 27): Apple Private Cloud Compute needs no key

    /// The remote provider rides on the plan; the default keeps every existing answer exactly
    /// as it was, key hand-off included.
    @Test func theDefaultRemoteIsOpenAiAndAsksForItsKey() {
        let plan = ProcessingPlan.plan(for: .cloud, transcripts: .inCloud, ai: .inCloud)
        #expect(plan.remoteAiProvider == .openAi)
        #expect(plan.needsAiKey)
    }

    /// Choosing Apple's cloud for the AI asks for NO AI key. With local transcripts there is no
    /// key screen at all — onboarding finishes on Continue.
    @Test func applePrivateCloudWithLocalTranscriptsNeedsNoKeyScreen() {
        let settings = makeSettings()
        let model = makeModel()
        model.phase = .transcripts
        model.choice = .mixed
        model.transcriptsPlace = .onPhone
        model.aiPlace = .inCloud
        model.remoteAiProvider = .applePrivateCloud
        model.continueFromProcessing(settings: settings)

        #expect(!model.plan.needsAiKey)
        #expect(!model.plan.needsAnyKey)
        #expect(settings.onboardingComplete)
        #expect(settings.aiMode == .remoteFirst)
        #expect(settings.remoteAiProvider == .applePrivateCloud)
        #expect(settings.remoteAiDestination == Copy.Privacy.applePrivateCloud)
    }

    /// Full cloud with Apple's AI still needs a transcription key, and only that.
    @Test func applePrivateCloudWithCloudTranscriptsAsksOnlyForATranscriptionKey() {
        let settings = makeSettings()
        let model = makeModel()
        model.phase = .transcripts
        model.choice = .cloud
        model.remoteAiProvider = .applePrivateCloud
        model.continueFromProcessing(settings: settings)

        #expect(model.phase == .cloudKey)
        #expect(model.plan.needsTranscriptionKey)
        #expect(!model.plan.needsAiKey)
        #expect(settings.remoteAiProvider == .applePrivateCloud)
    }

    /// AI on the phone was never asked which cloud, so the stored provider is left alone.
    @Test func onPhoneAiDoesNotTouchTheRemoteProvider() {
        let settings = makeSettings()
        settings.remoteAiProvider = .applePrivateCloud
        let model = makeModel()
        model.phase = .transcripts
        model.choice = .onPhone
        model.remoteAiProvider = .openAi  // the view model's default, never shown
        model.continueFromProcessing(settings: settings)

        #expect(settings.remoteAiProvider == .applePrivateCloud)
    }

    /// The stance previewed under the card, with the pending provider, is the one the settings
    /// produce after the write — for both remotes.
    @Test func previewedStanceMatchesTheWrittenOneForBothRemotes() {
        for remote in RemoteAiProvider.allCases {
            let settings = makeSettings()
            let plan = ProcessingPlan.plan(
                for: .mixed, transcripts: .onPhone, ai: .inCloud, remoteAi: remote)
            let previewed = settings.privacyStance(
                transcriptionMode: plan.transcriptionMode, aiMode: plan.aiMode,
                remoteAiProvider: plan.remoteAiProvider)
            let model = makeModel()
            model.phase = .transcripts
            model.choice = .mixed
            model.transcriptsPlace = .onPhone
            model.aiPlace = .inCloud
            model.remoteAiProvider = remote
            model.continueFromProcessing(settings: settings)
            #expect(previewed == settings.privacyStance, "\(remote)")
            #expect(previewed.headline.contains(Copy.Privacy.remoteAiName(for: remote)))
        }
    }

    /// A re-run that changes only the remote provider keeps the stored modes verbatim — the
    /// provider is not a mode and must not collapse `.localFirst` onto `.remoteFirst`.
    @Test func changingOnlyTheRemoteProviderKeepsTheStoredModes() {
        let settings = makeSettings()
        settings.transcriptionMode = .localOnly
        settings.aiMode = .localFirst
        settings.transcriptsConfigured = true
        settings.remoteAiProvider = .openAi

        let model = makeModel()
        model.seed(from: settings)
        #expect(model.remoteAiProvider == .openAi)
        model.remoteAiProvider = .applePrivateCloud
        model.continueFromProcessing(settings: settings)

        #expect(settings.transcriptionMode == .localOnly)
        #expect(settings.aiMode == .localFirst)
        #expect(settings.remoteAiProvider == .applePrivateCloud)
        // …and Local-first AI with Apple's cloud needs no key, so the flow finished.
        #expect(settings.onboardingComplete)
    }
}
