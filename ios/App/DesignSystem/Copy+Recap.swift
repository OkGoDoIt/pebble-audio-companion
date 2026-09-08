import Foundation

// The recap card's tap affordance and the pushed detail's provenance (session: "'today so far'
// … takes up too much visual space … tapping it should take you to the full extended view").
//
// Vocabulary rule for this area: the card never claims to be the whole recap when it is not,
// and the detail never presents itself as a different document. There is ONE recap of the day;
// the card is a shorter reading of it, and both strings below say exactly that.
//
// Kept out of `Copy.swift` because that file is the shared catalog and very hot; this is a
// self-contained vocabulary belonging to one card and one pushed screen.

extension Copy {
    enum Recap {
        /// The card's own "there is more of this" line, shown only when the card is showing a
        /// shortened form. Not shown otherwise: the chevron is enough when the card already
        /// holds the whole recap, and a permanent "read more" under text that IS the whole
        /// thing would be a small lie.
        static let readFull = "Read the full recap"

        /// VoiceOver hint on the card. The card is already a button, so this says where it
        /// goes rather than repeating "double tap".
        static let openHint = "Opens the full recap for today"

        /// Under the detail's provenance line, when the card above was showing a short form.
        /// Answers the question a person arrives with — "is this the same thing I just read,
        /// or something else?"
        static let cardShowsShortVersion = "Today shows a shorter version of this."
    }
}
