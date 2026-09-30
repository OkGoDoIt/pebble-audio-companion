import Foundation

// Opening a conversation at a wall-clock moment (History plan 7.9): the transcript scrolled to
// that time and the player cued there, with nothing highlighted.
//
// A moment is not a citation. A citation names a stretch somebody quoted, and the screen bands
// the lines inside it; a moment is a place on the clock — a chapter's start, a tap on the day —
// and may fall where nobody said anything at all. So it cannot ask for a row INSIDE a window,
// which is what a citation's focus needs; it asks for the row it would be reading at that time.

/// Where a moment lands.
enum MomentResolver {
    /// The transcript row a moment lands on: the last row starting at or before `wallMs`, or —
    /// when every timed row starts after it — the first row after it. Nil only when no row has
    /// a time to compare (an empty transcript, or a mock fixture with no stamps).
    ///
    /// Rows are compared by their stamps, not by position: a conversation whose members overlap
    /// can put a row out of time order, and "the last row in the list that starts before" would
    /// then land on the stray row rather than on what was being said. Equal stamps resolve to
    /// the later row going back and the earlier row going forward, which in a well-ordered
    /// transcript is simply the last and the first.
    ///
    /// A marker counts as a row: a moment inside a quiet stretch lands on "quiet for 25 min",
    /// which is the honest answer to "what was happening then?".
    static func rowIndex(in transcript: [TranscriptItem], atWallMs wallMs: Int64) -> Int? {
        var atOrBefore: (index: Int, ms: Int64)?
        var after: (index: Int, ms: Int64)?
        for (index, item) in transcript.enumerated() {
            guard let startedAt = item.startedAt else { continue }
            let ms = Int64((startedAt.timeIntervalSince1970 * 1000).rounded())
            if ms <= wallMs {
                if ms >= (atOrBefore?.ms ?? .min) { atOrBefore = (index, ms) }
            } else if ms < (after?.ms ?? .max) {
                after = (index, ms)
            }
        }
        return atOrBefore?.index ?? after?.index
    }
}
