import Foundation

// Where a stretch of talk is cut into pieces, without AI (History, plan 7.2-7.3).
//
// THE ONE deterministic cutter. History's cards for talk no chapter covers yet use it, and the
// chapter stage's on-device path calls the same function, so the cards a person sees with AI off
// and the chapters written on the device have identical boundaries.
//
// It cuts only where the talk really stopped. It does not manufacture short pieces: a card is
// drawn at its true length on the timeline, so two hours of talk with no real pause in it stays
// one two-hour card. Splitting long talk by topic is the chapter stage's job (and the grouper's,
// separately); nothing here pretends to know where a subject changed.
//
//  a. Cut at every pause between speech runs of `preferredGapMs` or more. The cut sits at the
//     START of the run that follows the pause: the silence belongs to what came before.
//  b. One left-to-right pass: a piece shorter than `minPieceMs` merges into its shorter
//     neighbour (the earlier one on a tie) when the result is at most `mergeCapMs`; otherwise
//     it stays as it is.
//
// STABILITY under audio appended at the end (today, while recording). Step a never moves a cut:
// a later pause only ADDS one. Step b can move one, in one place: whether the piece before the
// last one merges left or right depends on the length of the last piece, which is still
// growing — and if that piece is short, so are the short pieces immediately before it that
// merge into it on the way. So the cuts that may still move are those from the start of the
// run of short (step-a) pieces that ends just before the last piece; every cut before it is
// fixed once made (`HistoryTalkCutterTests` pins exactly this). Step b is a single
// left-to-right pass rather than "shortest first" for that reason: a global order would let a
// change at the end reorder merges anywhere in the day.

public struct HistoryTalkCutRules: Equatable, Sendable {
    /// A real pause: always cut here, at the start of the run after it.
    public var preferredGapMs: Int64 = 3 * 60_000
    /// A piece shorter than this merges into its shorter neighbour (within `mergeCapMs`).
    public var minPieceMs: Int64 = 10 * 60_000
    /// A merge never makes a piece longer than this. Not a maximum piece length: nothing is
    /// ever cut to fit it.
    public var mergeCapMs: Int64 = 60 * 60_000
    public static let `default` = HistoryTalkCutRules()

    public init(
        preferredGapMs: Int64 = 3 * 60_000, minPieceMs: Int64 = 10 * 60_000,
        mergeCapMs: Int64 = 60 * 60_000
    ) {
        self.preferredGapMs = preferredGapMs
        self.minPieceMs = minPieceMs
        self.mergeCapMs = mergeCapMs
    }
}

public enum HistoryTalkCutter {
    /// Cut points (wall ms) strictly inside `stretch`, ascending. Pieces tile the stretch: piece k ends where k+1 begins.
    public static func cuts(stretch: Range<Int64>, speechRuns: [Range<Int64>], rules: HistoryTalkCutRules = .default) -> [Int64] {
        let runs = mergedRuns(speechRuns, in: stretch)
        return mergingShortPieces(stretch: stretch, cuts: pauseCuts(stretch: stretch, runs: runs, rules: rules), rules: rules)
    }

    /// The runs clipped to the stretch, sorted, with overlapping or touching runs joined: a cut
    /// can only fall where speech STARTS after a pause.
    static func mergedRuns(_ runs: [Range<Int64>], in stretch: Range<Int64>) -> [Range<Int64>] {
        let clipped = runs.compactMap { run -> Range<Int64>? in
            let lower = max(run.lowerBound, stretch.lowerBound)
            let upper = min(run.upperBound, stretch.upperBound)
            return upper > lower ? lower..<upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int64>] = []
        for run in clipped {
            if let last = merged.last, run.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, run.upperBound)
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    /// Step a: the start of every run that follows a pause of `preferredGapMs` or more.
    static func pauseCuts(stretch: Range<Int64>, runs: [Range<Int64>], rules: HistoryTalkCutRules) -> [Int64] {
        runs.indices.dropFirst().compactMap { index in
            let at = runs[index].lowerBound
            guard at - runs[index - 1].upperBound >= rules.preferredGapMs,
                at > stretch.lowerBound, at < stretch.upperBound
            else { return nil }
            return at
        }
    }

    /// Step b: one left-to-right pass over the pieces.
    static func mergingShortPieces(stretch: Range<Int64>, cuts: [Int64], rules: HistoryTalkCutRules) -> [Int64] {
        var bounds = [stretch.lowerBound] + cuts + [stretch.upperBound]
        var index = 0  // the piece [bounds[index], bounds[index + 1])
        while index < bounds.count - 1 {
            let length = bounds[index + 1] - bounds[index]
            guard length < rules.minPieceMs, bounds.count > 2 else {
                index += 1
                continue
            }
            let left = index > 0 ? bounds[index] - bounds[index - 1] : nil
            let right = index + 2 < bounds.count ? bounds[index + 2] - bounds[index + 1] : nil
            let goLeft: Bool
            switch (left, right) {
            case let (l?, r?): goLeft = l <= r
            case (_?, nil): goLeft = true
            case (nil, _?), (nil, nil): goLeft = false
            }
            guard let neighbour = goLeft ? left : right, length + neighbour <= rules.mergeCapMs else {
                index += 1
                continue
            }
            if goLeft {
                // The piece behind now runs to this one's end; carry on with the next.
                bounds.remove(at: index)
            } else {
                // This piece now runs to the next one's end; look at it again, it may still be short.
                bounds.remove(at: index + 1)
            }
        }
        return Array(bounds.dropFirst().dropLast())
    }
}
