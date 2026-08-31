import Foundation

// Everything in `ios/Shared/` compiles into BOTH the app and the widget/control extension.
// It must therefore stay dependency-free: Foundation only, no PebbleAudioKit, no database.

/// The App Group both processes share (plan 6.8): it holds the database, the segment files,
/// `coverage_snapshot.json`, and the small defaults the widget/Control Center need.
///
/// Mirrors `AppDB.AppDatabase.appGroupIdentifier` — duplicated as a literal on purpose so the
/// extension does not have to link the kit (and GRDB) just to read a group identifier.
enum SharedAppGroup {
    static let identifier = "group.dev.audiocompanion"

    /// The shared container, or nil when the entitlement is missing (macOS unit-test hosts).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// The shared defaults suite; falls back to `.standard` only when the group is unavailable.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    /// Darwin (cross-process) notification posted when an App Intent changes capture intent.
    /// A live app observes this on the Darwin center and applies the request through its
    /// normal ReceiverService path — the extension never touches the receiver itself.
    static let captureIntentChangedNotification = "dev.audiocompanion.captureIntentChanged"

    // WidgetKit kinds. These strings are user data once a widget is on a Home Screen — the
    // system keys placed widgets off them, so renaming one orphans it. Add, never rename.

    /// "Is it recording?" plus a Pause/Resume button (small + both lock-screen accessories).
    static let statusWidgetKind = "dev.audiocompanion.widget.status"
    /// The current conversation: title, newest line, recent activity, control (medium).
    static let nowWidgetKind = "dev.audiocompanion.widget.now"
    /// Open follow-ups, each deep-linking into its conversation (small + medium).
    static let followUpsWidgetKind = "dev.audiocompanion.widget.followups"
    /// The day-coverage strip — kept as the non-default diagnostic view.
    static let coverageWidgetKind = "dev.audiocompanion.widget.coverage"
    /// Control Center control kind.
    static let captureControlKind = "dev.audiocompanion.control.capture"
}
