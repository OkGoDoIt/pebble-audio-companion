import SwiftUI

// MARK: - Model

/// One span of the day-coverage strip, as a fraction range of the strip width.
/// The time domain is the logical day (5 AM → 5 AM, Part 6.2).
struct CoverageSpan: Equatable {
    enum Kind: Equatable {
        case recorded  // Tokens.tint
        case quiet     // Tokens.quiet (known silence — calm, distinct from loss)
        case missing   // Tokens.missing (genuine loss — always explicit)
        case paused    // track + 45° tint stripes at 20% (a pattern, not a fifth color)
        case off       // track (nothing drawn)
    }

    let kind: Kind
    let range: ClosedRange<Double>  // 0…1 fractions of the day
}

// MARK: - Strip

/// Day coverage strip: h12 r6 on the `track` background, spans laid out by fraction.
/// Tapping reports the tapped span via `onSpanTap` (drives the Q11 explain-popover).
struct CoverageStrip: View {
    let spans: [CoverageSpan]
    var showAxis: Bool = true
    var onSpanTap: ((CoverageSpan) -> Void)? = nil

    @ScaledMetric(relativeTo: .caption2) private var axisHeight: CGFloat = 12
    /// Rough width of one axis label at the current type size ("6 AM" at 11 pt ≈ 34).
    @ScaledMetric(relativeTo: .caption2) private var axisLabelWidth: CGFloat = 34

    // Axis fractions in the 5 AM–5 AM domain: 6 AM = 1/24, noon = 7/24, 6 PM = 13/24.
    private static let axisMarks: [(String, Double)] = [
        (Copy.Today.axisMorning, 1.0 / 24.0),
        (Copy.Today.axisNoon, 7.0 / 24.0),
        (Copy.Today.axisEvening, 13.0 / 24.0),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            strip
            if showAxis { axis }
        }
    }

    private var strip: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Tokens.track)
                ForEach(spans.indices, id: \.self) { index in
                    let span = spans[index]
                    if span.kind != .off {
                        spanView(span)
                            .frame(width: width(of: span, in: geo.size.width))
                            .offset(x: geo.size.width * span.range.lowerBound)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let onSpanTap, geo.size.width > 0 else { return }
                let fraction = min(max(location.x / geo.size.width, 0), 1)
                if let hit = spans.first(where: { $0.range.contains(fraction) }) {
                    onSpanTap(hit)
                }
            }
        }
        .frame(height: 12)
        // One element carrying a spoken summary — never the individual spans (U10).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.A11y.coverageLabel)
        .accessibilityValue(accessibilitySummary)
        .accessibilityAddTraits(onSpanTap == nil ? [] : .isButton)
        .accessibilityHint(onSpanTap == nil ? "" : Copy.A11y.coverageHint)
        .accessibilityAction {
            // VoiceOver can't tap a location, so activate explains the span that matters
            // most: loss first, then a pause, then whatever the day mostly was.
            guard let onSpanTap else { return }
            let priority: [CoverageSpan.Kind] = [.missing, .paused, .quiet, .recorded]
            if let span = priority.lazy.compactMap({ kind in
                spans.first(where: { $0.kind == kind })
            }).first {
                onSpanTap(span)
            }
        }
    }

    @ViewBuilder
    private func spanView(_ span: CoverageSpan) -> some View {
        switch span.kind {
        case .recorded:
            Rectangle().fill(Tokens.tint)
        case .quiet:
            Rectangle().fill(Tokens.quiet)
        case .missing:
            Rectangle().fill(Tokens.missing)
        case .paused:
            Rectangle()
                .fill(Tokens.track)
                .overlay(DiagonalStripes().stroke(Tokens.pausedStripe, lineWidth: 1.5))
                .clipped()
        case .off:
            EmptyView()
        }
    }

    private func width(of span: CoverageSpan, in total: CGFloat) -> CGFloat {
        max(total * (span.range.upperBound - span.range.lowerBound), 1)
    }

    private var axis: some View {
        GeometryReader { geo in
            ForEach(marks(fitting: geo.size.width), id: \.0) { label, fraction in
                Text(label)
                    .font(AppFont.micro)
                    .foregroundStyle(Tokens.faint)
                    .fixedSize()
                    .position(
                        x: min(
                            max(geo.size.width * fraction, axisLabelWidth / 2),
                            max(geo.size.width - axisLabelWidth / 2, axisLabelWidth / 2)
                        ),
                        y: axisHeight / 2
                    )
            }
        }
        // The strip is a data graphic with a fixed height, but its axis labels scale (U10).
        .frame(height: axisHeight)
        .accessibilityHidden(true)
    }

    /// Axis labels grow with Dynamic Type, so past a point three of them cannot sit side by
    /// side. Drop ticks — the way a chart does — rather than let them overlap into mush.
    private func marks(fitting width: CGFloat) -> [(String, Double)] {
        let all = Self.axisMarks
        guard width > 0, all.count == 3 else { return all }
        let needed = axisLabelWidth + 6
        if width * (all[1].1 - all[0].1) >= needed { return all }
        if width * (all[2].1 - all[0].1) >= needed { return [all[0], all[2]] }
        return [all[1]]
    }

    private var accessibilitySummary: String {
        func pct(_ kind: CoverageSpan.Kind) -> Int {
            let fraction = spans.filter { $0.kind == kind }
                .reduce(0.0) { $0 + ($1.range.upperBound - $1.range.lowerBound) }
            return Int((fraction * 100).rounded())
        }
        return Copy.A11y.coverageSummary(
            recordedPct: pct(.recorded),
            quietPct: pct(.quiet),
            missingPct: pct(.missing),
            pausedPct: pct(.paused)
        )
    }
}

// MARK: - Diagonal stripes (paused pattern, Part 6.2)

/// 45° hairline stripes; stroked in `tint` at 20% opacity over the track color.
struct DiagonalStripes: Shape {
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

// MARK: - Sample data

extension [CoverageSpan] {
    /// The Today artboard's strip: 8% off, 10% rec, 6% quiet, 12% rec, 1% missing,
    /// 9% rec, 14% off, 7% quiet, 16% rec, 17% off.
    static var sampleDay: [CoverageSpan] {
        let widths: [(CoverageSpan.Kind, Double)] = [
            (.off, 0.08), (.recorded, 0.10), (.quiet, 0.06), (.recorded, 0.12),
            (.missing, 0.01), (.recorded, 0.09), (.off, 0.14), (.quiet, 0.07),
            (.recorded, 0.16), (.off, 0.17),
        ]
        var cursor = 0.0
        return widths.map { kind, width in
            defer { cursor += width }
            return CoverageSpan(kind: kind, range: cursor...(cursor + width))
        }
    }

    /// A day containing a pause (legend gains the striped item).
    static var sampleDayWithPause: [CoverageSpan] {
        [
            CoverageSpan(kind: .off, range: 0.0...0.10),
            CoverageSpan(kind: .recorded, range: 0.10...0.32),
            CoverageSpan(kind: .paused, range: 0.32...0.44),
            CoverageSpan(kind: .recorded, range: 0.44...0.58),
            CoverageSpan(kind: .quiet, range: 0.58...0.64),
            CoverageSpan(kind: .recorded, range: 0.64...0.72),
            CoverageSpan(kind: .off, range: 0.72...1.0),
        ]
    }
}

// MARK: - Previews

#Preview("Coverage strip") {
    VStack(spacing: Tokens.blockGap) {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(Copy.Today.recorded("4 hr 12 min"))
                        .font(AppFont.cardHead).foregroundStyle(Tokens.label)
                    Spacer()
                    Text(Copy.Today.missing("1 min"))
                        .font(AppFont.speaker).foregroundStyle(Tokens.missing)
                }
                CoverageStrip(spans: .sampleDay) { span in
                    print("tapped span: \(span)")
                }
            }
        }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("With a pause").font(AppFont.cardHead).foregroundStyle(Tokens.label)
                CoverageStrip(spans: .sampleDayWithPause)
                WaveformLegend(showPaused: true)
            }
        }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("No axis").font(AppFont.cardHead).foregroundStyle(Tokens.label)
                CoverageStrip(spans: .sampleDay, showAxis: false)
            }
        }
    }
    .padding(Tokens.screenMargin)
    .background(Tokens.ground)
}
