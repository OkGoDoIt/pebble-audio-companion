import AppDB
import Foundation
import Testing

// The DEBUG grouping of short conversations (-historyGroupShort): a pure function from the
// day's items to what the timeline draws. The model does not change.

@Suite("History short-conversation grouping")
struct HistoryDisplayGroupingTests {
    private let zone = "UTC"

    private func card(_ id: String, _ start: Int, _ end: Int) -> HistoryItem {
        .chapter(HistoryChapterBlock(
            id: id, startMs: Int64(start) * 60_000, endMs: Int64(end) * 60_000, zoneID: zone,
            source: .chapter, title: id, summary: nil))
    }

    private func gap(_ kind: HistoryGap.Kind, _ start: Int, _ end: Int) -> HistoryItem {
        .gap(HistoryGap(id: "g\(start)", kind: kind, startMs: Int64(start) * 60_000, endMs: Int64(end) * 60_000, zoneID: zone))
    }

    private func shape(_ items: [HistoryDisplayItem]) -> [String] {
        items.map {
            switch $0 {
            case .item(.chapter(let b)): return b.id
            case .item(.gap(let g)): return "\(g.kind.rawValue)"
            case .item: return "other"
            case .shortRun(let blocks): return "[" + blocks.map(\.id).joined(separator: ",") + "]"
            }
        }
    }

    @Test func shortNeighboursWithShortQuietBetweenBecomeOneRun() {
        let items = [card("a", 0, 5), gap(.quiet, 5, 12), card("b", 12, 16), card("c", 16, 19)]
        let grouped = HistoryDisplayGrouping.group(items)
        #expect(shape(grouped) == ["[a,b,c]"])
        #expect(grouped[0].startMs == 0 && grouped[0].endMs == 19 * 60_000)
    }

    @Test func aTenMinuteCardEndsARun() {
        let items = [card("a", 0, 5), card("b", 5, 9), card("long", 9, 19), card("c", 19, 22)]
        #expect(shape(HistoryDisplayGrouping.group(items)) == ["[a,b]", "long", "c"])
    }

    @Test func aLongQuietOrAnyLabelledGapEndsARun() {
        let quiet = [card("a", 0, 5), gap(.quiet, 5, 20), card("b", 20, 24)]
        #expect(shape(HistoryDisplayGrouping.group(quiet)) == ["a", "quiet", "b"])
        for kind in [HistoryGap.Kind.paused, .audioMissing, .notRecording, .noConversation, .deleted] {
            let items = [card("a", 0, 5), gap(kind, 5, 8), card("b", 8, 12)]
            #expect(shape(HistoryDisplayGrouping.group(items)) == ["a", kind.rawValue, "b"], "\(kind)")
        }
    }

    @Test func aTrailingQuietAfterARunIsKept() {
        let items = [card("a", 0, 5), card("b", 5, 9), gap(.quiet, 9, 14), card("long", 14, 40)]
        #expect(shape(HistoryDisplayGrouping.group(items)) == ["[a,b]", "quiet", "long"])
    }

    @Test func aSingleShortCardStaysACard() {
        let items = [card("a", 0, 5), gap(.quiet, 5, 30), card("b", 30, 34)]
        #expect(shape(HistoryDisplayGrouping.group(items)) == ["a", "quiet", "b"])
    }

    @Test func offDrawsEveryItemAsItIs() {
        let items = [card("a", 0, 5), card("b", 5, 9)]
        #expect(shape(HistoryDisplayGrouping.group(items, enabled: false)) == ["a", "b"])
    }

    @Test func theRunCoversTheTimeExactly() {
        let items = [card("x", 0, 30), card("a", 30, 35), gap(.quiet, 35, 40), card("b", 40, 44), gap(.quiet, 44, 60), card("y", 60, 90)]
        let grouped = HistoryDisplayGrouping.group(items)
        for (a, b) in zip(grouped, grouped.dropFirst()) { #expect(a.endMs == b.startMs) }
    }
}
