import SwiftUI
import UIKit

/// Design tokens from the implementation plan Part 2-A. Light values are the normative mockup
/// hex values; dark values are derived from iOS semantic colors anchored on these (Q12 — tuned
/// during M10 on device).
enum Tokens {
    // ── Brand / tint ────────────────────────────────────────────────────────
    static let tint = Color(light: 0x5B5BD6, dark: 0x7D7DE8)
    static let tintPressed = Color(light: 0x4A4AC4, dark: 0x6B6BDA)
    /// Captured / awaiting transcription (light violet).
    static let captured = Color(light: 0xB9B9EE, dark: 0x55558A)
    static let tintOnDark = Color(hex: 0x9F9FF0)
    /// Foreground on a filled-tint surface (filled buttons, selected chips, play button).
    static let onTint = Color(hex: 0xFFFFFF)
    // Tinted fills are alpha over the *card*, so dark mode needs more alpha to survive a
    // near-black ground — at the light alphas the chips and pills vanished (M10).
    static let tintFill10 = Tokens.tint.adaptiveOpacity(light: 0.10, dark: 0.24)
    static let tintFill12 = Tokens.tint.adaptiveOpacity(light: 0.12, dark: 0.26)
    static let tintFill18 = Tokens.tint.adaptiveOpacity(light: 0.18, dark: 0.34)
    static let tintBorder = Tokens.tint.adaptiveOpacity(light: 0.4, dark: 0.55)
    /// 45° stripe ink for the paused coverage pattern (Part 6.2).
    static let pausedStripe = Tokens.tint.adaptiveOpacity(light: 0.20, dark: 0.55)

    // ── Status ──────────────────────────────────────────────────────────────
    static let good = Color(light: 0x34C759, dark: 0x30D158)
    static let goodFill = Tokens.good.adaptiveOpacity(light: 0.12, dark: 0.22)
    /// Missing-data encoding — reserved for data surfaces (waveform, coverage, scrubber).
    static let missing = Color(light: 0xFF9500, dark: 0xFF9F0A)
    static let missingHair = Tokens.missing.adaptiveOpacity(light: 0.35, dark: 0.5)
    /// Ground for an opened interruption's reason list — the same alpha-over-card treatment the
    /// tint fills use, so the panel reads as part of the marker rather than a warning box.
    static let missingFill = Tokens.missing.adaptiveOpacity(light: 0.08, dark: 0.11)
    /// Attention states (paused, reconnecting, stock firmware, transcription failed).
    static let attention = Color(light: 0xFF9F0A, dark: 0xFFB340)
    static let destructive = Color(light: 0xFF3B30, dark: 0xFF453A)
    static let neutralDot = Color(light: 0x8A8A8E, dark: 0x98989D)

    // ── Four-state audio taxonomy (canonical) ───────────────────────────────
    // transcribed = tint · captured = captured · quiet = quiet · missing = missing
    // track (off) = track. Paused renders as track + 45° tint stripes (Part 6.2).

    // ── Grays / surfaces ────────────────────────────────────────────────────
    static let label = Color(light: 0x1C1C1E, dark: 0xF2F2F7)
    static let secondaryBody = Color(light: 0x3C3C43, dark: 0xD1D1D6)
    static let tertiary = Color(light: 0x6E6E73, dark: 0xAEAEB2)
    static let meta = Color(light: 0x8A8A8E, dark: 0x98989D)
    static let faint = Color(light: 0xB0B0B6, dark: 0x7C7C80)
    static let chevron = Color(light: 0xC7C7CC, dark: 0x48484A)
    static let quiet = Color(light: 0xD1D1D6, dark: 0x48484A)
    /// Quiet the watch skipped sending rather than quiet we decoded: the same hue, dimmer, so
    /// the live row can advance through a silent minute without claiming to have heard it.
    static let quietSkipped = Tokens.quiet.adaptiveOpacity(light: 0.5, dark: 0.55)
    static let hairline = Color(lightRGBA: (60, 60, 67, 0.18), darkRGBA: (84, 84, 88, 0.40))
    static let cardBorder = Color(lightRGBA: (60, 60, 67, 0.22), darkRGBA: (84, 84, 88, 0.48))
    static let barHairline = Color(lightRGBA: (60, 60, 67, 0.29), darkRGBA: (84, 84, 88, 0.55))
    static let fieldFill = Color(light: 0xE3E3E8, dark: 0x2C2C2E)
    static let track = Color(light: 0xECECF1, dark: 0x2C2C2E)
    static let grayChipFill = Color(light: 0xEFEFF4, dark: 0x2C2C2E)
    static let pillFill = Color(light: 0xE9E9EE, dark: 0x2C2C2E)
    static let toggleOff = Color(light: 0xE9E9EA, dark: 0x39393D)
    static let speakerOther = Color(light: 0x2E9E9E, dark: 0x40C8C8)
    static let scrim = Color(light: 0x8E8E96, dark: 0x1C1C1E).opacity(0.5)
    // ── Illustration-only tones ─────────────────────────────────────────────
    // The onboarding consent mock depicts the watch itself, so its strap/bezel/screen stay
    // fixed in both appearances — the point is "this is what your watch will show".
    static let watchStrap = Color(hex: 0xD9D9DE)
    static let watchBezel = Color(hex: 0x1C1C1E)
    static let watchScreen = Color(hex: 0xFFFFFF)
    static let watchScreenMuted = Color(hex: 0x8A8A8E)
    /// Soft-tint decoration (the watch↔phone connector dashes) — this *is* UI, so it adapts.
    static let tintSoft = Color(light: 0xC9C9F0, dark: 0x4A4A85)
    static let ground = Color(light: 0xF2F2F7, dark: 0x000000)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let barBg = Color(light: 0xF9F9F9, dark: 0x161616)
    static let snackbarBg = Color(light: 0x1C1C1E, dark: 0x2C2C2E)

    // ── Spacing / radii ─────────────────────────────────────────────────────
    static let screenMargin: CGFloat = 16
    static let blockGap: CGFloat = 12
    static let cardRadius: CGFloat = 12
    static let optionCardRadius: CGFloat = 14
    static let primaryButtonRadius: CGFloat = 14
    static let sheetRadius: CGFloat = 16
    static let menuRadius: CGFloat = 13
}

/// Type scale (Part 2-A) mapped onto Dynamic Type text styles with the mockup sizes as the
/// `.large` anchors.
enum AppFont {
    /// 34/700 — tab-root titles.
    static let tabTitle = Font.system(.largeTitle, design: .default, weight: .bold)
    /// 28/700 — onboarding headlines, pushed-Settings titles, state-sheet titles.
    static let screenTitle = Font.system(.title, design: .default, weight: .bold)
    /// 24/700 — pushed detail titles.
    static let detailTitle = Font.system(.title2, design: .default, weight: .bold)
    /// 20/700 — in-page section heads; sheet titles.
    static let sectionTitle = Font.system(.title3, design: .default, weight: .bold)
    /// 17/600 — headlines, options, prominent buttons.
    static let headline = Font.system(.headline, weight: .semibold)
    /// 17/400 — back labels, Cancel.
    static let bodyPlain = Font.system(.body)
    /// 16/600 — row titles.
    static let rowTitle = Font.system(.callout, weight: .semibold)
    /// 16/400 — settings labels, transcript body, search text.
    static let callout = Font.system(.callout)
    /// 15/600 — card heads + button labels.
    static let cardHead = Font.system(.subheadline, weight: .semibold)
    /// 15/400 — body/values.
    static let subBody = Font.system(.subheadline)
    /// 14/400 — descriptions and snippets.
    static let caption = Font.system(size: 14)
    /// 13/600 uppercase +0.4 — section headers.
    static let sectionHeader = Font.system(.footnote, weight: .semibold)
    /// 13/400 — metadata, footnotes.
    static let footnote = Font.system(.footnote)
    /// 12/600 — speaker names.
    static let speaker = Font.system(.caption, weight: .semibold)
    /// 11 — timecodes, provenance, citations, Live badge.
    static let micro = Font.system(.caption2)
    static let microBold = Font.system(.caption2, weight: .semibold)

    // ── Additions for the component layer (missing from the first cut) ──────
    /// 13/500 — tint filter chips, scope pills, Edit links.
    static let chip = Font.system(.footnote, weight: .medium)
    /// 11/500 — gray read-only tag chips.
    static let tagChip = Font.system(.caption2, weight: .medium)
    /// 14/500 — editable tag chips + suggestion chips.
    static let editableChip = Font.system(size: 14, weight: .medium)
    /// 14/600 — small bordered buttons.
    static let smallButton = Font.system(size: 14, weight: .semibold)
    /// 15/500 — neutral action pills, Pause/Resume text links.
    static let pill = Font.system(.subheadline, weight: .medium)
    /// 10/400 anchor — waveform legend; rendered as caption2 so Dynamic Type
    /// gets the larger accessibility representation the plan calls for.
    static let legend = Font.system(.caption2)
}

extension Color {
    /// Single-appearance color from a hex literal.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Theme-aware color: light anchor from the mockups, provisional dark derivation.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    /// The same base hue at a different alpha per appearance. Alpha fills are composited over
    /// the card, so a light-mode alpha that reads clearly on white disappears on near-black.
    func adaptiveOpacity(light: Double, dark: Double) -> Color {
        let base = UIColor(self)
        return Color(uiColor: UIColor { traits in
            base.resolvedColor(with: traits)
                .withAlphaComponent(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    init(lightRGBA: (Int, Int, Int, Double), darkRGBA: (Int, Int, Int, Double)) {
        self.init(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? darkRGBA : lightRGBA
            return UIColor(
                red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255,
                blue: CGFloat(c.2) / 255, alpha: c.3
            )
        })
    }
}
