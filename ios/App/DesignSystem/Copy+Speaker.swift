import Foundation

// The speaker-rename sheet's strings (plan 6.3 / Q17). Kept as an extension on `Copy` — it is
// still the one approved catalog — in its own file only because `Copy.swift` is a large shared
// surface and this is a self-contained vocabulary.
//
// Vocabulary rules that apply here:
// - "person" is the registry record; "speaker" is one diarization label in one conversation.
//   Every string below is explicit about which one an action touches, because the difference
//   is the difference between renaming Sam everywhere and renaming Sam in this transcript.
// - No protocol or model vocabulary: never "label", "diarization" or "assignment" on screen.

extension Copy {
    enum Speaker {
        static let title = "Who’s speaking?"
        static let passage = "This passage"
        static let passageFooter = "This changes only the selected passage. Voice recognition is not enabled."
        static let thisIsMe = "This is me"
        static let you = "You"
        static let unnamed = "Leave unnamed"
        static let newPerson = "Add a new person"
        static let timingUnavailable = "Speaker timing isn’t available for this passage yet."
        static let loadFailed = "Couldn’t load people. Try again."
        static let saveFailed = "Couldn’t save this change. Your selection is still here; try again."
        static let retry = "Try again"
        static let peopleHeader = "People"
        static let peopleFooter = "Touch and hold a name to rename it, mark it as you, or remove the person everywhere."
        static let namePlaceholder = "Name"

        static let rename = "Rename"
        static let renamePerson = "Rename Person"
        static let renamePersonMessage =
            "This name is used everywhere. Every conversation with this person updates."

        static let deletePerson = "Delete Person"
        static func deletePersonTitle(_ name: String) -> String { "Delete \(name)?" }
        static let deletePersonMessage =
            "They are removed from every conversation. Recordings and transcripts are kept."

        static let removeName = "Remove Name"
        /// Says exactly what it does — this conversation only — so it cannot be mistaken for
        /// deleting the person.
        static func removeNameFooter(_ name: String) -> String {
            "\(name) stays in your list. This speaker goes back to being unnamed in this "
                + "conversation only."
        }
    }
}
