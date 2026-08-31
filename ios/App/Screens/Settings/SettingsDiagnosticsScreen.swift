import SwiftUI

/// Settings · Diagnostics (artboard 2.14): live counters, recent segments in plain language
/// (never key=value dumps), Support Report + Detailed Logs (the raw lines live only behind
/// the push). DEBUG builds add a Design section (token/component galleries) and the
/// onboarding reset used by the M7 walkthrough.
struct SettingsDiagnosticsScreen: View {
    @Environment(AppSettings.self) private var settings

    private var diagnostics: DiagnosticsSource { SettingsDataSources.current.diagnostics }

    var body: some View {
        SettingsScroll {
            ListCard {
                SettingsRow(
                    title: Copy.Settings.Diagnostics.receiver,
                    value: diagnostics.receiverStatus,
                    showsChevron: false
                )
                SettingsRow(
                    title: Copy.Settings.Diagnostics.watchReports,
                    value: diagnostics.watchReports,
                    showsChevron: false
                )
                SettingsRow(
                    title: Copy.Settings.Diagnostics.transcriptionQueue,
                    value: Copy.Settings.Diagnostics.queueValue(
                        waiting: diagnostics.queueWaiting,
                        failed: diagnostics.queueFailed
                    ),
                    showsChevron: false
                )
                SettingsRow(
                    title: Copy.Settings.Diagnostics.aiEnrichment,
                    value: Copy.Settings.Diagnostics.enrichmentValue(
                        waiting: diagnostics.enrichmentWaiting,
                        running: diagnostics.enrichmentRunning
                    ),
                    showsChevron: false
                )
            }

            // "6 failed" above is a count without a cause, which is the one thing a person
            // reading Diagnostics is actually trying to find out. The reason has always been
            // persisted (`transcription_tasks.lastError`); these rows are where it surfaces.
            // The stored string is never shown — it is classified into the app's own vocabulary
            // first, because the cloud paths splice the provider's response body into it (B20).
            if !diagnostics.failedItems.isEmpty {
                SettingsSectionHeader(title: Copy.Settings.Diagnostics.failures)
                ListCard {
                    ForEach(diagnostics.failedItems) { item in
                        FailedTranscriptionRow(item: item)
                    }
                }
            }

            // Before the first recording there are no segments; a header over an empty card
            // reads like something failed to load.
            if !diagnostics.recentSegments.isEmpty {
                SettingsSectionHeader(title: Copy.Settings.Diagnostics.recentSegments)
                ListCard {
                    ForEach(diagnostics.recentSegments) { segment in
                        SettingsRow(
                            title: segment.title,
                            value: segment.detail,
                            showsChevron: false
                        )
                    }
                }
            }

            ListCard {
                ShareLink(item: diagnostics.supportReportText) {
                    HStack {
                        Text(Copy.Settings.Diagnostics.supportReport)
                            .font(AppFont.callout)
                            .foregroundStyle(Tokens.tint)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Navigation, not an action: label colour + chevron, like every other pushed
                // row in Settings. Tint text is reserved for things that DO something.
                SettingsPushRow(title: Copy.Settings.Diagnostics.detailedLogs) {
                    DetailedLogsScreen()
                }
            }

            SettingsFooter(text: Copy.Settings.Diagnostics.footer)

            #if DEBUG
            designSection
            #endif
        }
        .navigationTitle(Copy.Settings.Diagnostics.title)
    }

    #if DEBUG
    /// Debug-only design references (also the onboarding reset for state walkthroughs).
    @ViewBuilder
    private var designSection: some View {
        SettingsSectionHeader(title: "Design")
        ListCard {
            SettingsPushRow(title: "Token gallery") { TokenGallery() }
            SettingsPushRow(title: "Component gallery") { ComponentGallery() }
            SettingsRow(title: "Reset onboarding", showsChevron: false) {
                settings.onboardingComplete = false
            }
        }
    }
    #endif
}

/// One failed recording: when it was made, then the reason in full underneath.
///
/// A `SettingsRow` would truncate the reason to one trailing line, and the reason is the whole
/// point of the row — so this stacks instead, in the same shape the local-model rows use.
private struct FailedTranscriptionRow: View {
    let item: DiagnosticFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(item.title)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                Spacer(minLength: 10)
                Text(item.attemptsLine)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.meta)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(item.reason)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.secondaryBody)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The raw technical view — the one place protocol vocabulary is allowed. Counters and gap
/// metadata only; never audio or transcript text.
private struct DetailedLogsScreen: View {
    private var diagnostics: DiagnosticsSource { SettingsDataSources.current.diagnostics }

    var body: some View {
        // Lines WRAP rather than scrolling sideways: the two-axis scroll view centred short
        // content in the middle of the screen and clipped every long line at the right edge,
        // so the one place with the real detail was the one place you could not read it.
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if diagnostics.detailedLogLines.isEmpty {
                    Text(Copy.Settings.Diagnostics.noLogs)
                        .font(AppFont.callout)
                        .foregroundStyle(Tokens.meta)
                }
                ForEach(Array(diagnostics.detailedLogLines.enumerated()), id: \.offset) {
                    _, line in
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Tokens.secondaryBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Tokens.screenMargin)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Tokens.ground)
        .navigationTitle(Copy.Settings.Diagnostics.detailedLogs)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Diagnostics") {
    NavigationStack {
        SettingsDiagnosticsScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
