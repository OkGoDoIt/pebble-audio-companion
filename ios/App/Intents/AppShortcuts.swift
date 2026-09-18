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
        // The iOS 27 additions. `#available` is the one condition the builder accepts, and
        // the three above stay exactly as they were, so iOS 26 sees the same list it did.
        if #available(iOS 27, *) {
            AppShortcut(
                intent: SearchInAppIntent(),
                phrases: [
                    "Search \(.applicationName)",
                    "Find a recording in \(.applicationName)",
                    "Search for a conversation in \(.applicationName)",
                ],
                shortTitle: "Search",
                systemImageName: "magnifyingglass"
            )
            AppShortcut(
                intent: GetTodaysRecapIntent(),
                phrases: [
                    "What's today's recap in \(.applicationName)",
                    "Today's recap from \(.applicationName)",
                    "Read me today's recap from \(.applicationName)",
                ],
                shortTitle: "Today's Recap",
                systemImageName: "text.book.closed"
            )
            AppShortcut(
                intent: ProcessNowIntent(),
                phrases: [
                    "Catch up now in \(.applicationName)",
                    "Catch up \(.applicationName)",
                    "Process my recordings in \(.applicationName)",
                ],
                shortTitle: "Catch Up Now",
                systemImageName: "arrow.triangle.2.circlepath"
            )
        }
    }
}
