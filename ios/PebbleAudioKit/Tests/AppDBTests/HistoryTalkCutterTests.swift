import Foundation
import Testing

@testable import AppDB

// `HistoryTalkCutter`: cut only where the talk really stopped, merge short pieces, never force a
// long one apart, and never move a settled cut when more talk arrives.

private func m(_ minutes: Double) -> Int64 { Int64(minutes * 60_000) }

/// Runs given as (start, end) minutes.
private func runs(_ pairs: [(Double, Double)]) -> [Range<Int64>] { pairs.map { m($0.0)..<m($0.1) } }

private func cuts(_ pairs: [(Double, Double)], stretch: Range<Int64>? = nil, rules: HistoryTalkCutRules = .default) -> [Double] {
    let list = runs(pairs)
    let span = stretch ?? (list.first!.lowerBound..<list.last!.upperBound)
    return HistoryTalkCutter.cuts(stretch: span, speechRuns: list, rules: rules).map { Double($0) / 60_000 }
}

@Suite struct HistoryTalkCutterTests {
    @Test("cuts at every pause of three minutes or more, at the start of the talk after it")
    func cutsAtRealPauses() {
        // 0-20 talk, 4-min pause, 24-50 talk, 2-min pause (no cut), 52-70, 3-min pause, 73-90.
        #expect(cuts([(0, 20), (24, 50), (52, 70), (73, 90)]) == [24, 73])
    }

    @Test("no forced maximum: two hours of talk without a real pause stays one piece")
    func noForcedMaximum() {
        var pairs: [(Double, Double)] = []
        var at = 0.0
        while at < 120 {
            pairs.append((at, at + 1.5))
            at += 2.5  // one-minute pauses: never a cut
        }
        #expect(cuts(pairs).isEmpty)
    }

    @Test("a piece under ten minutes joins its shorter neighbour, never past the merge cap")
    func shortPiecesMerge() {
        // Pieces 0-30, 34-38 (short), 42-60 → the short one joins the shorter neighbour (42-60).
        #expect(cuts([(0, 30), (34, 38), (42, 60)]) == [34])
        // Tie between neighbours: the earlier one.
        #expect(cuts([(0, 20), (24, 28), (32, 56)]) == [32])
        // Both neighbours too long to take it within the cap: it stays.
        #expect(cuts([(0, 55), (59, 63), (67, 122)]) == [59, 67])
        // A short piece at the start joins the one after it. A run of short pieces is taken in
        // order: 6+6 → 12 (long enough), then the third 6 joins that shorter neighbour.
        #expect(cuts([(0, 3), (7, 30)]) == [])
        #expect(cuts([(0, 2), (6, 8), (12, 14), (18, 40)]) == [18])
        // A short piece at the end joins the one before it.
        #expect(cuts([(0, 30), (34, 36)]) == [])
        // One short stretch alone is left as it is.
        #expect(cuts([(0, 2), (6, 8)]) == [])
    }

    @Test("the stretch may extend beyond the talk; runs outside it are ignored, overlaps joined")
    func stretchAndRunsHygiene() {
        #expect(cuts([(0, 20), (24, 45)], stretch: m(-5)..<m(60)) == [24])
        #expect(cuts([(-10, 5), (2, 20), (24, 45), (70, 90)], stretch: m(0)..<m(50)) == [24])
        #expect(HistoryTalkCutter.cuts(stretch: 0..<m(30), speechRuns: []).isEmpty)
    }

    @Test("fuzz: pieces tile, cuts are run starts after a real pause, short pieces merged where they can be")
    func fuzz() {
        var rng = SeededGenerator(seed: 0xC077)
        let rules = HistoryTalkCutRules.default
        for _ in 0..<3_000 {
            let list = randomRuns(&rng)
            guard let first = list.first, let last = list.last else { continue }
            let stretch = first.lowerBound - Int64.random(in: 0...60_000, using: &rng)
                ..< last.upperBound + Int64.random(in: 0...60_000, using: &rng)
            let result = HistoryTalkCutter.cuts(stretch: stretch, speechRuns: list, rules: rules)
            let merged = HistoryTalkCutter.mergedRuns(list, in: stretch)
            // Ascending, strictly inside, each the start of a run after a pause of 3 min or more.
            #expect(result == result.sorted() && Set(result).count == result.count)
            for cut in result {
                #expect(stretch.contains(cut) && cut != stretch.lowerBound)
                let index = merged.firstIndex { $0.lowerBound == cut }
                #expect(index != nil && index! > 0 && cut - merged[index! - 1].upperBound >= rules.preferredGapMs)
            }
            // Every real pause that is NOT cut was merged away, which only happens to a piece
            // under the minimum.
            let bounds = [stretch.lowerBound] + result + [stretch.upperBound]
            let pieces = zip(bounds, bounds.dropFirst()).map { $0.1 - $0.0 }
            #expect(pieces.allSatisfy { $0 > 0 })
            #expect(pieces.reduce(0, +) == stretch.upperBound - stretch.lowerBound)
            // A piece that could still have merged (short, with a shorter-or-equal neighbour that
            // fits under the cap) does not exist, apart from what one pass leaves behind — so
            // check only the weaker guarantee: no merge ever passed the cap.
            let raw = HistoryTalkCutter.pauseCuts(stretch: stretch, runs: merged, rules: rules)
            let rawBounds = [stretch.lowerBound] + raw + [stretch.upperBound]
            for (a, b) in zip(bounds, bounds.dropFirst()) where b - a > rules.mergeCapMs {
                // Longer than the cap only if it was never merged: it is one step-a piece.
                #expect(rawBounds.contains(a) && rawBounds.contains(b)
                    && !raw.contains { $0 > a && $0 < b })
            }
        }
    }

    @Test("appending talk never moves a cut before the growing end (and says where it can)")
    func stableUnderAppend() {
        var rng = SeededGenerator(seed: 0xA99E)
        let rules = HistoryTalkCutRules.default
        var checked = 0
        var moved = 0
        for _ in 0..<3_000 {
            let list = randomRuns(&rng)
            guard list.count >= 3 else { continue }
            let full = HistoryTalkCutter.cuts(stretch: list[0].lowerBound..<list.last!.upperBound, speechRuns: list, rules: rules)
            for k in 1..<list.count {
                let prefixRuns = Array(list[..<k])
                let span = prefixRuns[0].lowerBound..<prefixRuns.last!.upperBound
                let prefix = HistoryTalkCutter.cuts(stretch: span, speechRuns: prefixRuns, rules: rules)
                // The frontier: the start of the run of short step-a pieces that ends just before
                // the prefix's last piece (or the start of the last piece when there is none).
                let merged = HistoryTalkCutter.mergedRuns(prefixRuns, in: span)
                let raw = [span.lowerBound] + HistoryTalkCutter.pauseCuts(stretch: span, runs: merged, rules: rules) + [span.upperBound]
                // Start at the last piece; step back over the short pieces just before it.
                var frontierIndex = raw.count - 2
                while frontierIndex > 0, raw[frontierIndex] - raw[frontierIndex - 1] < rules.minPieceMs {
                    frontierIndex -= 1
                }
                let frontier = raw[frontierIndex]
                checked += 1
                #expect(prefix.filter { $0 < frontier } == full.filter { $0 < frontier })
                if prefix.filter({ $0 < span.upperBound }) != full.filter({ $0 < span.upperBound }) { moved += 1 }
            }
        }
        #expect(checked > 10_000)
        // Some cuts DO move near the growing end; that is the documented, bounded exception.
        #expect(moved > 0)
    }
}

/// 1-40 runs of 5 s to 40 min, separated by pauses weighted towards the interesting range
/// (under and over the 3-minute cut, around the 10-minute minimum).
private func randomRuns(_ rng: inout SeededGenerator) -> [Range<Int64>] {
    var result: [Range<Int64>] = []
    var at: Int64 = 1_000_000
    for _ in 0..<Int.random(in: 1...40, using: &rng) {
        let length = [5_000, 60_000, 4 * 60_000, 9 * 60_000, 25 * 60_000, 40 * 60_000].randomElement(using: &rng)!
            + Int64.random(in: 0...30_000, using: &rng)
        result.append(at..<(at + length))
        let pause = [0, 10_000, 2 * 60_000, 3 * 60_000, 5 * 60_000, 12 * 60_000].randomElement(using: &rng)!
            + Int64.random(in: 0...20_000, using: &rng)
        at += length + pause
    }
    return result
}
