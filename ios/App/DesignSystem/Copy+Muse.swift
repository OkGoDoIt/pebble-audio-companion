import Foundation

// Settings · Muse: set Muse up (two steps), pair the watch, then ask it things.
extension Copy {
    enum Muse {
        static let title = "Muse"
        static let rowTitle = "Muse"
        static let rowPaired = "Paired"
        static let rowNotSetUp = "Not set up"

        static func step(_ number: Int, of total: Int) -> String { "Step \(number) of \(total)" }

        // Step 1: the SDK token.
        static let tokenStepTitle = "Add your SDK token"
        static let tokenStepLine = "Make one at gadgets.muse.ai, then paste it here."
        static let tokenPlaceholder = "SDK token"
        static let tokenSave = "Save Token"
        static let tokenGet = "Open gadgets.muse.ai"

        // Step 2: pairing.
        static let pairStepTitle = "Pair your watch"
        static let pairStepLine = "Your watch shows up in the Muse app as a new device, and you add it there."
        static let pair = "Pair with Muse"
        static let tryAgain = "Try Again"

        // Pairing in progress: one checklist, the current step says what to do.
        static let pairingTitle = "Pairing with Muse"
        static let allowStep = "Allow it on your watch"
        static let allowDetail = "Press the top button on your watch."
        static let addStep = "Add it in the Muse app"
        static func addDetail(_ name: String) -> String {
            "In Muse, go to Settings › Devices › Add, then choose \(name)."
        }
        static func timeLeft(_ seconds: Int) -> String {
            seconds >= 60 ? "\(seconds / 60) min left" : "\(seconds) s left"
        }
        static let finishStep = "Finish setup"
        static let finishDetail = "Muse is setting up your watch."
        static let cancel = "Cancel Pairing"

        // Paired.
        static let pairedTitle = "Paired with Muse"
        static func pairedLine(_ name: String) -> String { "Listed as \(name) in the Muse app." }

        // How a pairing ended without pairing.
        static let watchNotConnectedTitle = "Watch not connected"
        static let watchNotConnectedLine = "Pairing needs your watch connected to this app."
        static let watchNeedsUpdateTitle = "Update your watch"
        static let watchNeedsUpdateLine = "This watch's software can't pair with Muse."
        static let timedOutTitle = "Muse didn't find your watch"
        static let timedOutLine = "Add the device in the Muse app while your watch is waiting."
        static let didNotFinishTitle = "Pairing didn't finish"
        static let didNotFinishLine = "Muse connected but setup stopped partway."
        static let couldNotStartTitle = "Couldn't start pairing"
        static let couldNotStartLine = "Try again in a moment."

        // What goes where: the privacy model's D7 sentences (docs/privacy-model.md), word for
        // word, until the model's own function supplies them.
        static let whatGoesHeader = "What goes to Meta"
        static let questionsLine =
            "The questions you ask Muse go to Meta as text, and its answers come back. Nothing "
            + "goes while you aren't asking."
        static let trainingLine =
            "Meta may use your questions to improve its AI. You can turn that off in the Muse app."

        // Asking.
        static let askHeader = "Ask Muse"
        static let askPlaceholder = "Ask Muse something"
        static let askSend = "Ask"
        static let asking = "Asking Muse…"
        static let askFailed = "Muse didn't answer. Try again."
        static let askIncomplete = "Muse was still answering when this stopped."

        // Managing.
        static let tokenRow = "SDK token"
        static let tokenTitle = "SDK token"
        static let tokenAdded = "Added"
        static let tokenRemove = "Remove Token"
        static let tokenFooter = "Stored in this phone's Keychain."
        static let forget = "Forget Muse"
        static let forgetTitle = "Forget Muse?"
        static let forgetMessage = "Your watch stops reaching Muse until you pair again."
        static let forgetConfirm = "Forget"
    }
}
