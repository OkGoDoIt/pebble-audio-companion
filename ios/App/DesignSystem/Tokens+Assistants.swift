import SwiftUI

// The surfaces the AI Assistants and Privacy screens use that `Tokens.swift` did not have yet,
// lifted from the approved round-3 mockups (`docs/redesign/assistant-access-mockups/round3/
// tokens.css`), light and dark, and the brand tiles' fixed colors. Kept apart from
// `Tokens.swift`, which the widget also compiles. No text color changes here: the mockups'
// "-ink" text colors were left out (Roger, 2026-10-21: contrast stays as it is everywhere), so
// these screens use `Tokens.good`, `Tokens.destructive`, and `Tokens.attention` like the rest.
extension Tokens {
    /// Ground inside a card: the "What goes to …" block (`--inset`).
    static let inset = Color(light: 0xF2F2F7, dark: 0x2C2C2E)
    /// The chosen segment of a segmented picker (`.seg span.on`).
    static let segmentOn = Color(light: 0xFFFFFF, dark: 0x636366)

    /// Brand tiles keep fixed colors in both appearances: a mark is an identity, not UI.
    enum Brand {
        static let white = Color(hex: 0xFFFFFF)
        static let black = Color(hex: 0x000000)
        /// Anthropic's near-black, the Claude Code tile.
        static let anthropicInk = Color(hex: 0x191919)
        static let claude = Color(hex: 0xD97757)
        static let gemini = Color(hex: 0x8E75B2)
        static let meta = Color(hex: 0x0467DF)
        static let iCloud = Color(hex: 0x3693F3)
        /// White tiles get a hairline in light mode, dark tiles a light edge in dark mode.
        static let edgeOnWhite = Color(lightRGBA: (0, 0, 0, 0.12), darkRGBA: (0, 0, 0, 0))
        static let edgeOnDark = Color(lightRGBA: (0, 0, 0, 0), darkRGBA: (255, 255, 255, 0.24))
    }
}

/// The type sizes these screens use that `AppFont` does not name, scaled with Dynamic Type from
/// the mockups' `.large` anchors.
enum AssistantFont {
    /// 20/600: a state heading that leads its screen (`--f-step-head`).
    static let stepHead = Font.system(.title3, weight: .semibold)
    /// 13/500: the setup step labels (`--f-step-label`).
    static let stepLabel = Font.system(.footnote, weight: .medium)
    /// 14/400: an option's description (`--f-caption`).
    static let caption = scaled(14, .subheadline)
    /// 13/500: a chip (`.chip`).
    static let chip = Font.system(.footnote, weight: .medium)
    /// 12/500: a small chip in the flow tree (`.chip.sm`).
    static let chipSmall = Font.system(.caption, weight: .medium)
    /// 13/600 and 12/400: a node's name and its line in the flow tree.
    static let flowName = Font.system(.footnote, weight: .semibold)
    static let flowSub = Font.system(.caption)
    /// 15/500 and 14/500: the segmented pickers.
    static let segment = Font.system(.subheadline, weight: .medium)
    static let segmentSmall = scaled(14, .subheadline, weight: .medium)
    /// 21/600 monospaced: a code box.
    static let codeBox = Font(
        UIFontMetrics(forTextStyle: .title2).scaledFont(
            for: .monospacedSystemFont(ofSize: 21, weight: .semibold)))
    /// 14/500: the camera's caption.
    static let cameraCaption = scaled(14, .subheadline, weight: .medium)
    /// 16/600: the glass Done pill.
    static let pill = Font.system(.callout, weight: .semibold)

    /// A size that is not a text style's own, still scaled with Dynamic Type from `style`.
    static func scaled(_ size: CGFloat, _ style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> Font {
        Font(UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight)))
    }
}
