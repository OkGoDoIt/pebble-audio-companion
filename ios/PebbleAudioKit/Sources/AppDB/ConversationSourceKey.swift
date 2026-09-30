import Foundation

// WHICH PIECES something derived from a conversation was derived from.
//
// A conversation's id is a position, not a content hash: when a conversation is cut in two, its
// first part keeps the id (`ConversationGrouper.adoptStableIds`), and on the first run after
// conversations became topic-sized every conversation in the library was cut into several. So a
// record keyed by conversation id — a title, above all — can outlive the audio it was written
// about: the ten minutes that inherit a ten-hour conversation's id would inherit its title too.
//
// The key is the conversation's piece list written out: segment ids and media ranges, never a
// word of transcript. Whoever stores something derived from a conversation stores the key beside
// it (`annotations.sourceKey`), and compares on the way back in.
//
// It is deliberately a readable list rather than a hash, because one change to a conversation
// must NOT count as a change: retention deletes the oldest audio a segment at a time, so the
// conversation at the edge of the window loses its leading pieces while what is left is exactly
// what it was. Re-titling it — a model call for a conversation that will be gone by the next
// sweep, once per evicted segment, for as long as the recorder runs — is pure waste, and only
// the list itself can say "what is left is the tail of what I was written from".

public enum ConversationSourceKey {
    /// The key of an ordered piece list. Stable across launches; changes when a piece is added,
    /// removed, or has either end of its range moved.
    public static func key(of pieces: [ConversationMember]) -> String {
        pieces.map(entry).joined(separator: separator)
    }

    /// Whether something stored under `stored` still describes a conversation whose pieces now
    /// have the key `current`.
    ///
    /// True when the two are the same, and when `current` is what remains of `stored` after
    /// whole leading pieces were removed (see the note at the top of this file). A missing or
    /// empty `stored` — every row written before the key existed — describes nothing.
    public static func describes(stored: String?, current: String) -> Bool {
        guard let stored, !stored.isEmpty, !current.isEmpty else { return false }
        return stored == current || stored.hasSuffix(separator + current)
    }

    /// Segment ids are `seg-<ms>-<hex>-<n>`: none of the punctuation below can occur in one.
    private static let separator = ";"

    private static func entry(_ piece: ConversationMember) -> String {
        let start = piece.startMediaMs ?? 0
        let end = piece.endMediaMs.map { String($0) } ?? ""
        return "\(piece.segmentId)@\(start)-\(end)"
    }
}
