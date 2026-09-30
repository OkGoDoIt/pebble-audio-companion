import Foundation
import SegmentStore
import WireProtocol

// Where the conversations inside ONE structurally-chained run of segments start.
//
// A run is what the structural rules in `ConversationGrouper` leave joined: segments that hand
// straight over to each other with no user Stop, no pause and no gap in the record between
// them. With the watch recording all day that is routinely ten or twenty hours. This file
// divides it, in three layers, each of which only ever ADDS cuts:
//
//  1. HARD cuts, from settled evidence alone: a stretch of the record at least
//     `BoundaryPolicy.quietSplitMs` long in which nothing was said ends the conversation at its
//     last word and starts the next at the first word after it.
//  2. FIXED cuts: the segmenter's own earlier decisions that have settled (`conversation_cuts`)
//     and the person's manual splits. These never move.
//  3. The SEGMENTER (`ConversationSegmenter`), over each stretch between fixed and hard cuts.
//
// A cut is a POSITION — a segment and an offset into its stored audio — and always falls
// between two turns. Everything before it in the run belongs to the conversation that was
// already going; everything from it on belongs to the new one.

/// A position in a run: member index, and media ms into that member.
struct RunPosition: Comparable, Hashable {
    var seg: Int
    var mediaMs: Int64

    static func < (a: RunPosition, b: RunPosition) -> Bool {
        a.seg == b.seg ? a.mediaMs < b.mediaMs : a.seg < b.seg
    }
}

/// One settled turn of the run, on both clocks.
struct RunTurn {
    var seg: Int
    var mediaStartMs: Int64
    var mediaEndMs: Int64
    var wallStartMs: Int64
    var wallEndMs: Int64
    var words: Int
    var features: TurnFeatures?
}

struct PlannedCut: Equatable {
    enum Kind: Equatable {
        /// A long settled silence. Recomputed from evidence every time; never stored.
        case hard
        /// A segmenter decision that has already settled, or the person's own split.
        case fixed
        /// A segmenter decision made in this pass.
        case segmenter
    }
    var position: RunPosition
    var reason: ConversationStartReason
    var kind: Kind
    /// A segmenter cut old enough to be written down and held (see `commitLagMs`).
    var shouldCommit = false
}

/// The user's and the segmenter's standing decisions about positions INSIDE segments, keyed by
/// segment id. (Decisions about a segment's own start stay in `boundary_overrides`.)
public struct ConversationCutInputs: Equatable, Sendable {
    /// Settled segmenter cuts: media ms → why.
    public var committed: [String: [Int64: ConversationStartReason]]
    /// "Start a new conversation here."
    public var splits: [String: Set<Int64>]
    /// "This is the same conversation as what came before": no cut at or near these offsets.
    public var joins: [String: Set<Int64>]

    public init(
        committed: [String: [Int64: ConversationStartReason]] = [:],
        splits: [String: Set<Int64>] = [:], joins: [String: Set<Int64>] = [:]
    ) {
        self.committed = committed
        self.splits = splits
        self.joins = joins
    }

    public static let none = ConversationCutInputs()
    var isEmpty: Bool { committed.isEmpty && splits.isEmpty && joins.isEmpty }
}

struct RunPlan {
    var cuts: [PlannedCut]
    var turns: [RunTurn]
}

enum ConversationRunPlanner {
    /// A cut is placed this far ahead of the first word of the new conversation, so playback
    /// does not begin on a clipped syllable — but never before the end of the previous turn.
    static let preRollMs: Int64 = 1_500
    /// A trailing silence starts this long after the last word.
    static let postRollMs: Int64 = 2_000
    /// A "these are one conversation" decision keeps automatic cuts this far away from it.
    static let joinReachMs: Int64 = 120_000
    /// A segmenter cut is written down once this much settled talk lies after it. Until then
    /// it is re-decided each time more of the day arrives: the search's answer near the end of
    /// what it has seen can still change, and its answer this far back does not.
    static let commitLagMs: Int64 = 45 * 60_000

    // --- the run on both clocks --------------------------------------------------------------

    struct Member {
        var meta: SegmentMeta
        var startWallMs: Int64
        var endWallMs: Int64
        var mediaSpanMs: Int64
        var isSettled: Bool
        var clock: SegmentMediaClock

        /// Wall clock of a media offset, the same way `spokenRuns` places a turn: through the
        /// gap records where they add up, and as a plain offset where they do not.
        func wall(ofMedia mediaMs: Int64) -> Int64 {
            let span = max(endWallMs - startWallMs, 0)
            let offset = clock.isExact ? clock.wall(fromMedia: mediaMs) : mediaMs
            return startWallMs + min(max(offset, 0), span)
        }
    }

    static func members(
        _ metas: [SegmentMeta], evidence: [String: SegmentSpeechEvidence]
    ) -> [Member] {
        metas.map { meta in
            let clock = SegmentMediaClock(meta)
            return Member(
                meta: meta, startWallMs: ConversationGrouper.segmentStartMs(meta),
                endWallMs: ConversationGrouper.segmentEndMs(meta),
                mediaSpanMs: clock.mediaSpanMs,
                isSettled: evidence[meta.segmentId]?.isSettled == true, clock: clock)
        }
    }

    static func turns(
        _ members: [Member], evidence: [String: SegmentSpeechEvidence]
    ) -> [RunTurn] {
        var out: [RunTurn] = []
        for (index, member) in members.enumerated() where member.isSettled {
            guard let speech = evidence[member.meta.segmentId]?.speech, !speech.isEmpty else {
                continue
            }
            let ordered = speech.sorted {
                $0.startMs == $1.startMs ? $0.endMs < $1.endMs : $0.startMs < $1.startMs
            }
            for span in ordered {
                let start = member.wall(ofMedia: span.startMs)
                let end = max(member.wall(ofMedia: span.endMs), start)
                out.append(
                    RunTurn(
                        seg: index, mediaStartMs: max(span.startMs, 0),
                        mediaEndMs: max(span.endMs, span.startMs, 0), wallStartMs: start,
                        wallEndMs: end, words: span.wordCount, features: span.features))
            }
        }
        return out
    }

    /// The cut that starts a conversation at turn `index`: a little ahead of its first word,
    /// never before the previous turn in the same segment has ended, and never after the turn
    /// itself (turns overlap when two people talk at once).
    static func position(beforeTurn index: Int, in turns: [RunTurn]) -> RunPosition {
        let turn = turns[index]
        var previousEnd: Int64 = 0
        if index > 0, turns[index - 1].seg == turn.seg {
            previousEnd = turns[index - 1].mediaEndMs
        }
        let media = min(max(turn.mediaStartMs - preRollMs, previousEnd), turn.mediaStartMs)
        return RunPosition(seg: turn.seg, mediaMs: max(media, 0))
    }

    // --- the plan ------------------------------------------------------------------------------

    static func plan(
        metas: [SegmentMeta],
        evidence: [String: SegmentSpeechEvidence],
        policy: BoundaryPolicy,
        inputs: ConversationCutInputs,
        joinedSegments: Set<String>,
        isOpenEnded: Bool
    ) -> RunPlan {
        let members = members(metas, evidence: evidence)
        let turns = turns(members, evidence: evidence)
        guard !members.isEmpty else { return RunPlan(cuts: [], turns: turns) }
        let runStart = RunPosition(seg: 0, mediaMs: 0)
        let runEnd = RunPosition(seg: members.count, mediaMs: 0)

        // Where the person has said "no cut here".
        var blockedAt: [Int: [Int64]] = [:]
        for (index, member) in members.enumerated() {
            var offsets = Array(inputs.joins[member.meta.segmentId] ?? [])
            if joinedSegments.contains(member.meta.segmentId) { offsets.append(0) }
            if !offsets.isEmpty { blockedAt[index] = offsets }
        }
        func isBlocked(_ position: RunPosition) -> Bool {
            guard let offsets = blockedAt[position.seg] else { return false }
            return offsets.contains { abs($0 - position.mediaMs) <= joinReachMs }
        }

        var cuts: [RunPosition: PlannedCut] = [:]
        func add(_ cut: PlannedCut) {
            guard cut.position > runStart, cut.position < runEnd else { return }
            // A hard cut and a fixed one at the same place: the fixed one wins, it is the one
            // whose id other things may already hang on.
            if let existing = cuts[cut.position], existing.kind == .fixed { return }
            cuts[cut.position] = cut
        }

        // 1. Hard cuts.
        if policy.quietSplitMs != .max {
            for cut in quietCuts(members: members, turns: turns, evidence: evidence, policy: policy)
            where !isBlocked(cut.position) {
                add(cut)
            }
        }

        // 2. Fixed cuts: the person's splits beat a blocked neighbourhood (a split is the newer,
        // more specific decision about that exact place); settled segmenter cuts do not.
        for (index, member) in members.enumerated() {
            let id = member.meta.segmentId
            for (media, reason) in inputs.committed[id] ?? [:] where media > 0 {
                let position = RunPosition(seg: index, mediaMs: media)
                guard media < member.mediaSpanMs, !isBlocked(position) else { continue }
                add(PlannedCut(position: position, reason: reason, kind: .fixed))
            }
            for media in inputs.splits[id] ?? [] where media > 0 && media < member.mediaSpanMs {
                add(
                    PlannedCut(
                        position: RunPosition(seg: index, mediaMs: media), reason: .manual,
                        kind: .fixed))
            }
        }

        // 3. The segmenter, over every stretch the cuts so far leave whole.
        if let segmenter = policy.segmenter {
            let edges = [runStart] + cuts.keys.sorted() + [runEnd]
            for (lower, upper) in zip(edges, edges.dropFirst()) {
                let isLastStretch = upper == runEnd
                let found = segmenterCuts(
                    from: lower, to: upper, members: members, turns: turns, policy: segmenter,
                    isBlocked: isBlocked,
                    endsOpen: isLastStretch && isOpenEnded)
                for cut in found { add(cut) }
            }
        }

        var ordered = cuts.values.sorted { $0.position < $1.position }
        ordered = droppingEmptyUnits(ordered, members: members, turns: turns, runEnd: runEnd)
        return RunPlan(cuts: ordered, turns: turns)
    }

    // --- 1. hard cuts --------------------------------------------------------------------------

    /// A long settled silence ends the conversation at its last word, and the next one starts
    /// at the first word after it. The silence itself stays with what came before — a
    /// conversation never opens on minutes of nothing — except at the very start of a run,
    /// where there is nothing before, and at the end of one, where the silent tail becomes its
    /// own unit so the conversation can finish.
    static func quietCuts(
        members: [Member], turns: [RunTurn], evidence: [String: SegmentSpeechEvidence],
        policy: BoundaryPolicy
    ) -> [PlannedCut] {
        guard !turns.isEmpty, let first = members.first else { return [] }
        let runStartMs = first.startWallMs
        let runEndMs = members.map(\.endWallMs).max() ?? runStartMs
        // Turn indexes by wall start: members can overlap in wall time, so run order is not
        // always time order.
        let byWall = turns.indices.sorted {
            turns[$0].wallStartMs == turns[$1].wallStartMs
                ? turns[$0].wallEndMs < turns[$1].wallEndMs
                : turns[$0].wallStartMs < turns[$1].wallStartMs
        }

        struct Stretch {
            var startMs: Int64
            var endMs: Int64
            /// The turn holding the last word before the silence, and the first after it.
            var last: Int?
            var next: Int?
        }
        var stretches: [Stretch] = []
        let firstTurn = byWall[0]
        if turns[firstTurn].wallStartMs > runStartMs {
            stretches.append(
                Stretch(
                    startMs: runStartMs, endMs: turns[firstTurn].wallStartMs, last: nil,
                    next: firstTurn))
        }
        var previousEnd = turns[firstTurn].wallEndMs
        var previous = firstTurn
        for index in byWall.dropFirst() {
            let turn = turns[index]
            if turn.wallStartMs > previousEnd {
                stretches.append(
                    Stretch(
                        startMs: previousEnd, endMs: turn.wallStartMs, last: previous,
                        next: index))
            }
            if turn.wallEndMs > previousEnd {
                previousEnd = turn.wallEndMs
                previous = index
            }
        }
        if runEndMs > previousEnd {
            stretches.append(
                Stretch(startMs: previousEnd, endMs: runEndMs, last: previous, next: nil))
        }

        var out: [PlannedCut] = []
        for stretch in stretches {
            let duration = stretch.endMs - stretch.startMs
            guard duration >= policy.quietSplitMs else { continue }
            let overlapping = members.filter {
                $0.endWallMs > stretch.startMs && $0.startWallMs < stretch.endMs
            }
            // DEFERRAL, not a decision: a member still transcribing (or still open) looks
            // exactly like a member in which nobody spoke.
            guard overlapping.allSatisfy(\.isSettled) else { continue }
            let lostMs = overlapping.reduce(Int64(0)) { total, member in
                total
                    + ConversationBoundaryDetector.lossSpansMs(member.meta).reduce(Int64(0)) {
                        $0 + max(0, min($1.1, stretch.endMs) - max($1.0, stretch.startMs))
                    }
            }
            let lossDominated = Double(lostMs) / Double(duration) > policy.lossDominanceFraction
            if lossDominated {
                let scaled = Double(policy.quietSplitMs) * policy.lossThresholdMultiplier
                guard Double(duration) >= scaled else { continue }
            }
            let reason: ConversationStartReason = lossDominated ? .interrupted : .quiet
            if let next = stretch.next {
                out.append(
                    PlannedCut(
                        position: position(beforeTurn: next, in: turns), reason: reason,
                        kind: .hard))
            } else if let last = stretch.last {
                // Trailing: the silent tail becomes its own unit.
                let turn = turns[last]
                let after = turn.mediaEndMs + postRollMs
                let position =
                    after < members[turn.seg].mediaSpanMs
                    ? RunPosition(seg: turn.seg, mediaMs: after)
                    : RunPosition(seg: turn.seg + 1, mediaMs: 0)
                out.append(PlannedCut(position: position, reason: reason, kind: .hard))
            }
        }
        return out
    }

    // --- 3. the segmenter ----------------------------------------------------------------------

    /// One block and where a cut in front of it would sit.
    struct PlacedBlock {
        var block: SegmenterBlock
        var position: RunPosition
    }

    /// The blocks of `[lower, upper)`: settled talk as `ConversationSegmenter` blocks, and each
    /// unsettled member (or the part of one inside the range) as one opaque block.
    static func blocks(
        from lower: RunPosition, to upper: RunPosition, members: [Member], turns: [RunTurn]
    ) -> [PlacedBlock] {
        var out: [PlacedBlock] = []
        var previousEnd: Int64?
        var speakers = Set<UInt32>()
        var lineSpeaker: UInt32 = 0
        var lineEnd: Int64 = 0
        var lineStart: Int64 = 0
        var blockSegment = -1
        var turnCursor = turns.partitioningIndex {
            RunPosition(seg: $0.seg, mediaMs: $0.mediaStartMs) >= lower
        }

        func gapBefore(_ startMs: Int64) -> Int64 {
            guard let previousEnd else { return 0 }
            let gap = max(startMs - previousEnd, 0)
            guard gap >= 30_000 else { return gap }
            // Missing audio inside the pause counts half.
            var lost: Int64 = 0
            for member in members
            where member.endWallMs > previousEnd && member.startWallMs < startMs {
                for span in ConversationBoundaryDetector.lossSpansMs(member.meta) {
                    lost += max(0, min(span.1, startMs) - max(span.0, previousEnd))
                }
            }
            return max(gap - min(lost, gap) / 2, 0)
        }

        for seg in lower.seg..<min(upper.seg + 1, members.count) {
            let member = members[seg]
            let low = seg == lower.seg ? lower.mediaMs : 0
            let high = seg == upper.seg ? upper.mediaMs : Int64.max
            guard high > low else { continue }
            if !member.isSettled {
                let start = member.wall(ofMedia: low)
                let end = max(member.wall(ofMedia: min(high, member.mediaSpanMs)), start)
                // An unsettled member with no stored audio in range says nothing at all.
                guard high == .max ? member.endWallMs > start : end > start else { continue }
                let wallEnd = high == .max ? member.endWallMs : end
                out.append(
                    PlacedBlock(
                        block: SegmenterBlock(
                            wallStartMs: start, wallEndMs: wallEnd, gapBeforeMs: 0, lines: 0,
                            words: 0, terms: [], isDialogue: false, isForeign: false,
                            isDictation: false, opensWithGreeting: false, isOpaque: true),
                        position: RunPosition(seg: seg, mediaMs: low)))
                previousEnd = max(previousEnd ?? wallEnd, wallEnd)
                blockSegment = -1
                continue
            }
            while turnCursor < turns.count, turns[turnCursor].seg == seg,
                turns[turnCursor].mediaStartMs < high
            {
                let turn = turns[turnCursor]
                let features = turn.features
                let speaker = features?.speaker ?? 0
                let gap = previousEnd.map { turn.wallStartMs - $0 } ?? Int64.max
                let joins =
                    blockSegment == seg && gap < ConversationSegmenter.blockJoinGapMs
                    && turn.wallEndMs - (out.last?.block.wallStartMs ?? turn.wallStartMs)
                        < ConversationSegmenter.blockMaxMs
                    && out.last?.block.isOpaque == false
                if joins {
                    var block = out[out.count - 1].block
                    block.wallEndMs = max(block.wallEndMs, turn.wallEndMs)
                    block.words += turn.words
                    block.terms.append(contentsOf: features?.terms ?? [])
                    // A new line: another voice, or the same one after a breath.
                    let sameLine =
                        speaker == lineSpeaker && turn.wallStartMs - lineEnd
                        < ConversationSegmenter.lineJoinGapMs
                        && turn.wallEndMs - lineStart < ConversationSegmenter.blockMaxMs
                    if !sameLine {
                        block.lines += 1
                        lineSpeaker = speaker
                        lineStart = turn.wallStartMs
                    }
                    lineEnd = max(lineEnd, turn.wallEndMs)
                    speakers.insert(speaker)
                    block.isDialogue = speakers.count > 1
                    block.isForeign = block.isForeign || (features?.isForeign ?? false)
                    block.isDictation = block.isDictation || (features?.isDictation ?? false)
                    out[out.count - 1].block = block
                } else {
                    speakers = [speaker]
                    lineSpeaker = speaker
                    lineStart = turn.wallStartMs
                    lineEnd = turn.wallEndMs
                    blockSegment = seg
                    var cut = position(beforeTurn: turnCursor, in: turns)
                    if cut < lower { cut = lower }
                    out.append(
                        PlacedBlock(
                            block: SegmenterBlock(
                                wallStartMs: turn.wallStartMs, wallEndMs: turn.wallEndMs,
                                gapBeforeMs: gapBefore(turn.wallStartMs), lines: 1,
                                words: turn.words, terms: features?.terms ?? [],
                                isDialogue: false, isForeign: features?.isForeign ?? false,
                                isDictation: features?.isDictation ?? false,
                                opensWithGreeting: features?.opensWithGreeting ?? false),
                            position: cut))
                }
                previousEnd = max(previousEnd ?? turn.wallEndMs, turn.wallEndMs)
                turnCursor += 1
            }
            // Turns of this member at or past `high` belong to the next stretch.
            while turnCursor < turns.count, turns[turnCursor].seg == seg { turnCursor += 1 }
        }
        return out
    }

    static func segmenterCuts(
        from lower: RunPosition, to upper: RunPosition, members: [Member], turns: [RunTurn],
        policy: SegmenterPolicy, isBlocked: (RunPosition) -> Bool, endsOpen: Bool
    ) -> [PlannedCut] {
        let placed = blocks(from: lower, to: upper, members: members, turns: turns)
        guard placed.count > 1 else { return [] }
        var blocked = Set<Int>()
        for (index, block) in placed.enumerated() where index > 0 {
            // A cut must move the position forward, and must not be where the person said no.
            if block.position <= lower || isBlocked(block.position) { blocked.insert(index) }
        }
        let starts = ConversationSegmenter.cuts(
            blocks: placed.map(\.block), blocked: blocked, policy: policy)
        guard !starts.isEmpty else { return [] }

        // How far settled talk runs after each block without an unsettled stretch in the way.
        var settledThrough = [Int64](repeating: 0, count: placed.count)
        var reach: Int64 = endsOpen ? Int64.min : Int64.max
        for index in placed.indices.reversed() {
            if placed[index].block.isOpaque {
                reach = Int64.min
            } else if reach != .max {
                reach = max(reach, placed[index].block.wallEndMs)
            }
            settledThrough[index] = reach
        }

        var out: [PlannedCut] = []
        for (order, start) in starts.enumerated() {
            let block = placed[start].block
            let previousStart = order > 0 ? starts[order - 1] : 0
            // Both conversations the cut separates must be fully heard.
            let nextStart = order + 1 < starts.count ? starts[order + 1] : placed.count
            let heard = !placed[previousStart..<nextStart].contains { $0.block.isOpaque }
            let through = settledThrough[start]
            let settled =
                heard && !block.isOpaque
                && (through == .max || through - block.wallStartMs >= commitLagMs)
            let reason: ConversationStartReason =
                block.isOpaque ? .length : (block.gapBeforeMs >= 120_000 ? .lull : .topicChange)
            out.append(
                PlannedCut(
                    position: placed[start].position, reason: reason, kind: .segmenter,
                    shouldCommit: settled))
        }
        return out
    }

    // --- tidying -------------------------------------------------------------------------------

    /// A fixed or segmenter cut that would start a unit with nothing in it — its words have
    /// since been deleted, or a re-transcription moved them — is dropped, so the empty range
    /// joins the conversation before it as ordinary trailing silence instead of appearing as a
    /// conversation of its own. Hard cuts are left alone: the silent tail of a run, and the
    /// silence before its first word, are exactly what they are for.
    static func droppingEmptyUnits(
        _ cuts: [PlannedCut], members: [Member], turns: [RunTurn], runEnd: RunPosition
    ) -> [PlannedCut] {
        guard !cuts.isEmpty else { return cuts }
        var kept = cuts
        var changed = true
        while changed {
            changed = false
            let edges = [RunPosition(seg: 0, mediaMs: 0)] + kept.map(\.position) + [runEnd]
            for unit in 0..<(edges.count - 1) {
                let lower = edges[unit]
                let upper = edges[unit + 1]
                guard !hasContent(from: lower, to: upper, members: members, turns: turns) else {
                    continue
                }
                if unit > 0, kept[unit - 1].kind != .hard {
                    kept.remove(at: unit - 1)
                    changed = true
                    break
                }
                if unit == 0, !kept.isEmpty, kept[0].kind != .hard {
                    kept.remove(at: 0)
                    changed = true
                    break
                }
            }
        }
        return kept
    }

    /// Whether `[lower, upper)` holds a turn, or any audio whose transcript is not settled.
    static func hasContent(
        from lower: RunPosition, to upper: RunPosition, members: [Member], turns: [RunTurn]
    ) -> Bool {
        let first = turns.partitioningIndex {
            RunPosition(seg: $0.seg, mediaMs: $0.mediaStartMs) >= lower
        }
        if first < turns.count,
            RunPosition(seg: turns[first].seg, mediaMs: turns[first].mediaStartMs) < upper
        {
            return true
        }
        for seg in lower.seg..<min(upper.seg + 1, members.count) where !members[seg].isSettled {
            let low = seg == lower.seg ? lower.mediaMs : 0
            let high = seg == upper.seg ? upper.mediaMs : Int64.max
            if high > low { return true }
        }
        return false
    }
}

extension Array {
    /// Index of the first element for which `predicate` is true, the array being partitioned
    /// (every false before every true).
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
