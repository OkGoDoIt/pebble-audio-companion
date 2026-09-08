import Intelligence
import SwiftUI
import Transcription

// The quiet half of onboarding step 3: the two axes, set separately.
//
// Transcription (audio → text) and AI (text → summaries, notes, follow-ups, answers) are
// independent, and the genuinely interesting configuration — transcripts on the phone so the
// audio never leaves it, AI in the cloud so the summaries are good — was unreachable from
// onboarding entirely. It is reachable from here, and from nowhere else in the flow: the three
// cards remain the question everyone else answers.
//
// Nothing on this screen describes where data goes in its own words. That is
// `OnboardingConsequences` below, which renders `Copy.Privacy.stance` for the pending modes.

struct OnboardingProcessingDetailView: View {
    @Bindable var model: OnboardingViewModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            OnboardingBackBar(label: Copy.OnboardingProcessing.backToProcessing) {
                model.backToProcessing()
            }

            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Copy.OnboardingProcessing.detailTitle)
                                .font(AppFont.screenTitle)
                                .foregroundStyle(Tokens.label)
                            Text(Copy.OnboardingProcessing.detailLine)
                                .font(AppFont.subBody)
                                .foregroundStyle(Tokens.tertiary)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 2)

                        axis(
                            header: Copy.OnboardingProcessing.transcriptsSection,
                            selection: $model.transcriptsPlace,
                            onPhone: (
                                Copy.OnboardingProcessing.transcriptsOnPhone,
                                Copy.OnboardingProcessing.transcriptsOnPhoneBody
                            ),
                            inCloud: (
                                Copy.OnboardingProcessing.transcriptsInCloud,
                                Copy.OnboardingProcessing.transcriptsInCloudBody
                            )
                        )

                        axis(
                            header: Copy.OnboardingProcessing.aiSection,
                            selection: $model.aiPlace,
                            onPhone: (
                                Copy.OnboardingProcessing.aiOnPhone,
                                Copy.OnboardingProcessing.aiOnPhoneBody
                            ),
                            inCloud: (
                                Copy.OnboardingProcessing.aiInCloud,
                                Copy.OnboardingProcessing.aiInCloudBody
                            )
                        )

                        // The payoff: the exact stance these two answers add up to, restated the
                        // instant either of them changes.
                        OnboardingConsequences(plan: model.plan, settings: settings)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                    .motionAware(
                        .snappy(duration: 0.25),
                        value: ModePair(model.transcriptsPlace, model.aiPlace)
                    )
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            VStack(spacing: 12) {
                Button(Copy.Onboarding.continueButton) {
                    model.continueFromProcessing(settings: settings)
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

    /// One axis: a section header and its two places. `OptionCard` is the same control the three
    /// presets use, so a person arriving here is not learning a second selection idiom.
    @ViewBuilder
    private func axis(
        header: String,
        selection: Binding<ProcessingPlace>,
        onPhone: (title: String, body: String),
        inCloud: (title: String, body: String)
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(header)
                .font(AppFont.sectionHeader)
                .textCase(.uppercase)
                .kerning(0.4)
                .foregroundStyle(Tokens.meta)
                .accessibilityAddTraits(.isHeader)

            OptionCard(
                title: onPhone.title,
                subtitle: onPhone.body,
                isSelected: selection.wrappedValue == .onPhone
            ) { selection.wrappedValue = .onPhone }

            OptionCard(
                title: inCloud.title,
                subtitle: inCloud.body,
                isSelected: selection.wrappedValue == .inCloud
            ) { selection.wrappedValue = .inCloud }
        }
    }

    /// `motionAware` wants one `Equatable` value; the two axes together are what changes.
    private struct ModePair: Equatable {
        let transcripts: ProcessingPlace
        let ai: ProcessingPlace
        init(_ transcripts: ProcessingPlace, _ ai: ProcessingPlace) {
            self.transcripts = transcripts
            self.ai = ai
        }
    }
}

// MARK: - What the pending answer actually does

/// The consequences of the answer currently selected: where data goes (derived, never written
/// here) and — when the AI would run on device — what that costs.
///
/// Used by both step-3 screens so the three-card question and the two-axis question cannot
/// describe the same configuration differently.
///
/// Rendered as plain text rather than a `Card`: on the preset screen it sits directly under the
/// selected `OptionCard`, and a second card there would read as a fourth option.
struct OnboardingConsequences: View {
    let plan: ProcessingPlan
    let settings: AppSettings

    private var stance: Copy.Privacy.Stance {
        settings.privacyStance(
            transcriptionMode: plan.transcriptionMode, aiMode: plan.aiMode
        )
    }

    var body: some View {
        let stance = self.stance
        VStack(alignment: .leading, spacing: 6) {
            // Same dot semantics as Settings · Storage & Privacy: `good` marks "nothing leaves",
            // neutral otherwise — never `attention`. Choosing the cloud is a legitimate choice,
            // and colouring it as a warning would be exactly the scare-mongering this app's
            // privacy copy is written against.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(
                    color: stance.isFullyLocal ? Tokens.good : Tokens.neutralDot, size: .lifecycle
                )
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(stance.headline)
                    .font(AppFont.cardHead)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            Text(stance.summary)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.secondaryBody)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            // Only ever the "cloud first" sentence in this flow — no card here maps to a
            // `localFirst` mode, precisely because "local first" is a preference, not a promise.
            ForEach(stance.qualifiers, id: \.self) { qualifier in
                Text(qualifier)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The price of on-device AI, said where the choice is made rather than discovered
            // later by someone wondering why no follow-up has ever appeared. Not on "Later",
            // which fails closed to the same modes without anyone having chosen them.
            if plan.showsOnDeviceAiCost {
                Text(Copy.OnboardingProcessing.onDeviceAiNote)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One statement, not five fragments a VoiceOver swipe apart.
        .accessibilityElement(children: .combine)
    }
}

#Preview("Processing detail") {
    OnboardingProcessingDetailView(model: OnboardingViewModel(source: MockWatchPairingSource()))
        .environment(AppSettings())
        .background(Tokens.ground)
        .tint(Tokens.tint)
}
