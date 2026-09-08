import SwiftUI

/// A live-transport control: glyph, title, and one line naming what it does to the recording.
///
/// The subline is the whole point. The bar this replaces was `[⏸ Pause][⏹ Stop]` and nothing
/// else, and the reported defect was exactly that — "I'm not entirely certain the technical
/// difference between pause and stop in our case". Both end the conversation; only what
/// happens to CAPTURE afterwards differs, and a control that hides its consequence on a
/// background-microphone product is a control that will be mis-tapped.
///
/// Deliberately not an addition to `TransportButton`: that one is a single-line pill used
/// wherever a compact transport is wanted, and widening it for one screen's needs would push
/// this screen's problem into every other caller.
struct LiveTransportButton: View {
    enum Role { case normal, stop }

    let title: String
    /// One short line: what this does that the other one does not.
    let subline: String
    let systemImage: String
    var role: Role = .normal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                    Text(title)
                        .font(AppFont.cardHead)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(role == .stop ? Tokens.destructive : Tokens.label)
                Text(subline)
                    .font(AppFont.micro)
                    .foregroundStyle(Tokens.meta)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 18).strokeBorder(Tokens.cardBorder))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        // One spoken phrase rather than two fragments: the consequence is not decoration here,
        // it is the half of the control that says which button this is.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Copy.A11y.transport(title, subline))
    }
}

#Preview("Live transport") {
    VStack(spacing: 20) {
        HStack(spacing: 10) {
            LiveTransportButton(
                title: Copy.Live.pause, subline: Copy.Live.pauseSubline,
                systemImage: "pause.fill"
            ) {}
            LiveTransportButton(
                title: Copy.Live.stop, subline: Copy.Live.stopSubline,
                systemImage: "stop.fill", role: .stop
            ) {}
        }
    }
    .padding(Tokens.screenMargin)
    .background(Tokens.barBg)
}
