import SwiftUI
import UIKit

// The History tab's additions to the design system (plan 7.12 "Components"). Light values are
// the round-10 mockup's; dark values follow the same derivation as `Tokens` (iOS semantic grays
// on a black ground). Kept out of `Tokens.swift` because that file is compiled into the widget,
// which has no timeline.

extension Tokens {
    // ── History: timeline ───────────────────────────────────────────────────
    /// The day's hour axis (1.5 pt), solid through the timeline and dashed at its ends.
    static let timelineAxis = Color(light: 0xDCDCE2, dark: 0x38383A)
    /// The short tick where an hour label meets the axis.
    static let timelineTick = Color(light: 0xC7C7CC, dark: 0x48484A)
    /// Missing-audio TEXT. The data-surface orange (`missing`) fails contrast as text on the
    /// ground colour, so words use this darker amber; the bar on the axis stays `missing`.
    static let missingText = Color(light: 0xC77700, dark: 0xFFA23A)
    /// The soft bar of a no-conversation stretch with a descriptor ("Background audio").
    static let backgroundAudioBar = Color(light: 0xC7C7CC, dark: 0x545458)
    /// The light half of the paused stripes on the axis (the dark half is `tint`).
    static let pausedStripeGround = Color(light: 0xDCDCF6, dark: 0x34345C)
    /// The "now" marker's label on today's axis; its tick is `good`.
    static let nowMarker = Color(light: 0x1F9D47, dark: 0x30D158)
    /// A done follow-up's circle and text: dimmed, and the icon changes too (5.9).
    static let followUpDone = Color(light: 0xA0A0A6, dark: 0x6C6C70)
    /// The dashed outline of a recording that is not transcribed yet.
    static let pendingOutline = Color(light: 0xC7C7CC, dark: 0x48484A)

    /// Timeline geometry (plan 5.3 "Layout").
    enum Timeline {
        /// Hour labels and the axis live in this leading gutter; cards start after it.
        static let gutter: CGFloat = 58
        /// The axis line's x, inside the gutter.
        static let axisX: CGFloat = 50
        static let axisWidth: CGFloat = 1.5
        /// Vertical space between two items: consecutive chapters touch in time, so the cards
        /// need it to read as two.
        static let itemSpacing: CGFloat = 6
        /// Hour labels are right-aligned to this x.
        static let hourLabelTrailing: CGFloat = 40
        /// The tick runs from here across the axis.
        static let tickX: CGFloat = 46
        static let tickWidth: CGFloat = 9
        /// Gap bars (paused, missing, background audio) sit on the axis.
        static let barWidth: CGFloat = 5
        /// Gap labels and edge lines start here, 13 pt into the content column.
        static let labelInset: CGFloat = 13
        /// The chapter card's radius (the app's card radius; the mockups drew 14).
        static let cardRadius: CGFloat = Tokens.cardRadius
    }
}

extension AppFont {
    // ── History ─────────────────────────────────────────────────────────────
    /// 12/400 — hour labels on the axis. Callers cap its growth at the second accessibility
    /// size so the gutter keeps its width (plan 5.9).
    static let hourLabel = Font.system(.caption)
    /// 12/400 — a card's time line, gap labels, edge lines.
    static let timelineMeta = Font.system(.caption)
    /// 20/500 — the day number in a week row.
    static let dayNumeral = Font.system(.title3, weight: .medium)
    /// 16/500 — the gray title of a pending card, and of a week row with nothing to show.
    static let pendingTitle = Font.system(.callout, weight: .medium)
    /// 12/600 — the "now" marker.
    static let nowMarker = Font.system(.caption, weight: .semibold)

    /// A mockup size that is not one of the text styles, scaled with Dynamic Type as `style`
    /// scales. `Font.system(size:)` does not scale, and History's 14 and 30 pt text has to
    /// (plan 5.9: all text uses scaled fonts). The line heights `ChapterCardMetrics` computes
    /// come from the same scaling, so the card's fitting agrees with what is drawn.
    static func scaled(
        _ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: UIFont.TextStyle,
        _ dynamicTypeSize: DynamicTypeSize
    ) -> Font {
        let traits = UITraitCollection(
            preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let pointSize = UIFontMetrics(forTextStyle: style).scaledValue(
            for: size, compatibleWith: traits)
        return Font.system(size: pointSize, weight: weight)
    }

    /// 30/700 — a History page's title ("Tuesday", "Sep 20 – 26").
    static func historyTitle(_ size: DynamicTypeSize) -> Font {
        scaled(30, weight: .bold, relativeTo: .largeTitle, size)
    }

    /// 14/400 — brief text, a card's summary, a card's follow-ups.
    static func historyBody(_ size: DynamicTypeSize) -> Font {
        scaled(14, relativeTo: .subheadline, size)
    }
}
