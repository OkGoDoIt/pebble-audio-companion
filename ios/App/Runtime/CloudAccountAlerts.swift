import CompanionRuntime
import Foundation
import Observation
import Transcription
import UIKit
import UserNotifications

// The news that a cloud account has stopped taking work, for every screen that shows it, and the
// one notification per outage.
//
// Told, never polling: `CloudAccountHold.onChanged`, a settings or key change, and coming to the
// foreground. Content-gated: a refresh that finds the same thing publishes nothing.

@MainActor
@Observable
final class CloudAccountAlerts {
    static let shared = CloudAccountAlerts()

    private(set) var issues: [CloudAccountIssue] = []
    /// Accounts being asked right now, because the person just came back from fixing one.
    private(set) var checking: Set<CloudProvider> = []

    @ObservationIgnored private var resolve: (() async -> [CloudAccountIssue])?
    @ObservationIgnored private var recheckAccount:
        ((CloudProvider) async -> CloudAccountProbeOutcome?)?
    @ObservationIgnored private var notifier: CloudAccountNotifier?
    @ObservationIgnored private var visited: CloudProvider?
    @ObservationIgnored private var watchesForeground = false

    init(issues: [CloudAccountIssue] = []) { self.issues = issues }

    func install(
        resolve: @escaping () async -> [CloudAccountIssue],
        recheckAccount: @escaping (CloudProvider) async -> CloudAccountProbeOutcome?,
        notifier: CloudAccountNotifier?
    ) {
        self.resolve = resolve
        self.recheckAccount = recheckAccount
        self.notifier = notifier
        guard !watchesForeground else { return }
        watchesForeground = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                await CloudAccountAlerts.shared.refresh()
                await CloudAccountAlerts.shared.returnedToApp()
            }
        }
    }

    func refresh() async {
        guard let resolve else { return }
        let found = await resolve()
        if found != issues { issues = found }
        // Every time, not only on a change: an outage found while notifications were off is
        // still news the first time they are on. The notifier says each one once.
        await notifier?.accountsChanged(found)
    }

    // MARK: Fixing it

    /// The person is leaving for the provider's site (or the key screen).
    func wentToFix(_ provider: CloudProvider) { visited = provider }

    /// Back in the app: ask the account they went to fix, now, and say what it answered.
    func returnedToApp() async {
        guard let provider = visited else { return }
        visited = nil
        await recheck(provider)
    }

    func recheck(_ provider: CloudProvider) async {
        guard let recheckAccount, !checking.contains(provider),
            issues.contains(where: { $0.provider == provider })
        else { return }
        checking.insert(provider)
        let outcome = await recheckAccount(provider)
        checking.remove(provider)
        await refresh()
        let name = provider.displayName
        let message: String
        switch outcome {
        case .accepted: message = Copy.CloudAccount.worksAgain(name)
        case .refused(let kind): message = Copy.CloudAccount.stillRefused(kind, provider: name)
        case .inconclusive: message = Copy.CloudAccount.couldNotCheck(name)
        // Not held any more: something else (an upload, the pipeline's own check) got there first.
        case nil: message = Copy.CloudAccount.worksAgain(name)
        }
        UndoCenter.shared.snackbar = SnackbarItem(message: message)
    }
}

// MARK: - The notification

protocol CloudAccountNotificationPosting: Sendable {
    /// Whether iOS will show it. Never asks: nobody asked for this alert, so it must not be what
    /// raises the permission prompt.
    func isAuthorized() async -> Bool
    func post(identifier: String, title: String, body: String, route: Route) async
    func withdraw(identifier: String) async
}

struct SystemCloudAccountNotificationPoster: CloudAccountNotificationPosting {
    func isAuthorized() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied, .notDetermined: return false
        @unknown default: return false
        }
    }

    func post(identifier: String, title: String, body: String, route: Route) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [UserNotificationLossNotifier.routeUserInfoKey: route.url.absoluteString]
        content.interruptionLevel = .active
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    func withdraw(identifier: String) async {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

/// Once per outage, and never again for the same account within `quietMs`: a balance that is
/// topped up by a few cents and runs out again is not news every hour. Taken back when the
/// account works, so nobody is sent to fix what is already fixed.
actor CloudAccountNotifier {
    static let quietMs: Int64 = 12 * 60 * 60_000
    private static let toldKey = "cloud_account_notified"

    private let poster: any CloudAccountNotificationPosting
    private let defaults: UserDefaults
    private let nowMs: @Sendable () -> Int64
    private var showing: Set<CloudProvider> = Set(CloudProvider.allCases)

    init(
        poster: any CloudAccountNotificationPosting = SystemCloudAccountNotificationPoster(),
        defaultsSuite: String? = nil,
        nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.poster = poster
        self.defaults = defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.nowMs = nowMs
    }

    private static func identifier(_ provider: CloudProvider) -> String {
        "cloud-account-\(provider.rawValue)"
    }

    func accountsChanged(_ issues: [CloudAccountIssue]) async {
        for provider in CloudProvider.allCases {
            guard let issue = issues.first(where: { $0.provider == provider }) else {
                if showing.remove(provider) != nil {
                    await poster.withdraw(identifier: Self.identifier(provider))
                }
                continue
            }
            await tell(issue)
        }
    }

    private func tell(_ issue: CloudAccountIssue) async {
        var told = defaults.dictionary(forKey: Self.toldKey) ?? [:]
        let previous = told[issue.provider.rawValue] as? [String: Any]
        if previous?["id"] as? String == issue.id { return }
        if let at = (previous?["at"] as? NSNumber)?.int64Value, nowMs() >= at,
            nowMs() - at < Self.quietMs
        {
            return
        }
        guard await poster.isAuthorized() else { return }
        // Written before posting: two refreshes racing must not both post.
        told[issue.provider.rawValue] = ["id": issue.id, "at": NSNumber(value: nowMs())]
        defaults.set(told, forKey: Self.toldKey)
        showing.insert(issue.provider)
        await poster.post(
            identifier: Self.identifier(issue.provider),
            title: Copy.CloudAccount.headline(issue.kind, provider: issue.provider.displayName),
            body: Copy.CloudAccount.line(issue), route: .today(date: nil))
        AppRuntimeLog.shared.record(
            "account notification · \(issue.provider.rawValue) \(issue.kind.rawValue)")
    }
}

// MARK: - Review states

#if DEBUG
    /// `-accountDemo <state>` with `-demo-data`: each state of the card, for screenshots.
    @MainActor
    enum CloudAccountDemo {
        static var state: String? {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "-accountDemo"), index + 1 < args.count
            else { return nil }
            return args[index + 1]
        }

        static func apply(to settings: AppSettings) {
            guard let state else { return }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let threeDays = nowMs - 3 * 86_400_000
            var issues: [CloudAccountIssue] = []
            settings.transcriptsConfigured = true
            settings.cloudTranscriptionProvider = .soniox
            settings.transcriptionMode = .remoteFirst
            settings.aiMode = .remoteFirst
            settings.remoteAiProvider = .openAi
            settings.transcriptionBackup = .none
            settings.aiBackup = .none
            switch state {
            case "soniox":
                issues = [.init(provider: .soniox, kind: .accountOutOfFunds, sinceMs: threeDays, transcription: .onDevice)]
            case "sonioxWaiting":
                settings.transcriptionMode = .remoteOnly
                issues = [.init(provider: .soniox, kind: .accountOutOfFunds, sinceMs: nowMs - 3_600_000, transcription: .waiting)]
            case "sonioxOpenAi":
                settings.transcriptionBackup = .openAi
                issues = [.init(provider: .soniox, kind: .accountOutOfFunds, sinceMs: threeDays, transcription: .provider(.openAi))]
            case "openAi":
                issues = [.init(provider: .openAi, kind: .accountOutOfFunds, sinceMs: threeDays, ai: .onDevice)]
            case "both":
                settings.cloudTranscriptionProvider = .openAi
                issues = [.init(provider: .openAi, kind: .accountOutOfFunds, sinceMs: threeDays, transcription: .onDevice, ai: .onDevice)]
            case "two":
                issues = [
                    .init(provider: .soniox, kind: .accountOutOfFunds, sinceMs: threeDays, transcription: .onDevice),
                    .init(provider: .openAi, kind: .spendingLimitReached, sinceMs: nowMs - 3_600_000, ai: .onDevice),
                ]
            case "key":
                issues = [.init(provider: .soniox, kind: .keyRejected, sinceMs: threeDays, transcription: .onDevice)]
            case "back":
                (SettingsDataSources.current.processing as? MockProcessingModeSource)?.toTranscribeAgain = 180
            default: break
            }
            CloudAccountAlerts.shared.install(
                resolve: { issues },
                recheckAccount: { _ in
                    try? await Task.sleep(for: .seconds(2))
                    return .refused(.accountOutOfFunds)
                },
                notifier: nil)
            Task { await CloudAccountAlerts.shared.refresh() }
        }
    }
#endif
