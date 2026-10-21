import CompanionRuntime
import UIKit
import UserNotifications

/// Muse's handoffs to the phone, as notifications here: a tap opens what the watch couldn't (the
/// link itself, a place in Maps, or the Muse chat), and the long press offers the rest.
///
/// One at a time: a newer one replaces the last. It makes no sound, since the watch already tapped
/// the wrist. Nothing is posted while the app is on screen, where the answer already shows. The
/// watch firmware drops iOS's copy of these (their titles start with "Muse"), because it showed
/// the answer itself.
final class MuseHandoffNotifier: MusePhoneHandoffPosting {
    static let identifier = "muse.handoff"
    static let categoryPrefix = "muse.handoff."
    static let actionPrefix = "muse.open."
    static let urlKey = "muse.url"
    static let actionURLsKey = "muse.actionURLs"
    /// A handoff was due before notifications were allowed: the next time the app is on screen,
    /// iOS asks (a question asked on the watch is the action that needed it).
    static let permissionPendingKey = "muse.handoffPermissionPending"

    func post(_ handoff: MusePhoneHandoff) async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            UserDefaults.standard.set(true, forKey: Self.permissionPendingKey)
            return false
        case .denied:
            return false
        @unknown default:
            return false
        }
        if await MainActor.run(body: { UIApplication.shared.applicationState == .active }) { return false }

        // Each handoff's buttons name what they open, so each gets a category of its own; the
        // last one's is replaced, never added to.
        let category = Self.categoryPrefix + UUID().uuidString.lowercased()
        let actions = handoff.actions.enumerated().map { index, action in
            UNNotificationAction(identifier: Self.actionPrefix + "\(index)", title: action.title, options: [.foreground])
        }
        var categories = await center.notificationCategories().filter { !$0.identifier.hasPrefix(Self.categoryPrefix) }
        categories.insert(UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: []))
        center.setNotificationCategories(categories)

        let content = UNMutableNotificationContent()
        content.title = handoff.title
        content.body = handoff.body
        content.categoryIdentifier = category
        content.interruptionLevel = .active
        content.userInfo = [
            Self.urlKey: handoff.url.absoluteString,
            Self.actionURLsKey: handoff.actions.map(\.url.absoluteString),
        ]
        do {
            try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    /// What a tap on a handoff opens: the notification's own link, or the button's. Nil for any
    /// other notification.
    static func url(for response: UNNotificationResponse) -> URL? {
        let info = response.notification.request.content.userInfo
        guard let main = info[urlKey] as? String else { return nil }
        if response.actionIdentifier.hasPrefix(actionPrefix),
            let index = Int(response.actionIdentifier.dropFirst(actionPrefix.count)),
            let urls = info[actionURLsKey] as? [String], urls.indices.contains(index)
        {
            return URL(string: urls[index])
        }
        return URL(string: main)
    }

    /// Asks iOS for notifications once, when a handoff found them not yet allowed.
    @MainActor
    static func askIfPending() {
        guard UserDefaults.standard.bool(forKey: permissionPendingKey), UIApplication.shared.applicationState == .active
        else { return }
        UserDefaults.standard.removeObject(forKey: permissionPendingKey)
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }
}
