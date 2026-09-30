import Foundation
import SegmentStore

// The promises `HistoryDay` makes (its doc comment), checked against the coverage the day was
// built from — independently of how `HistoryDayBuilder` got there. Used by the honesty tests on
// synthetic and fuzzed days, and by the real-backup run; cheap enough for a debug assertion.

extension HistoryDayBuilder {
    /// Every way `day` breaks a promise, in words; empty when it keeps them all. `input` must be
    /// what the day was built from.
    public static func honestyViolations(of day: HistoryDay, input: Input) -> [String] {
        var problems: [String] = []
        func fail(_ message: String) { problems.append(message) }

        guard day.hasRecordings else {
            if !day.items.isEmpty { fail("a day with no recordings has items") }
            if day.leadingEdge != nil || day.trailingEdge != nil { fail("a day with no recordings has an edge") }
            return problems
        }
        if day.isToday, day.trailingEdge != nil { fail("today has a trailing edge") }

        // Shape: in order, tiling, zone dividers only between two items, ids unique.
        let timed = day.items.filter { if case .zoneChange = $0 { return false } else { return true } }
        if Set(day.items.map(\.id)).count != day.items.count { fail("item ids are not unique") }
        if case .zoneChange? = day.items.first { fail("the day starts with a zone divider") }
        if case .zoneChange? = day.items.last { fail("the day ends with a zone divider") }
        for item in day.items where item.endMs < item.startMs { fail("item \(item.id) ends before it starts") }
        var afterZoneChange = false
        var previous: HistoryItem?
        for item in day.items {
            if case .zoneChange = item {
                afterZoneChange = true
                continue
            }
            if let previous, previous.endMs != item.startMs {
                // Across a divider the day may jump (a date that happened twice: the other date's
                // time lies between); anywhere else it must tile.
                if !(afterZoneChange && item.startMs > previous.endMs) {
                    fail("hole or overlap between \(previous.id) and \(item.id): \(previous.endMs) → \(item.startMs)")
                }
            }
            previous = item
            afterZoneChange = false
        }
        if let live = day.items.last(where: { if case .live = $0 { return true } else { return false } }),
            live.id != day.items.last?.id
        {
            fail("the live block is not last")
        }
        if input.isLive, input.nowMs != nil, !day.items.isEmpty {
            if case .live? = day.items.last {} else { fail("today while recording does not end in the live block") }
        }
        guard let first = timed.first, let last = timed.last else { return problems }

        // What coverage says, over the same windows (and the deletions, which win over it).
        var missing: [Range<Int64>] = []
        var quiet: [Range<Int64>] = []
        var off: [Range<Int64>] = []
        var recorded: [Range<Int64>] = []
        var userPaused: [Range<Int64>] = []
        var domains: [Range<Int64>] = []
        for window in input.windows {
            let coverage = CoverageComputer.computeAttributed(
                dateKey: input.dateKey, timeZoneID: window.zoneID, segments: input.segments,
                pauses: input.pauses, nowMs: input.nowMs)
            guard let domain = coverage.domain, let range = clip(window.range, to: domain) else { continue }
            domains.append(range)
            for span in coverage.spansWithWatchQuiet {
                guard let piece = clip(span.startMs..<span.endMs, to: range) else { continue }
                switch span.kind {
                case .missing: missing.append(piece)
                case .quiet: quiet.append(piece)
                case .off: off.append(piece)
                case .recorded: recorded.append(piece)
                case .paused: break
                }
            }
            // A person's pause (not the watch's power save) wherever coverage drew paused.
            let pausedSpans = coverage.coverage.spans.filter { $0.kind == .paused }.map { $0.startMs..<$0.endMs }
            let personal = coverage.pauseRecords.filter { pauseActor(forSource: $0.source) != .watchPowerSave }
                .map(\.range)
            userPaused += intersect(mergeRanges(pausedSpans), mergeRanges(personal)).compactMap { clip($0, to: range) }
        }
        let deleted = mergeRanges(input.deletedSpans.map { $0.startMs..<$0.endMs })
        missing = subtractRanges(missing, subtracting: deleted)
        quiet = subtractRanges(quiet, subtracting: deleted)
        off = subtractRanges(off, subtracting: deleted)
        recorded = subtractRanges(recorded, subtracting: deleted)

        func ranges(_ include: (HistoryItem) -> Bool) -> [Range<Int64>] {
            mergeRanges(timed.filter(include).map { $0.startMs..<$0.endMs })
        }
        func isGap(_ kind: HistoryGap.Kind) -> (HistoryItem) -> Bool {
            { if case .gap(let gap) = $0 { return gap.kind == kind } else { return false } }
        }
        let cards = ranges { if case .chapter = $0 { return true } else { return false } }
        let missingItems = ranges(isGap(.audioMissing))
        // Quiet that says outright how much loss it holds (`carryShortLoss`) is checked by the
        // per-item rule above; the rest must hold none.
        let quietItems = ranges { if case .gap(let gap) = $0 { return gap.kind == .quiet && gap.missingMs == 0 } else { return false } }
        let shown = first.startMs..<last.endMs
        func total(_ list: [Range<Int64>]) -> Int64 { list.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

        // Loss is never reduced or relabelled: every millisecond of it is an `.audioMissing`
        // item or counted in the `missingMs` of the item it lies in, and the sum shown is at
        // least coverage's.
        let lossInView = missing.compactMap { clip($0, to: shown) }
        var shownMissing: Int64 = 0
        for item in timed {
            let carried: Int64
            switch item {
            case .gap(let gap) where gap.kind == .audioMissing:
                shownMissing += gap.endMs - gap.startMs
                continue
            case .gap(let gap):
                carried = gap.missingMs
            case .chapter(let block):
                carried = block.missingMs
            case .live, .zoneChange:
                carried = 0
            }
            shownMissing += carried
            let inside = total(missing.compactMap { clip($0, to: item.startMs..<item.endMs) })
            if carried < inside { fail("\(item.id) holds \(inside) ms of loss but shows \(carried) ms missing") }
        }
        if shownMissing < total(lossInView) {
            fail("missing shown \(shownMissing) ms < coverage's \(total(lossInView)) ms")
        }
        // ...and never invented: every `.audioMissing` item is loss coverage drew.
        let inventedLoss = subtractRanges(missingItems, subtracting: missing)
        if total(inventedLoss) > 0 { fail("\(total(inventedLoss)) ms drawn as missing that coverage does not call loss") }
        // Suppressed silence is never missing; loss and unrecorded time are never quiet.
        if total(intersect(quiet, missingItems)) > 0 { fail("quiet drawn as missing") }
        if total(intersect(missing, quietItems)) > 0 { fail("loss drawn as quiet") }
        if total(intersect(off, quietItems)) > 0 { fail("time nothing recorded drawn as quiet") }
        // Loss is never in an edge (edges hold only what lies outside the items).
        let outside = subtractRanges(domains, subtracting: [shown])
        if total(intersect(missing, outside)) > 0 { fail("loss folded into an edge") }
        if total(intersect(mergeRanges(userPaused), outside)) > 0 { fail("a person's pause folded into an edge") }
        if total(intersect(deleted, outside)) > 0 { fail("a deletion folded into an edge") }
        if let edge = day.leadingEdge, edge.atMs != first.startMs { fail("leading edge is not where the items start") }
        if let edge = day.trailingEdge, edge.atMs != last.endMs { fail("trailing edge is not where the items end") }

        // A recording that failed or is not transcribed yet is never inside a card.
        let untranscribed = mergeRanges(
            input.segmentStates.filter { !($0.state == .complete || $0.state == .noSpeech) }
                .map { $0.startMs..<$0.endMs })
        let hidden = intersect(intersect(recorded, untranscribed), cards)
        if total(hidden) > 0 { fail("\(total(hidden)) ms of untranscribed recording inside a card") }
        return problems
    }

    /// Pairwise intersection of two range lists (any order, any overlap), merged.
    static func intersect(_ a: [Range<Int64>], _ b: [Range<Int64>]) -> [Range<Int64>] {
        let left = mergeRanges(a)
        let right = mergeRanges(b)
        var result: [Range<Int64>] = []
        var i = 0
        var j = 0
        while i < left.count, j < right.count {
            if let overlap = clip(left[i], to: right[j]) { result.append(overlap) }
            if left[i].upperBound < right[j].upperBound { i += 1 } else { j += 1 }
        }
        return result
    }
}
