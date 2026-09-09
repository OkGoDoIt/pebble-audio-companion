import Foundation

// Strings for reading a long conversation, as opposed to listening to one — the corner control
// that takes you back to the end of it.
//
// It names its destination, not its mechanism, for the same reason "Back to playing" does: the
// two controls share a corner and a shape, and the only thing that tells them apart for someone
// using VoiceOver is where each one says it is going.

extension Copy {
    enum Reading {
        /// The ⌄ button offered when a conversation carries on below the fold.
        static let jumpToEnd = "Jump to the end"
        static let jumpToEndHint = "Scrolls to the end of the conversation"
    }
}
