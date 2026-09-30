import CoreGraphics
import Foundation
import Testing

// Card size tiers (2026-10): which card a conversation gets, by its length, and how each
// tier's floor compares with the height its time is given on the 70 pt/hour scale.

@Suite("chapter card tiers")
struct ChapterCardTierTests {
    private func minutes(_ m: Double) -> Int64 { Int64(m * 60_000) }
    private let metrics = ChapterCardMetrics(
        titleLine: 20, timeLine: 15, summaryLine: 17, pillRow: 18, followUpRow: 21)

    @Test func tiersFollowTheDuration() {
        #expect(ChapterCardTier.tier(durationMs: minutes(0.1)) == .compact)
        #expect(ChapterCardTier.tier(durationMs: minutes(9.9)) == .compact)
        #expect(ChapterCardTier.tier(durationMs: minutes(10)) == .medium)
        #expect(ChapterCardTier.tier(durationMs: minutes(24.9)) == .medium)
        #expect(ChapterCardTier.tier(durationMs: minutes(25)) == .full)
        #expect(ChapterCardTier.tier(durationMs: minutes(90)) == .full)
    }

    @Test func accessibilitySizesMoveEveryTierOneStepUp() {
        #expect(ChapterCardTier.tier(durationMs: minutes(3), isAccessibilitySize: true) == .medium)
        #expect(ChapterCardTier.tier(durationMs: minutes(15), isAccessibilitySize: true) == .full)
        #expect(ChapterCardTier.tier(durationMs: minutes(40), isAccessibilitySize: true) == .full)
    }

    @Test func floorsShrinkWithTheTier() {
        let full = ChapterCardTier.full.floorHeight(metrics)
        let medium = ChapterCardTier.medium.floorHeight(metrics)
        let compact = ChapterCardTier.compact.floorHeight(metrics)
        #expect(full == 106)
        // 8 + 20 + 2 + 18 (the pills set the second line) + 9
        #expect(medium == 57)
        #expect(compact == 34)
        #expect(compact < medium && medium < full)
    }

    /// The numbers the tiers were chosen by, at the default text size: printed for the report.
    @Test @MainActor func floorVersusTimeAtTheBoundaries() {
        let m = ChapterCardMetrics.standard
        for (tier, at) in [(ChapterCardTier.compact, 5.0), (.compact, 10), (.medium, 10), (.medium, 25), (.full, 25), (.full, 60)] {
            let floor = tier.floorHeight(m)
            let time = TimelineGeometry.minHeight(for: TimelineSpan(startMs: 0, endMs: minutes(at)))
            print(String(format: "[tiers] %@ at %.0f min: floor %.0f pt, time %.0f pt (floor = %.0f min of scale)",
                         tier.rawValue, at, floor, time, Double(floor) / (70.0 / 60.0)))
        }
        #expect(ChapterCardTier.compact.floorHeight(m) < 40)
    }
}
