import SwiftUI

// The Today coverage strip, redrawn for widget sizes. It mirrors `App/Components/
// CoverageStrip.swift` — same four-state taxonomy, same striped `paused`, same rounded track —
// but takes millisecond spans straight off the App Group snapshot and carries a monochrome
// palette for the Lock Screen, where the system tints everything anyway.

/// How the strip colors itself for the surface it is on.
enum StripPalette {
    /// Home Screen: the app's real taxonomy colors.
    case color
    /// Lock Screen accessory: the system renders a single tint, so the states separate by
    /// opacity instead. Loss stays the most prominent step — it must not disappear.
    case monochrome

    var recorded: Color {
        switch self {
        case .color: return Tokens.tint
        case .monochrome: return .white.opacity(0.95)
        }
    }
    var quiet: Color {
        switch self {
        case .color: return Tokens.quiet
        case .monochrome: return .white.opacity(0.45)
        }
    }
    var missing: Color {
        switch self {
        case .color: return Tokens.missing
        case .monochrome: return .white.opacity(0.7)
        }
    }
    var track: Color {
        switch self {
        case .color: return Tokens.track
        case .monochrome: return .white.opacity(0.18)
        }
    }
    var stripe: Color {
        switch self {
        case .color: return Tokens.tint.opacity(0.2)
        case .monochrome: return .white.opacity(0.35)
        }
    }
}

struct WidgetCoverageStrip: View {
    let snapshot: CoverageSnapshot
    var palette: StripPalette = .color
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(palette.track)
                ForEach(Array(snapshot.spans.enumerated()), id: \.offset) { _, span in
                    if span.kind != .off, let range = snapshot.fractionRange(of: span) {
                        fill(for: span.kind)
                            // Hairline minimum: a 4-second loss must still be visible.
                            .frame(width: max(geo.size.width * (range.upperBound - range.lowerBound), 1))
                            .offset(x: geo.size.width * range.lowerBound)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: min(6, height / 2)))
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private func fill(for kind: CoverageSnapshot.Span.Kind) -> some View {
        switch kind {
        case .recorded: Rectangle().fill(palette.recorded)
        case .quiet: Rectangle().fill(palette.quiet)
        case .missing: Rectangle().fill(palette.missing)
        case .paused:
            // A pattern, not a fifth color (plan 6.2) — paused is never rendered as loss.
            Rectangle()
                .fill(palette.track)
                .overlay(WidgetDiagonalStripes().stroke(palette.stripe, lineWidth: 1.5))
                .clipped()
        case .off: EmptyView()
        }
    }

    private var accessibilitySummary: String {
        func pct(_ kind: CoverageSnapshot.Span.Kind) -> Int {
            let ms = snapshot.spans.filter { $0.kind == kind }.reduce(0) { $0 + $1.durationMs }
            return Int((Double(ms) / Double(CoverageSnapshot.dayDurationMs) * 100).rounded())
        }
        return Copy.A11y.coverageSummary(
            recordedPct: pct(.recorded),
            quietPct: pct(.quiet),
            missingPct: pct(.missing),
            pausedPct: pct(.paused)
        )
    }
}

/// 45° hairlines — the paused pattern, copied from the app's `DiagonalStripes`.
struct WidgetDiagonalStripes: Shape {
    var spacing: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

/// The 6 AM / noon / 6 PM ticks, on the medium widget only (the small one has no room).
struct WidgetCoverageAxis: View {
    private static let marks: [(String, Double)] = [
        (Copy.Today.axisMorning, 1.0 / 24.0),
        (Copy.Today.axisNoon, 7.0 / 24.0),
        (Copy.Today.axisEvening, 13.0 / 24.0),
    ]

    var body: some View {
        GeometryReader { geo in
            ForEach(Self.marks, id: \.0) { label, fraction in
                Text(label)
                    .font(AppFont.micro)
                    .foregroundStyle(Tokens.faint)
                    .fixedSize()
                    .position(x: geo.size.width * fraction, y: 6)
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}
