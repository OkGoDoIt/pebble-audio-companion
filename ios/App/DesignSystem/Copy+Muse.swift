import Foundation

// Settings · Muse: pairing the watch with Meta's Muse assistant, and trying it.
extension Copy {
    enum Muse {
        static let title = "Muse"
        static let rowTitle = "Muse"
        static let rowPaired = "Paired"

        // Status card: a heading and at most one line.
        static let notSetUpTitle = "Muse isn't set up on this phone"
        static let notSetUpLine = "It needs a one-time developer setup in Diagnostics."
        static let notPairedTitle = "Not paired"
        static let notPairedLine = "Pair once, and your watch shows up in the Muse app."
        static let startingTitle = "Starting…"
        static let confirmTitle = "Confirm on your watch"
        static let confirmLine = "Press the top button to allow pairing."
        static let addTitle = "Add it in Muse"
        static func addLine(_ name: String) -> String {
            "In the Muse app, go to Settings › Devices › Add, then choose \(name)."
        }
        static func timeLeft(_ seconds: Int) -> String {
            seconds >= 60 ? "\(seconds / 60) min left" : "\(seconds) s left"
        }
        static let connectedTitle = "Muse is connected"
        static let connectedLine = "Finishing setup…"
        static let pairedTitle = "Paired with Muse"
        static func pairedLine(_ name: String) -> String { "Listed as \(name) in the Muse app." }

        static let watchNotConnectedTitle = "Watch not connected"
        static let watchNotConnectedLine = "Pairing needs your watch connected to this app."
        static let watchNeedsUpdateTitle = "Update your watch"
        static let watchNeedsUpdateLine = "This watch's software can't pair with Muse."
        static let timedOutTitle = "Muse didn't find your watch"
        static let timedOutLine = "Add the device in the Muse app while your watch is waiting."
        static let didNotFinishTitle = "Pairing didn't finish"
        static let didNotFinishLine = "Try again."
        static let couldNotStartTitle = "Couldn't start pairing"
        static let couldNotStartLine = "Try again in a moment."

        // Actions
        static let pair = "Pair with Muse"
        static let tryAgain = "Try Again"
        static let cancel = "Cancel Pairing"
        static let forget = "Forget Muse"
        static let forgetTitle = "Forget Muse?"
        static let forgetMessage = "Your watch stops reaching Muse until you pair again."
        static let forgetConfirm = "Forget"

        // What goes where: the privacy model's D7 sentences (docs/privacy-model.md), word for
        // word, until the model's own function supplies them.
        static let whatGoesHeader = "What goes to Meta"
        static let questionsLine =
            "The questions you ask Muse go to Meta as text, and its answers come back. Nothing "
            + "goes while you aren't asking."
        static let trainingLine =
            "Meta may use your questions to improve its AI. You can turn that off in the Muse app."

        // Developer setup, in Diagnostics: the one place a mechanism may be named.
        static let developerTokenRow = "Muse SDK token"
        static let developerTokenTitle = "Muse SDK token"
        static let developerTokenPlaceholder = "SDK token"
        static let developerTokenSave = "Save"
        static let developerTokenRemove = "Remove Token"
        static let developerTokenAdded = "Added"
        static let developerTokenMissing = "Not added"
        static let developerTokenFooter = "From gadgets.muse.ai. Stored in this phone's Keychain."

        // Trying it
        static let askHeader = "Try it"
        static let askPlaceholder = "Ask Muse something"
        static let askSend = "Ask"
        static let asking = "Asking Muse…"
        static let askFailed = "Muse didn't answer. Try again."
        static let askIncomplete = "Muse was still answering when this stopped."
    }
}
