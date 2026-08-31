import SwiftUI

// MARK: - Model

/// One bar of the live-minute waveform.
struct WaveformBar: Equatable {
    enum State: Equatable {
        case transcribed  // Tokens.tint, amplitude-scaled
        case captured     // Tokens.captured, amplitude-scaled (awaiting transcription)
        case quiet        // Tokens.quiet, fixed stub height (known silence)
        case missing      // Tokens.missing, fixed marker height (no data — never hidden)
    }

    var amplitude: Double  // 0…1
    var state: State
}

// MARK: - Waveform

/// The live-minute waveform: h32 container, 40 bars w3 r1.5, space-between.
/// Four-state audio taxonomy: transcribed/captured amplitude-scaled full-height bars;
/// quiet renders as h4 stubs; missing renders as the amber h10 marker (per the artboard
/// taxonomy — visually distinct from both voice and quiet, never silently hidden).
struct WaveformView: View {
    let bars: [WaveformBar]

    private let containerHeight: CGFloat = 32
    private let quietHeight: CGFloat = 4
    private let missingHeight: CGFloat = 10

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(bars.indices, id: \.self) { index in
                if index > 0 { Spacer(minLength: 1) }
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color(for: bars[index].state))
                    .frame(width: 3, height: height(for: bars[index]))
            }
        }
        .frame(height: containerHeight, alignment: .bottom)
        .frame(maxWidth: .infinity)
        // One element, never 40 — VoiceOver gets the spoken summary, not the bars (U10).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.A11y.waveformLabel)
        .accessibilityValue(accessibilitySummary)
    }

    private func color(for state: WaveformBar.State) -> Color {
        switch state {
        case .transcribed: Tokens.tint
        case .captured: Tokens.captured
        case .quiet: Tokens.quiet
        case .missing: Tokens.missing
        }
    }

    private func height(for bar: WaveformBar) -> CGFloat {
        switch bar.state {
        case .quiet: quietHeight
        case .missing: missingHeight
        case .transcribed, .captured:
            8 + CGFloat(min(max(bar.amplitude, 0), 1)) * (containerHeight - 8)
        }
    }

    /// "42 seconds recorded, 10 seconds quiet, 8 seconds missing" — the bars cover one
    /// minute, so each bar represents 60/count seconds.
    private var accessibilitySummary: String {
        guard !bars.isEmpty else { return Copy.A11y.waveformSummary(recordedSec: 0, quietSec: 0, missingSec: 0) }
        let secondsPerBar = 60.0 / Double(bars.count)
        func seconds(_ matching: (WaveformBar.State) -> Bool) -> Int {
            Int((Double(bars.filter { matching($0.state) }.count) * secondsPerBar).rounded())
        }
        return Copy.A11y.waveformSummary(
            recordedSec: seconds { $0 == .transcribed || $0 == .captured },
            quietSec: seconds { $0 == .quiet },
            missingSec: seconds { $0 == .missing }
        )
    }
}

// MARK: - Legend

/// The 4-item taxonomy legend (10pt anchor, 7pt dots). Gains a fifth striped "Paused"
/// item only on days containing a pause (Part 6.2).
struct WaveformLegend: View {
    var showPaused: Bool = false

    var body: some View {
        // Flows onto extra lines at large Dynamic Type sizes instead of truncating (M10).
        FlowLayout(horizontalSpacing: 14, verticalSpacing: 6) {
            item(Copy.Legend.transcribed, Tokens.tint)
            item(Copy.Legend.captured, Tokens.captured)
            item(Copy.Legend.quiet, Tokens.quiet)
            item(Copy.Legend.missing, Tokens.missing)
            if showPaused { pausedItem }
        }
        .accessibilityHidden(true)  // the waveform/strip carries the summary
    }

    private func item(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            StatusDot(color: color, size: .legend)
            Text(label).font(AppFont.legend).foregroundStyle(Tokens.meta)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pausedItem: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Tokens.track)
                .overlay(
                    DiagonalStripes()
                        .stroke(Tokens.pausedStripe, lineWidth: 1.5)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                )
                .frame(width: 10, height: 7)
            Text(Copy.Legend.paused).font(AppFont.legend).foregroundStyle(Tokens.meta)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Sample data

extension [WaveformBar] {
    /// The Today artboard's live minute: 14 transcribed, 5 quiet, 2 missing, 3 quiet,
    /// 16 captured (deterministic amplitudes).
    static var sampleLiveMinute: [WaveformBar] {
        func amp(_ i: Int) -> Double { 0.25 + 0.7 * abs(sin(Double(i) * 1.7 + 0.6)) }
        var bars: [WaveformBar] = []
        bars += (0..<14).map { WaveformBar(amplitude: amp($0), state: .transcribed) }
        bars += (0..<5).map { _ in WaveformBar(amplitude: 0, state: .quiet) }
        bars += (0..<2).map { _ in WaveformBar(amplitude: 0, state: .missing) }
        bars += (0..<3).map { _ in WaveformBar(amplitude: 0, state: .quiet) }
        bars += (14..<30).map { WaveformBar(amplitude: amp($0), state: .captured) }
        return bars
    }
}

// MARK: - Previews

#Preview("Live minute + legend") {
    VStack(alignment: .leading, spacing: 12) {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusDot(color: Tokens.good, size: .status)
                    Text(Copy.Status.recording).font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                    Spacer()
                    Text(Copy.Today.pause).font(AppFont.pill).foregroundStyle(Tokens.tint)
                }
                Text(Copy.Status.connected(device: "Pebble Time 2"))
                    .font(AppFont.footnote).foregroundStyle(Tokens.meta)
                WaveformView(bars: .sampleLiveMinute)
                WaveformLegend()
            }
        }
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("All quiet").font(AppFont.cardHead).foregroundStyle(Tokens.label)
                WaveformView(
                    bars: (0..<40).map { _ in WaveformBar(amplitude: 0, state: .quiet) }
                )
                WaveformLegend(showPaused: true)
            }
        }
    }
    .padding(Tokens.screenMargin)
    .background(Tokens.ground)
}
