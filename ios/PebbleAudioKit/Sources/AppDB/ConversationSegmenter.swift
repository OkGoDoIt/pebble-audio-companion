import Foundation

// Where one conversation ends and the next begins INSIDE continuous talk.
//
// WHY THIS EXISTS. The grouper used to cut only where the record went quiet for 15 minutes, and
// only at a 15-minute file rotation. Scored against 384 hand-marked conversation starts on eight
// of Roger's real days (2026-09-19 … 09-29; 199 of them `certain`), that rule finds 13% of the
// certain ones and produces units with a median of 1 h 06 m, a p90 of 4 h 24 m and a longest of
// 9 h 48 m, where the marked conversations have a median of 9 minutes and a p90 of 26. Cutting at
// every pause instead does not work either: pauses of 3 minutes or more find 58% of the certain
// starts, but half of those cuts land inside one conversation (a pause is as likely to be
// somebody thinking as somebody leaving), a third of the pieces are under two minutes, and
// sixteen are still over an hour because the talk never paused. A conversation is not defined by
// silence.
//
// WHAT IT DOES INSTEAD. It treats a stretch of talk as a sequence of short BLOCKS (a few turns
// with no more than a few seconds between them) and chooses, among all the ways of dividing
// the blocks into consecutive units, the one with the best total score — an exact search
// (dynamic programming over "best division of everything up to this block"), not a greedy walk.
// A division scores well when
//   - each unit is ONE KIND OF TALK: its own vocabulary, its own rhythm of turns, its own mix of
//     dialogue / dictation / another language. Each of those is scored as the likelihood of the
//     unit's blocks under a model fitted to that unit alone, so two stretches that differ score
//     higher apart than together and one homogeneous stretch scores higher whole;
//   - each cut sits where the talk visibly CHANGED: a pause, a jump in how fast turns arrive, a
//     switch between one voice and several, a greeting;
//   - the units are conversation-sized. Every unit pays a fixed price (so a cut has to earn its
//     place), a unit shorter than a few minutes pays for being a sliver, and a unit pays
//     quadratically for every minute beyond the length real conversations reach. That last term
//     is the guarantee: a stretch with no pause and no visible change is still divided, at its
//     best available points, rather than left as a three-hour "conversation".
//
// A cut is always BETWEEN two turns, so nothing is ever split mid-sentence, and the search is
// pure and deterministic: the same blocks give the same cuts.
//
// It needs no AI and reads no text — `ConversationLexicon` has already turned each turn into
// hashed words and a few flags — so it behaves the same in Local Only, with AI off, and before
// any cloud call has returned.

/// One block of talk as the segmenter sees it.
struct SegmenterBlock: Equatable {
    var wallStartMs: Int64
    var wallEndMs: Int64
    /// How long nothing was said before this block (ms). Missing audio counts half: a hole in
    /// the record is not evidence that nobody spoke.
    var gapBeforeMs: Int64
    /// Speaker runs in the block (consecutive turns by one voice count once).
    var lines: Int
    var words: Int
    var terms: [UInt32]
    /// More than one voice took a turn.
    var isDialogue: Bool
    var isForeign: Bool
    var isDictation: Bool
    var opensWithGreeting: Bool
    /// A stretch whose transcript is not settled yet: there is audio, and nothing else is known.
    /// It contributes its length to a unit and nothing to any other score.
    var isOpaque: Bool = false
}

/// The segmenter's numbers.
///
/// FITTED, not chosen: a search over these against the 384 hand-marked conversation starts on
/// the eight labelled days, scored as a balance of finding marked starts and not cutting where
/// none was marked, with a penalty for slivers and for any unit over 90 minutes. Fitting on four
/// days and scoring the other four gives nearly the same answer as fitting on all eight (the
/// table is in `RealConversationSegmentationTests`), which is the evidence that they describe
/// how talk behaves rather than those particular days. Change one only with that measurement
/// rerun.
public struct SegmenterPolicy: Hashable, Sendable {
    // Coherence of a unit.
    /// Dirichlet concentration for a unit's vocabulary, and the vocabulary size it is spread
    /// over. Small: a unit is expected to reuse a few words heavily.
    public var wordPrior = 0.08
    public var vocabularySize = 4_000.0
    public var wordWeight = 0.46
    public var rhythmWeight = 0.4
    public var dialogueWeight = 1.16
    public var foreignWeight = 0.84
    public var dictationWeight = 0.16

    // The size of a unit.
    public var unitCost = 8.0
    /// Minutes past which a unit pays `longWeight × (minutes − longFromMinutes)²`: nothing
    /// extra at 17 minutes, 5.5 at an hour, 32 at two hours, 80 at three — against a price of
    /// 8 for making one more unit, so two hours of talk is cheaper as three conversations than
    /// as one even when nothing else distinguishes them.
    public var longFromMinutes = 17.0
    public var longWeight = 0.003
    /// Minutes under which a unit pays `shortWeight × (shortBelowMinutes − minutes)`.
    public var shortBelowMinutes = 4.3
    public var shortWeight = 1.17

    // Evidence at a cut.
    /// Times log(1 + pause seconds) / log(900): 0 for no pause, 1 for a quarter of an hour.
    public var pauseWeight = 5.36
    public var pause2MinWeight = 0.0
    public var pause5MinWeight = 3.16
    public var pause8MinWeight = 0.7
    /// Times |log ratio| of turns per minute after and before — the strongest single signal:
    /// sparse dictation giving way to a rapid exchange, or the reverse.
    public var turnRateWeight = 3.42
    public var wordRateWeight = 0.13
    public var dialogueShiftWeight = 2.19
    public var foreignShiftWeight = 0.97
    public var dictationShiftWeight = 2.03
    public var greetingWeight = 2.69

    /// How much talk either side of a candidate cut is compared.
    public var windowMs: Int64 = 5 * 60_000
    /// No unit is considered longer than this; the quadratic cost rules it out long before.
    public var maxUnitMs: Int64 = 4 * 60 * 60_000

    public init() {}
    public static let `default` = SegmenterPolicy()
}

/// log Γ(x). (`lgamma` is ambiguous between the C and the generic overloads here.)
private func logGamma(_ x: Double) -> Double {
    var sign: Int32 = 0
    return lgamma_r(x, &sign)
}

enum ConversationSegmenter {
    /// Turns closer together than this are one block …
    static let blockJoinGapMs: Int64 = 6_000
    /// … up to this length.
    static let blockMaxMs: Int64 = 60_000
    /// Consecutive turns by one voice this close together are one line.
    static let lineJoinGapMs: Int64 = 5_000

    /// Block indexes (never 0) that start a new unit, ascending.
    ///
    /// `blocked` are block indexes where the person has said "these are one conversation"; no
    /// cut is placed there.
    static func cuts(
        blocks: [SegmenterBlock], blocked: Set<Int> = [], policy: SegmenterPolicy = .default
    ) -> [Int] {
        let count = blocks.count
        guard count > 1 else { return [] }

        // Dense local ids for the words, so a unit's counts are an array.
        var localId: [UInt32: Int] = [:]
        var ids: [[Int]] = []
        ids.reserveCapacity(count)
        for block in blocks {
            ids.append(
                block.terms.map { term in
                    if let id = localId[term] { return id }
                    let id = localId.count
                    localId[term] = id
                    return id
                })
        }
        let concentration = policy.vocabularySize * policy.wordPrior
        let lgammaConcentration = logGamma(concentration)

        let logGaps: [Double] = blocks.map { log(Double(max($0.gapBeforeMs, 0)) / 1000 + 1) }
        let cutScores = boundaryScores(blocks: blocks, policy: policy)

        var best = [Double](repeating: -.infinity, count: count + 1)
        var back = [Int](repeating: 0, count: count + 1)
        best[0] = 0
        var counts = [Int32](repeating: 0, count: max(localId.count, 1))
        var touched: [Int] = []

        for start in 0..<count {
            guard best[start] > -.infinity else { continue }
            if start > 0, blocked.contains(start) { continue }
            let base = best[start] + (start > 0 ? cutScores[start] : 0)
            let unitStartMs = blocks[start].wallStartMs

            var wordLogSum = 0.0
            var wordTotal = 0
            var gapCount = 0
            var gapSum = 0.0
            var gapSquares = 0.0
            var dialogue = 0
            var foreign = 0
            var dictation = 0
            var spoken = 0

            var end = start
            while end < count {
                let block = blocks[end]
                if end > start, block.wallEndMs - unitStartMs > policy.maxUnitMs { break }
                if !block.isOpaque {
                    for id in ids[end] {
                        let seen = counts[id]
                        if seen == 0 { touched.append(id) }
                        wordLogSum += log(Double(seen) + policy.wordPrior)
                        counts[id] = seen + 1
                    }
                    wordTotal += ids[end].count
                    if end > start, !blocks[end - 1].isOpaque {
                        let gap = logGaps[end]
                        gapCount += 1
                        gapSum += gap
                        gapSquares += gap * gap
                    }
                    spoken += 1
                    if block.isDialogue { dialogue += 1 }
                    if block.isForeign { foreign += 1 }
                    if block.isDictation { dictation += 1 }
                }
                var score =
                    policy.wordWeight
                    * (lgammaConcentration - logGamma(Double(wordTotal) + concentration) + wordLogSum)
                score += policy.rhythmWeight * rhythmLikelihood(gapCount, gapSum, gapSquares)
                score += policy.dialogueWeight * flagLikelihood(dialogue, spoken)
                score += policy.foreignWeight * flagLikelihood(foreign, spoken)
                score += policy.dictationWeight * flagLikelihood(dictation, spoken)
                let value =
                    base + score
                    - durationCost(ms: block.wallEndMs - unitStartMs, policy: policy)
                if value > best[end + 1] {
                    best[end + 1] = value
                    back[end + 1] = start
                }
                end += 1
            }
            for id in touched { counts[id] = 0 }
            touched.removeAll(keepingCapacity: true)
        }

        var cuts: [Int] = []
        var cursor = count
        while cursor > 0 {
            let start = back[cursor]
            if start > 0 { cuts.append(start) }
            cursor = start
        }
        return cuts.reversed()
    }

    /// What a unit of this length costs.
    static func durationCost(ms: Int64, policy: SegmenterPolicy) -> Double {
        let minutes = Double(ms) / 60_000
        var cost = policy.unitCost
        if minutes > policy.longFromMinutes {
            let over = minutes - policy.longFromMinutes
            cost += policy.longWeight * over * over
        }
        if minutes < policy.shortBelowMinutes {
            cost += policy.shortWeight * (policy.shortBelowMinutes - minutes)
        }
        return cost
    }

    /// Marginal likelihood of a unit's pauses: their logarithms are taken as Normal with the
    /// unit's own mean and spread (Normal-Inverse-Gamma prior), so a unit with one steady rhythm
    /// scores higher than the same blocks with a long silence in the middle.
    static func rhythmLikelihood(_ count: Int, _ sum: Double, _ squares: Double) -> Double {
        guard count > 0 else { return 0 }
        let n = Double(count)
        let mean = sum / n
        let spread = max(squares - n * mean * mean, 0)
        let priorMean = 1.5
        let priorCount = 0.5
        let priorShape = 1.0
        let priorScale = 1.0
        let postCount = priorCount + n
        let postShape = priorShape + n / 2
        let postScale =
            priorScale + 0.5 * spread
            + priorCount * n * (mean - priorMean) * (mean - priorMean) / (2 * postCount)
        return logGamma(postShape) - logGamma(priorShape) + priorShape * log(priorScale)
            - postShape * log(postScale) + 0.5 * log(priorCount / postCount)
            - (n / 2) * log(2 * Double.pi)
    }

    /// Marginal likelihood of `hits` of `count` blocks carrying a flag, the unit having its own
    /// rate (uniform prior): a unit that is all dialogue or all dictation scores higher than a
    /// mixture.
    static func flagLikelihood(_ hits: Int, _ count: Int) -> Double {
        guard count > 0 else { return 0 }
        let k = Double(hits)
        let n = Double(count)
        return logGamma(2) - logGamma(2 + n) + logGamma(1 + k) + logGamma(1 + n - k)
    }

    /// The evidence for a cut immediately before each block (index 0 is unused).
    static func boundaryScores(blocks: [SegmenterBlock], policy: SegmenterPolicy) -> [Double] {
        let count = blocks.count
        var scores = [Double](repeating: 0, count: count)
        guard count > 1 else { return scores }
        let logQuarterHour = log(900.0)

        struct Window {
            var turnRate = 0.0
            var wordRate = 0.0
            var dialogue = 0.0
            var foreign = 0.0
            var dictation = 0.0
        }
        func summarise(_ range: ClosedRange<Int>) -> Window {
            var first = Int64.max
            var last = Int64.min
            var lines = 0
            var words = 0
            var dialogue = 0
            var foreign = 0
            var dictation = 0
            var spoken = 0
            for index in range {
                let block = blocks[index]
                guard !block.isOpaque else { continue }
                first = min(first, block.wallStartMs)
                last = max(last, block.wallEndMs)
                lines += block.lines
                words += block.words
                spoken += 1
                if block.isDialogue { dialogue += 1 }
                if block.isForeign { foreign += 1 }
                if block.isDictation { dictation += 1 }
            }
            guard spoken > 0 else { return Window() }
            let minutes = Double(max(last - first, 30_000)) / 60_000
            let n = Double(spoken)
            return Window(
                turnRate: Double(lines) / minutes, wordRate: Double(words) / minutes,
                dialogue: Double(dialogue) / n, foreign: Double(foreign) / n,
                dictation: Double(dictation) / n)
        }

        for index in 1..<count {
            let block = blocks[index]
            guard !block.isOpaque, !blocks[index - 1].isOpaque else { continue }
            // The talk before: back from the previous block until the window is full.
            var low = index - 1
            let beforeAnchor = blocks[index - 1].wallEndMs
            while low > 0, !blocks[low - 1].isOpaque,
                beforeAnchor - blocks[low - 1].wallStartMs <= policy.windowMs
            {
                low -= 1
            }
            // The talk after: forward from this block until the window is full.
            var high = index
            while high + 1 < count, !blocks[high + 1].isOpaque,
                blocks[high + 1].wallEndMs - block.wallStartMs <= policy.windowMs
            {
                high += 1
            }
            let before = summarise(low...(index - 1))
            let after = summarise(index...high)

            let gapSeconds = Double(max(block.gapBeforeMs, 0)) / 1000
            var score = policy.pauseWeight * log(gapSeconds + 1) / logQuarterHour
            if gapSeconds >= 120 { score += policy.pause2MinWeight }
            if gapSeconds >= 300 { score += policy.pause5MinWeight }
            if gapSeconds >= 480 { score += policy.pause8MinWeight }
            score +=
                policy.turnRateWeight
                * min(abs(log((after.turnRate + 0.5) / (before.turnRate + 0.5))), 3)
            score +=
                policy.wordRateWeight
                * min(abs(log((after.wordRate + 5) / (before.wordRate + 5))), 3)
            score += policy.dialogueShiftWeight * abs(after.dialogue - before.dialogue)
            score += policy.foreignShiftWeight * abs(after.foreign - before.foreign)
            score += policy.dictationShiftWeight * abs(after.dictation - before.dictation)
            if block.opensWithGreeting { score += policy.greetingWeight }
            scores[index] = score
        }
        return scores
    }
}
