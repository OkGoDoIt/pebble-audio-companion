import Foundation

// The recap card's tap affordance and the pushed detail's provenance (session: "'today so far'
// … takes up too much visual space … tapping it should take you to the full extended view").
//
// Vocabulary rule for this area: the card never claims to be the whole recap when it is not,
// and the detail never presents itself as a different document. There is ONE recap of the day
// and the card is a shorter reading of it — said by the chevron on the card and by the full
// text on the screen it opens, not by a caption on either.
//
// Kept out of `Copy.swift` because that file is the shared catalog and very hot; this is a
// self-contained vocabulary belonging to one card and one pushed screen.

extension Copy {
    enum Recap {

        /// VoiceOver hint on the card. The card is already a button, so this says where it
        /// goes rather than repeating "double tap".
        static let openHint = "Opens the full recap for today"

        // `cardShowsShortVersion` ("Today shows a shorter version of this.") sat under the
        // detail's provenance line and is gone with the card's own "Read the full recap":
        // arriving at a longer version of what you just tapped needs no announcement.
    }
}
