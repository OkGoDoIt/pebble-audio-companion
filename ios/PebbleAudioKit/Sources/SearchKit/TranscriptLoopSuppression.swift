import AppDB
import Foundation

// Render-side use of `TranscriptArtefacts` (AppDB), which carries the rationale, the measured
// numbers and the thresholds.
//
// What a person sees when a cloud model loops today is 1 649 copies of one sentence — a
// transcript that cannot be read or scrolled past, over a room that was in fact silent. The
// honest rendering of that stretch is the one the app already has a word for: QUIET. Not
// "missing" — no audio was lost, the watch sent every frame of it — and the vocabulary in
// `StatusUI/GapStatus.swift` keeps those two apart on purpose.
//
// So suppression here is not deletion. The first occurrence of every repeated line stays on
// screen; the echoes after it stop being rows, and the time they occupied becomes an ordinary
// quiet row through the machinery that already exists, carrying a count of what it stands in
// for. The transcript file on disk is never touched, so the raw text is one re-read away.

/// A stretch of turns that was suppressed, on the provider clock the caller passed in.
public struct SuppressedLoop: Equatable, Sendable {
    public var startMs: Int64
    public var endMs: Int64
    /// Turns hidden — what the quiet row reports so the reader knows something stood here.
    public var turnCount: Int

    public init(startMs: Int64, endMs: Int64, turnCount: Int) {
        self.startMs = startMs
        self.endMs = endMs
        self.turnCount = turnCount
    }
}

/// A transcript with looped artefacts removed, plus what was removed.
public struct LoopFilteredTranscript: Equatable, Sendable {
    public var segments: [TranscriptSegment]
    public var words: [TranscriptWord]
    public var loops: [SuppressedLoop]

    public var isUnchanged: Bool { loops.isEmpty }

    public init(
        segments: [TranscriptSegment], words: [TranscriptWord], loops: [SuppressedLoop] = []
    ) {
        self.segments = segments
        self.words = words
        self.loops = loops
    }
}

/// Removes looped ASR artefacts from one segment's turns, and the word timings that belong to
/// them.
///
/// Both must move together. The only trustworthy correspondence between the turn text and the
/// word list is POSITIONAL — the Nth letter of the transcript is the Nth letter of the words,
/// which is what `TranscriptWordAligner` walks — so dropping turns without dropping their
/// share of the word stream slides every later karaoke highlight by the removed characters. A
/// highlight two seconds out is worse than none, and a loop of six "Yeah."s is enough to do it.
public func filteringLoopedArtefacts(
    segments: [TranscriptSegment],
    words: [TranscriptWord] = []
) -> LoopFilteredTranscript {
    guard segments.count > 1 else {
        return LoopFilteredTranscript(segments: segments, words: words)
    }
    // Chronological order with the blanks dropped, exactly as `coalescedSpeechBlocks` and the
    // word aligner see it — the character stream those two agree on is this one, not the
    // caller's array order. Index breaks ties because Swift's sort is not stable.
    let ordered =
        segments.enumerated()
        .filter { !isBlank($0.element.text) }
        .sorted { left, right in
            left.element.startMs != right.element.startMs
                ? left.element.startMs < right.element.startMs
                : left.offset < right.offset
        }
    let turns = ordered.map {
        ArtefactTurn(text: $0.element.text, startMs: $0.element.startMs)
    }
    let runs = TranscriptArtefacts.loopedArtefactRuns(in: turns)
    guard !runs.isEmpty else {
        return LoopFilteredTranscript(segments: segments, words: words)
    }

    var suppressedIndices = Set<Int>()
    var loops: [SuppressedLoop] = []
    for run in runs {
        for position in run.startIndex..<run.endIndex {
            suppressedIndices.insert(ordered[position].offset)
        }
        // The end of the run is the end of its LAST turn, not that turn's start: the quiet row
        // that replaces it has to cover the whole stretch or the reader sees a phantom pause.
        let last = ordered[run.endIndex - 1].element
        loops.append(
            SuppressedLoop(
                startMs: run.startMs, endMs: max(last.endMs, run.endMs), turnCount: run.count))
    }

    // Significant-character ranges of the suppressed turns, in the order the word stream runs.
    var suppressedCharRanges: [(Int, Int)] = []
    var consumed = 0
    for entry in ordered {
        let length = significantCharacterCount(entry.element.text)
        if suppressedIndices.contains(entry.offset), length > 0 {
            if var last = suppressedCharRanges.last, last.1 == consumed {
                last.1 = consumed + length
                suppressedCharRanges[suppressedCharRanges.count - 1] = last
            } else {
                suppressedCharRanges.append((consumed, consumed + length))
            }
        }
        consumed += length
    }

    let keptSegments = segments.enumerated()
        .filter { !suppressedIndices.contains($0.offset) }
        .map(\.element)
    return LoopFilteredTranscript(
        segments: keptSegments,
        words: filteringWords(words, droppingCharacterRanges: suppressedCharRanges),
        loops: loops)
}

/// Drops the words whose characters fall inside a suppressed turn. Words are walked in the same
/// order the aligner walks them (blank-free, sorted by start), so the running character offset
/// is the same offset the turn ranges were measured on.
private func filteringWords(
    _ words: [TranscriptWord], droppingCharacterRanges ranges: [(Int, Int)]
) -> [TranscriptWord] {
    guard !words.isEmpty, !ranges.isEmpty else { return words }
    let ordered =
        words.enumerated()
        .filter { !isBlank($0.element.text) }
        .sorted { left, right in
            left.element.startMs != right.element.startMs
                ? left.element.startMs < right.element.startMs
                : left.offset < right.offset
        }
    var dropped = Set<Int>()
    var consumed = 0
    var rangeIndex = 0
    for entry in ordered {
        let length = significantCharacterCount(entry.element.text)
        while rangeIndex < ranges.count, ranges[rangeIndex].1 <= consumed { rangeIndex += 1 }
        if rangeIndex < ranges.count, consumed >= ranges[rangeIndex].0,
            consumed < ranges[rangeIndex].1, length > 0
        {
            dropped.insert(entry.offset)
        }
        consumed += length
    }
    guard !dropped.isEmpty else { return words }
    return words.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
}

/// Letters and digits only — the same measure `TranscriptWordAligner` uses to line the two
/// streams up. Whitespace and punctuation move around between them; letters do not.
func significantCharacterCount(_ text: String) -> Int {
    text.reduce(0) { $0 + (($1.isLetter || $1.isNumber) ? 1 : 0) }
}

private func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
