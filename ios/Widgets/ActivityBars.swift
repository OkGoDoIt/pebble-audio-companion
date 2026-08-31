import SwiftUI

/// The last few minutes of capture, one bar per bucket, oldest → newest.
///
/// This is NOT an audio waveform and must not be described as one. The snapshot is written by a
/// process that may only be awake for a ten-second Bluetooth wake, so decoding Speex to get real
/// amplitudes is out of reach — and a decoded waveform would freeze the moment the app suspended,
/// which on a "recording" widget would read as "the room went silent". Each bar's height is the
/// share of its bucket that carried voice-detected audio, and its color is the same four-state
/// taxonomy the coverage strip uses, so quiet stays calm and loss stays visible.
struct ActivityBars: View {
    let bars: [CoverageSnapshot.ActivityBar]
    var palette: StripPalette = .color
    var height: CGFloat = 28
    var spacing: CGFloat = 2

    /// Even a fully silent bucket draws a stub, so the strip reads as a timeline rather than
    /// as a broken view with holes in it.
    private let floorFraction: CGFloat = 0.14

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                Capsule(style: .continuous)
                    .fill(color(for: bar.kind))
                    .frame(height: max(height * floorFraction, height * CGFloat(bar.level)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Copy.Widgets.activityLabel)
    }

    private func color(for kind: CoverageSnapshot.Span.Kind) -> Color {
        switch kind {
        case .recorded: return palette.recorded
        case .quiet: return palette.quiet
        case .missing: return palette.missing
        case .paused: return palette.stripe
        case .off: return palette.track
        }
    }
}
