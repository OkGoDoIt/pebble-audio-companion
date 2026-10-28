import Foundation

// The one thing this app cannot do for you.
//
// Every screen in the app assumes the watch is already offering the audio service. It only
// exists in a custom PebbleOS build, and until now nothing in the app said so anywhere a person
// could act on it: the connect screen stated "Requires the custom audio firmware." as a fact
// with no next step, and the "This Pebble can't send audio" branch opened the PebbleOS GitHub
// repository — a source tree, not an install.
//
// Rules this copy follows:
//
// - **Four steps, one line each.** Getting firmware onto a sealed watch is genuinely a
//   four-step job; anything shorter is a lie and anything longer is a manual. The full
//   procedure lives in `PEBBLE_TIME_2_CUSTOM_FIRMWARE_GUIDE.md`, which is where the two
//   details worth repeating here came from: the official app hides Sideload FW behind
//   `Show debug options`, and it rejects a bundle built for the slot it is not updating.
// - **One file.** Builds are published as GitHub releases of the PebbleOS fork, each with a
//   single `.pbz` that carries both slots, so the official app picks the slot itself and there
//   is no "try the other slot's build" step to explain.
// - **Name the official app, and say what this app does not do to it.** The install happens
//   in the official Core Devices Pebble app; this one is a separate app that never touches it
//   or its data. That is the product shape, and it is the first thing anyone asks.
//
// Namespaced `FirmwareGuidance` rather than `Firmware`: the firmware DISTRIBUTION work — the
// release feed, version checking, handing the file to the official app — owns `Copy.Firmware`,
// and two extensions cannot both declare the same nested type. This one is only the
// instructions, and it stands on its own until that lands.
extension Copy {
    enum FirmwareGuidance {

        // ─── The guide ───────────────────────────────────────────────────────

        static let title = "Custom firmware"

        /// Why the guide exists, in the one sentence a person needs before the steps.
        /// Verified: the app is a pure GATT client of the watch-hosted audio-companion service
        /// (UUID base `7C2B0000-…`), which is compiled in only under
        /// `CONFIG_SERVICE_AUDIO_COMPANION` — on stock firmware the service discovery guard is
        /// what produces the "This Pebble can't send audio" branch.
        static let why =
            "Your Pebble needs a PebbleOS build with the audio service. Stock firmware "
            + "doesn't have it."

        static let step1Title = "Get the firmware file"
        /// Verified: `.pbz` is the only bundle the official app's firmware path accepts — it
        /// carries the manifest, board and slot metadata a raw `.bin` has no way to declare.
        static let step1Line = "A .pbz bundle built for your watch."

        static let step2Title = "Open it in the official Pebble app"
        /// Verified two ways: the official app routes any incoming file whose name ends in
        /// `.pbz` to its firmware installer (`PebbleDeepLinkHandler`), and the same install is
        /// reachable manually from Settings → Show debug options → Devices → your watch.
        static let step2Line =
            "Share the .pbz to it, or turn on Show debug options and use "
            + "Firmware Update Debug → Sideload FW."

        static let step3Title = "Let it finish"
        /// Verified: the watch writes the inactive slot and reboots into it, so a failed
        /// transfer cannot damage the firmware that is running.
        static let step3Line = "Keep the watch charged and nearby. It reboots into the new build."

        static let step4Title = "Come back and connect"
        static let step4Line = "The watch asks you to allow this phone once."

        /// The reassurance the two-app shape earns: audio never reaches the official app, and
        /// nothing here modifies it.
        static let officialAppNote =
            "The official Pebble app installs the firmware. This app never changes it or its data."

        // ─── Where the build comes from ──────────────────────────────────────

        /// The newest published release (`scripts/publish-firmware-release.sh`). The guide
        /// renders `releaseUnavailable` when this is nil.
        static let releaseURL: URL? = URL(
            string: "https://github.com/OkGoDoIt/PebbleOS/releases/latest"
        )
        static let releaseLinkTitle = "Get the latest build"
        static let releaseUnavailable = "Builds are not published yet."

        /// The guide opened from the install flow's "Install It Myself", where step 1's file is
        /// already downloaded and checked.
        static let installYourselfTitle = "Install It Yourself"
        static let saveToFiles = "Save to Files"
        static let gitHub = "GitHub"

        // ─── Ways in ─────────────────────────────────────────────────────────


        /// Offered under the "No Pebble found" branch. A watch on stock firmware is invisible to
        /// this app in exactly the same way as a watch that is out of range, so the two are worth
        /// telling apart at the moment someone is stuck.
        static let noPebbleFirmwarePrompt = "Does your watch have the custom firmware?"
    }
}
