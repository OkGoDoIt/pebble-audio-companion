import CompanionRuntime
import Foundation
import Intelligence
import Testing
import Transcription

// A refused account: what the card and the notification say, when the notification fires, where
// the fix is, and what can stand in. The notification center is faked; nothing is posted.

private final class FakePoster: CloudAccountNotificationPosting, @unchecked Sendable {
    var authorized = true
    var posted: [(id: String, title: String, body: String, route: Route)] = []
    var withdrawn: [String] = []
    func isAuthorized() async -> Bool { authorized }
    func post(identifier: String, title: String, body: String, route: Route) async {
        posted.append((identifier, title, body, route))
    }
    func withdraw(identifier: String) async { withdrawn.append(identifier) }
}

private final class Clock: @unchecked Sendable { var now: Int64 = 1_800_000_000_000 }

@Suite("cloud account alert", .serialized) @MainActor
struct CloudAccountAlertTests {
    private func issue(
        _ provider: CloudProvider = .soniox, kind: TranscriptionFailureKind = .accountOutOfFunds,
        since: Int64 = 1, transcription: CloudAccountIssue.StandIn? = .onDevice,
        fallbackOnly: Bool = false, ai: CloudAccountIssue.StandIn? = nil
    ) -> CloudAccountIssue {
        CloudAccountIssue(
            provider: provider, kind: kind, sinceMs: since, transcription: transcription,
            transcriptionIsFallbackOnly: fallbackOnly, ai: ai)
    }

    private func makeNotifier(_ poster: FakePoster, _ clock: Clock) -> CloudAccountNotifier {
        CloudAccountNotifier(
            poster: poster, defaultsSuite: "cloud-account-\(UUID().uuidString)",
            nowMs: { clock.now })
    }

    // MARK: - The notification

    @Test func itIsSentOncePerOutageAndTakenBackWhenTheAccountWorks() async {
        let poster = FakePoster()
        let clock = Clock()
        let notifier = makeNotifier(poster, clock)
        await notifier.accountsChanged([issue()])
        await notifier.accountsChanged([issue()])
        #expect(poster.posted.count == 1)
        #expect(poster.posted.first?.title == "Soniox is out of credit")
        #expect(poster.posted.first?.body
                == "This iPhone is transcribing. Soniox will redo these recordings when it works again.")
        #expect(poster.posted.first?.route == .today(date: nil))
        poster.withdrawn = []
        await notifier.accountsChanged([])
        #expect(poster.withdrawn.contains("cloud-account-Soniox"))
    }

    @Test func aBalanceThatFlapsIsNotNewsEveryTime() async {
        let poster = FakePoster()
        let clock = Clock()
        let notifier = makeNotifier(poster, clock)
        await notifier.accountsChanged([issue(since: 1)])
        await notifier.accountsChanged([])
        clock.now += 3_600_000
        await notifier.accountsChanged([issue(since: 2)])
        #expect(poster.posted.count == 1)
        clock.now += CloudAccountNotifier.quietMs
        await notifier.accountsChanged([issue(since: 2)])
        #expect(poster.posted.count == 2)
    }

    @Test func withoutPermissionNothingIsSentAndItIsStillNewsLater() async {
        let poster = FakePoster()
        poster.authorized = false
        let notifier = makeNotifier(poster, Clock())
        await notifier.accountsChanged([issue()])
        #expect(poster.posted.isEmpty)
        poster.authorized = true
        await notifier.accountsChanged([issue()])
        #expect(poster.posted.count == 1)
    }

    // MARK: - What it says

    @Test func theLineNamesWhatIsDoingTheWork() {
        #expect(Copy.CloudAccount.line(issue(transcription: .waiting)) == "New recordings are waiting to be transcribed.")
        #expect(Copy.CloudAccount.line(issue(transcription: .provider(.openAi))) == "OpenAI is transcribing new recordings.")
        #expect(Copy.CloudAccount.line(issue(fallbackOnly: true)) == "Recordings this iPhone can’t finish are waiting.")
        #expect(
            Copy.CloudAccount.line(issue(.openAi, transcription: nil, ai: .onDevice))
                == "This iPhone is writing summaries and answers.")
        #expect(
            Copy.CloudAccount.line(issue(.openAi, ai: .onDevice))
                == "This iPhone is transcribing and writing summaries.")
        #expect(
            Copy.CloudAccount.line(issue(.openAi, transcription: .provider(.soniox), ai: .waiting))
                == "Soniox is transcribing new recordings. New summaries and answers are waiting.")
    }

    @Test func sinceReadsAsATimeADayOrADate() {
        let zone = TimeZone(identifier: "America/New_York")!
        // Wednesday, October 21, 2026, 10:00 AM in New York.
        let now: Int64 = 1_792_591_200_000
        let day: Int64 = 86_400_000
        #expect(Copy.CloudAccount.since(now - 2 * day, nowMs: now, timeZone: zone) == "since Monday")
        #expect(Copy.CloudAccount.since(now - 20 * day, nowMs: now, timeZone: zone) == "since October 1")
        #expect(Copy.CloudAccount.since(now - 3_600_000, nowMs: now, timeZone: zone).hasPrefix("since 9:00"))
    }

    @Test func theFixIsWhereTheProblemIs() {
        #expect(
            CloudProvider.soniox.accountPage(for: .accountOutOfFunds).absoluteString
                == "https://console.soniox.com/org/billing/overview/")
        #expect(
            CloudProvider.openAi.accountPage(for: .accountOutOfFunds).absoluteString
                == "https://platform.openai.com/settings/organization/billing/overview")
        #expect(CloudProvider.soniox.accountPage(for: .spendingLimitReached).path.contains("limits"))
        #expect(issue(kind: .keyRejected).isAboutTheKey)
        #expect(!issue().isAboutTheKey)
    }

    // MARK: - What can stand in

    @Test func aBackupThatCannotWorkIsShownWithItsReasonAndCannotBeChosen() {
        func options(
            _ mode: TranscriptionMode, ready: Bool = true, key: Bool = true, held: String? = nil
        ) -> [CloudAccountBackupOption<TranscriptionBackup>] {
            CloudAccountBackupOptions.transcription(
                main: .soniox, mode: mode, onDeviceReady: ready, hasKey: { _ in key },
                heldReason: { _ in held })
        }
        #expect(options(.remoteFirst).map(\.value) == [.onDevice, .openAi])
        #expect(options(.remoteOnly).map(\.value) == [.none, .onDevice, .openAi])
        #expect(options(.remoteFirst, ready: false).first?.isEnabled == false)
        let keyless = options(.remoteFirst, key: false).last
        #expect(keyless?.needsKey == .openAi)
        #expect(keyless?.isEnabled == true)
        let broke = options(.remoteFirst, held: "out of credit").last
        #expect(broke?.detail == "Out of credit")
        #expect(broke?.isEnabled == false)
        #expect(CloudAccountBackupOptions.shown(.none, main: .soniox, mode: .remoteFirst) == .onDevice)
        #expect(CloudAccountBackupOptions.shown(.none, main: .soniox, mode: .remoteOnly) == .none)
        #expect(
            CloudAccountBackupOptions.ai(
                mode: .remoteFirst, onDevice: .ready, applePrivateCloud: .notEnabledForThisBuild
            ).map(\.value) == [.onDevice])
    }

    // MARK: - Privacy

    /// A backup service is sent to without asking again, so it is a destination in its own right.
    @Test func aBackupServiceIsOnThePrivacyScreen() {
        var inputs = PrivacyInputs()
        inputs.transcriptionDestination = "Soniox"
        inputs.transcriptionBackup = "OpenAI"
        let alone = PrivacyModel.derive(inputs, nowMs: 0)
        #expect(alone.destinations.map(\.name) == ["Soniox", "OpenAI"])
        #expect(alone.destinations.last?.why == "Transcribes if Soniox stops")
        #expect(PrivacyModel.vendors(inputs).contains("OpenAI"))
        inputs.aiDestination = "OpenAI"
        let merged = PrivacyModel.derive(inputs, nowMs: 0)
        #expect(merged.destinations.map(\.name) == ["Soniox", "OpenAI"])
        #expect(merged.destinations.last?.why == "Writes summaries, and transcribes if Soniox stops")
        #expect(merged.destinations.last?.chips.map(\.label) == ["Audio", "Text"])
    }

    @Test func aBackupKeyHasARowUnlessThatKeyIsAlreadyShown() {
        var plan = TranscriptionAiRowPlan(
            transcriptionMode: .remoteFirst, aiMode: .localOnly,
            cloudTranscriptionProvider: .soniox)
        #expect(plan.backupKey == nil)
        plan.transcriptionBackup = .openAi
        #expect(plan.backupKey == .openAi)
        #expect(plan.providersInUse.contains(.openAi))
        plan.aiMode = .remoteFirst
        #expect(plan.backupKey == nil)
    }
}
