import SwiftUI
import Transcription
import Intelligence

/// Settings · Transcription & AI (artboard 2.11 + plan 6.7): disclosure rows only (no
/// segmented controls), the four local-model row states, keys shown as "saved in Keychain"
/// with a pushed change flow — never inline fields.
struct SettingsTranscriptionScreen: View {
    @Environment(AppSettings.self) private var settings

    private var sources: SettingsDataSources { SettingsDataSources.current }
    private var model: LocalModelManaging { sources.localModel }

    private var cloudHealth: CloudHealthSource { sources.cloudHealth }

    var body: some View {
        @Bindable var settings = settings
        SettingsScroll {
            SettingsSectionHeader(title: Copy.Settings.TranscriptionAI.transcriptionSection)
            ListCard {
                SettingsPushRow(
                    title: Copy.Settings.TranscriptionAI.mode,
                    value: settings.transcriptionMode.displayName
                ) {
                    ChoiceScreen(
                        title: Copy.Settings.TranscriptionAI.mode,
                        options: TranscriptionMode.allCases.map {
                            .init(value: $0, label: $0.displayName)
                        },
                        selection: $settings.transcriptionMode,
                        footer: Copy.Settings.TranscriptionAI.footer
                    )
                }
                // Never starts a download by itself — it pushes the catalog, where the size is
                // visible before anything is fetched.
                SettingsPushRow(
                    title: Copy.Settings.TranscriptionAI.localModel,
                    value: localModelValue,
                    valueColor: localModelValueColor
                ) {
                    SettingsLocalModelScreen()
                }
                SettingsPushRow(
                    title: Copy.Settings.TranscriptionAI.cloudProvider,
                    value: settings.cloudTranscriptionProvider.displayName
                ) {
                    ChoiceScreen(
                        title: Copy.Settings.TranscriptionAI.cloudProvider,
                        options: CloudProvider.allCases.map {
                            .init(value: $0, label: $0.displayName)
                        },
                        selection: $settings.cloudTranscriptionProvider
                    )
                }
                keyRow(for: settings.cloudTranscriptionProvider)
            }

            SettingsSectionHeader(title: Copy.Settings.TranscriptionAI.aiSection)
            ListCard {
                SettingsPushRow(
                    title: Copy.Settings.TranscriptionAI.mode,
                    value: settings.aiMode.displayName
                ) {
                    ChoiceScreen(
                        title: Copy.Settings.TranscriptionAI.mode,
                        options: AiProcessingMode.allCases.map {
                            .init(value: $0, label: $0.displayName)
                        },
                        selection: $settings.aiMode
                    )
                }
                SettingsPushRow(
                    title: Copy.Settings.TranscriptionAI.model,
                    value: sources.aiModelName(for: settings.aiModel)
                ) {
                    ChoiceScreen(
                        title: Copy.Settings.TranscriptionAI.model,
                        options: sources.aiModels.map {
                            .init(value: $0.id, label: $0.displayName)
                        },
                        selection: $settings.aiModel
                    )
                }
                keyRow(for: .openAi)
            }

            ListCard {
                TintActionRow(
                    title: Copy.Settings.TranscriptionAI.testConnection,
                    action: testConnection
                ) {
                    testAccessory
                }
            }
            SettingsFooter(text: Copy.Settings.TranscriptionAI.footer)
        }
        .navigationTitle(Copy.Settings.TranscriptionAI.title)
        .task { model.refresh() }
    }

    // MARK: Local model row

    /// "Apple Speech" · "Parakeet TDT 0.6B · 706 MB" when installed; otherwise the state
    /// itself, in the same lowercase register as "not set" on the key rows.
    private var localModelValue: String {
        switch model.state(for: settings.localTranscriptionModelId) {
        case .notInstalled:
            return Copy.Settings.TranscriptionAI.notInstalled
        case .waitingForWiFi:
            return Copy.Settings.TranscriptionAI.waitingForWiFi
        case .downloading(let progress):
            return Copy.Settings.TranscriptionAI.downloading(Int(progress * 100))
        case .failed:
            return Copy.Settings.TranscriptionAI.downloadFailed
        case .unavailable:
            return Copy.Settings.TranscriptionAI.unavailable
        case .installed:
            guard let option = model.selectedModel(settings.localTranscriptionModelId) else {
                return Copy.Settings.TranscriptionAI.notInstalled
            }
            return [option.compactName, option.sizeText]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
    }

    private var localModelValueColor: Color {
        model.state(for: settings.localTranscriptionModelId) == .failed
            ? Tokens.attention : Tokens.meta
    }

    // MARK: Key rows

    private func keyRow(for provider: CloudProvider) -> some View {
        SettingsPushRow(
            title: Copy.Settings.TranscriptionAI.keyRow(provider: provider.displayName),
            value: settings.hasApiKey(for: provider)
                ? Copy.Settings.TranscriptionAI.savedInKeychain
                : Copy.Settings.TranscriptionAI.notSet
        ) {
            ApiKeyChangeScreen(provider: provider)
        }
    }

    // MARK: Test connection

    @ViewBuilder
    private var testAccessory: some View {
        switch cloudHealth.testState {
        case .untested:
            // Nothing has been asked yet, so there is nothing honest to report.
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .connected(let ago):
            Text(Copy.Settings.TranscriptionAI.connectedAgo(ago))
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.good)
        case .problem(let message):
            Text(message)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.attention)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func testConnection() { cloudHealth.test() }
}

// MARK: - API-key change flow (6.7)

/// Pushed screen per provider: masked current value, secure field, [Save] to Keychain,
/// "Replaces the saved key." Keys never render in plaintext (B13).
struct ApiKeyChangeScreen: View {
    let provider: CloudProvider

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var newKey = ""

    var body: some View {
        SettingsScroll {
            if let masked = settings.maskedApiKey(for: provider) {
                ListCard {
                    SettingsRow(
                        title: Copy.Settings.TranscriptionAI.savedInKeychain,
                        value: masked,
                        showsChevron: false
                    )
                }
            }
            Card {
                SecureField("New key", text: $newKey)
                    .font(AppFont.callout)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button(Copy.Common.save) {
                settings.setApiKey(newKey, for: provider)
                dismiss()
            }
            .buttonStyle(.primaryFilled)
            .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(newKey.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)

            SettingsFooter(text: Copy.Settings.TranscriptionAI.keyChangeFootnote)
        }
        .navigationTitle(Copy.Settings.TranscriptionAI.keyRow(provider: provider.displayName))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Transcription & AI") {
    NavigationStack {
        SettingsTranscriptionScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
