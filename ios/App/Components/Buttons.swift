import SwiftUI

// MARK: - Button styles (Part 2-A inventory)

/// Primary filled: h50 r14 full-width, 17/600 white on tint. Onboarding CTAs.
struct PrimaryFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.headline)
            .foregroundStyle(Tokens.onTint)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: Tokens.primaryButtonRadius)
                    .fill(configuration.isPressed ? Tokens.tintPressed : Tokens.tint)
            )
            .contentShape(RoundedRectangle(cornerRadius: Tokens.primaryButtonRadius))
    }
}

/// In-card filled: h40 r11, 15/600 white on tint. "Resolves the state" (Resume,
/// Open Settings, Start Recording, Set Up Transcripts).
struct InCardFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.cardHead)
            .foregroundStyle(Tokens.onTint)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(configuration.isPressed ? Tokens.tintPressed : Tokens.tint)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

/// Bordered tint: h40 r11, 15/600 tint text, `tintBorder` border. Helper/retry actions
/// (Find Watch, Try Again, Transcribe Now).
struct BorderedTintButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.cardHead)
            .foregroundStyle(configuration.isPressed ? Tokens.tintPressed : Tokens.tint)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 11).strokeBorder(Tokens.tintBorder)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Small bordered: h36 r10, 14/600 tint, hugging width. Lifecycle-card actions
/// (Retry Now), Test Connection, Support Report.
struct SmallBorderedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.smallButton)
            .foregroundStyle(configuration.isPressed ? Tokens.tintPressed : Tokens.tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Tokens.tintBorder))
            .frame(minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryFilledButtonStyle {
    static var primaryFilled: Self { .init() }
}
extension ButtonStyle where Self == InCardFilledButtonStyle {
    static var inCardFilled: Self { .init() }
}
extension ButtonStyle where Self == BorderedTintButtonStyle {
    static var borderedTint: Self { .init() }
}
extension ButtonStyle where Self == SmallBorderedButtonStyle {
    static var smallBordered: Self { .init() }
}

// MARK: - Transport button

/// Bordered-neutral transport button: flex-width h40 r18 with glyph; Stop tints red.
/// Used on the live-conversation transport bar [Pause][Stop].
struct TransportButton: View {
    enum Role { case normal, stop }

    let title: String
    let systemImage: String
    var role: Role = .normal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                Text(title).font(AppFont.cardHead)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(role == .stop ? Tokens.destructive : Tokens.label)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 18).strokeBorder(Tokens.cardBorder))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Circular buttons

/// 44pt circular play/pause button (conversation player).
struct CirclePlayButton: View {
    var isPlaying: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Tokens.onTint)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Tokens.tint))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? Copy.A11y.pausePlayback : Copy.A11y.play)
    }
}

/// 36pt circular send button (Ask composer). Hit target padded to ≥44pt.
struct CircleSendButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tokens.onTint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Tokens.tint))
                .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.A11y.sendQuestion)
    }
}

// MARK: - Previews

#Preview("Buttons") {
    ScrollView {
        VStack(spacing: 14) {
            Button(Copy.Onboarding.connectButton) {}.buttonStyle(.primaryFilled)
            Button(Copy.Status.resume) {}.buttonStyle(.inCardFilled)
            Button(Copy.Status.findWatch) {}.buttonStyle(.borderedTint)
            HStack {
                Button(Copy.Conversation.retryNow) {}.buttonStyle(.smallBordered)
                Button(Copy.Settings.TranscriptionAI.testConnection) {}
                    .buttonStyle(.smallBordered)
            }
            HStack(spacing: 10) {
                TransportButton(title: Copy.Live.pause, systemImage: "pause.fill") {}
                TransportButton(
                    title: Copy.Live.stop, systemImage: "stop.fill", role: .stop
                ) {}
            }
            HStack(spacing: 20) {
                CirclePlayButton {}
                CirclePlayButton(isPlaying: true) {}
                CircleSendButton {}
            }
        }
        .padding(Tokens.screenMargin)
    }
    .background(Tokens.ground)
}
