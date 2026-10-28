import Foundation
import Firmware

// Putting the audio firmware on a watch that does not have it: onboarding's firmware step, and
// the same flow from Today and Settings → Watch when an official update has replaced it.
//
// Design of record: docs/mockups/firmware-onboarding/directions.html, direction A.
//
// Rules this copy follows:
//
// - **Only what the official app's source backs.** The Pebble app installs an opened `.pbz`
//   immediately with no confirmation, shows its progress only on its Watches tab, never says
//   it finished, installs only on a watch connected at that moment, and refuses another
//   board's build silently. The watch writes the spare slot and restarts into it, so an
//   interrupted transfer leaves the running firmware alone. Every line below is one of those
//   facts in the reader's words, and nothing claims what the app cannot see (the Pebble app's
//   percentage, or a confirmed install before the watch says so).
// - **Tapping Install is the consent.** The screen says everything the Settings dialog says,
//   so there is no second "are you sure" between the button and the iOS menu.
// - **Pebble Time 2 is what the firmware is built for, never what the watch is claimed to be.**
//   Nothing the app can read before the install names the model.
extension Copy {
    enum FirmwareInstall {

        // ─── The offer ───────────────────────────────────────────────────────

        static let title = "Add audio to your Pebble"
        static let lede = "Your Pebble needs the Pebble Audio firmware to send audio to this phone."

        static let openSourceTitle = "Open source"
        static let openSourceLine =
            "PebbleOS with Pebble Audio’s watch features added, built from public code."
        static let installerTitle = "Installed by the Pebble app"
        static let installerLine =
            "Its usual installer. If the transfer stops, your watch keeps the firmware it has."
        static let microphoneTitle = "Microphone off until you allow it"
        static let microphoneLine = "Your watch asks before this phone can record."

        /// "Built for Pebble Time 2 · v4.41.0-678 · 3.5 MB" — the facts a careful reader checks,
        /// in one line under the reasons.
        static func buildLine(_ release: FirmwareRelease) -> String {
            var parts = ["Built for \(release.board.displayName ?? release.board.id)"]
            parts.append(release.version.label)
            if let size = release.sizeBytes { parts.append(Copy.Firmware.size(size)) }
            return parts.joined(separator: " · ")
        }

        static let about = "About This Firmware"
        static let install = "Install Firmware"
        static let installMyself = "Install It Myself"
        static let checking = "Checking for the firmware…"
        static let noRelease = "No firmware is published yet."

        // ─── While the iOS menu is up ────────────────────────────────────────

        /// Shown above the system menu, which covers the bottom half: the one instruction iOS
        /// leaves us room to give.
        static let chooseTitle = "Choose Pebble"
        static let chooseLine = "Pebble starts installing as soon as it opens the file."

        // ─── Waiting for the watch ───────────────────────────────────────────

        static let waitingTitle = "Installing on your watch"
        static let waitingLede =
            "Keep your watch close and charged. It restarts on its own when the install is done."

        static let stepDownloaded = Copy.Firmware.downloaded
        static func stepDownloadedLine(_ release: FirmwareRelease) -> String {
            [release.version.label, release.sizeBytes.map(Copy.Firmware.size)]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        static let stepInstalling = "Installing in the Pebble app"
        static let stepInstallingLine =
            "Its Watches tab shows “Updating to PebbleOS” with a progress bar."
        /// When something other than Pebble was chosen in the menu.
        static let stepInstallingElsewhereLine =
            "It went to another app. Open the file in Pebble to install it."
        static let waitingForRestart = "Waiting for your watch to restart"
        static let stepAllow = "Allow this phone"
        static let stepAllowLine = "Your watch asks once."

        static let notUpdatingTitle = "Pebble app not updating?"
        static let notUpdatingLine =
            "Open it, wait for your watch to say Connected, then send the file again."
        static let sendAgain = "Send to Pebble Again"

        /// The confirm step's first line after a watch came back with the firmware.
        static let installed = "Firmware installed."

        /// Settings → Watch, under Install Firmware, when the watch answered without the service.
        static let settingsRowLine = "Your Pebble doesn’t have the audio firmware right now."

        // ─── About this firmware ─────────────────────────────────────────────

        static let aboutVersion = "Version"
        static let aboutFor = "For"
        static let aboutPublished = "Published"
        static let aboutSize = "Size"
        static let aboutAddsHeading = "What it adds"
        static let aboutAdds =
            "A Bluetooth service that sends your watch’s microphone to this app, and the watch "
            + "side of Pebble Audio, like Quiet Time and timers. Everything else is the PebbleOS "
            + "the Pebble app installs."
        static let aboutSourceHeading = "Where it comes from"
        static let aboutSource =
            "Built from the open PebbleOS source and published on GitHub. Pebble Audio checks the "
            + "file against its published fingerprint before sending it."
        static let aboutSourceLink = "View Source and Release Notes"
        static let aboutOfficialHeading = "Official updates"
        static let aboutOfficial =
            "The Pebble app still offers official PebbleOS updates. Installing one replaces this "
            + "firmware, and Pebble Audio offers to install it again."

        static func publishedDate(_ date: Date) -> String {
            date.formatted(date: .long, time: .omitted)
        }
    }
}
