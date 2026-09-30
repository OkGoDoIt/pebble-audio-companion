import AppDB
import Foundation
import StatusUI

// Strings for conversation boundaries — why one starts where it does, and the two things a
// person can do about it. In its own file because `Copy.swift` is a large shared surface; the
// catalog is still `Copy`.
//
// Vocabulary rules:
// - "recording" is what the microphone captured; "conversation" is the thing in the list. Only
//   conversations split and join — nothing here ever edits, trims or deletes audio, and the
//   copy has to make that obvious or a person will fear it does.
// - "quiet" is time when nobody spoke; "missing" is audio the app never received. Never mixed.
// - No algorithm vocabulary on screen: never "boundary", "segment", "threshold", "candidate".

extension Copy {
    enum Boundaries {
        static let title = "Split or join"
        /// The ⋯ menu entry that opens the sheet. Named for the thing being changed rather than
        /// the mechanism — "grouping", "boundaries" and "segments" are all words for how this
        /// works, not for what the person is doing.
        static let menuItem = "Split or Join…"
        /// The one thing this sheet has to promise, since "split" on a recording app reads like
        /// destructive editing.
        static let footer =
            "This only changes how the recording is grouped. Nothing is deleted."

        static let joinHeader = "Previous conversation"
        static let join = "Join with the previous conversation"
        static let joined = "Joined with the previous conversation"
        // `joinFooter` said when to use this ("after you stopped and started recording again,
        // for instance") under a row that already reads "Join with the previous conversation".
        static let undoJoin = "Separate them again"

        /// Joins the person made INSIDE this conversation — what made it the size it is.
        static let joinedHeader = "Joined by you"
        static let joinedFooter = "Tap one to separate the two conversations again."

        static let splitHeader = "Start a new conversation"
        /// What the list is, and how a split is taken back — which is no longer "tap it
        /// again": the place you split at becomes the start of another conversation and
        /// leaves this list.
        ///
        /// "Break", not "pause" or "quiet": a pause is something the person does to the
        /// recording, and the stretch between two turns can be quiet or missing audio — the
        /// list does not know which, so it does not say.
        static let splitFooter =
            "These are the places where talk picked up again after a break. Tap one to start "
            + "a new conversation there. To undo, open the new conversation and join it with "
            + "the previous one."
        /// True of what is offered, not of what is possible: a conversation with no break in
        /// it has no place this sheet can name, and saying "nowhere to split" would be a
        /// claim about the recording rather than about the list.
        static let noSplitPoints =
            "There was no long break in this conversation, so there is no obvious place to "
            + "split it."
        /// VoiceOver hint on a place row.
        static let splitHint = "Starts a new conversation here"

        /// "25 min in" — how far into the conversation a possible split point sits.
        static func minutesIn(_ offsetMs: Int64) -> String {
            "\(Formatting.duration(max(offsetMs, 0))) in"
        }

        /// "3:42 PM · 25 min in" — a place inside the conversation, by the clock and by how
        /// far in it is.
        static func place(time: String, offsetMs: Int64) -> String {
            "\(time) · \(minutesIn(offsetMs))"
        }

        /// The first words said at a place, quoted. Nil when there are none, so the row has
        /// no second line rather than a pair of empty quotation marks.
        static func opening(_ words: String) -> String? {
            words.isEmpty ? nil : "“\(words)”"
        }

        /// "After a 2 min break · “So about the trip…”" — why this place is on the list, and
        /// what was said when talk resumed.
        static func afterBreak(_ breakMs: Int64, opening words: String) -> String {
            let after = "After a \(Formatting.duration(max(breakMs, 0))) break"
            guard let quoted = opening(words) else { return after }
            return "\(after) · \(quoted)"
        }

        /// Shown under the list after a split, in place of the instruction: the tapped row is
        /// gone, so this says where the new conversation starts and how to take it back.
        static func didSplit(at time: String) -> String {
            "A new conversation now starts at \(time). To undo, open it and join it with the "
                + "previous one."
        }

        /// The calm one-liner under a conversation's title saying why it starts here. Nil where
        /// there is nothing worth saying — the first conversation of a rebuild, or a plain
        /// continuation.
        static func startedBecause(_ reason: ConversationStartReason?) -> String? {
            switch reason {
            case .quiet: return "Started after a long quiet stretch."
            case .interrupted: return "Started after a long stretch of missing audio."
            case .userStop: return "Started when you began recording again."
            case .pause: return "Started when you resumed after a pause."
            case .gap: return "Started when recording picked back up."
            case .topicChange: return "Started here — the conversation changed."
            case .lull: return "Started after a few quiet minutes."
            // Not a claim about the talk: nothing is known about it yet.
            case .length: return "Not transcribed yet — divided by length for now."
            case .manual: return "You split the recording here."
            case nil: return nil
            }
        }
    }
}
