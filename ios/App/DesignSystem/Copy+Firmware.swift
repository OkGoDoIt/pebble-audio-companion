import Firmware
import Foundation

// Settings · Watch firmware. `Copy.swift` is the approved catalog and stays as it is; this adds
// one new namespace beside it.
//
// Two rules shape every sentence here, and both come from what the mechanism actually is:
//
// 1. **Never claim an install.** This app downloads a file and hands it to the Pebble app. It is
//    not told whether the flash happened, or whether the watch was even in range. So the words
//    are "sent", "handed to", "asked Pebble to install" — never "installed", never "updated".
// 2. **Say what the next tap does, before it does it.** The Pebble app has no confirmation step:
//    `handleFirmware()` goes straight to `sideloadFirmware()`, which begins the transfer. The
//    moment of consent is therefore here, and it has to name the consequence — the watch
//    restarts and stops recording for a few minutes.

extension Copy {
    enum Firmware {
        /// Section header over the installation steps, which are the same four the onboarding
        /// flow shows — this screen is where someone comes back to them.
        static let howToHeading = "Installing it"

        // ─────────────────────────────────────────────────────────────────────
        // MARK: Entry point
        // ─────────────────────────────────────────────────────────────────────

        /// The Settings-root row. "Watch firmware", not "Firmware update": the row exists
        /// whether or not there is an update, and a row named for an update that is not there
        /// reads as a notification that never clears.
        static let rowTitle = "Watch firmware"
        static let title = "Watch firmware"

        /// The row's trailing value. Only ever set when there is genuinely an update — the row
        /// stays quiet otherwise rather than reporting "Up to date" at someone who did not ask.
        static let rowUpdateAvailable = "Update"

        // ─────────────────────────────────────────────────────────────────────
        // MARK: What is on the watch
        // ─────────────────────────────────────────────────────────────────────

        static let installedHeading = "On your watch"

        /// The honest default. The audio-companion service does carry a firmware-version field,
        /// but the firmware never fills it in, so the app has never once been told.
        static let installedUnknown = "Not known"
        static let installedUnknownNote =
            "The watch doesn't report its firmware version, so this app can't check it."

        /// The watch's own word — reserved for the day the firmware fills the field.
        static func installedReported(_ version: String) -> String { version }

        /// The weaker claim, and the one that is actually used: this app handed that build over
        /// on that date. It is not evidence the watch took it.
        static func handedOver(_ version: String, on date: Date) -> String {
            "\(version) · sent \(shortDate(date))"
        }
        static let handedOverNote = "What this app last sent to Pebble. Not confirmation it installed."
        static let forgetHandoff = "Clear"
        static let forgetHandoffHint = "Forget what this app last sent"

        // ─────────────────────────────────────────────────────────────────────
        // MARK: The offer
        // ─────────────────────────────────────────────────────────────────────

        static let availableHeading = "Available"
        static let checking = "Checking…"
        static let checkAgain = "Check Again"

        static func published(_ date: Date) -> String { "Published \(shortDate(date))" }
        static func forBoard(_ board: FirmwareBoard) -> String {
            "For \(board.displayName ?? board.id)"
        }
        static func size(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }

        static let noReleases = "No builds published yet."
        static let upToDate = "You already have the newest build."
        static let installedIsNewer = "Your watch is on a newer build than the one published."
        /// Shown under an offer when nothing is known about the watch — the reason there is no
        /// "update available" badge.
        static let judgeForYourself = "Install it if it's newer than what you're running."

        /// The feed was read a while ago and could not be re-read just now.
        static func lastChecked(_ date: Date) -> String { "Checked \(shortDate(date))" }
        static let offlineNote = "Couldn't reach the update list. Showing the last one read."

        static func partiallyUnreadable(_ count: Int) -> String {
            count == 1
                ? "1 entry in the update list couldn't be read and was skipped."
                : "\(count) entries in the update list couldn't be read and were skipped."
        }

        // ─────────────────────────────────────────────────────────────────────
        // MARK: Download
        // ─────────────────────────────────────────────────────────────────────

        static let download = "Download"
        static func downloadProgress(_ received: Int64, _ total: Int64) -> String {
            guard total > 0 else { return size(received) }
            return "\(size(received)) of \(size(total))"
        }
        /// "and checked" is the whole point of the line: the digest was verified against the
        /// published one before this app would offer to hand the file anywhere.
        static let downloaded = "Downloaded and checked"

        // ─────────────────────────────────────────────────────────────────────
        // MARK: Hand-off
        // ─────────────────────────────────────────────────────────────────────

        /// The button. An ellipsis because a chooser opens; "Pebble" because the person has to
        /// pick it by name in that chooser, and a button that names it prepares them to.
        static let handOff = "Install with Pebble…"
        static let handOffFallback = "Save to Files…"
        static let handOffFallbackHint = "Then open it from Files and choose Pebble"

        static let consentTitle = "Send this firmware to Pebble?"
        /// Every consequence, in the order they happen. The Pebble app starts installing as soon
        /// as it receives the file — there is no second confirmation after this one.
        static let consentMessage =
            "Pebble starts installing right away. Your watch restarts and won't record for a few "
            + "minutes. Keep it close to your phone."
        static let consentConfirm = "Send to Pebble"

        /// After the chooser closed and Pebble was the app chosen.
        static let sentToPebble = "Sent to Pebble. Watch for the progress there."
        /// After the chooser closed and something else was chosen. Not an error — it just means
        /// this app has nothing to report about it.
        static let sentElsewhere = "Sent. Open it in Pebble to install."
        static let savedToFiles = "Saved. Open it from Files and choose Pebble."

        /// `presentOpenInMenu` returned false: nothing installed can open a `.pbz`.
        static let noOpenerTitle = "Nothing here can open it"
        static let noOpenerMessage =
            "The Pebble app installs firmware. Install it, or save the file and open it later."

        // ─────────────────────────────────────────────────────────────────────
        // MARK: Failures
        // ─────────────────────────────────────────────────────────────────────

        /// One sentence per failure kind, each saying whose problem it is and what to do.
        /// `checksum` is the only one that is not the person's problem in any sense, and it is
        /// worded to make clear that refusing was the right outcome.
        static func failure(_ failure: FirmwareFailure) -> String {
            switch failure {
            case .offline:
                return "Couldn't reach the update list."
            case .server(let status):
                return "The update list isn't answering (\(status))."
            case .badFeed:
                return "The update list couldn't be read."
            case .checksum:
                return "The download didn't match its checksum, so it was deleted. Try again."
            case .storage:
                return "Couldn't save the download."
            case .cancelled:
                return "Canceled."
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // MARK: Dormant
        // ─────────────────────────────────────────────────────────────────────

        /// Only reachable in a development build: with no feed configured the Settings row is
        /// not drawn at all, so nobody can arrive here by accident.
        static let notConfigured = "No update source is set for this build."

        private static func shortDate(_ date: Date) -> String {
            date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
