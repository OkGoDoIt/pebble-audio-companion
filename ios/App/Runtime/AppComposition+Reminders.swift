import AppDB
import CompanionRuntime
import Foundation
import UIKit

/// Where reminders are kept, built from the running composition (`docs/reminders.md`): Settings
/// › Reminders and the review read and change it, and it keeps Apple Reminders in step while that
/// is the home.
@MainActor
enum RemindersComposition {
    private static var made: RemindersHome?
    private static var foregroundObserver: NSObjectProtocol?

    /// The person's choices: the home, the Apple list, alerts, and the evening review.
    static let preferences = ReminderPreferencesStore()

    static var home: RemindersHome? {
        if let made { return made }
        guard let composition = AppComposition.shared else { return nil }
        let home = RemindersHome(
            followUps: composition.followUps, apple: EventKitReminders(),
            alerts: NotificationCenterAlerts(), preferences: preferences,
            log: { AppRuntimeLog.shared.record($0) })
        made = home
        return home
    }

    /// Starts following the follow-ups and Apple Reminders. Called once the composition is
    /// installed.
    static func start() {
        guard foregroundObserver == nil, let composition = AppComposition.shared, let home else {
            return
        }
        let database = composition.database
        Task { await home.start(database: database) }
        // Back on screen: whatever changed in Reminders while away is taken in.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { await home.sync() }
        }
    }
}
