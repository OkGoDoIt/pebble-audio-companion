import Foundation
import StatusUI

// The one label for a conversation whose audio never arrived, and the one place that decides
// when to use it.
//
// WHY THIS EXISTS
//
// A conversation's meta line is "7:02 PM · 1 hr 40 min", and the duration half came straight
// from `Formatting.duration(row.durationMs)`. `LibraryRow.durationMs` is `endMs - startMs`, so a
// conversation whose segment was opened and then received nothing at all has a duration of
// exactly zero — and `Formatting.duration(0)` is the string "0 sec".
//
// There are five such rows in the real library. "0 sec" is not a length; it is the app failing
// to say that nothing was recorded, in the vocabulary it uses for things that WERE. Someone
// scrolling past reads it as a recording so short it is not worth opening, when the truth is
// that the watch opened a conversation and no audio ever reached the phone — which is exactly
// the class of fact this product promises never to dress up as something else.
//
// The predicate is deliberately `== 0` and not "under a second". A 400 ms conversation is real
// audio and still renders "0 sec", which is imprecise but true; zero is the only value that
// means nothing was received, and only the exact case gets the sentence.
//
// Live rows are excluded: a conversation that started a moment ago has a duration of zero for
// the first second of its life, and "No audio received" over a recording that is starting
// normally would be the same kind of lie in the other direction.
extension Copy.Conversation {
    /// The duration half of a conversation's meta line when nothing was ever received.
    static let noAudioReceived = "No audio received"
}

enum ConversationDuration {
    /// The duration half of a conversation's meta line: a length, or the plain statement that
    /// there is none. `isLive` suppresses the statement — see the note above.
    static func label(durationMs: Int64, isLive: Bool = false) -> String {
        guard durationMs == 0, !isLive else { return Formatting.duration(durationMs) }
        return Copy.Conversation.noAudioReceived
    }
}
