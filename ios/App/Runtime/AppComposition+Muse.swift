import CompanionRuntime
import Foundation
import Receiver
import SwiftUI
import UIKit

/// The Muse gadget, built from the running composition. Pairing and typed questions are things a
/// person starts on the Muse screen; push-to-talk listens from launch, because a question can
/// come from the watch at any time. Listening costs nothing: nothing reaches Meta until a button
/// is held (docs/privacy-model.md, D7).
@MainActor
enum MuseComposition {
    private static var made: MuseGadgetService?
    private static var pushToTalk: MusePushToTalk?

    /// The person's Muse choices: watch actions, what Muse can see, where questions go, the
    /// voice level.
    static let preferences = MusePreferencesStore()
    /// The phone's Calendar and Reminders, shared by the tools and the Muse screen's permission
    /// rows.
    static let eventKit = MuseEventKitSource()

    static var service: MuseGadgetService? {
        if let made { return made }
        guard let composition = AppComposition.shared else { return nil }
        let service = MuseGadgetService(
            link: composition.receiver,
            log: { AppRuntimeLog.shared.record("muse  \($0)") }
        )
        made = service
        return service
    }

    /// What the last question from the watch was heard as, for the Muse screen.
    static var lastQuestion: StateSubject<MusePushToTalk.QuestionReport?>? { pushToTalk?.lastQuestion }

    /// The voice level check (Diagnostics), and starting or cancelling one.
    static var levelCheck: StateSubject<MusePushToTalk.LevelCheck?>? { pushToTalk?.levelCheck }
    static func armLevelCheck() {
        guard let pushToTalk else { return }
        Task { await pushToTalk.armLevelCheck() }
    }
    static func cancelLevelCheck() {
        guard let pushToTalk else { return }
        Task { await pushToTalk.cancelLevelCheck() }
    }

    /// Starts answering questions asked on the watch. Called once the composition is installed.
    static func startPushToTalk() {
        guard pushToTalk == nil, let composition = AppComposition.shared, let service else { return }
        installPrivacyHooks()
        // A question can wake a suspended app; this keeps it running until the answer is out.
        let awake = BackgroundActivityAssertion(log: AppRuntimeLog.runtimeLog)
        let pushToTalk = MusePushToTalk(
            link: composition.receiver,
            connector: service,
            preferences: preferences,
            data: AppMuseData(composition: composition),
            eventKit: eventKit,
            keepAwake: { awake.renew() },
            log: { AppRuntimeLog.shared.record("muse  \($0)") }
        )
        self.pushToTalk = pushToTalk
        Task { await pushToTalk.start(paired: service.pairedName) }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { askForPendingPhoneAccess() }
        }
        askForPendingPhoneAccess()
    }

    private static var foregroundObserver: NSObjectProtocol?
    private static var askingPhoneAccess = false

    /// The wearer allowed Calendar or Reminders on the watch while iOS hadn't given the app
    /// access: the first time the app is on screen after that, iOS asks, once per source.
    static func askForPendingPhoneAccess() {
        guard !askingPhoneAccess, UIApplication.shared.applicationState == .active else { return }
        let pending = preferences.current.value.pendingPhoneAccess
        guard !pending.isEmpty else { return }
        askingPhoneAccess = true
        Task { @MainActor in
            for source in MuseSource.allCases where pending.contains(source) {
                // Cleared first: the prompt is shown once, whatever the answer.
                preferences.update { $0.pendingPhoneAccess.remove(source) }
                switch source {
                case .calendar: _ = await eventKit.requestCalendar()
                case .reminders: _ = await eventKit.requestReminders()
                default: break
                }
            }
            askingPhoneAccess = false
        }
    }

    // MARK: - Privacy (docs/privacy-model.md, D7)

    /// What the Privacy screen says about Muse, read from the Muse settings each time it asks,
    /// and where its Meta row leads.
    static func installPrivacyHooks() {
        PrivacyHooks.museState = { museState() }
        PrivacyHooks.museChanges = { museChanges() }
        PrivacyHooks.museScreen = { AnyView(SettingsMuseScreen()) }
    }

    /// A tick for each change to Muse's settings or pairing (each publishes only when it changes).
    static func museChanges() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let settings = preferences.current.stream()
            let paired = service?.pairedName.stream()
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { for await _ in settings { continuation.yield() } }
                    if let paired {
                        group.addTask { for await _ in paired { continuation.yield() } }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Nil until Muse is paired. A source iOS refused can't be read, so it reads as off.
    static func museState() -> PrivacyInputs.MuseState? {
        guard let service, service.isPaired else { return nil }
        let prefs = preferences.current.value
        var sources: [MuseDataSource: MuseAccess] = [:]
        for source in MuseSource.allCases {
            var access = prefs.access(source)
            if source == .calendar, MuseEventKitSource.calendarRefused { access = .off }
            if source == .reminders, MuseEventKitSource.remindersRefused { access = .off }
            sources[privacySource(source)] = privacyAccess(access)
        }
        return PrivacyInputs.MuseState(
            spokenQuestions: MuseGadgetService.asksFromWatch,
            watchActions: Set(prefs.watchActions.map(privacyAction)),
            dataSources: sources)
    }

    static func privacyAction(_ kind: MuseWatchActionKind) -> MuseWatchAction {
        switch kind {
        case .timer: return .timer
        case .alarm: return .alarm
        case .music: return .music
        case .quietTime: return .quietTime
        case .launchApp: return .openApp
        case .findWatch: return .findWatch
        case .recording: return .recording
        }
    }

    static func privacySource(_ source: MuseSource) -> MuseDataSource {
        switch source {
        case .conversations: return .conversations
        case .health: return .health
        case .calendar: return .calendar
        case .reminders: return .reminders
        case .followUps: return .followUps
        }
    }

    static func privacyAccess(_ access: MuseSourceAccess) -> MuseAccess {
        switch access {
        case .ask: return .ask
        case .allowed: return .allowed
        case .off: return .off
        }
    }
}
