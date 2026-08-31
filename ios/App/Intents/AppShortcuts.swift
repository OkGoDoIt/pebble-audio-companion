import AppIntents

/// The phrases Siri and the Shortcuts app offer without any setup. Every phrase must contain
/// `\(.applicationName)`, so they read naturally against the app's display name ("Pebble
/// Audio"): "Pause Pebble Audio", "Resume capture in Pebble Audio".
struct CompanionAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseCaptureIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause capture in \(.applicationName)",
                "Stop recording with \(.applicationName)",
            ],
            shortTitle: "Pause Capture",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeCaptureIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume capture in \(.applicationName)",
                "Start recording with \(.applicationName)",
            ],
            shortTitle: "Resume Capture",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: AskCompanionIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Search my recordings in \(.applicationName)",
            ],
            shortTitle: "Ask",
            systemImageName: "sparkle.magnifyingglass"
        )
    }
}
