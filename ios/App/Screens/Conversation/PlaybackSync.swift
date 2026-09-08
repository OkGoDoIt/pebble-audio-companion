import Foundation
import SwiftUI

// Following along: keeping the transcript and the audio pointing at the same instant, in both
// directions.
//
// Everything here is pure so it can be pinned by `AppTests/PlaybackSyncTests.swift` — the
// screen has no way to prove "the right word is lit" by eye at 1.5×, and an off-by-a-clock
// mapping is invisible until you notice the highlight is always a sentence ahead.
//
// One rule runs through all of it: the transcript's positions and the player's position are
// both MEDIA time (stored audio, gaps excluded). Wall time never appears below.

// MARK: - Where the playhead is

/// The transcript position the audio is currently at.
struct TranscriptPlayheadPosition: Equatable {
    var turnId: String
    /// Index into that turn's `words`. Nil when the turn carries no word timings — the whole
    /// turn is then the finest thing we honestly know, and the whole turn is what lights up.
    var wordIndex: Int?
}

/// A conversation's transcript, indexed for "which word is playing at t?".
///
/// Built once per transcript load and searched at the player's tick rate, so both levels are
/// binary searches: a two-hour conversation is tens of thousands of words and this runs on the
/// main actor.
struct TranscriptPlayheadIndex: Equatable {
    /// A turn's extent on the scrubber.
    struct TurnRange: Equatable {
        var id: String
        var startMs: Int64
        var endMs: Int64
        /// Offset of this turn's first word in `wordStarts`, and how many it has.
        var firstWord: Int
        var wordCount: Int
    }

    private(set) var turns: [TurnRange] = []
    /// Every word span's start, flattened in reading order — the array the search runs over.
    private(set) var wordStarts: [Int64] = []

    /// A turn keeps the highlight for a moment after its last word so a half-second of breath
    /// between two paragraphs does not blank the transcript out and back in.
    static let turnHoldMs: Int64 = 1_200
    /// A turn with no end timing is assumed to run this long, so it cannot swallow the rest of
    /// the recording.
    static let assumedTurnMs: Int64 = 8_000

    init() {}

    init(_ transcript: [TranscriptItem]) {
        var ranges: [TurnRange] = []
        var starts: [Int64] = []
        for item in transcript {
            guard case .turn(let turn) = item, let start = turn.mediaOffsetMs else { continue }
            let firstWord = starts.count
            for span in turn.words { starts.append(span.mediaStartMs) }
            let wordEnd = turn.words.last?.mediaEndMs
            let end = max(turn.mediaEndMs ?? wordEnd ?? (start + Self.assumedTurnMs), start)
            ranges.append(
                TurnRange(
                    id: turn.id, startMs: start, endMs: end,
                    firstWord: firstWord, wordCount: turn.words.count))
        }
        // Reading order is not guaranteed to be scrubber order across a member boundary that
        // stored nothing, and the search below needs it to be.
        let order = ranges.indices.sorted { ranges[$0].startMs < ranges[$1].startMs }
        turns = order.map { ranges[$0] }
        wordStarts = starts
        // A turn that ends after the next one starts would keep the highlight on the wrong
        // paragraph for the overlap; clip it to its successor.
        for index in turns.indices.dropLast() {
            turns[index].endMs = min(turns[index].endMs, turns[index + 1].startMs)
        }
    }

    var isEmpty: Bool { turns.isEmpty }

    /// True when at least one turn has word timings — what the screen uses to decide whether it
    /// may claim word-level precision at all.
    var hasWordTimings: Bool { !wordStarts.isEmpty }

    /// The transcript position for a scrubber position, or nil when the audio playing right now
    /// has no transcript under it (a stretch of noise, or before the first word).
    func position(atMediaMs mediaMs: Int64) -> TranscriptPlayheadPosition? {
        guard let index = lastIndex(notAfter: mediaMs, count: turns.count, at: { turns[$0].startMs })
        else { return nil }
        let turn = turns[index]
        guard mediaMs < turn.endMs + Self.turnHoldMs else { return nil }
        guard turn.wordCount > 0 else {
            return TranscriptPlayheadPosition(turnId: turn.id, wordIndex: nil)
        }
        // The last word that has STARTED keeps the highlight until the next one starts, so the
        // marker never blinks off in the pause between two words.
        guard
            let word = lastIndex(
                notAfter: mediaMs, count: turn.wordCount,
                at: { wordStarts[turn.firstWord + $0] })
        else {
            return TranscriptPlayheadPosition(turnId: turn.id, wordIndex: nil)
        }
        return TranscriptPlayheadPosition(turnId: turn.id, wordIndex: word)
    }

    /// Largest index whose key is <= `value`; nil when every key is after it.
    private func lastIndex(
        notAfter value: Int64, count: Int, at key: (Int) -> Int64
    ) -> Int? {
        guard count > 0, key(0) <= value else { return nil }
        var low = 0
        var high = count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if key(mid) <= value {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}

// MARK: - Observable playhead

/// The one place the transcript reads "where are we now" from.
///
/// It is a separate observable object rather than two more fields on `PlayerModel` so that the
/// player's 10 Hz position updates do not re-run the conversation screen's body: only the views
/// that actually read `turnId` (the transcript rows) and `wordIndex` (the one active row) are
/// invalidated, and `wordIndex` changes are confined to a single paragraph.
@MainActor
@Observable
final class TranscriptPlayhead {
    /// The turn under the playhead; nil when nothing is playing there.
    private(set) var turnId: String?
    /// Which word of that turn, when the transcript has word timings for it.
    private(set) var wordIndex: Int?
    /// True while audio is actually moving. The highlight persists while paused (you paused to
    /// read it) but the transcript stops auto-scrolling and the player stops docking.
    private(set) var isPlaying = false

    /// Nothing on screen announces whether this transcript has word timings. A recording that
    /// only has paragraph timings highlights paragraphs and says nothing about it; a label
    /// claiming word accuracy would be a lie on exactly the recordings where it matters, and a
    /// label apologising for its absence would be noise on all the others.
    private var index = TranscriptPlayheadIndex()

    func load(transcript: [TranscriptItem]) {
        index = TranscriptPlayheadIndex(transcript)
    }

    /// Point the playhead at a scrubber position. Cheap enough to call on every tick.
    func update(mediaMs: Int64, playing: Bool) {
        // Every field is assigned only on change. `@Observable` notifies on every WRITE, not on
        // every change, so writing the same values ten times a second would invalidate every
        // transcript row ten times a second — which is the cost this whole arrangement exists
        // to avoid.
        if isPlaying != playing { isPlaying = playing }
        let position = index.position(atMediaMs: mediaMs)
        if position?.turnId != turnId { turnId = position?.turnId }
        if position?.wordIndex != wordIndex { wordIndex = position?.wordIndex }
    }

    func clear() {
        if turnId != nil { turnId = nil }
        if wordIndex != nil { wordIndex = nil }
        if isPlaying { isPlaying = false }
    }
}

// MARK: - Tap → position

/// Resolving a tap on a paragraph to the word under the finger.
///
/// A transcript turn is ONE `Text`. That is deliberate: it keeps the app's main reading surface
/// rendering with real line breaking, and it keeps a two-hour transcript at a few hundred views
/// instead of tens of thousands. The cost is that SwiftUI will not tell us which character was
/// hit, so this reconstructs it from the paragraph's own geometry — how many lines it wrapped
/// to, which line the tap was on, and how far across.
///
/// The approximation is the assumption that characters are spread evenly down the paragraph. It
/// is good to about a word in the body of a paragraph and degrades on a short last line, where
/// it can run past the end (clamped). Compared with the alternative on offer — seeking to the
/// start of the whole paragraph, ten to fifteen seconds earlier — it is a large improvement,
/// and the result is always snapped to a real word boundary, so it never lands mid-word.
enum TranscriptTapGeometry {
    /// Character offset (into the paragraph's text) a tap landed on.
    ///
    /// - Parameters:
    ///   - point: tap location in the paragraph's own coordinate space.
    ///   - size: the paragraph's rendered size.
    ///   - lineHeight: height of ONE line of the paragraph's font, measured live rather than
    ///     assumed, because Dynamic Type moves it.
    ///   - lineSpacing: the `.lineSpacing` the paragraph is rendered with.
    static func characterOffset(
        at point: CGPoint,
        in size: CGSize,
        lineHeight: CGFloat,
        lineSpacing: CGFloat,
        characterCount: Int
    ) -> Int {
        guard characterCount > 0, size.width > 0, size.height > 0, lineHeight > 0 else { return 0 }
        let step = lineHeight + lineSpacing
        // SwiftUI puts spacing BETWEEN lines, so n lines measure n·height + (n−1)·spacing.
        // Adding one spacing back makes that divide exactly.
        let lines = max(Int(((size.height + lineSpacing) / step).rounded()), 1)
        let line = min(max(Int(point.y / step), 0), lines - 1)
        let across = min(max(point.x / size.width, 0), 1)
        let fraction = (CGFloat(line) + across) / CGFloat(lines)
        // Rounded, not truncated: the fractions here are thirds and halves, and truncating
        // 14.999999 to 14 would put a tap on the wrong side of a word boundary for no reason.
        let offset = Int((fraction * CGFloat(characterCount)).rounded())
        return min(max(offset, 0), characterCount - 1)
    }

    /// The word span covering a character offset — the one whose range contains it, else the
    /// last one that starts before it (punctuation and the trailing edge of a line).
    static func wordIndex(forCharacterOffset offset: Int, in spans: [TranscriptWordSpan]) -> Int? {
        guard !spans.isEmpty else { return nil }
        if offset < spans[0].start { return 0 }
        var low = 0
        var high = spans.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if spans[mid].start <= offset {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// Where a tap on a turn should send the scrubber. Falls back to the turn's own start when
    /// the transcript has no word timings for it, which is the honest coarse answer.
    static func seekTarget(
        at point: CGPoint,
        in size: CGSize,
        lineHeight: CGFloat,
        lineSpacing: CGFloat,
        turn: TranscriptTurn
    ) -> Int64? {
        guard !turn.words.isEmpty else { return turn.mediaOffsetMs }
        let offset = characterOffset(
            at: point, in: size, lineHeight: lineHeight, lineSpacing: lineSpacing,
            characterCount: turn.text.count)
        guard let index = wordIndex(forCharacterOffset: offset, in: turn.words) else {
            return turn.mediaOffsetMs
        }
        return turn.words[index].mediaStartMs
    }
}

// MARK: - Tap cadence

/// Single tap seeks; a quick second tap also starts playing.
///
/// Composing `.onTapGesture(count: 2)` beside a single-tap gesture would make EVERY single tap
/// wait out the double-tap window before it did anything — on a transcript, where the single tap
/// is the common move, that reads as a broken screen. So there is only ever one tap gesture, and
/// the second tap is recognised after the fact from its timestamp: the first tap seeks
/// immediately, and if a second lands within the window it starts playback. Seeking twice to the
/// same word is a no-op, so nothing has to be undone.
struct TapCadence {
    /// iOS's own double-tap window.
    static let windowMs: Double = 300

    private var lastTapAt: Date?

    /// Records a tap and says whether it completed a double.
    mutating func register(now: Date = Date()) -> Bool {
        defer { lastTapAt = now }
        guard let lastTapAt else { return false }
        return now.timeIntervalSince(lastTapAt) * 1000 <= Self.windowMs
    }
}
