import AppDB
import Foundation

// A conversation owns a RANGE of a segment's stored audio (`ConversationMember`), so whoever
// reads "the transcript of a conversation" has to read the part of each member's transcript
// that falls in its piece — not the whole file. This is the one place that cut is made.

extension SegmentTranscript {
    /// The part of this transcript that belongs to `member`'s piece of the segment.
    ///
    /// A turn belongs to the piece its first instant falls in (`ConversationMember.contains`),
    /// so every turn is in exactly one conversation. Timings are left in the segment's own
    /// media clock: they still index the same stored audio. A whole-segment piece returns the
    /// transcript untouched.
    public func piece(_ member: ConversationMember) -> SegmentTranscript {
        guard !member.isWhole else { return self }
        guard !segments.isEmpty else {
            // No timings to cut by: the text goes, whole, to the piece that starts the segment.
            var copy = self
            if member.startMediaMs != nil {
                copy.text = ""
                copy.words = []
            }
            return copy
        }
        var copy = self
        copy.segments = segments.filter { member.contains(mediaMs: $0.startMs) }
        copy.words = words.filter { member.contains(mediaMs: $0.startMs) }
        copy.text = copy.segments.map(\.text).joined(separator: " ")
        return copy
    }
}
