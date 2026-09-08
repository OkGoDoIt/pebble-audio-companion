import Foundation

// Strings for the two halves of the "AI notes stop blocking you" change:
//
//   • `Copy.Notes.templateExtendedSummary` — the new built-in template (the long, plain account
//     of what happened, as opposed to Meeting notes, which sorts a recording into categories).
//   • `Copy.NoteJobs` — the dock that reports a note being written while the user goes on using
//     the app, and hands it back when it is done.
//
// Kept out of `Copy.swift` because that file is a large, very hot shared surface; the pattern is
// the one `Copy+Speaker.swift` established. It is still the one approved catalog.
//
// Vocabulary rules that apply here:
// - Say what is happening in the present tense and in the user's words: the app is "writing"
//   notes, it is not "processing a job" or "running an inference".
// - Never claim more certainty than we have. A generation that failed says it did not finish and
//   why, and offers the retry; it never disappears quietly, and it never blames the user.
// - The template's own title carries the specifics ("Meeting notes ready", "Extended summary
//   didn't finish"), so a person who started two of these can tell them apart at a glance.

extension Copy.Notes {
    /// The long-form account (kit template id `extended-summary`). Named for what it gives you
    /// rather than how long it is — "Full summary" would suggest the short one is partial, which
    /// is not what the header's two sentences are.
    static let templateExtendedSummary = "Extended summary"
}

extension Copy {
    enum NoteJobs {
        // ── The template sheet's two sections ────────────────────────────────
        // The sheet is now the whole Notes menu — what this conversation already has, then what
        // it could have — so both halves need naming. Plain nouns: the sheet is already titled
        // "Notes", so a header that repeated the word would say nothing.
        /// Header over the notes that already exist for this conversation.
        static let existingNotesHeader = "Saved for this conversation"
        /// Header over the templates. Only shown when there is a section above it to distinguish
        /// it from — on a conversation with no notes yet, the templates ARE the sheet.
        static let newNoteHeader = "Write something new"

        // ── The dock's three states ──────────────────────────────────────────
        /// "Writing Meeting notes…" — present tense, because it is happening now and the user
        /// is free to walk away from it.
        static func writing(_ template: String) -> String { "Writing \(template)…" }
        /// The same thing said on a row that already names the template — the template sheet's
        /// "you already asked for this one" marker.
        static let writingShort = "Writing…"
        /// "Meeting notes ready" — the come-back-to-it line.
        static func ready(_ template: String) -> String { "\(template) ready" }
        /// "Meeting notes didn't finish" — never "failed", never an error code. The reason goes
        /// on the line underneath.
        static func didNotFinish(_ template: String) -> String { "\(template) didn't finish" }

        /// Sub-line while a job runs and we do not know the conversation's title. This is the
        /// sentence the whole change exists to make true, so it is worth saying once.
        static let keepsGoing = "This keeps going while you use the app."

        /// "+2 more" — how many other notes are queued behind the one on show. The dock shows
        /// one at a time on purpose: they surface in turn as each is dealt with.
        static func more(_ count: Int) -> String { "+\(count) more" }

        // ── Actions ──────────────────────────────────────────────────────────
        static let view = "View"
        static let stop = "Stop"
        static let dismiss = "Dismiss"

        // ── Why a generation did not finish ──────────────────────────────────
        // Each one says what to do next, and where. A reason we cannot explain is reported as
        // exactly that rather than dressed up as something we understood.
        static let providerUnavailable =
            "No AI provider is available. Check Transcription & AI in Settings."
        static let consentRequired =
            "Cloud AI needs your go-ahead first. Check Transcription & AI in Settings."
        static let nothingToWorkFrom =
            "There is no transcript for this conversation yet."
        static let cancelled = "Stopped."
        static let unknown = "Something went wrong."

        // ── Accessibility ────────────────────────────────────────────────────
        static func writingLabel(_ template: String) -> String {
            "Writing \(template). This keeps going while you use the app."
        }
        static func readyLabel(_ template: String) -> String {
            "\(template) ready. Double tap View to open it."
        }
        static func failedLabel(_ template: String, reason: String) -> String {
            "\(template) didn't finish. \(reason)"
        }
    }
}
