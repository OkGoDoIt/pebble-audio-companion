import CoreGraphics
import SwiftUI
import UIKit

// How a chapter card fits its time (plan 5.3 "The time scale", 7.12 "Fitting a chapter's text").
//
// The card aims to stay under `duration × 3 pt`. To get there it first gives up summary lines,
// down to one — that is done in layout, by proposing the summary the height that is left — and
// then collapses its follow-ups to the first plus "N more". The second step changes WHICH views
// exist, so it cannot be a layout decision; it is decided here, before layout, from the
// duration, the number of follow-ups and the line heights at the current text size.
//
// The floor — title, time line, one summary line, pills — is never cut, so a very short chapter
// may exceed its band.

/// The vertical measurements of a chapter card at one text size. Constants are the mockup's
/// paddings; line heights come from the fonts the card draws with.
struct ChapterCardMetrics: Equatable, Sendable {
    var titleLine: CGFloat
    var timeLine: CGFloat
    var summaryLine: CGFloat
    var pillRow: CGFloat
    var followUpRow: CGFloat

    static let paddingTop: CGFloat = 10
    static let paddingBottom: CGFloat = 11
    static let paddingHorizontal: CGFloat = 13
    static let titleToTime: CGFloat = 2
    static let timeToSummary: CGFloat = 5
    static let pillsTop: CGFloat = 8
    static let pillSpacing: CGFloat = 5
    /// Space above the hairline, and between it and the first follow-up.
    static let followUpsTop: CGFloat = 10
    static let followUpsInset: CGFloat = 7
    /// Vertical padding around each follow-up line.
    static let followUpRowPadding: CGFloat = 2
    static let pillVerticalPadding: CGFloat = 2

    /// The default text size, measured from the system font (SwiftUI lays a line of text out at
    /// the font's line height).
    static let standard = ChapterCardMetrics(
        titleLine: lineHeight(16, .semibold), timeLine: lineHeight(12),
        summaryLine: lineHeight(14), pillRow: lineHeight(11, .medium) + 2 * pillVerticalPadding,
        followUpRow: lineHeight(14) + 2 * followUpRowPadding)

    init(
        titleLine: CGFloat, timeLine: CGFloat, summaryLine: CGFloat, pillRow: CGFloat,
        followUpRow: CGFloat
    ) {
        self.titleLine = titleLine
        self.timeLine = timeLine
        self.summaryLine = summaryLine
        self.pillRow = pillRow
        self.followUpRow = followUpRow
    }

    /// The same card at a Dynamic Type size. Each line scales with the text style its font is
    /// anchored to (`HistoryType`).
    @MainActor
    init(dynamicTypeSize: DynamicTypeSize) {
        let traits = UITraitCollection(
            preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        func scaled(_ size: CGFloat, _ style: UIFont.TextStyle, _ weight: UIFont.Weight = .regular)
            -> CGFloat
        {
            let pointSize = UIFontMetrics(forTextStyle: style).scaledValue(
                for: size, compatibleWith: traits)
            return Self.lineHeight(pointSize, weight)
        }
        self.init(
            titleLine: scaled(16, .callout, .semibold),
            timeLine: scaled(12, .caption1),
            summaryLine: scaled(14, .subheadline),
            pillRow: scaled(11, .caption2, .medium) + 2 * Self.pillVerticalPadding,
            followUpRow: scaled(14, .subheadline) + 2 * Self.followUpRowPadding)
    }

    static func lineHeight(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> CGFloat {
        UIFont.systemFont(ofSize: size, weight: weight).lineHeight.rounded(.up)
    }
}

enum ChapterCardFit {

    /// Chapters under 25 minutes show no summary at all.
    static func showsSummary(durationMs: Int64, hasSummary: Bool) -> Bool {
        hasSummary && Double(durationMs) / 60_000 >= TimelineScale.noSummaryUnderMinutes
    }

    /// The card's height with one summary line and `followUps` follow-up lines, assuming a
    /// one-line title and one row of pills.
    static func estimatedHeight(
        showsSummary: Bool, hasPills: Bool, followUps: Int, metrics: ChapterCardMetrics
    ) -> CGFloat {
        typealias M = ChapterCardMetrics
        var height = M.paddingTop + metrics.titleLine + M.titleToTime + metrics.timeLine
        if showsSummary { height += M.timeToSummary + metrics.summaryLine }
        if hasPills { height += M.pillsTop + metrics.pillRow }
        if followUps > 0 {
            height += M.followUpsTop + M.followUpsInset + CGFloat(followUps) * metrics.followUpRow
        }
        return height + M.paddingBottom
    }

    /// Whether the card's follow-ups collapse to the first one plus "N more": only when there
    /// is more than one, and only when showing them all would take the card past its soft
    /// maximum even with its summary cut to one line.
    static func collapsesFollowUps(
        durationMs: Int64, followUpCount: Int, showsSummary: Bool, hasPills: Bool,
        metrics: ChapterCardMetrics, timeline: TimelineMetrics
    ) -> Bool {
        guard followUpCount > 1 else { return false }
        let span = TimelineSpan(startMs: 0, endMs: durationMs)
        let full = estimatedHeight(
            showsSummary: showsSummary, hasPills: hasPills, followUps: followUpCount,
            metrics: metrics)
        return full > TimelineGeometry.softMaxHeight(for: span, metrics: timeline)
    }
}

// MARK: - Size tiers

/// How much of a card a conversation of a given length gets (2026-10: conversations became
/// topic-sized — median 16 min, a quarter under 5 — and the full card's floor, ~106 pt, is
/// 90 minutes of the 70 pt/hour scale). Each tier's floor is chosen to sit as close to its
/// duration's height as legible text allows, so the hour scale Roger tuned survives a day of
/// short conversations. The scale and the soft maximum are unchanged; a card is still never
/// shorter than its duration.
enum ChapterCardTier: String, Equatable, Sendable, CaseIterable {
    /// 25 min and longer: title (two lines), time line, fitted summary, pills, follow-ups.
    case full
    /// 10 to 25 min: title (one line, two if it needs it), the time line with the pills beside
    /// it when they fit, and follow-ups as one line. No summary.
    case medium
    /// Under 10 min: one line — the title, and the time and duration trailing. A follow-up
    /// indicator when there are any; no pills.
    case compact

    /// The boundaries, in minutes.
    static let fullFromMinutes: Double = 25
    static let mediumFromMinutes: Double = 10

    /// The tier for a duration. At the accessibility text sizes every tier moves one step up
    /// (compact → medium, medium → full): one line of large type holds a few words, and a card
    /// that says nothing is worse than a taller one.
    static func tier(durationMs: Int64, isAccessibilitySize: Bool = false) -> ChapterCardTier {
        let minutes = Double(max(0, durationMs)) / 60_000
        let base: ChapterCardTier =
            minutes >= fullFromMinutes ? .full : minutes >= mediumFromMinutes ? .medium : .compact
        guard isAccessibilitySize else { return base }
        switch base {
        case .full, .medium: return .full
        case .compact: return .medium
        }
    }

    // Paddings per tier. The full tier keeps `ChapterCardMetrics`' 10/11.
    static let mediumPaddingTop: CGFloat = 8
    static let mediumPaddingBottom: CGFloat = 9
    static let compactPaddingVertical: CGFloat = 7

    /// The least a card of this tier is, at these metrics: the full card with one summary
    /// line and a row of pills; the medium card with a one-line title; the compact line.
    func floorHeight(_ m: ChapterCardMetrics) -> CGFloat {
        switch self {
        case .full:
            return ChapterCardFit.estimatedHeight(
                showsSummary: true, hasPills: true, followUps: 0, metrics: m)
        case .medium:
            return Self.mediumPaddingTop + m.titleLine + ChapterCardMetrics.titleToTime
                + max(m.timeLine, m.pillRow) + Self.mediumPaddingBottom
        case .compact:
            return Self.compactPaddingVertical * 2 + m.titleLine
        }
    }
}
