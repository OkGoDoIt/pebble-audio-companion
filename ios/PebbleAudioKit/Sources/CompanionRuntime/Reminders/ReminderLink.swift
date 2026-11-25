import Foundation

/// The links between a reminder in the app and its copy in Apple Reminders.
public enum ReminderLink {
    /// What a reminder in Apple Reminders carries back: the app's own deep link to that reminder.
    public static func url(followUpId: String) -> URL? {
        var components = URLComponents()
        components.scheme = "companion"
        components.host = "followup"
        components.path = "/" + followUpId
        return components.url
    }

    /// The follow-up a reminder's link names; nil when it isn't one of ours. Reminders made
    /// before 2026-11-25 say `companion://followup?id=…`.
    public static func followUpId(in url: URL?) -> String? {
        guard let url, url.scheme == "companion", url.host == "followup" else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        if path.count == 1 { return path[0] }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value
    }

    /// Opens one reminder's details in the Reminders app. `appleId` is EventKit's
    /// `calendarItemIdentifier`. The scheme is Reminders' own and undocumented.
    public static func inReminders(appleId: String) -> URL? {
        URL(string: "x-apple-reminderkit://REMCDReminder/\(appleId)/details")
    }
}
