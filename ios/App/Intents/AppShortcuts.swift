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
        // "Ask Pebble Audio …" is answered by Siri (Roger, 2026-10-21): a spoken answer and a
        // card, and the app opens only on a tap or when the answer runs past Siri's wait. The
        // question itself cannot be part of a phrase (only entities and enums can), so Siri asks
        // for it; the period can.
        AppShortcut(
            intent: AskArchiveIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) about \(\.$period)",
                "Ask my archive in \(.applicationName)",
                "Ask my conversations in \(.applicationName)",
            ],
            shortTitle: "Ask My Archive",
            systemImageName: "text.bubble"
        )
        // Opening the Ask screen itself stays one phrase away, worded as an open.
        AppShortcut(
            intent: AskCompanionIntent(),
            phrases: [
                "Open Ask in \(.applicationName)",
                "Show Ask in \(.applicationName)",
            ],
            shortTitle: "Open Ask",
            systemImageName: "sparkle.magnifyingglass"
        )
        AppShortcut(
            intent: OpenFollowUpsIntent(),
            phrases: [
                "Open follow-ups in \(.applicationName)",
                "Open my follow-ups in \(.applicationName)",
                "Show my follow-ups in \(.applicationName)",
            ],
            shortTitle: "Follow-ups",
            systemImageName: "checklist"
        )
        // The iOS 27 additions. `#available` is the one condition the builder accepts, and
        // the entries above work the same on iOS 26.
        if #available(iOS 27, *) {
            AppShortcut(
                intent: SearchInAppIntent(),
                phrases: [
                    "Search \(.applicationName)",
                    "Find a recording in \(.applicationName)",
                    "Search for a conversation in \(.applicationName)",
                    // Moved here from Open Ask, which it never described: it opened Ask.
                    "Search my recordings in \(.applicationName)",
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
