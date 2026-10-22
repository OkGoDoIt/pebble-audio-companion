import Foundation
import UserNotifications

/// Local notifications for reminders kept in the app: the due-date alerts and the evening review.
/// `NotificationCenterAlerts` is the real one; tests use a fake.
public protocol ReminderAlertScheduling: Sendable {
    /// Ids of the pending notifications whose id starts with `prefix`.
    func pending(prefix: String) async -> Set<String>
    func schedule(id: String, title: String, body: String, at date: Date, route: String) async
    func remove(ids: [String]) async
    /// Whether notifications may be shown, without asking.
    func allowed() async -> Bool
    /// Asks iOS, once. Only in answer to something the person did.
    func requestPermission() async -> Bool
}

/// The key a reminders notification carries in `userInfo`, naming where a tap opens:
/// `reminders` (the list), `review` (the follow-ups to review), or `summary` (what today added,
/// when nothing is left to review).
public let reminderNotificationRouteKey = "reminders.route"

public struct NotificationCenterAlerts: ReminderAlertScheduling {
    public init() {}

    public func pending(prefix: String) async -> Set<String> {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return Set(requests.map(\.identifier).filter { $0.hasPrefix(prefix) })
    }

    public func schedule(id: String, title: String, body: String, at date: Date, route: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [reminderNotificationRouteKey: route]
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    public func remove(ids: [String]) async {
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    public func allowed() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    public func requestPermission() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return await allowed() }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge])) ?? false
    }
}
