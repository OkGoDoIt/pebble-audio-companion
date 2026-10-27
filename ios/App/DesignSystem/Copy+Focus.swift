import Foundation

extension Copy {
    enum Focus {
        static let title = "Quiet Time"
        static let toggle = "Follow iPhone Focus"
        static let setup = "How to set up"
        static let steps = [
            "Open Settings → Focus on your iPhone.",
            "Choose Do Not Disturb or another Focus.",
            "Tap Add Filter → Pebble Audio, turn Quiet Time on, and tap Add.",
        ]
        static let footer = "While connected, your watch follows the Focus filters you add."
        static let recording = "Quiet Time silences watch notifications. Recording stays as you set it."
        static func status(_ status: FocusQuietTimeController.Status) -> String {
            switch status {
            case .off: "Off"
            case .checking: "Checking Focus"
            case .waitingForWatch: "Waiting for your watch"
            case .needsFirmware: "Watch update needed"
            case .syncing: "Updating your watch"
            case .following: "Following Focus"
            case .ready: "Ready for a Focus"
            case .retry: "Waiting to sync"
            }
        }
        static func detail(_ status: FocusQuietTimeController.Status) -> String? {
            switch status {
            case .needsFirmware: "Install watch firmware that supports Focus."
            case .checking: "Open the app again if Focus doesn’t update."
            case .retry: "The watch hasn’t confirmed this change yet."
            default: nil
            }
        }
    }
}
