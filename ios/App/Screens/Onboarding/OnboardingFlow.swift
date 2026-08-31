import SwiftUI
import UIKit
import Transcription

/// The three-step onboarding flow (artboards 2.1–2.3 + the 2.19/6.7 failure branches),
/// presented as a full-screen cover while `onboardingComplete` is false. No tab bar, no
/// navigation chrome — steps swap with a slide.
struct OnboardingFlow: View {
    @Environment(AppSettings.self) private var settings
    @State private var model = OnboardingViewModel()

    var body: some View {
        ZStack {
            Tokens.ground.ignoresSafeArea()

            switch model.phase {
            case .connect:
                OnboardingConnectView(model: model)
                    .transition(stepTransition)
            case .confirm:
                OnboardingConfirmView(model: model)
                    .transition(stepTransition)
            case .transcripts:
                OnboardingTranscriptsView(model: model)
                    .transition(stepTransition)
            case .cloudKey:
                OnboardingCloudKeyView(model: model)
                    .transition(stepTransition)
            }
        }
        .animation(.snappy(duration: 0.3), value: model.phase)
        .environment(settings)
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}

// MARK: - Step 1 · Connect (2.1)

private struct OnboardingConnectView: View {
    let model: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                ConnectHeroGlyph()
                Text(Copy.Onboarding.connectTitle)
                    .font(AppFont.screenTitle)
                    .foregroundStyle(Tokens.label)
                    .multilineTextAlignment(.center)
                Text(Copy.Onboarding.connectBody)
                    .font(AppFont.bodyPlain)
                    .foregroundStyle(Tokens.tertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 300)
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button(Copy.Onboarding.connectButton) {
                    model.beginPairing()
                }
                .buttonStyle(.primaryFilled)

                Text(Copy.Onboarding.connectFootnote)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

/// Watch → phone hero (140×72 artboard glyph, redrawn with SF Symbols + connector dashes).
private struct ConnectHeroGlyph: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "applewatch")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Tokens.tint)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(Color(hex: 0xC9C9F0))
                        .frame(width: 8, height: 2.5)
                }
            }
            Image(systemName: "iphone")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Tokens.tint)
        }
        .frame(height: 72)
        .accessibilityHidden(true)
    }
}

// MARK: - Step 2 · Confirm on your watch (2.2 + failure branches 2.19/6.7)

private struct OnboardingConfirmView: View {
    let model: OnboardingViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            #if DEBUG
            debugBar
            #endif

            Spacer()

            switch model.pairing {
            case .failed(let failure):
                failureCard(failure)
                    .padding(.horizontal, Tokens.screenMargin)
            default:
                waitingContent
            }

            Spacer()

            Button(Copy.Common.cancel) {
                model.cancelPairing()
            }
            .font(AppFont.bodyPlain)
            .foregroundStyle(Tokens.tint)
            .padding(12)
            .padding(.bottom, 20)
        }
        .animation(.snappy(duration: 0.25), value: model.pairing)
    }

    private var waitingContent: some View {
        VStack(spacing: 20) {
            WatchFaceMock()
            Text(Copy.Onboarding.confirmTitle)
                .font(AppFont.screenTitle)
                .foregroundStyle(Tokens.label)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                StatusDot(color: Tokens.tint, size: .lifecycle)
                Text(Copy.Onboarding.waiting)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
            }
        }
        .padding(.horizontal, 32)
    }

    private func failureCard(_ failure: OnboardingFailure) -> some View {
        StatusCard(
            dotColor: dotColor(failure.dotStyle),
            headline: failure.headline,
            line: failure.line,
            action: .init(title: failure.actionTitle, style: .bordered) {
                perform(failure)
            }
        )
    }

    private func dotColor(_ style: OnboardingFailure.DotStyle) -> Color {
        switch style {
        case .neutral: return Tokens.neutralDot
        case .attention: return Tokens.attention
        case .destructive: return Tokens.destructive
        }
    }

    private func perform(_ failure: OnboardingFailure) {
        switch failure {
        case .cantSendAudio:
            openURL(OnboardingViewModel.firmwareGuideURL)
        case .bluetoothDenied:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        default:
            model.startRequest()
        }
    }

    #if DEBUG
    /// Hidden staging control: script each failure branch from the simulator.
    private var debugBar: some View {
        HStack {
            Spacer()
            Menu {
                ForEach(OnboardingFailure.allCases) { failure in
                    Button(failure.headline) { model.debugTrigger(failure) }
                }
                Button("Succeed now") { model.startRequest() }
            } label: {
                Image(systemName: "hammer")
                    .font(.system(size: 15))
                    .foregroundStyle(Tokens.faint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Debug pairing states")
        }
        .padding(.horizontal, 8)
    }
    #endif
}

/// The watch-face consent mock (fixed colors — it depicts hardware, identical in dark mode).
private struct WatchFaceMock: View {
    private let strapColor = Color(hex: 0xD9D9DE)
    private let bezelColor = Color(hex: 0x1C1C1E)

    var body: some View {
        VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                .fill(strapColor)
                .frame(width: 148, height: 26)
            RoundedRectangle(cornerRadius: 22)
                .fill(bezelColor)
                .frame(width: 190, height: 190)
                .overlay(watchScreen.padding(10))
            UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                .fill(strapColor)
                .frame(width: 148, height: 26)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(Copy.Onboarding.watchFaceTitle). \(Copy.Onboarding.watchFacePrompt)"
        )
    }

    private var watchScreen: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.Onboarding.watchFaceTitle)
                .font(.system(size: 11, weight: .bold))
                .kerning(0.3)
                .foregroundStyle(bezelColor)
            Text(Copy.Onboarding.watchFacePrompt)
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(bezelColor)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Copy.Onboarding.watchFaceAllow) ›")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(bezelColor)
                Text("\(Copy.Onboarding.watchFaceDecline) ›")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x8A8A8E))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.init(top: 12, leading: 12, bottom: 10, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 6).fill(.white))
    }
}

// MARK: - Step 3 · Where should transcripts happen? (2.3 / Q14)

private struct OnboardingTranscriptsView: View {
    @Bindable var model: OnboardingViewModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Text(Copy.Onboarding.transcriptsTitle)
                    .font(AppFont.screenTitle)
                    .foregroundStyle(Tokens.label)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)

                OptionCard(
                    title: Copy.Onboarding.onPhoneTitle,
                    subtitle: Copy.Onboarding.onPhoneBody,
                    isSelected: model.choice == .onPhone
                ) { model.choice = .onPhone }

                OptionCard(
                    title: Copy.Onboarding.inCloudTitle,
                    subtitle: Copy.Onboarding.inCloudBody,
                    isSelected: model.choice == .cloud
                ) { model.choice = .cloud }

                OptionCard(
                    title: Copy.Onboarding.laterTitle,
                    subtitle: Copy.Onboarding.laterBody,
                    isSelected: model.choice == .later
                ) { model.choice = .later }
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                Button(Copy.Onboarding.continueButton) {
                    model.continueFromTranscripts(settings: settings)
                }
                .buttonStyle(.primaryFilled)

                Text(Copy.Onboarding.transcriptsFootnote)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Cloud key hand-off (6.7)

/// One key screen between "In the cloud" and Today: provider segmented row (the single
/// approved segmented control — onboarding only), secure field, [Save to Keychain],
/// "Skip for now". Keys go straight to the Keychain (B13).
private struct OnboardingCloudKeyView: View {
    let model: OnboardingViewModel
    @Environment(AppSettings.self) private var settings

    @State private var provider: CloudProvider = .soniox
    @State private var key = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                Text(Copy.Onboarding.addProviderKey)
                    .font(AppFont.screenTitle)
                    .foregroundStyle(Tokens.label)
                    .multilineTextAlignment(.center)

                Picker(Copy.Settings.TranscriptionAI.cloudProvider, selection: $provider) {
                    ForEach(CloudProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                Card {
                    SecureField("API key", text: $key)
                        .font(AppFont.callout)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                Button(Copy.Onboarding.saveToKeychain) {
                    settings.setApiKey(key, for: provider)
                    settings.cloudTranscriptionProvider = provider
                    model.finish(settings: settings)
                }
                .buttonStyle(.primaryFilled)
                .disabled(trimmedKey.isEmpty)
                .opacity(trimmedKey.isEmpty ? 0.4 : 1)

                Button(Copy.Onboarding.skipForNow) {
                    settings.cloudTranscriptionProvider = provider
                    model.finish(settings: settings)
                }
                .font(AppFont.bodyPlain)
                .foregroundStyle(Tokens.tint)
                .padding(8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .onAppear { provider = settings.cloudTranscriptionProvider }
    }

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespaces)
    }
}

#Preview("Onboarding") {
    OnboardingFlow()
        .environment(AppSettings())
        .tint(Tokens.tint)
}
