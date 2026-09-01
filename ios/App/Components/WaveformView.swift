import SwiftUI

// MARK: - Model

/// One bar of the live-minute waveform.
struct WaveformBar: Equatable {
    enum State: Equatable {
        case transcribed  // Tokens.tint, amplitude-scaled
        case captured     // Tokens.captured, amplitude-scaled (awaiting transcription)
        case quiet        // Tokens.quiet, fixed stub height (silence we measured)
        /// Silence the watch skipped sending. Still Quiet in the taxonomy — the same legend item
        /// — but drawn fainter and shorter, because it is quiet we INFER from a live link that
        /// sent nothing rather than quiet we decoded. Never amber: nothing was lost.
        case skipped
        case missing      // Tokens.missing, fixed marker height (no data — never hidden)
    }

    var amplitude: Double  // 0…1
    var state: State
}

// MARK: - Waveform

/// The live-minute waveform: h32 container, 80 bars w2, space-between.
/// Four-state audio taxonomy: transcribed/captured amplitude-scaled full-height bars;
/// quiet renders as h4 stubs (h2 and fainter for silence the watch skipped); missing renders
/// as the amber h10 marker (per the artboard taxonomy — visually distinct from both voice and
/// quiet, never silently hidden).
struct WaveformView: View {
    /// One slot per `slotCount`, oldest first, already placed on a time axis ending at the moment
    /// the snapshot was built (`WaveformWindow.slots`). A nil slot has no audio in it.
    ///
    /// The row used to take `bars.suffix(40)` and right-align it, which has no time axis at all:
    /// whatever arrived last was painted against the right edge and called the present, so a
    /// stream that stopped left a motionless minute of green bars sitting under "Recording".
    let slots: [WaveformBar?]

    /// The window is a FIXED number of slots, always the most recent minute, filling from the
    /// right. Slots keep the bar spacing stable instead of stretching a handful of early bars
    /// across the full width, and stop a growing bar count from dragging the Today layout
    /// sideways.
    ///
    /// 80 slots = 750 ms each. At 40 the row was 1.5 s per bar: fat, widely spaced lozenges that
    /// read as a toy rather than an instrument, and coarse enough to swallow a short word whole.
    /// Still three of the monitor's 250 ms bars per slot, so the row is a downsample of the
    /// audio and never an interpolation of it.
    static let slotCount = 80

    /// How much time the row covers, matching the live monitor's own window.
    static let windowMs: Int64 = 60_000

    private let containerHeight: CGFloat = 32
    private let barWidth: CGFloat = 2
    private let quietHeight: CGFloat = 4
    private let skippedHeight: CGFloat = 2
    private let missingHeight: CGFloat = 10

    /// Padded/truncated to exactly `slotCount`, so a short array still draws a stable row.
    private var window: [WaveformBar?] {
        if slots.count >= Self.slotCount { return Array(slots.suffix(Self.slotCount)) }
        return Array(repeating: nil, count: Self.slotCount - slots.count) + slots
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(window.indices, id: \.self) { index in
                // Each slot flexes, so the row fits any width and never overflows its card.
                Group {
                    if let bar = window[index] {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(color(for: bar.state))
                            .frame(width: barWidth, height: height(for: bar))
                    } else {
                        // A slot we know nothing about — before the app opened, or before the
                        // link came up — is genuinely blank, and must stay distinguishable from
                        // the faint tick that means "live, and quiet".
                        Color.clear.frame(width: barWidth, height: 1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: containerHeight, alignment: .bottom)
        .frame(maxWidth: .infinity)
        .clipped()
        // One element, never 80 — VoiceOver gets the spoken summary, not the bars (U10).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Copy.A11y.waveformLabel)
        .accessibilityValue(accessibilitySummary)
    }

    private func color(for state: WaveformBar.State) -> Color {
        switch state {
        case .transcribed: Tokens.tint
        case .captured: Tokens.captured
        case .quiet: Tokens.quiet
        case .skipped: Tokens.quietSkipped
        case .missing: Tokens.missing
        }
    }

    private func height(for bar: WaveformBar) -> CGFloat {
        switch bar.state {
        case .quiet: quietHeight
        case .skipped: skippedHeight
        case .missing: missingHeight
        case .transcribed, .captured:
            8 + CGFloat(min(max(bar.amplitude, 0), 1)) * (containerHeight - 8)
        }
    }

    /// "42 seconds recorded, 10 seconds quiet, 8 seconds missing" — read off the SLOTS, which
    /// are the row that is actually drawn. Each slot is one window divided by the slot count, so
    /// the spoken summary shrinks as the window drains rather than describing bars nobody sees.
    private var accessibilitySummary: String {
        let drawn = window.compactMap { $0 }
        guard !drawn.isEmpty else {
            return Copy.A11y.waveformSummary(recordedSec: 0, quietSec: 0, missingSec: 0)
        }
        let secondsPerSlot = Double(Self.windowMs) / 1000 / Double(Self.slotCount)
        func seconds(_ matching: (WaveformBar.State) -> Bool) -> Int {
            Int((Double(drawn.filter { matching($0.state) }.count) * secondsPerSlot).rounded())
        }
        return Copy.A11y.waveformSummary(
            recordedSec: seconds { $0 == .transcribed || $0 == .captured },
            // Skipped silence is quiet, spoken as quiet: the visual distinction is about how
            // confident the drawing is, not about a fifth thing having happened.
            quietSec: seconds { $0 == .quiet || $0 == .skipped },
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

extension [WaveformBar?] {
    /// The Today artboard's live minute, at the row's resolution: a stretch nobody was watching,
    /// then transcribed speech, measured quiet, loss, silence the watch skipped, and the newest
    /// seconds still awaiting transcription (deterministic amplitudes).
    static var sampleLiveMinute: [WaveformBar?] {
        func amp(_ i: Int) -> Double { 0.25 + 0.7 * abs(sin(Double(i) * 1.7 + 0.6)) }
        var bars: [WaveformBar?] = []
        bars += (0..<6).map { _ in nil }
        bars += (0..<26).map { WaveformBar(amplitude: amp($0), state: .transcribed) }
        bars += (0..<5).map { _ in WaveformBar(amplitude: 0, state: .quiet) }
        bars += (0..<4).map { _ in WaveformBar(amplitude: 0, state: .missing) }
        bars += (0..<8).map { _ in WaveformBar(amplitude: 0, state: .skipped) }
        bars += (26..<57).map { WaveformBar(amplitude: amp($0), state: .captured) }
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
                WaveformView(slots: .sampleLiveMinute)
                WaveformLegend()
            }
        }
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("All quiet").font(AppFont.cardHead).foregroundStyle(Tokens.label)
                WaveformView(
                    slots: (0..<WaveformView.slotCount).map {
                        // Measured quiet, then the fainter tick for silence the watch skipped.
                        WaveformBar(amplitude: 0, state: $0 < 40 ? .quiet : .skipped)
                    }
                )
                WaveformLegend(showPaused: true)
            }
        }
    }
    .padding(Tokens.screenMargin)
    .background(Tokens.ground)
}
