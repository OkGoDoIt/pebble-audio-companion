import Foundation
import Testing
@testable import AppDB

// One block between conversations: runs of gaps fold into one stretch with one label, and
// nothing about their time or their loss is lost on the way.

@Suite("History stretches")
struct HistoryStretchTests {
    private let zone = "UTC"
    private func m(_ minutes: Double) -> Int64 { Int64(minutes * 60_000) }

    private func gap(
        _ kind: HistoryGap.Kind, _ from: Double, _ to: Double, missingSeconds: Double = 0,
        descriptor: String? = nil
    ) -> HistoryItem {
        var g = HistoryGap(
            id: "g\(from)", kind: kind, startMs: m(from), endMs: m(to), zoneID: zone,
            descriptor: descriptor)
        g.missingMs = Int64(missingSeconds * 1000)
        return .gap(g)
    }

    private func card(_ from: Double, _ to: Double) -> HistoryItem {
        .chapter(HistoryChapterBlock(
            id: "c\(from)", startMs: m(from), endMs: m(to), zoneID: zone, source: .chapter,
            title: "t", summary: nil))
    }

    private func day(_ items: [HistoryItem], isToday: Bool = false) -> HistoryDay {
        HistoryDay(dateKey: "2026-09-29", zoneID: zone, isToday: isToday, hasRecordings: true,
                   leadingEdge: nil, items: items, trailingEdge: nil)
    }

    private func stretch(_ items: [HistoryItem]) -> HistoryStretch {
        let entries = HistoryStretches.combine(day(items))
        guard entries.count == 1, case .stretch(let s) = entries[0] else {
            Issue.record("expected one stretch, got \(entries)")
            return HistoryStretch(parts: [])
        }
        return s
    }

    /// The night of 09-29 → 09-30 as Roger's phone drew it: thirteen labelled blocks between two
    /// conversations (seconds as fractions of a minute).
    private var night: [HistoryItem] {
        [
            gap(.paused, 0, 38),                                 // 10:13 – 10:51
            gap(.quiet, 38, 45, missingSeconds: 90),              // · 1 min missing
            gap(.notRecording, 45, 45.33),
            gap(.audioMissing, 45.33, 45.83),
            gap(.notRecording, 45.83, 46.17),
            gap(.audioMissing, 46.17, 46.67),
            gap(.notRecording, 46.67, 47),
            gap(.quiet, 47, 47.5, missingSeconds: 15),
            gap(.paused, 47.5, 56.5),                             // 11:00 – 11:09
            gap(.quiet, 56.5, 61),
            gap(.notRecording, 61, 61.3),                         // 11:14
            gap(.paused, 61.3, 103.3),                            // 11:14 – 11:56
            gap(.quiet, 103.3, 108.8),
            gap(.notRecording, 108.8, 109.1),                     // 12:02
            gap(.paused, 109.1, 123.1),                           // 12:02 – 12:16
            gap(.quiet, 123.1, 140),
        ]
    }

    @Test func theThirteenBlockNightIsOneBlock() {
        let entries = HistoryStretches.combine(day([card(-30, 0)] + night + [card(140, 154)]))
        #expect(entries.count == 3)
        guard case .stretch(let s) = entries[1] else { Issue.record("no stretch"); return }
        #expect(s.parts.count == night.count)
        let summary = s.summary
        #expect(summary.primary == .paused)
        #expect(summary.primaryMs == m(38) + m(9) + m(42) + m(14))   // 1 hr 43 min
        #expect(summary.secondary == nil)
        #expect(!summary.isBare)
        #expect(summary.lossWordsMs == s.lossMs)
    }

    @Test func aStretchCoversExactlyItsPartsWithNoOverlap() {
        let s = stretch(night)
        #expect(s.startMs == 0 && s.endMs == m(140))
        for (a, b) in zip(s.parts, s.parts.dropFirst()) { #expect(a.endMs == b.startMs) }
        let covered = s.parts.reduce(Int64(0)) { $0 + $1.endMs - $1.startMs }
        #expect(covered == s.durationMs)
    }

    @Test func noLossIsDropped() {
        let s = stretch(night)
        let pieces = s.parts.filter { $0.kind == .audioMissing }.reduce(Int64(0)) { $0 + $1.endMs - $1.startMs }
        let carried = s.parts.filter { $0.kind != .audioMissing }.reduce(Int64(0)) { $0 + $1.missingMs }
        #expect(s.lossMs == pieces + carried)
        #expect(s.lossMs > 0 && s.hasLoss)
    }

    @Test func runsEndAtCardsPendingCardsZoneChangesAndTodaysOpenEndedGap() {
        let pending = gap(.notTranscribedYet, 20, 30)
        let items: [HistoryItem] = [gap(.quiet, 0, 10), gap(.paused, 10, 20), pending, gap(.quiet, 30, 40),
                                    .zoneChange(HistoryZoneChange(atMs: m(40), zoneID: "Asia/Tokyo")),
                                    gap(.quiet, 40, 50), card(50, 60), gap(.paused, 60, 70)]
        let entries = HistoryStretches.combine(day(items, isToday: true))
        let shape = entries.map { entry -> String in
            switch entry {
            case .stretch(let s): return "S\(s.parts.count)"
            case .item(.gap): return "gap"
            case .item(.chapter): return "card"
            case .item(.zoneChange): return "zone"
            case .item(.live): return "live"
            }
        }
        #expect(shape == ["S2", "gap", "S1", "zone", "S1", "card", "gap"])
    }

    // MARK: The label

    @Test func primaryOnlyIsTheClassWithTheMostTime() {
        let s = stretch([gap(.quiet, 0, 20), gap(.paused, 20, 60)])
        #expect(s.summary.primary == .paused && s.summary.primaryMs == m(40))
        #expect(s.summary.secondary == nil)   // quiet 20 min is under 30
    }

    @Test func aSecondClassNeedsThirtyMinutesAndAThird() {
        let two = stretch([gap(.paused, 0, 70), gap(.quiet, 70, 120)])
        #expect(two.summary.secondary == HistoryStretch.Share(.quiet, m(50)))
        // 35 min is not a third of 150.
        let short = stretch([gap(.paused, 0, 115), gap(.quiet, 115, 150)])
        #expect(short.summary.secondary == nil)
    }

    @Test func lossAsPrimaryIsTheTitle() {
        let s = stretch([gap(.audioMissing, 0, 10), gap(.audioMissing, 10, 31), gap(.notRecording, 31, 31.5)])
        #expect(s.summary.primary == .loss)
        #expect(s.summary.primaryMs == m(31))
        #expect(s.summary.lossWordsMs == nil)
    }

    @Test func lossOfAMinuteOrMoreIsSaidAndLessIsLeftToTheAxis() {
        let said = stretch([gap(.quiet, 0, 40, missingSeconds: 180)])
        #expect(said.summary.lossWordsMs == m(3))
        let unsaid = stretch([gap(.quiet, 0, 40, missingSeconds: 20)])
        #expect(unsaid.summary.lossWordsMs == nil)
        #expect(unsaid.hasLoss)
    }

    @Test func bareThresholds() {
        #expect(stretch([gap(.quiet, 0, 29)]).summary.isBare)
        #expect(!stretch([gap(.quiet, 0, 30)]).summary.isBare)
        #expect(stretch([gap(.paused, 0, 9)]).summary.isBare)
        #expect(!stretch([gap(.paused, 0, 10)]).summary.isBare)
        // Loss of a minute or more is always labelled, however short the stretch.
        #expect(!stretch([gap(.notRecording, 0, 3, missingSeconds: 60)]).summary.isBare)
        #expect(stretch([gap(.notRecording, 0, 3, missingSeconds: 30)]).summary.isBare)
    }

    @Test func quietSaysNoConversationWhenMostOfItIs() {
        let s = stretch([gap(.quiet, 0, 7, missingSeconds: 20), gap(.noConversation, 7, 25, missingSeconds: 20)])
        #expect(s.summary.primary == .quiet && s.summary.primaryMs == m(25))
        #expect(s.quietIsMostlyNoConversation)
        #expect(s.summary.isBare)            // under 30 min, loss under a minute
        #expect(s.hasLoss)
    }

    @Test func describedAudioIsItsOwnClass() {
        let s = stretch([gap(.quiet, 0, 10), gap(.noConversation, 10, 50, descriptor: "music")])
        #expect(s.summary.primary == .described)
        #expect(s.dominantDescriptor == "music")
    }

    @Test func aSingleOpenablePieceKeepsItsOwnBehaviour() {
        var g = HistoryGap(id: "n", kind: .noConversation, startMs: 0, endMs: m(45), zoneID: zone, isOpenable: true)
        #expect(HistoryStretch(parts: [g]).singleOpenablePiece != nil)
        g.isOpenable = false
        #expect(HistoryStretch(parts: [g]).singleOpenablePiece == nil)
    }
}
