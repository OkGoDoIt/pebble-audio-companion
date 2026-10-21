import Foundation

// The recap-ready notification and its Settings switch. The switch sits under "Alert me about
// missed audio" and is built the same way: a title and one short line.

extension Copy {
    enum RecapNotification {
        /// "Tuesday's recap"
        static func title(weekday: String) -> String { "\(weekday)’s recap" }

        static let settingTitle = "Notify me when my recap is ready"
        static let settingSub = "Once a day, after the day ends."
    }
}
