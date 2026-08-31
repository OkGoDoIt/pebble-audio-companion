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
            waitingLine(Copy.Onboarding.waitingLine)
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
            waitingLine(Copy.Status.confirmOnWatchLine)
        }
        .padding(.horizontal, 32)
    }

    /// The waiting sub-line: violet dot (the consent/waiting semantic) sitting on the first
    /// line like a bullet, with the sentence wrapped in a centered block under a centered title.
    private func waitingLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(color: Tokens.tint, size: .lifecycle)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(text)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.tertiary)
                .multilineTextAlignment(.leading)
                .lineSpacing(3)
        }
        .frame(maxWidth: 300)
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
    @State private var sonioxCheck = KeyCheckState()
    @State private var openAiCheck = KeyCheckState()
    @FocusState private var focused: CloudProvider?

    /// One cheap authenticated GET per check; the kit owns the taxonomy, this file owns the words.
    private let validator = CloudKeyValidator(transport: URLSessionHttpTransport())

    /// What a row knows about the key typed into it.
    private struct KeyCheckState: Equatable {
        var isChecking = false
        var outcome: ApiKeyCheckOutcome?
        /// The exact text the outcome refers to, so an edit clears a stale verdict.
        var checkedKey = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingBackBar(label: Copy.Onboarding.backToTranscripts) {
                model.backToTranscripts()
            }

            // Centred while it fits; scrolls once the keyboard, a check result, or large type
            // takes the room.
            GeometryReader { proxy in
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

                        Card {
                            keyRow(
                                .soniox, role: Copy.Onboarding.sonioxRole,
                                key: $sonioxKey, check: $sonioxCheck
                            )
                        }
                        Card {
                            keyRow(
                                .openAi, role: Copy.Onboarding.openAiRole,
                                key: $openAiKey, check: $openAiCheck
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

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
        // Leaving a field is the natural moment to check it — one network call per key, never
        // one per keystroke.
        .onChange(of: focused) { previous, _ in
            switch previous {
            case .soniox: runCheck(.soniox, key: sonioxKey, into: $sonioxCheck)
            case .openAi: runCheck(.openAi, key: openAiKey, into: $openAiCheck)
            case nil: break
            }
        }
    }

    /// Provider name, what it is for, any saved key (masked, on the right), the field that
    /// replaces it, and what the last check of that field found.
    private func keyRow(
        _ provider: CloudProvider,
        role: String,
        key: Binding<String>,
        check: Binding<KeyCheckState>
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
            .focused($focused, equals: provider)
            .submitLabel(.done)
            .onSubmit { runCheck(provider, key: key.wrappedValue, into: check) }
            .onChange(of: key.wrappedValue) { _, _ in
                // Editing invalidates the last verdict rather than leaving a stale one on screen.
                if check.wrappedValue.checkedKey
                    != key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) {
                    check.wrappedValue.outcome = nil
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            // The app's field idiom (search bars): a filled inset inside the white card, so the
            // row reads as something to type in rather than a third label.
            .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.fieldFill))
            .accessibilityLabel("\(provider.displayName) \(Copy.Onboarding.keyPlaceholder)")

            checkStatus(check.wrappedValue) {
                runCheck(provider, key: key.wrappedValue, into: check, force: true)
            }
        }
    }

    /// Checking / verified / what went wrong. Never blocks Save or Skip — a key the provider
    /// refuses is still the user's to keep.
    @ViewBuilder
    private func checkStatus(
        _ check: KeyCheckState, retry: @escaping () -> Void
    ) -> some View {
        if check.isChecking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Copy.KeyCheck.checking)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.tertiary)
            }
            .padding(.top, 2)
        } else if let outcome = check.outcome, outcome != .missing {
            if outcome.isValid {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.good)
                        .accessibilityHidden(true)
                    Text(Copy.KeyCheck.valid)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.tertiary)
                }
                .padding(.top, 2)
            } else {
                // The reason gets the full width — squeezed beside a button it wrapped to three
                // ragged lines — and the retry sits under it, aligned with the text.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        StatusDot(color: Tokens.attention, size: .lifecycle)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(Self.reason(for: outcome))
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.secondaryBody)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    Button(Copy.KeyCheck.checkAgain, action: retry)
                        .buttonStyle(.smallBordered)
                        .padding(.leading, 16)
                }
                .padding(.top, 2)
            }
        }
    }

    /// Outcome→words is shared with Settings (`ApiKeyCheckOutcome+Copy.swift`); this screen
    /// shows a check mark for success, so it wants only the failure line.
    private static func reason(for outcome: ApiKeyCheckOutcome) -> String {
        outcome.failureReason ?? ""
    }

    private func runCheck(
        _ provider: CloudProvider,
        key: String,
        into check: Binding<KeyCheckState>,
        force: Bool = false
    ) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            check.wrappedValue = KeyCheckState()
            return
        }
        // Re-checking the same text on every focus change would spend a network call to learn
        // what is already on screen; an explicit Check Again always runs.
        if !force, trimmed == check.wrappedValue.checkedKey, check.wrappedValue.outcome != nil {
            return
        }
        check.wrappedValue.isChecking = true
        Task {
            let outcome = await validator.validate(trimmed, for: provider.keyValidatorProvider)
            check.wrappedValue = KeyCheckState(
                isChecking: false, outcome: outcome, checkedKey: trimmed
            )
        }
    }

    /// Writes only what was typed — an untouched row keeps whatever the Keychain already holds.
    /// A failed check is guidance, not a gate: if the user wants the key saved, it is saved.
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

extension CloudProvider {
    /// The key-validator's own provider enum (the kit keeps the two apart so the validator can
    /// be used without the transcription settings).
    var keyValidatorProvider: CloudKeyValidator.Provider {
        switch self {
        case .soniox: return .soniox
        case .openAi: return .openAi
        }
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
