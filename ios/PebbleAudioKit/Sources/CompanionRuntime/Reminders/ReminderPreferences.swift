import Foundation
import Receiver

/// Where reminders are kept (`docs/reminders.md`): always exactly one home.
public enum ReminderHome: String, Equatable, Sendable, CaseIterable {
    /// In the app, the way follow-ups always were. The default.
    case app
    /// In Apple Reminders, in `ReminderPreferences.appleListId`.
    case apple
}

/// The person's choices about reminders: Settings › Reminders.
public struct ReminderPreferences: Equatable, Sendable {
    public var home: ReminderHome = .app
    /// The Apple Reminders list NEW reminders go to while the home is Apple Reminders.
    public var appleListId: String?
    /// An alert on a reminder's due date, at `dueAlertMinutes` past midnight.
    public var dueAlerts = true
    public var dueAlertMinutes = 9 * 60
    /// One notification in the evening when there is something to review or something was added.
    public var eveningReview = false
    public var eveningReviewMinutes = 20 * 60

    public init() {}
}

/// `ReminderPreferences`, kept in the app's own defaults and published as they change.
public final class ReminderPreferencesStore: @unchecked Sendable {
    public let current: StateSubject<ReminderPreferences>
    private let defaults: UserDefaults
    private let lock = NSLock()

    private enum Key {
        static let home = "reminders.home"
        static let appleListId = "reminders.appleListId"
        static let dueAlerts = "reminders.dueAlerts"
        static let dueAlertMinutes = "reminders.dueAlertMinutes"
        static let eveningReview = "reminders.eveningReview"
        static let eveningReviewMinutes = "reminders.eveningReviewMinutes"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = StateSubject(Self.load(defaults))
    }

    public func update(_ change: (inout ReminderPreferences) -> Void) {
        let next: ReminderPreferences? = lock.withLock {
            var value = current.value
            change(&value)
            guard value != current.value else { return nil }
            defaults.set(value.home.rawValue, forKey: Key.home)
            defaults.set(value.appleListId, forKey: Key.appleListId)
            defaults.set(value.dueAlerts, forKey: Key.dueAlerts)
            defaults.set(value.dueAlertMinutes, forKey: Key.dueAlertMinutes)
            defaults.set(value.eveningReview, forKey: Key.eveningReview)
            defaults.set(value.eveningReviewMinutes, forKey: Key.eveningReviewMinutes)
            return value
        }
        // Nothing changed, nothing published: an observer never hears its own no-op.
        if let next { current.value = next }
    }

    private static func load(_ defaults: UserDefaults) -> ReminderPreferences {
        var value = ReminderPreferences()
        if let home = defaults.string(forKey: Key.home).flatMap(ReminderHome.init(rawValue:)) {
            value.home = home
        }
        value.appleListId = defaults.string(forKey: Key.appleListId)
        if defaults.object(forKey: Key.dueAlerts) != nil {
            value.dueAlerts = defaults.bool(forKey: Key.dueAlerts)
        }
        if defaults.object(forKey: Key.dueAlertMinutes) != nil {
            value.dueAlertMinutes = defaults.integer(forKey: Key.dueAlertMinutes)
        }
        value.eveningReview = defaults.bool(forKey: Key.eveningReview)
        if defaults.object(forKey: Key.eveningReviewMinutes) != nil {
            value.eveningReviewMinutes = defaults.integer(forKey: Key.eveningReviewMinutes)
        }
        return value
    }
}
