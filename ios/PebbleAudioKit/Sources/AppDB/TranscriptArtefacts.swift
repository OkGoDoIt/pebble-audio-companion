import Foundation

// Looped-ASR-artefact detection, measured on Roger's real library (591 transcripts,
// 74 125 diarized turns, 517 236 words, 2026-06-12 → 2026-09-08).
//
// WHY THIS EXISTS
//
// Cloud speech models do not fail on silence by returning nothing. They loop. One 15-minute
// recording in that library contains 12 439 words, 1 649 of them the identical sentence
// "I'm going to bring you some cookies." — 99% of the segment, over roughly ten minutes of a
// room whose decoded audio never rose above its own noise floor. That one phrase is 2.2% of
// every turn in the library: the second most common utterance in it, ahead of "okay". The
// diarizer happily splits the loop between two alternating speakers, so turn-taking is no
// defence. Corpus-wide the rules below account for 5 840 turns and 25 669 words (5.0%),
// concentrated in 44 of 589 segments; six segments are 47–99% artefact.
//
// WHY IT LIVES IN AppDB
//
// Two very different consumers need the SAME verdicts: the transcript renderer (SearchKit) and
// everything that feeds text to a model (Intelligence). SearchKit deliberately does not depend
// on Transcription, and Intelligence does not depend on SearchKit, so AppDB — which both
// already depend on and which already holds pure conversation logic — is their lowest common
// module. Nothing here touches a database.
//
// THE DESIGN CONSTRAINT THAT SHAPED EVERY THRESHOLD
//
// Wrongly hiding one real sentence is far worse than leaving ten invented ones visible: this is
// a background-microphone product and the transcript is the record. So a turn is suppressed
// only when BOTH of these hold:
//
//   1. it is an ECHO — it introduces no phrase that has not already been said in the preceding
//      two minutes of the same recording, and
//   2. it sits in a LOOP CONTEXT — a run of identical consecutive turns, or a stretch whose
//      phrase diversity has collapsed.
//
// Condition 1 alone over-fires: 0.6% of turns in otherwise-clean segments repeat all of their
// own 4-grams, and reading them shows ordinary speech ("Yesterday I was looking at recipes,").
// Condition 2 alone over-fires far worse: it swallows the real sentences interleaved between
// loop bursts. Together they gave zero false positives on a full read of every flagged run in
// the 44 smaller affected segments.
//
// The pair also buys a STRUCTURAL guarantee that no statistical precision figure can: because a
// suppressed turn contains no phrase that is not still present within two minutes of it, even a
// wrong verdict cannot remove information from the record. And nothing here writes to disk —
// the provider's transcript file is never modified, so every verdict is re-derivable and
// reversible by not calling this.
//
// WHAT THIS DELIBERATELY DOES NOT CATCH
//
// The other artefact class is sporadic, non-repeating, plausible-sounding confabulation over
// room noise ("Senyor mestre.", "the planning of the group ... planning for the planning").
// It was measured and it does not separate: the worst example's 5-gram diversity is 0.539,
// while genuinely clean segments in the same library go down to 0.355. Decoding the stored
// Speex and gating on loudness does not separate it either — the confabulated segment sits at
// p95 RMS 59 and a real but quiet conversation at 91. Guessing there would cost real speech,
// so it is left visible. The honest fix for that class is upstream: do not ask a model to
// transcribe silence (watch-side VAD, which currently never fires, or a phone-side energy gate
// before upload).

/// One provider turn, reduced to what artefact detection needs. Deliberately not tied to any
/// module's transcript type: SearchKit and Intelligence each have their own.
public struct ArtefactTurn: Equatable, Sendable {
    public var text: String
    public var startMs: Int64

    public init(text: String, startMs: Int64) {
        self.text = text
        self.startMs = startMs
    }
}

public enum TranscriptArtefacts {
    // MARK: - Tuning
    //
    // Every number here was chosen against the measured library, erring toward leaving text
    // visible. Changing one is a decision about someone's record of their own life; the
    // comment on each says what it is protecting.

    /// How far back a phrase counts as "already said". Two minutes is long enough to span the
    /// worst observed loop bursts and short enough that a genuine callback to something said
    /// earlier in a conversation is not treated as an echo.
    public static let lookbackMs: Int64 = 120_000

    /// Phrase length for the echo test. Shorter turns are compared whole. Four tokens is the
    /// shortest window at which ordinary conversation stops colliding with itself: at three,
    /// real speech repeats its own phrases often enough to matter.
    public static let echoPhraseTokens = 4

    /// Identical consecutive turns needed to call a run a loop, when the repeated line has at
    /// least `runMinWords` words. Three is safe because the FIRST occurrence is always kept.
    public static let runMinRepeats = 3
    public static let runMinWords = 3

    /// ... and when the repeated line is one or two words ("Yeah.", "Okay."). Six, because
    /// three consecutive "yeah"s is a thing people do and nine hundred is not.
    public static let shortRunMinRepeats = 6

    /// The bounded window the diversity test looks at, and the token floor below which the
    /// ratio is too noisy to trust.
    public static let loopWindowMs: Int64 = 90_000
    public static let loopWindowMinTokens = 60

    /// Distinct n-grams ÷ total n-grams, below which a window counts as degenerate. Real
    /// conversation in the measured library never came close: across 537 segments with no
    /// artefact at all, the LOWEST 90-second window diversity was 0.355 and the 1st percentile
    /// 0.615. Loop windows sit at 0.02–0.10. 0.20 is in the empty space between them.
    public static let loopPhraseTokens = 5
    public static let loopMaxDiversity = 0.20

    /// A contiguous stretch of suppressed turns.
    public struct Run: Equatable, Sendable {
        /// Index of the first suppressed turn, and one past the last.
        public var startIndex: Int
        public var endIndex: Int
        /// Turn start of the first suppressed turn (provider clock, as given).
        public var startMs: Int64
        /// Turn start of the last suppressed turn.
        public var endMs: Int64

        public var count: Int { endIndex - startIndex }

        public init(startIndex: Int, endIndex: Int, startMs: Int64, endMs: Int64) {
            self.startIndex = startIndex
            self.endIndex = endIndex
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    /// Per-turn verdicts: `true` means "a looped artefact — safe to hide, never to delete".
    /// The first occurrence of any repeated line is always `false`, so the reader still sees
    /// what was said, once.
    public static func loopedArtefacts(in turns: [ArtefactTurn]) -> [Bool] {
        let count = turns.count
        guard count > 1 else { return Array(repeating: false, count: count) }

        // Tokens are interned to Int32 ids up front so every phrase below is a fixed-size
        // value with no allocation and no string hashing. This runs on the main actor while
        // the transcript screen builds its rows, over segments that reach two thousand turns,
        // and the string-keyed version of it cost milliseconds per member.
        var vocabulary: [String: Int32] = [:]
        let tokens: [[Int32]] = turns.map { turn in
            tokenize(turn.text).map { token in
                if let id = vocabulary[token] { return id }
                let id = Int32(vocabulary.count)
                vocabulary[token] = id
                return id
            }
        }
        let echo = echoCandidates(turns, tokens)
        // Nothing can be suppressed without an echo, so a recording with none skips both
        // context passes. Worth the branch: this runs on the main actor while the transcript
        // screen builds its rows, and the pathological segment in the measured library is
        // 1 894 turns (≈11 ms end to end on a development Mac, ≈0.5–2 ms for a normal one).
        guard echo.contains(true) else { return Array(repeating: false, count: count) }
        let identicalRun = identicalRuns(tokens)
        let degenerate = degenerateWindows(turns, tokens)

        var verdicts = Array(repeating: false, count: count)
        for index in 0..<count {
            verdicts[index] = echo[index] && (identicalRun[index] || degenerate[index])
        }
        return verdicts
    }

    /// The same verdicts, grouped into contiguous runs — what a renderer needs to say "412
    /// repeated lines hidden" on one row instead of leaving 412 holes.
    public static func loopedArtefactRuns(in turns: [ArtefactTurn]) -> [Run] {
        let verdicts = loopedArtefacts(in: turns)
        var runs: [Run] = []
        var index = 0
        while index < verdicts.count {
            guard verdicts[index] else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < verdicts.count, verdicts[end + 1] { end += 1 }
            runs.append(
                Run(
                    startIndex: index, endIndex: end + 1,
                    startMs: turns[index].startMs, endMs: turns[end].startMs))
            index = end + 1
        }
        return runs
    }

    // MARK: - Condition 1: echo

    /// True where the turn introduces no phrase that was not already said inside `lookbackMs`.
    /// Sliding window over turns with a phrase multiset, so this is linear in total tokens.
    private static func echoCandidates(
        _ turns: [ArtefactTurn], _ tokens: [[Int32]]
    ) -> [Bool] {
        var seen: [Phrase: Int] = [:]
        var candidates = Array(repeating: false, count: turns.count)
        var low = 0
        for index in turns.indices {
            while low < index, turns[index].startMs - turns[low].startMs > lookbackMs {
                for phrase in phrases(tokens[low], length: echoPhraseTokens) {
                    if let existing = seen[phrase], existing > 1 {
                        seen[phrase] = existing - 1
                    } else {
                        seen[phrase] = nil
                    }
                }
                low += 1
            }
            let mine = phrases(tokens[index], length: echoPhraseTokens)
            candidates[index] = !mine.isEmpty && mine.allSatisfy { seen[$0] != nil }
            for phrase in mine { seen[phrase, default: 0] += 1 }
        }
        return candidates
    }

    // MARK: - Condition 2a: identical consecutive runs

    private static func identicalRuns(_ tokens: [[Int32]]) -> [Bool] {
        var inRun = Array(repeating: false, count: tokens.count)
        var index = 0
        while index < tokens.count {
            var end = index
            while end + 1 < tokens.count, !tokens[index].isEmpty, tokens[end + 1] == tokens[index] {
                end += 1
            }
            if !tokens[index].isEmpty {
                let needed = tokens[index].count >= runMinWords ? runMinRepeats : shortRunMinRepeats
                if end - index + 1 >= needed {
                    for position in index...end { inRun[position] = true }
                }
            }
            index = end + 1
        }
        return inRun
    }

    // MARK: - Condition 2b: collapsed phrase diversity

    /// True where the bounded window STARTING at this turn has distinct-n-gram ratio below
    /// `loopMaxDiversity`. Both window edges advance monotonically, so the phrase multiset is
    /// maintained incrementally rather than rebuilt per turn — a segment in this library can
    /// hold nearly two thousand turns stamped at the same millisecond, which is exactly the
    /// shape that turns a rebuild-per-turn scan into a visible stall.
    private static func degenerateWindows(
        _ turns: [ArtefactTurn], _ tokens: [[Int32]]
    ) -> [Bool] {
        // Flatten to one token stream; turn i owns tokens [turnStart[i], turnStart[i + 1]).
        var turnStart = [Int](repeating: 0, count: tokens.count + 1)
        var flat: [Int32] = []
        for (index, turnTokens) in tokens.enumerated() {
            turnStart[index] = flat.count
            flat.append(contentsOf: turnTokens)
        }
        turnStart[tokens.count] = flat.count
        let gramLength = loopPhraseTokens
        guard flat.count >= gramLength else {
            return Array(repeating: false, count: tokens.count)
        }
        // Gram at position p covers flat[p ..< p + gramLength]; the last valid p is
        // flat.count - gramLength.
        let lastGram = flat.count - gramLength

        var counts: [Phrase: Int] = [:]
        var distinct = 0
        var total = 0
        var addedThrough = 0  // one past the highest gram position added
        var removedThrough = 0  // one past the highest gram position removed

        func add(_ position: Int) {
            let phrase = Phrase(flat, position, gramLength)
            let existing = counts[phrase] ?? 0
            if existing == 0 { distinct += 1 }
            counts[phrase] = existing + 1
            total += 1
        }
        func remove(_ position: Int) {
            let phrase = Phrase(flat, position, gramLength)
            guard let existing = counts[phrase] else { return }
            if existing <= 1 {
                counts[phrase] = nil
                distinct -= 1
            } else {
                counts[phrase] = existing - 1
            }
            total -= 1
        }

        var degenerate = Array(repeating: false, count: tokens.count)
        var high = 0
        for index in tokens.indices {
            if high < index { high = index }
            while high < tokens.count, turns[high].startMs - turns[index].startMs <= loopWindowMs {
                high += 1
            }
            // Grams fully inside the window's token range [turnStart[index], turnStart[high]).
            let windowLow = turnStart[index]
            let windowHigh = turnStart[high]
            let gramLimit = min(max(windowHigh - gramLength + 1, windowLow), lastGram + 1)
            while addedThrough < gramLimit {
                add(addedThrough)
                addedThrough += 1
            }
            while removedThrough < windowLow, removedThrough < addedThrough {
                remove(removedThrough)
                removedThrough += 1
            }
            let windowTokens = windowHigh - windowLow
            guard windowTokens >= loopWindowMinTokens, total > 0 else { continue }
            if Double(distinct) / Double(total) < loopMaxDiversity {
                for position in index..<high { degenerate[position] = true }
            }
        }
        return degenerate
    }

    // MARK: - Text handling

    /// Lowercased word tokens. Punctuation and casing carry no information for this: the
    /// provider splits the SAME looped sentence into "I'm going to bring y" / "ou some cookies."
    /// mid-word, so only the letters line up.
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || character == "'" {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// A turn's phrases: its n-grams, or the whole turn when it is shorter than `length`.
    /// Falls back to the whole turn rather than skipping it, because "Yeah." has to be
    /// comparable to the four hundred "Yeah."s around it.
    private static func phrases(_ tokens: [Int32], length: Int) -> [Phrase] {
        guard !tokens.isEmpty else { return [] }
        guard tokens.count >= length else { return [Phrase(tokens, 0, tokens.count)] }
        return (0...(tokens.count - length)).map { Phrase(tokens, $0, length) }
    }

    /// A short run of interned token ids as a fixed-size value: no allocation, no string
    /// hashing, synthesized equality. Five slots covers both users — the echo test's 4-grams
    /// (and whole turns of 1–3 tokens) and the diversity test's 5-grams — and a longer phrase
    /// would be a bug, so it traps rather than silently truncating into a false match.
    private struct Phrase: Hashable {
        private var a: Int32 = -1
        private var b: Int32 = -1
        private var c: Int32 = -1
        private var d: Int32 = -1
        private var e: Int32 = -1
        private var count: Int32 = 0

        init(_ tokens: [Int32], _ start: Int, _ length: Int) {
            precondition(length <= 5, "phrase longer than the fixed slots")
            count = Int32(length)
            if length > 0 { a = tokens[start] }
            if length > 1 { b = tokens[start + 1] }
            if length > 2 { c = tokens[start + 2] }
            if length > 3 { d = tokens[start + 3] }
            if length > 4 { e = tokens[start + 4] }
        }
    }
}
