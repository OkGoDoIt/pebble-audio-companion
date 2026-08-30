import SwiftUI

/// The status-card SHELL (States · Status Card artboard): dot + headline + ONE calm line
/// + at most one action. Filled action = resolves the state; bordered = helper.
/// Content (live minute, Pause link, etc.) is composed by screens, not baked in here.
struct StatusCard: View {
    struct Action {
        enum Style { case filled, bordered }
        let title: String
        let style: Style
        let handler: () -> Void
    }

    let dotColor: Color
    let headline: String
    let line: String
    var action: Action? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(color: dotColor, size: .status)
                    Text(headline)
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                }
                .accessibilityElement(children: .combine)

                Text(line)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let action {
                    actionButton(action).padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: Action) -> some View {
        switch action.style {
        case .filled:
            Button(action.title, action: action.handler).buttonStyle(.inCardFilled)
        case .bordered:
            Button(action.title, action: action.handler).buttonStyle(.borderedTint)
        }
    }
}

// MARK: - Previews: the status families, exact approved copy

#Preview("Status families") {
    ScrollView {
        VStack(spacing: Tokens.blockGap) {
            StatusCard(
                dotColor: Tokens.good,
                headline: Copy.Status.recording,
                line: Copy.Status.recordingLine(device: "Pebble Time 2")
            )
            StatusCard(
                dotColor: Tokens.attention,
                headline: Copy.Status.paused,
                line: Copy.Status.pausedLine,
                action: .init(title: Copy.Status.resume, style: .filled) {}
            )
            StatusCard(
                dotColor: Tokens.attention,
                headline: Copy.Status.reconnecting,
                line: Copy.Status.reconnectingLine,
                action: .init(title: Copy.Status.findWatch, style: .bordered) {}
            )
            StatusCard(
                dotColor: Tokens.destructive,
                headline: Copy.Status.bluetoothOff,
                line: Copy.Status.bluetoothOffLine,
                action: .init(title: Copy.Status.openSettings, style: .filled) {}
            )
            StatusCard(
                dotColor: Tokens.neutralDot,
                headline: Copy.Status.notRecording,
                line: Copy.Status.notRecordingLine,
                action: .init(title: Copy.Status.startRecording, style: .filled) {}
            )
            StatusCard(
                dotColor: Tokens.tint,
                headline: Copy.Status.confirmOnWatch,
                line: Copy.Status.confirmOnWatchLine
            )
            StatusCard(
                dotColor: Tokens.neutralDot,
                headline: Copy.Status.transcriptsOff,
                line: Copy.Status.transcriptsOffLine,
                action: .init(title: Copy.Status.setUpTranscripts, style: .filled) {}
            )
        }
        .padding(Tokens.screenMargin)
    }
    .background(Tokens.ground)
}

#Preview("Onboarding failure branches") {
    ScrollView {
        VStack(spacing: Tokens.blockGap) {
            StatusCard(
                dotColor: Tokens.neutralDot,
                headline: Copy.Onboarding.Failure.noPebbleFound,
                line: Copy.Onboarding.Failure.noPebbleFoundLine,
                action: .init(title: Copy.Common.tryAgain, style: .bordered) {}
            )
            StatusCard(
                dotColor: Tokens.attention,
                headline: Copy.Onboarding.Failure.cantSendAudio,
                line: Copy.Onboarding.Failure.cantSendAudioLine,
                action: .init(title: Copy.Onboarding.Failure.firmwareGuide, style: .bordered) {}
            )
            StatusCard(
                dotColor: Tokens.neutralDot,
                headline: Copy.Onboarding.Failure.declined,
                line: Copy.Onboarding.Failure.declinedLine,
                action: .init(title: Copy.Common.tryAgain, style: .bordered) {}
            )
            StatusCard(
                dotColor: Tokens.attention,
                headline: Copy.Onboarding.Failure.boundElsewhere,
                line: Copy.Onboarding.Failure.boundElsewhereLine,
                action: .init(title: Copy.Common.tryAgain, style: .bordered) {}
            )
            StatusCard(
                dotColor: Tokens.neutralDot,
                headline: Copy.Onboarding.Failure.noAnswer,
                line: Copy.Onboarding.Failure.noAnswerLine,
                action: .init(title: Copy.Onboarding.Failure.askAgain, style: .bordered) {}
            )
            StatusCard(
                dotColor: Tokens.destructive,
                headline: Copy.Onboarding.Failure.bluetoothDenied,
                line: Copy.Onboarding.Failure.bluetoothDeniedLine,
                action: .init(title: Copy.Status.openSettings, style: .bordered) {}
            )
        }
        .padding(Tokens.screenMargin)
    }
    .background(Tokens.ground)
}
