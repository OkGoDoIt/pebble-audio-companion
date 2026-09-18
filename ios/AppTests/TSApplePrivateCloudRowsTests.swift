import CompanionRuntime
import Foundation
import Intelligence
import Testing
import Transcription

// Settings · Transcription & AI with Apple Private Cloud Compute as the remote model (iOS 27):
// which rows appear, what the readiness row says, and that "fully local" is never claimed for a
// configuration that sends text to Apple's cloud. Every case is a pure function of plan inputs —
// no framework, no device.

@Suite("TS · Apple Private Cloud rows") @MainActor
struct TSApplePrivateCloudRowsTests {

    private func makePlan(
        ai: AiProcessingMode,
        transcription: TranscriptionMode = .localOnly,
        remote: RemoteAiProvider = .applePrivateCloud,
        offered: Bool = true,
        provider: CloudProvider = .soniox
    ) -> TranscriptionAiRowPlan {
        TranscriptionAiRowPlan(
            transcriptionMode: transcription, aiMode: ai, cloudTranscriptionProvider: provider,
            remoteAiProvider: remote, applePrivateCloudOffered: offered)
    }

    private func makeSettings() -> AppSettings {
        let suite = "ts-pcc-rows-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults, keychain: KeychainStore(service: "tests.unused"))
    }

    // MARK: - Which rows

    /// With Apple's cloud as the remote there is no OpenAI model to pick and no key to enter:
    /// the two OpenAI rows go, the readiness row comes.
    @Test("Apple Private Cloud replaces the OpenAI model and key rows")
    func replacesTheOpenAiRows() {
        for ai in [AiProcessingMode.localFirst, .remoteFirst, .remoteOnly] {
            let plan = makePlan(ai: ai)
            #expect(plan.showsRemoteModelChoice, "\(ai)")
            #expect(plan.showsApplePrivateCloud, "\(ai)")
            #expect(!plan.showsCloudModel, "\(ai)")
            #expect(plan.aiKey == nil, "\(ai)")
            #expect(!plan.providersInUse.contains(.openAi), "\(ai)")
            #expect(plan.keyRows.isEmpty, "\(ai)")
        }
    }

    /// The historical configuration is untouched by the new field's default.
    @Test("OpenAI as the remote shows exactly what it always did")
    func openAiIsUnchanged() {
        let before = TranscriptionAiRowPlan(
            transcriptionMode: .localOnly, aiMode: .remoteFirst, cloudTranscriptionProvider: .soniox)
        let explicit = makePlan(ai: .remoteFirst, remote: .openAi, offered: true)
        #expect(before.showsCloudModel && explicit.showsCloudModel)
        #expect(before.aiKey == .openAi && explicit.aiKey == .openAi)
        #expect(!before.showsApplePrivateCloud && !explicit.showsApplePrivateCloud)
        // The only difference the OS makes: whether the choice row is drawn.
        #expect(!before.showsRemoteModelChoice)
        #expect(explicit.showsRemoteModelChoice)
    }

    /// AI Local only reads nothing remote, so neither the choice nor the readiness row appears
    /// whatever the setting says.
    @Test("AI Local only shows nothing about the remote model")
    func localOnlyShowsNothingRemote() {
        let plan = makePlan(ai: .localOnly)
        #expect(!plan.showsRemoteModelChoice)
        #expect(!plan.showsApplePrivateCloud)
        #expect(!plan.usesApplePrivateCloud)
    }

    /// A setting that names Private Cloud Compute on an OS that does not offer it still draws
    /// the choice row — the one way back — while the provider itself fails closed.
    @Test("the choice row stays reachable when the OS does not offer the choice")
    func choiceStaysReachableForSwitchingBack() {
        let stuck = makePlan(ai: .remoteFirst, remote: .applePrivateCloud, offered: false)
        #expect(stuck.showsRemoteModelChoice)
        let normal = makePlan(ai: .remoteFirst, remote: .openAi, offered: false)
        #expect(!normal.showsRemoteModelChoice)
    }

    // MARK: - Never "fully local"

    /// Text leaves the phone for Apple's servers. No key is involved, which is exactly why this
    /// needs its own assertion: `providersInUse` is empty and the old rule would have said
    /// "everything stays on this phone".
    @Test("Apple Private Cloud is never fully local, and agrees with the privacy stance")
    func neverFullyLocal() {
        let settings = makeSettings()
        settings.remoteAiProvider = .applePrivateCloud
        for transcription in TranscriptionMode.allCases {
            for ai in AiProcessingMode.allCases {
                settings.transcriptionMode = transcription
                settings.aiMode = ai
                let plan = makePlan(ai: ai, transcription: transcription)
                #expect(plan.providersInUse.isEmpty == (plan.keyRows.isEmpty))
                #expect(
                    plan.isFullyLocal == settings.privacyStance.isFullyLocal,
                    "\(transcription.rawValue) + \(ai.rawValue)")
                if ai.usesCloudProvider {
                    #expect(!plan.isFullyLocal, "\(transcription.rawValue) + \(ai.rawValue)")
                    #expect(settings.remoteAiDestination == Copy.Privacy.applePrivateCloud)
                } else {
                    #expect(settings.remoteAiDestination == nil)
                }
            }
        }
    }

    /// The stance names the provider in full.
    @Test("the stance names Apple Private Cloud Compute as where text goes")
    func stanceNamesApple() {
        let settings = makeSettings()
        settings.transcriptionMode = .localOnly
        settings.aiMode = .remoteFirst
        settings.remoteAiProvider = .applePrivateCloud
        #expect(settings.privacyStance.headline == "Only text goes to Apple Private Cloud Compute")
        settings.remoteAiProvider = .openAi
        #expect(settings.privacyStance.headline == "Only text goes to OpenAI")
    }

    // MARK: - The readiness row's words

    @Test("every readiness reads differently, and the allowance only shows when ready")
    func readinessValues() {
        let values = ApplePrivateCloudReadiness.allCases.map {
            Copy.Settings.TranscriptionAI.applePrivateCloudValue($0, quota: .fine)
        }
        #expect(Set(values).count == ApplePrivateCloudReadiness.allCases.count)
        #expect(
            Copy.Settings.TranscriptionAI.applePrivateCloudValue(.ready, quota: .usedUp(resetsAt: nil))
                == "daily allowance used up")
        #expect(
            Copy.Settings.TranscriptionAI.applePrivateCloudValue(.ready, quota: .nearlyUsedUp)
                .contains("near"))
        // A phone that cannot use it is told that, not "used up".
        #expect(
            Copy.Settings.TranscriptionAI.applePrivateCloudValue(
                .notSupported, quota: .usedUp(resetsAt: nil)) == "not supported here")
        #expect(
            Copy.Settings.TranscriptionAI.applePrivateCloudValue(
                .notEnabledForThisBuild, quota: .fine) == "not available for this build")
    }

    /// The note appears only where the mode depends on the cloud, never as an alert, and says
    /// what happens meanwhile.
    @Test("the note appears only where the mode depends on Apple's cloud")
    func noteAppearsWhereItMatters() {
        for readiness in ApplePrivateCloudReadiness.allCases {
            #expect(
                Copy.Settings.TranscriptionAI.applePrivateCloudNote(
                    mode: .localOnly, readiness: readiness, quota: .fine) == nil)
        }
        // Ready with allowance to spare: nothing to say.
        #expect(
            Copy.Settings.TranscriptionAI.applePrivateCloudNote(
                mode: .remoteFirst, readiness: .ready, quota: .fine) == nil)
        // Used up in Remote first: the on-device model carries the work, and the note says so.
        let carried = Copy.Settings.TranscriptionAI.applePrivateCloudNote(
            mode: .remoteFirst, readiness: .ready, quota: .usedUp(resetsAt: nil))
        #expect(carried?.contains("Apple Intelligence on this iPhone writes them meanwhile") == true)
        // Used up in Remote only: nothing else writes, and the note says that instead.
        let waits = Copy.Settings.TranscriptionAI.applePrivateCloudNote(
            mode: .remoteOnly, readiness: .ready, quota: .usedUp(resetsAt: nil))
        #expect(waits?.contains("wait until") == true)
        // The build fact, plainly.
        let build = Copy.Settings.TranscriptionAI.applePrivateCloudNote(
            mode: .remoteOnly, readiness: .notEnabledForThisBuild, quota: .fine)
        #expect(build?.contains("This build of the app isn't enabled") == true)
        #expect(build?.contains("!") == false)
    }

    @Test("the reset phrase is relative to today")
    func resetPhrase() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 10))!
        let later = calendar.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 15))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 9))!
        let nextWeek = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 9))!
        #expect(
            Copy.Settings.TranscriptionAI.resetPhrase(later, now: now, calendar: calendar)
                .hasPrefix("at "))
        #expect(
            Copy.Settings.TranscriptionAI.resetPhrase(tomorrow, now: now, calendar: calendar)
                .hasPrefix("tomorrow at "))
        #expect(
            Copy.Settings.TranscriptionAI.resetPhrase(nextWeek, now: now, calendar: calendar)
                .hasPrefix("on "))
    }

    /// The Local-first sentence names where text actually goes.
    @Test("the on-device note names the configured remote provider")
    func onDeviceNoteNamesTheRemote() {
        let openAi = Copy.Settings.TranscriptionAI.onDeviceAiNote(
            mode: .localFirst, readiness: .switchedOff)
        #expect(openAi?.contains("OpenAI") == true)
        let apple = Copy.Settings.TranscriptionAI.onDeviceAiNote(
            mode: .localFirst, readiness: .switchedOff,
            remoteName: Copy.Privacy.applePrivateCloud)
        #expect(apple?.contains("Apple Private Cloud Compute") == true)
        #expect(apple?.contains("OpenAI") == false)
    }

    /// The OS comes before the build, and the build before the framework: on iOS 26 the row
    /// says "needs iOS 27" whatever the signature says; on iOS 27 this unentitled test bundle
    /// is told about the build, and the framework is never asked.
    @Test("readiness is the OS first, then the build, then the framework")
    func readinessOrder() {
        if #available(iOS 27.0, *) {
            #expect(ApplePrivateCloudReadiness.current == .notEnabledForThisBuild)
        } else {
            #expect(ApplePrivateCloudReadiness.current == .unsupportedOs)
        }
        #expect(ApplePrivateCloudReadiness.quota == .unknown)
        #expect(!ApplePrivateCloudReadiness.canRequestMore)
    }
}
