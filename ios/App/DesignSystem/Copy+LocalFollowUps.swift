import Foundation

// What the follow-up list says when the suggestions came from the on-device reader rather than
// the cloud one.
//
// This exists because the two are honestly not the same product, and the measurement is not
// close. Over twenty conversations from real capture, hand-labelled (eight genuine follow-ups
// in 149,343 characters), the on-device pipeline returned four items: three of the eight, one
// defensible, and nothing plainly wrong — but it never saw five of the eight at all, and it
// cannot resolve a date, so nothing it proposes carries one. A list built that way is worth
// having. What it cannot survive is somebody believing it is as thorough as the cloud reader,
// because then an empty list reads as "nothing this week", and that is an absence which means
// nothing at all.
//
// Vocabulary rules that apply here:
// - "On this iPhone" (or iPad), never "on-device", "local", "Apple Intelligence" or "the model".
//   The person chose private processing; the sentence should sound like that choice, not like
//   an apology for a component.
// - Say what it does and does not do in plain terms — "fewer", "never dated", "misses plenty" —
//   and never a percentage or a score. A number here would be false precision about one
//   person's twenty conversations.
// - Never "might be wrong" as the whole message. It has to say what to DO about it, which is
//   why every string ends on the recording: the quote and the moment are one tap away, and
//   checking one is quicker than reading this sentence.
extension Copy {
    enum LocalFollowUps {
        /// One line under the list heading, whenever the proposals on screen were found on this
        /// device. Short enough to sit above the first row without pushing it off screen.
        ///
        /// It leads with what is missing rather than with what might be wrong, because that is
        /// the half the measurement is certain about: five of the eight follow-ups a careful
        /// reader found never appeared here at all, and no on-device proposal carries a date.
        static let banner =
            "Found on this iPhone — fewer, and never dated. Tap one to hear what was said."

        /// The same fact for VoiceOver, where the trailing clause reads as an instruction
        /// rather than a hint.
        static let bannerA11y =
            "These follow-ups were found on this iPhone. It finds fewer than cloud processing, "
            + "never suggests a due date, and can be wrong. Open a follow-up to hear the moment "
            + "it came from."

        /// The empty state, in place of `Copy.FollowUps.emptyOpenBodySuggested`. The cloud
        /// version's "things you say you will do turn up here" promises more than this reader
        /// delivers, and an empty list would then read as "you promised nothing this week".
        static let emptyOpenBody =
            "Some of the things you say you will do turn up here, found on this iPhone. "
            + "It misses plenty."

        /// Settings, where someone is choosing between processing modes and deserves the trade
        /// stated before they make it rather than discovered afterwards.
        /// No claim here about how often it is wrong: on the panel nothing it showed was, but
        /// four items is far too few to promise that, and a promise is what a settings footnote
        /// reads as. What can be promised is that every row carries the words it came from.
        static let settingsFootnote =
            "With processing kept on this iPhone, follow-ups are found here too — fewer of "
            + "them, and with no due dates. Each one shows the words it came from, so you can "
            + "check it."
    }
}
