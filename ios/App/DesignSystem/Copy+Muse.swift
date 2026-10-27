import CompanionRuntime
import Foundation
import WireProtocol

// Settings · Muse: set Muse up (two steps), pair the watch, then ask it things.
extension Copy {
    enum Muse {
        static let title = "Muse"
        static let rowTitle = "Muse"
        static let rowPaired = "Paired"
        static let rowNotSetUp = "Not set up"
        static let reconnect = "Reconnect Muse"
        static let reconnectLine = "Muse no longer accepts this sign-in. Pair again to reconnect your watch."

        static func step(_ number: Int, of total: Int) -> String { "Step \(number) of \(total)" }

        // Before setting up: what it is for, and what it takes, so it is clear it's worth it.
        // The watch wording appears only once asking from the watch exists.
        static func introTitle(fromWatch: Bool) -> String {
            fromWatch ? "Ask Muse from your watch" : "Ask Muse from Pebble Audio"
        }
        static func introLine(fromWatch: Bool) -> String {
            fromWatch
                ? "Muse is Meta's AI assistant. Pair once, then hold a button on your watch, ask out loud, and read the answer on your wrist."
                : "Muse is Meta's AI assistant. Pair your watch once, then type a question here and get Muse's answer."
        }
        static let needsHeader = "What you need"
        static let needsMuseApp = "The Muse app and your Muse account"
        static let needsToken = "An SDK token from gadgets.muse.ai"
        static let needsTime = "A few minutes, with your watch nearby"

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
        /// D7, the sentence the Privacy screen shows (PrivacyModel), so the two always match:
        /// while Muse stays connected to message the watch, it says so instead of "Nothing goes
        /// while you aren't asking".
        static func questionsLine(staysConnected: Bool) -> String {
            let spoken = MuseGadgetService.asksFromWatch
            if staysConnected {
                return spoken ? PrivacyModel.museSentenceConnected : PrivacyModel.museSentenceTypedConnected
            }
            return spoken ? PrivacyModel.museSentence : PrivacyModel.museSentenceTyped
        }
        static let trainingLine =
            "Meta may use your questions to improve its AI. You can turn that off in the Muse app."

        // Asking from the watch.
        static let watchAskTitle = "Ask from your watch"
        static let watchAskStepSettings = "On your watch, open Settings › Quick Launch."
        static let watchAskStepPick = "Choose Hold Up, Hold Center or Hold Down, then Apps › Muse."
        static let watchAskStepHold = "On your watch face, hold that button, ask, and let go."
        static let watchAskInApp = "Or open Muse on your watch and hold the center button."
        static let lastQuestionHeader = "Last question"
        static func heard(_ text: String) -> String { "\u{201C}\(text)\u{201D}" }
        static let heardNothing = "Muse didn't catch the words."
        static let answered = "Answered on your watch"
        static let showAll = "Show All"
        static let showLess = "Show Less"
        /// One request Muse made while answering: what, then how it ended.
        static func toolUse(_ use: MuseToolUse) -> String {
            let what = toolName(use.command)
            switch use.outcome {
            case .done: return "\(what): done"
            case .declined: return "\(what): not allowed"
            case .unanswered: return "\(what): no answer on your watch"
            case .failed(let why):
                // The reason was written for Muse as a sentence; here it follows a colon.
                var reason = why.trimmingCharacters(in: .whitespaces)
                if reason.hasSuffix(".") { reason.removeLast() }
                guard let first = reason.first else { return "\(what): didn't work" }
                return "\(what): \(first.lowercased())\(reason.dropFirst())"
            }
        }
        static func toolName(_ command: String) -> String {
            switch command {
            case "health.read": return "Health"
            case "calendar": return "Calendar"
            case "reminders": return "Reminders"
            case "conversations": return "Your conversations"
            case "followups": return "Follow-ups"
            case "watch.set_timer": return "Timer"
            case "watch.set_alarm", "watch.alarms": return "Alarms"
            case "watch.music": return "Music"
            case "watch.quiet_time": return "Quiet Time"
            case "watch.open_app": return "Open a watch app"
            case "watch.find": return "Find your watch"
            case "recording": return "Recording"
            default: return command
            }
        }
        static func lastQuestionProblem(_ error: AssistantError) -> String {
            switch error {
            case .notSetUp: return "Muse needs setting up again"
            case .unreachable: return "Couldn't reach Muse"
            case .noAnswer: return "Muse didn't answer"
            case .didNotCatch: return "Too short to ask"
            case .busy: return "Muse was busy"
            case .stillWorking: return "Muse is still working on it"
            }
        }

        // What Muse can do on the watch (D7b): a switch each, on once paired.
        static let actionsHeader = "What Muse can do on your watch"
        static let actionTimer = "Set timers"
        static let actionAlarm = "Manage alarms"
        static let actionMusic = "Control music"
        static let actionQuietTime = "Turn on Quiet Time"
        static let actionLaunchApp = "Open watch apps"
        static let actionFindWatch = "Find your watch"
        static let actionRecording = "Pause or resume recording"

        // What Muse can see (D7a, D7c-D7e), word for word from docs/privacy-model.md.
        static let seeHeader = "What Muse can see"
        static let seeConversations = "Your conversations"
        static let seeConversationsSubtitle = "Includes what other people said."
        static let seeHealth = "Health"
        static let seeCalendar = "Calendar"
        static let seeReminders = "Reminders"
        static let seeRemindersSubtitle = "In Pebble Audio and Apple Reminders. Muse can also add, change, and delete them."
        static let seeFollowUps = "Follow-ups"
        static let seeFollowUpsSubtitle = "Waiting for your review. Muse can turn one into a reminder or skip it."
        static let accessAsk = "Ask first"
        static let accessAllowed = "Allowed"
        static let accessOff = "Off"
        static let seeFooter = "Muse reads these only while answering a question you asked on your watch. What it reads goes to Meta."
        static let accessAskFooter = "The first time Muse wants it, your watch asks you."
        static let accessAskFooterReminders =
            "The first time Muse wants to read them, your watch asks you. It also asks once per question before changing them."
        static let accessAskFooterFollowUps =
            "The first time Muse wants to read them, your watch asks you. It also asks once per question before turning them into reminders or skipping them."
        static let noPhoneAccess = "No access in iPhone Settings"
        static let allowAccess = "Allow Access"
        static let openSettings = "Open Settings"

        static let actionsFooter = "Only while it's answering a question you asked. Only the outcome goes back."

        // Questions from the watch.
        static let questionsHeader = "Questions from your watch"
        static let chatRow = "Go to"
        static let chatWatch = "Their own chat"
        static let chatMain = "Your main chat"
        static let chatFooter = "Where they appear in the Muse app."
        static let messagesRow = "Muse's own messages"
        static let messagesFooter = "Updates and results Muse sends without being asked come to your watch."
        static let levelRow = "Voice level"
        static let levelAutomatic = "Automatic"
        static func levelFixed(_ gain: Int) -> String { gain == 0 ? "No boost" : "+\(gain) dB" }
        static let levelFooterAutomatic = "Each question is measured and raised to a level Muse hears well."
        static func levelLast(_ gain: Int) -> String {
            gain <= 0 ? "Your last question needed no boost." : "Your last question was raised \(gain) dB."
        }

        // Diagnostics · Voice level check.
        static let levelCheckRow = "Muse voice level check"
        static let levelCheckTitle = "Voice level check"
        static let levelCheckIdle = "Check the voice level"
        static let levelCheckWaiting = "Ask Muse something from your watch"
        static let levelCheckRunning = "Checking with Muse…"
        static let levelCheckDone = "What Muse heard at each level"
        static let levelCheckFailed = "Couldn't reach Muse"
        static let levelCheckLine =
            "Your next question from the watch is also sent at four levels, to a chat of its own, "
            + "so you can see what Muse hears at each. Keep this screen open while it runs."
        static let levelCheckStart = "Check Next Question"
        static let levelCheckCancel = "Cancel"
        static func levelCheckResultTitle(target: Int, gain: Int, automatic: Bool) -> String {
            "\(target) dBFS · +\(gain) dB" + (automatic ? " · Automatic" : "")
        }
        static func levelCheckSpeech(_ level: Int) -> String {
            "Your question's speech measured \(level) dBFS before any boost."
        }

        // Asking by typing.
        static let askHeader = "Type a question"
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
