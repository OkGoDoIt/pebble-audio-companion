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

    private enum TestState: Equatable { case result(String), testing }
    @State private var testState: TestState = .result("2 min ago")

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
                LocalModelRow(model: model)
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
            SettingsFooter(text: Copy.Settings.TranscriptionAI.wifiFootnote)

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
        switch testState {
        case .testing:
            ProgressView().controlSize(.small)
        case .result(let ago):
            Text(Copy.Settings.TranscriptionAI.connectedAgo(ago))
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.good)
        }
    }

    private func testConnection() {
        guard testState != .testing else { return }
        testState = .testing
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            testState = .result("just now")
        }
    }
}

// MARK: - Local model row (the four 6.7 states)

/// "not installed" (tap downloads) · "downloading · N%" (progress + Cancel) ·
/// "<name> · installed" (⋯ / long-press → Delete Model…) · "download failed" (+ Retry).
private struct LocalModelRow: View {
    let model: LocalModelManaging

    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state {
            case .notInstalled:
                Button(action: model.startDownload) {
                    labelRow(value: Copy.Settings.TranscriptionAI.notInstalled, chevron: false)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

            case .downloading(let progress):
                labelRow(
                    value: Copy.Settings.TranscriptionAI.downloading(Int(progress * 100)),
                    chevron: false
                )
                HStack(spacing: 12) {
                    ProgressView(value: progress)
                        .tint(Tokens.tint)
                    Button(Copy.Common.cancel, action: model.cancelDownload)
                        .font(AppFont.smallButton)
                        .foregroundStyle(Tokens.tint)
                        .buttonStyle(.plain)
                }

            case .installed:
                HStack(spacing: 10) {
                    labelRow(
                        value: "\(model.modelName) · installed",
                        chevron: false
                    )
                    Menu {
                        Button(Copy.Settings.TranscriptionAI.deleteModel, role: .destructive) {
                            confirmDelete = true
                        }
                        #if DEBUG
                        Button("Debug: simulate failed download") {
                            model.debugFailDownload()
                        }
                        #endif
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Tokens.meta)
                            .hitTarget()
                    }
                    .accessibilityLabel(Copy.Settings.TranscriptionAI.deleteModel)
                }

            case .failed:
                HStack(spacing: 10) {
                    labelRow(
                        value: Copy.Settings.TranscriptionAI.downloadFailed,
                        valueColor: Tokens.attention,
                        chevron: false
                    )
                    Button(Copy.Common.retry, action: model.startDownload)
                        .buttonStyle(.smallBordered)
                }
            }
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                Haptics.destructiveConfirmed()
                model.deleteModel()
            }
        }
    }

    /// Names what gets deleted (model + size), e.g. "Parakeet v3 · 706 MB".
    private var deleteDialogTitle: String {
        if case .installed(let size) = model.state {
            return "\(model.modelName) · \(size)"
        }
        return model.modelName
    }

    private func labelRow(
        value: String, valueColor: Color = Tokens.meta, chevron: Bool
    ) -> some View {
        SettingsRow(
            title: Copy.Settings.TranscriptionAI.localModel,
            value: value,
            valueColor: valueColor,
            showsChevron: chevron
        )
    }
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
