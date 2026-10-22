import Foundation

// Reminders (`docs/reminders.md`, mockup `docs/mockups/reminders/reminders-v4.html`).
//
// Two nouns, never mixed: a **follow-up** is something the app noticed and is asking about; a
// **reminder** is one the person said yes to, or asked for. So the review counts follow-ups
// ("3 follow-ups to review") and the outcome counts reminders ("4 reminders added").
extension Copy {
    enum Reminders {
        static let title = "Reminders"

        // MARK: Entry rows (the Reminders tab and Today)

        static func toReview(_ count: Int) -> String {
            count == 1 ? "1 follow-up to review" : "\(count) follow-ups to review"
        }
        static let review = "Review"
        static func addedFromToday(_ count: Int) -> String {
            count == 1 ? "1 reminder added from today" : "\(count) reminders added from today"
        }
        static let nothingLeftToReview = "Nothing left to review"
        static let openInReminders = "Open in Reminders"

        // MARK: Review

        static let reviewTitle = "Follow-ups"
        static func counter(_ position: Int, of total: Int) -> String { "\(position) of \(total)" }
        static let remindMe = "Remind me"
        static let skip = "Skip"
        static let notNow = "Not Now"
        static let playTheMoment = "Play the moment"
        static let stopPlaying = "Stop"

        // MARK: Summary

        static func added(_ count: Int) -> String {
            switch count {
            case 0: return "No reminders added"
            case 1: return "1 reminder added"
            default: return "\(count) reminders added"
            }
        }
        static let fromToday = "From today’s conversations"
        static let stateReminder = "Reminder"
        static let stateSkipped = "Skipped"
        static let nothingToday = "Nothing from today yet"

        // MARK: A conversation's follow-ups

        /// Title case: it is a button, the way the rest of the app's buttons read.
        static let remindMeButton = "Remind Me"

        // MARK: Accessibility

        static let reminderHint = "Double tap to skip it instead"
        static let skippedHint = "Double tap to make it a reminder"
        static let cardHint = "Swipe right to be reminded, left to skip"

        // MARK: Settings › Reminders

        static let keepIn = "Keep reminders in"
        static let pebbleAudio = "Pebble Audio"
        static let appleReminders = "Apple Reminders"
        static let list = "List"
        /// Beside "Pebble Audio" in the list picker while that list does not exist yet.
        static let newList = "New"
        static let alerts = "Alerts"
        static let alertOnDueDate = "Alert on the due date"
        static let alertTime = "Alert time"
        static let reviewSection = "Review"
        static let eveningReview = "Evening review"
        static let time = "Time"
        static let accessOff = "Reminders access is off"
        static let notificationsOff = "Notifications are off in iOS Settings."

        static func moveTitle(_ count: Int) -> String {
            switch count {
            case 0: return "Keep reminders in Apple Reminders"
            case 1: return "Move 1 open reminder to Apple Reminders"
            default: return "Move \(count) open reminders to Apple Reminders"
            }
        }
        static let move = "Move"

        static func changeListTitle(_ count: Int, to list: String) -> String {
            count == 1
                ? "Move 1 open reminder to \(list)?"
                : "Move \(count) open reminders to \(list)?"
        }
        static let moveThem = "Move Them"
        static let onlyNewOnes = "Only New Ones"

        static func bringBackTitle(_ count: Int) -> String {
            count == 1
                ? "Bring 1 open reminder back to Pebble Audio?"
                : "Bring \(count) open reminders back to Pebble Audio?"
        }
        static let bringThemBack = "Bring Them Back"
    }
}
