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
                    .transition(Motion.transition(stepTransition))
            case .confirm:
                OnboardingConfirmView(model: model)
                    .transition(Motion.transition(stepTransition))
            case .transcripts:
                OnboardingTranscriptsView(model: model)
                    .transition(Motion.transition(stepTransition))
            case .cloudKey:
                OnboardingCloudKeyView(model: model)
                    .transition(Motion.transition(stepTransition))
            }
        }
        .motionAware(.snappy(duration: 0.3), value: model.phase)
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
                        .fill(Tokens.tintSoft)
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
            case .confirmOnWatch:
                confirmContent
            default:
                searchingContent
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
        .motionAware(.snappy(duration: 0.25), value: model.pairing)
    }

    /// Scanning / connecting / authorizing. NOTHING is waiting on the watch yet, so this must
    /// not draw the consent prompt — that would ask the user to look for something that is not
    /// there.
    private var searchingContent: some View {
        VStack(spacing: 20) {
            ConnectHeroGlyph()
            Text(Copy.Onboarding.waiting)
                .font(AppFont.screenTitle)
                .foregroundStyle(Tokens.label)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                StatusDot(color: Tokens.tint, size: .lifecycle)
                Text(Copy.Onboarding.waitingLine)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 32)
    }

    /// The watch is genuinely asking (receiver consent, or "turn Background Audio on").
    private var confirmContent: some View {
        VStack(spacing: 20) {
            WatchFaceMock()
            Text(Copy.Onboarding.confirmTitle)
                .font(AppFont.screenTitle)
                .foregroundStyle(Tokens.label)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                StatusDot(color: Tokens.tint, size: .lifecycle)
                Text(Copy.Status.confirmOnWatchLine)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
                    .multilineTextAlignment(.leading)
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
        case .bluetoothDenied, .bluetoothOff:
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
    private let strapColor = Tokens.watchStrap
    private let bezelColor = Tokens.watchBezel

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
                    .foregroundStyle(Tokens.watchScreenMuted)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.init(top: 12, leading: 12, bottom: 10, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.watchScreen))
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

/// One key screen between "In the cloud" and Today. BOTH providers are offered at once —
/// Soniox transcribes, OpenAI transcribes and/or runs the AI, and using one for each is a
/// normal setup, so a screen that only takes one key at a time hid half the product. Each row
/// writes its own Keychain entry (B13, the same entries Settings → Transcription & AI reads);
/// a saved key only ever renders masked. Back returns to the transcripts choice (B15).
private struct OnboardingCloudKeyView: View {
    let model: OnboardingViewModel
    @Environment(AppSettings.self) private var settings

    @State private var sonioxKey = ""
    @State private var openAiKey = ""

    var body: some View {
        VStack(spacing: 0) {
            OnboardingBackBar(label: Copy.Onboarding.backToTranscripts) {
                model.backToTranscripts()
            }

            ScrollView {
                VStack(spacing: 18) {
                    Text(Copy.Onboarding.addProviderKey)
                        .font(AppFont.screenTitle)
                        .foregroundStyle(Tokens.label)
                        .multilineTextAlignment(.center)

                    Text(Copy.Onboarding.providerKeysLine)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.tertiary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 320)

                    ListCard(rowVerticalPadding: 14) {
                        keyRow(.soniox, role: Copy.Onboarding.sonioxRole, key: $sonioxKey)
                        keyRow(.openAi, role: Copy.Onboarding.openAiRole, key: $openAiKey)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 12) {
                Button(Copy.Onboarding.saveToKeychain, action: save)
                    .buttonStyle(.primaryFilled)
                    .disabled(!hasAnyKey)
                    .opacity(hasAnyKey ? 1 : 0.4)

                Button(Copy.Onboarding.skipForNow) {
                    model.finish(settings: settings)
                }
                .font(AppFont.bodyPlain)
                .foregroundStyle(Tokens.tint)
                .padding(8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    /// Provider name, what it is for, any saved key (masked, on the right), and a field that
    /// replaces it.
    private func keyRow(
        _ provider: CloudProvider, role: String, key: Binding<String>
    ) -> some View {
        let masked = settings.maskedApiKey(for: provider)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(provider.displayName)
                    .font(AppFont.headline)
                    .foregroundStyle(Tokens.label)
                Spacer(minLength: 8)
                if let masked {
                    Text(masked)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                        .accessibilityLabel(
                            "\(Copy.Settings.TranscriptionAI.savedInKeychain), \(masked)"
                        )
                }
            }
            // What this provider is actually for — the whole point of showing both at once.
            Text(role)
                .font(AppFont.caption)
                .foregroundStyle(Tokens.tertiary)
                .padding(.bottom, 2)
            SecureField(
                masked == nil
                    ? Copy.Onboarding.keyPlaceholder : Copy.Onboarding.keyReplacePlaceholder,
                text: key
            )
            .font(AppFont.callout)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel(
                "\(provider.displayName) \(Copy.Onboarding.keyPlaceholder)"
            )
        }
    }

    /// Writes only what was typed — an untouched row keeps whatever the Keychain already holds.
    private func save() {
        let soniox = sonioxKey.trimmingCharacters(in: .whitespaces)
        let openAi = openAiKey.trimmingCharacters(in: .whitespaces)
        if !soniox.isEmpty { settings.setApiKey(soniox, for: .soniox) }
        if !openAi.isEmpty { settings.setApiKey(openAi, for: .openAi) }

        // Only one provider can transcribe at a time. If exactly one of them ends up with a key,
        // that is unambiguously the one to use; with both, the existing Settings choice stands.
        let hasSoniox = settings.hasApiKey(for: .soniox)
        let hasOpenAi = settings.hasApiKey(for: .openAi)
        if hasSoniox != hasOpenAi {
            settings.cloudTranscriptionProvider = hasSoniox ? .soniox : .openAi
        }
        model.finish(settings: settings)
    }

    private var hasAnyKey: Bool {
        !sonioxKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !openAiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Onboarding's back affordance: a chevron plus the name of the actual parent step (B15).
private struct OnboardingBackBar: View {
    let label: String
    let action: () -> Void

    var body: some View {
        HStack {
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text(label).font(AppFont.bodyPlain).lineLimit(1)
                }
                .foregroundStyle(Tokens.tint)
                .padding(.vertical, 12)
                .padding(.trailing, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to \(label)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.screenMargin)
    }
}

#Preview("Onboarding") {
    OnboardingFlow()
        .environment(AppSettings())
        .tint(Tokens.tint)
}
