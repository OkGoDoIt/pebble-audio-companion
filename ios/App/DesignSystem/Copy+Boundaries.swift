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
        static let footer =
            "This only changes how the recording is grouped in your list. No audio, transcript "
            + "or note is changed or removed."

        static let joinHeader = "Previous conversation"
        static let join = "Join with the previous conversation"
        static let joined = "Joined with the previous conversation"
        static let joinFooter =
            "Use this when one conversation was split in two — after you stopped and started "
            + "recording again, for instance."
        static let undoJoin = "Separate them again"

        static let splitHeader = "Start a new conversation"
        static let splitFooter =
            "A new conversation can start wherever the recording picked back up. Tap a time to "
            + "split there, and tap it again to undo."
        static let noSplitPoints =
            "This is one continuous recording, so there is nowhere inside it to split."

        /// "25 min in" — how far into the conversation a possible split point sits.
        static func minutesIn(_ offsetMs: Int64) -> String {
            "\(Formatting.duration(max(offsetMs, 0))) in"
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
            case .manual: return "You split the recording here."
            case nil: return nil
            }
        }
    }
}
