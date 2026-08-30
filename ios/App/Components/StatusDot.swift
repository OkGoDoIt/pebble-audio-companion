import SwiftUI

/// Semantic status dot. Three sizes by context (Part 2-A): 10pt on status cards, 8pt on
/// lifecycle/waiting rows, 7pt in the waveform legend.
struct StatusDot: View {
    enum Size: CGFloat {
        case status = 10
        case lifecycle = 8
        case legend = 7
    }

    let color: Color
    var size: Size = .status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size.rawValue, height: size.rawValue)
            .accessibilityHidden(true)
    }
}

#Preview("Status dots") {
    VStack(alignment: .leading, spacing: 14) {
        ForEach(
            [
                ("good — Recording", Tokens.good),
                ("attention — Paused / Reconnecting", Tokens.attention),
                ("destructive — Bluetooth off", Tokens.destructive),
                ("neutral — Not recording", Tokens.neutralDot),
                ("tint — Confirm on your watch", Tokens.tint),
                ("captured — waiting to transcribe", Tokens.captured),
            ], id: \.0
        ) { name, color in
            HStack(spacing: 10) {
                StatusDot(color: color, size: .status)
                StatusDot(color: color, size: .lifecycle)
                StatusDot(color: color, size: .legend)
                Text(name).font(AppFont.footnote).foregroundStyle(Tokens.label)
            }
        }
    }
    .padding(Tokens.screenMargin)
    .background(Tokens.ground)
}
