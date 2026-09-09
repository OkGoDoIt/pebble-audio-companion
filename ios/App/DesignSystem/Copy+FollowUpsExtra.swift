import Foundation

// Follow-up strings added when the list stopped offering to write items for you and started
// admitting what the age rule had quietly taken away. Kept as an extension on the one approved
// catalog — `Copy.swift` is simply a large shared surface, and this is a self-contained
// vocabulary.
//
// Vocabulary rules that apply here:
// - "Filed away" is the only name for archived, everywhere: the filter, this section, and the
//   snackbar all say the same two words, so the row you tapped and the list it came from are
//   recognisably the same thing.
// - Nothing here says "deleted", "archived" or "expired". Filing something away is not losing
//   it, and the footer's whole job is to make that believable.
extension Copy.FollowUps {

    // MARK: Empty state
    //
    // The originals ended "— you can add your own any time" and "and you can always add your
    // own". Both were true only while a + button existed. Nobody used it, it is gone, and an
    // empty state that offers something the screen cannot do is worse than a shorter one.
    //
    // They then carried a second sentence each ("Most conversations have none, and that is
    // normal", "Nothing here yet") — reassurance about, and a restatement of, an empty screen
    // the reader is already looking at.

    static let emptyOpenBodySuggested =
        "Things you say you will do turn up here, pulled out of what you record."
    static let emptyOpenBodySuggestedNoAi =
        "Follow-ups are suggested from your recordings once AI processing is set up."

    // MARK: Filed away, at the foot of the open list
    //
    // The age rule files a suggestion away after two weeks of nobody touching it. That is the
    // right behaviour — an open list full of a fortnight's worth of maybes is not a list — but
    // it happened entirely off screen, so the only evidence was a sentence in a footer pointing
    // at a filter. A count you can see, and open, is the difference between "the app tidied up"
    // and "the app lost things".

    /// Trailing count on the disclosure row. Digits only: the row is already labelled.
    static func filedAwayCount(_ count: Int) -> String { "\(count)" }

    /// What VoiceOver reads instead of "Filed away, 3" — the number needs its noun.
    static func filedAwayA11y(_ count: Int) -> String {
        count == 1 ? "Filed away, 1 item" : "Filed away, \(count) items"
    }

    static let filedAwayShowHint = "Double tap to show what has been filed away"
    static let filedAwayHideHint = "Double tap to hide these again"

    /// Only ever shown when the inline preview is shorter than the whole slice, so the number
    /// is the total and not a repeat of what is already on screen.
    static func seeAllFiledAway(_ count: Int) -> String { "See all \(count)" }

    /// The empty open list's one action. It replaces the "New Follow-up" button that used to
    /// sit there, and unlike that one it is only offered when there is actually something to
    /// look at.
    static func openFiledAway(_ count: Int) -> String {
        count == 1 ? "See 1 filed away" : "See \(count) filed away"
    }
}
