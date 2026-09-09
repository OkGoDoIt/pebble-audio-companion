import Foundation

// Strings for reading a long conversation, as opposed to listening to one — the corner control
// that takes you to the bottom of it.
//
// It names its destination, not its mechanism, for the same reason "Back to playing" does: the
// two controls share a corner and a shape, and the only thing that tells them apart for someone
// using VoiceOver is where each one says it is going.

extension Copy {
    enum Reading {
        /// The ⌄ button offered when a conversation carries on below the fold.
        static let scrollToBottom = "Scroll to the bottom"
        static let scrollToBottomHint = "Scrolls to the end of the conversation"
    }
}
