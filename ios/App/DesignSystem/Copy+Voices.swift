import Foundation

extension Copy {
    enum Voices {
        static let title = "People & voices"
        static let recognize = "Recognize voices"
        static let local = "On this phone"
        static let introduction = "Put a name to familiar voices. Recognition runs on this phone, with whichever transcription service you use."
        static let offDetail = "Off. Existing names stay; no new voices are matched."
        static let onDetail = "Names appear when there’s a clear match. Uncertain voices stay unnamed."
        static let yourVoice = "Your voice"
        static let setUp = "Set up your voice"
        static let setUpDetail = "Record a few short samples through your watch, each somewhere different."
        static let people = "People"
        static let recognition = "Recognition"
        static let coverageLine = "of what’s been said has a name"
        static let whoIsThis = "Who is this?"
        static let toReview = "To review"
        static let toName = "Voices to name"
        static let noneToName = "No voices to name right now."
        static let possibleMatches = "Possible matches"
        static let foundAutomatically = "Found automatically"
        static let seeAll = "See all"
        static let confirmedSamples = "Confirmed voice samples"
        static let someoneElse = "Someone else"
        static let someoneNew = "Someone new"
        static let itsSomeoneElse = "It’s someone else"
        static let notNow = "Not Now"
        static let uncheckAny = "Uncheck any that aren’t"
        static let listenToAll = "Opens every conversation it was heard in"
        static let playLonger = "Play Longer"
        static let isThisYou = "Is this you?"
        static let thatsMe = "That’s me"
        static let mostOfYourConversations = "In most of your conversations"
        static let mostOfYourConversationsLine = "This voice is in most of your conversations."
        static let closestMatch = "Sounds most like them"
        static let moreThanOne = "More than one person"
        static let dontAsk = "Don’t ask about this voice"
        static let wontAsk = "You won’t be asked about this voice"
        static let nameVoice = "Name this voice"
        static func isThis(_ name: String) -> String { "Is this \(name)?" }
        static func thats(_ name: String) -> String { "That’s \(name)" }
        static func notThem(_ name: String) -> String { name == "you" ? "That wasn’t you" : "Not \(name)" }
        static func noneOfThese(_ name: String) -> String { "None of these are \(name)" }
        static func confirm(_ count: Int, for name: String) -> String { "Confirm \(count) for \(name)" }
        static func named(_ name: String, in count: Int) -> String {
            count == 1 ? "Named \(name) in 1 conversation" : "Named \(name) in \(count) conversations"
        }
        static let noPeople = "No voices remembered yet"
        static let noPeopleDetail = "Set up your voice, or tap a speaker in a conversation to teach the app someone else’s voice."
        static let history = "Earlier recordings"
        static let historyDetail = "Look for voices in audio still on this phone. Names you chose yourself are kept. Runs while your phone charges."
        static let findingVoices = "Finding familiar voices…"
        static let waitingForCharging = "Waiting for charging"
        static let waitingLowPower = "Paused in Low Power Mode"
        static let waitingTooHot = "Waiting for the phone to cool down"
        static func recordingsToCheck(_ count: Int) -> String {
            count == 1 ? "1 recording to check" : "\(count) recordings to check"
        }
        static func checking(_ count: Int) -> String {
            count == 1 ? "Checking 1 recording" : "Checking \(count) recordings"
        }
        static func recordingsChecked(_ count: Int, of total: Int) -> String {
            total == 1 ? "\(count) of 1 recording checked" : "\(count) of \(total) recordings checked"
        }
        static func recordingsChecked(_ count: Int) -> String {
            count == 1 ? "1 recording checked" : "\(count) recordings checked"
        }
        static let counting = "Counting recordings…"
        static func matches(_ count: Int) -> String {
            count == 1 ? "voices found in 1" : "voices found in \(count)"
        }
        static let lastWeek = "Find voices in the past week"
        static let allRecordings = "Find voices in all recordings"
        static let cancelRun = "Stop finding voices"
        static let undo = "Undo these matches"
        static let undoDetail = "Removes this pass’s automatic names. Your own corrections are kept."
        static let clearAutomatic = "Remove automatic names"
        static let clearAutomaticDetail = "Removes every name added by voice recognition. Your own corrections and remembered voices stay."
        static let forget = "Forget this voice"
        static let forgetDetail = "Removes its voice samples and automatic matches. Names you chose yourself stay."
        static let samples = "Voice samples"
        static let sampleDetail = "Confirmed voice samples stay until you remove them, even after a recording expires. Remove a sample if it includes someone else or sounds unclear."
        static let addSample = "Add a voice sample"
        static let removeSample = "Remove sample"
        static let prepare = "Prepare voice recognition"
        static let downloadDetail = "Downloads about 18 MB of voice models for this phone. Your recordings are not uploaded."
        static let preparing = "Preparing voice recognition…"
        static let setupTitle = "Teach the app your voice"
        static let setupDetail = "Find a quiet spot. Speak naturally into your phone for about 20 seconds. You can listen and try again before saving."
        static let yourName = "Your name"
        static let record = "Record a sample"
        static let recording = "Listening to you…"
        static let stop = "Finish recording"
        static let prompt = "Here’s a little about my day. I’m trying a new way to remember conversations and the ideas that matter to me. Later, I might take a walk, call someone, or make plans for the weekend."
        static let listen = "Listen to sample"
        static let retry = "Record again"
        static let save = "Use this voice"
        static let saved = "Voice sample saved"
        static let savedDetail = "Recognition is on. Confirming clear passages recorded on your watch helps it recognize this voice in everyday conversations."
        static let needsAnother = "Add one more clear sample before this voice can be recognized."
        static let emptyProfile = "No voice samples remain. Names you chose are still saved in conversations."
        static let samplePrivacy = "The sample is processed on this phone. Its audio is discarded after you save or leave setup."
        static let microphoneDenied = "Allow microphone access in iOS Settings to record a sample, or use a passage from a watch recording."
        static let interrupted = "Recording was interrupted. Please try again in a quiet spot."
        static let shortSample = "Please record at least 10 seconds of clear speech."
        static let unavailable = "Voice recognition is not available right now. Try reopening this screen."
        static let loadFailed = "Couldn’t load voices. Try again."
        static let actionFailed = "Couldn’t finish that change. Please try again."
        static let rememberPassage = "Remember this voice"
        static let rememberDetail = "Learn from this clear passage and check earlier recordings on this phone. Names you chose yourself are kept."
        static let manualSavedSampleFailed = "The name was saved. This passage couldn’t be used as a voice sample; try a clearer passage with just one speaker."
    }
}
