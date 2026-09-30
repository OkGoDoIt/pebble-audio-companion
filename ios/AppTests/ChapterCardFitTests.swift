import CoreGraphics
import Foundation
import SwiftUI
import Testing

// Whether a chapter card's follow-ups collapse to "first + N more" (plan 5.3, 7.12). It is
// decided before layout because it changes which views exist; these pin the rule with fixed
// line heights so the answer does not depend on the fonts of the machine running the tests.

@Suite("chapter card fitting")
struct ChapterCardFitTests {
    /// Round numbers close to the system font at the default size.
    private let metrics = ChapterCardMetrics(
        titleLine: 20, timeLine: 15, summaryLine: 17, pillRow: 18, followUpRow: 21)

    private func minutes(_ m: Int) -> Int64 { Int64(m) * 60_000 }

    @Test func theFloorIsTitleTimeOneSummaryLineAndPills() {
        let height = ChapterCardFit.estimatedHeight(
            showsSummary: true, hasPills: true, followUps: 0, metrics: metrics)
        // 10 + 20 + 2 + 15 + 5 + 17 + 8 + 18 + 11
        #expect(height == 106)
        let bare = ChapterCardFit.estimatedHeight(
            showsSummary: false, hasPills: false, followUps: 0, metrics: metrics)
        #expect(bare == 58)
        let withTwo = ChapterCardFit.estimatedHeight(
            showsSummary: true, hasPills: true, followUps: 2, metrics: metrics)
        // ...plus 10 above the hairline, 7 below it and two 21-pt lines.
        #expect(withTwo == 165)
    }

    @Test func oneFollowUpNeverCollapses() {
        #expect(!ChapterCardFit.collapsesFollowUps(
            durationMs: minutes(10), followUpCount: 1, showsSummary: false, hasPills: true,
            metrics: metrics, timeline: .standard))
    }

    @Test func aShortCardWithSeveralFollowUpsCollapses() {
        // 40 min → 120 pt band; three follow-ups take the card to 186 pt.
        #expect(ChapterCardFit.collapsesFollowUps(
            durationMs: minutes(40), followUpCount: 3, showsSummary: true, hasPills: true,
            metrics: metrics, timeline: .standard))
    }

    @Test func aLongCardKeepsAllItsFollowUps() {
        // 125 min → 375 pt band.
        #expect(!ChapterCardFit.collapsesFollowUps(
            durationMs: minutes(125), followUpCount: 3, showsSummary: true, hasPills: true,
            metrics: metrics, timeline: .standard))
    }

    @Test func theBandIsExactlyTheLimit() {
        // Two follow-ups: 165 pt. A 55-min card (165 pt band) keeps both; 54 min collapses.
        #expect(!ChapterCardFit.collapsesFollowUps(
            durationMs: minutes(55), followUpCount: 2, showsSummary: true, hasPills: true,
            metrics: metrics, timeline: .standard))
        #expect(ChapterCardFit.collapsesFollowUps(
            durationMs: minutes(54), followUpCount: 2, showsSummary: true, hasPills: true,
            metrics: metrics, timeline: .standard))
    }

    @Test func aLargerTextSizeWidensTheBand() {
        let big = TimelineMetrics(typeScale: 2)
        #expect(!ChapterCardFit.collapsesFollowUps(
            durationMs: minutes(40), followUpCount: 3, showsSummary: true, hasPills: true,
            metrics: metrics, timeline: big))
    }

    @Test func noSummaryUnderTwentyFiveMinutes() {
        #expect(!ChapterCardFit.showsSummary(durationMs: minutes(18), hasSummary: true))
        #expect(ChapterCardFit.showsSummary(durationMs: minutes(25), hasSummary: true))
        #expect(!ChapterCardFit.showsSummary(durationMs: minutes(90), hasSummary: false))
    }

    @Test @MainActor func metricsGrowWithTheTextSize() {
        let standard = ChapterCardMetrics(dynamicTypeSize: .large)
        #expect(standard == ChapterCardMetrics.standard)
        let ax3 = ChapterCardMetrics(dynamicTypeSize: .accessibility3)
        #expect(ax3.titleLine > standard.titleLine * 1.5)
        #expect(ax3.summaryLine > standard.summaryLine * 1.5)
    }
}
