import AppDB
import Foundation

/// How a follow-up describes itself in one line.
///
/// The rule throughout: say the most useful true thing, and say nothing rather than something
/// generic. A row whose second line reads "Follow-up" on every item is a row with no second
/// line — it costs a line of screen and returns nothing — so the meta line is nil unless there
/// is a date, a snooze, or a recording worth naming.
enum FollowUpFormatting {
    struct Meta: Equatable {
        let text: String
        /// Overdue or due today: the one case that gets the amber treatment. Everything else
        /// stays quiet, because a list where every row shouts has no signal in it.
        let isUrgent: Bool
    }

    static func metaLine(_ item: FollowUpItem, now: Date) -> Meta? {
        if item.done {
            guard let completed = item.completedAtMs else { return nil }
            return Meta(
                text: Copy.FollowUps.completedOn(
                    relative(Date(timeIntervalSince1970: Double(completed) / 1000), now: now)),
                isUrgent: false)
        }
        if item.isArchived, let archived = item.archivedAtMs {
            return Meta(
                text: Copy.FollowUps.filedAwayOn(
                    relative(Date(timeIntervalSince1970: Double(archived) / 1000), now: now)),
                isUrgent: false)
        }
        if let snoozed = item.snoozedUntil, snoozed > now {
            return Meta(text: Copy.FollowUps.snoozedUntil(day(snoozed, now: now)), isUrgent: false)
        }
        if let due = item.dueDate {
            return dueMeta(due, now: now)
        }
        if let title = item.sourceConversationTitle {
            return Meta(text: title, isUrgent: false)
        }
        return nil
    }

    /// Just the day, for the filed-away summary at the foot of the open list. The section head
    /// already says "Filed away", so the row says only WHEN — repeating the words on every line
    /// of a five-line list would be the same noise `metaLine` exists to avoid. Nil when the row
    /// is not filed away at all, so a caller cannot label one that isn't.
    static func filedAwayDay(_ item: FollowUpItem, now: Date) -> String? {
        guard let archivedAtMs = item.archivedAtMs else { return nil }
        return day(Date(timeIntervalSince1970: Double(archivedAtMs) / 1000), now: now)
    }

    static func dueMeta(_ due: Date, now: Date) -> Meta {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let dueDay = calendar.startOfDay(for: due)
        if dueDay < startOfToday {
            let days = calendar.dateComponents([.day], from: dueDay, to: startOfToday).day ?? 0
            let phrase = days <= 1 ? "1 day" : "\(days) days"
            return Meta(text: Copy.FollowUps.overdueBy(phrase), isUrgent: true)
        }
        if dueDay == startOfToday {
            return Meta(text: Copy.FollowUps.dueToday, isUrgent: true)
        }
        return Meta(text: Copy.FollowUps.dueOn(day(due, now: now)), isUrgent: false)
    }

    /// "tomorrow" / "Friday" / "12 Sept" — a weekday for the coming week, a date after that.
    /// Nobody reads "2026-09-12" as a day of their life.
    static func day(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfToday, to: target).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...6:
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: date)
        default:
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate(
                calendar.isDate(date, equalTo: now, toGranularity: .year) ? "dMMM" : "dMMMyyyy")
            return formatter.string(from: date)
        }
    }

    /// "just now" / "2 hr ago" / "Friday" — for something that already happened.
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 6 * 3600 { return "\(Int(seconds / 3600)) hr ago" }
        return day(date, now: now)
    }

    /// The detail screen's provenance line: "Heard Friday at 4:12 PM".
    ///
    /// `timeStyle`, not a "jmm" template: the template renders "10:21PM" with no space, which
    /// reads as a typo in the middle of an otherwise plain sentence.
    static func heardAt(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(day(date, now: now)) at \(formatter.string(from: date))"
    }

    static func priorityLabel(_ priority: FollowUpPriority) -> String {
        switch priority {
        case .high: return Copy.FollowUps.priorityHigh
        case .normal: return Copy.FollowUps.priorityNormal
        case .low: return Copy.FollowUps.priorityLow
        }
    }
}
