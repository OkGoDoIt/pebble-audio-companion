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
    private var keyChecker: ApiKeyChecking { sources.apiKeys }

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
                // The AI features use the OpenAI key. When OpenAI is ALSO the cloud
                // transcription provider that row is already on this screen, and showing the
                // same setting twice invites the reader to wonder which one is which.
                if settings.cloudTranscriptionProvider != .openAi {
                    keyRow(for: .openAi)
                }
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
        .task {
            model.refresh()
            await checkKeysIfNeeded()
        }
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

    /// "not set" · "sk-…4f2a · verified" · "sk-…4f2a · no credit" — the row answers "is my key
    /// good?", not merely "is one set?".
    private func keyRow(for provider: CloudProvider) -> some View {
        SettingsPushRow(
            title: Copy.Settings.TranscriptionAI.keyRow(provider: provider.displayName),
            value: keyRowValue(for: provider),
            valueColor: keyRowColor(for: provider)
        ) {
            ApiKeyChangeScreen(provider: provider)
        }
    }

    private func keyRowValue(for provider: CloudProvider) -> String {
        guard let masked = settings.maskedApiKey(for: provider) else {
            return Copy.Settings.TranscriptionAI.notSet
        }
        guard let word = keyChecker.status(for: provider).rowWord else { return masked }
        return "\(masked) · \(word)"
    }

    private func keyRowColor(for provider: CloudProvider) -> Color {
        switch keyChecker.status(for: provider) {
        case .checked(.valid): return Tokens.good
        case .checked(let outcome) where outcome != .missing: return Tokens.attention
        default: return Tokens.meta
        }
    }

    /// Asks the provider about any saved key we have no verdict for yet — one cheap
    /// authenticated GET, so the rows mean something the first time the screen is opened.
    private func checkKeysIfNeeded() async {
        for provider in CloudProvider.allCases
        where settings.hasApiKey(for: provider) && keyChecker.status(for: provider) == .unchecked {
            await keyChecker.recheckSaved(provider)
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

    /// One tap, both truths: the end-to-end provider check AND a fresh verdict on the key it
    /// would use — so the key row and this row can never sit there disagreeing.
    private func testConnection() {
        cloudHealth.test()
        Task { await keyChecker.recheckSaved(settings.cloudTranscriptionProvider) }
    }
}

// MARK: - API-key change flow (6.7)

/// Pushed screen per provider: masked current value, secure field, [Save] to Keychain,
/// "Replaces the saved key." Keys never render in plaintext (B13).
///
/// Saving also TESTS the key against the provider and says what came back. The save itself is
/// never gated on that — a key can be right while the network is down — so a failed check reads
/// as "Saved, but …", never as a silent green tick or a lost key.
struct ApiKeyChangeScreen: View {
    let provider: CloudProvider

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var newKey = ""
    @State private var didSave = false

    private var keyChecker: ApiKeyChecking { SettingsDataSources.current.apiKeys }

    private var trimmedKey: String { newKey.trimmingCharacters(in: .whitespaces) }

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
            Button(Copy.Common.save, action: saveAndCheck)
                .buttonStyle(.primaryFilled)
                .disabled(trimmedKey.isEmpty || keyChecker.status(for: provider) == .checking)
                .opacity(trimmedKey.isEmpty ? 0.4 : 1)

            checkResult

            SettingsFooter(text: Copy.Settings.TranscriptionAI.keyChangeFootnote)
        }
        .navigationTitle(Copy.Settings.TranscriptionAI.keyRow(provider: provider.displayName))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Checking · verified · what went wrong + [Check Again]. Only after a save on this
    /// screen — an untouched screen makes no claims.
    @ViewBuilder
    private var checkResult: some View {
        if didSave {
            switch keyChecker.status(for: provider) {
            case .checking:
                Card {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(Copy.KeyCheck.checking)
                            .font(AppFont.callout)
                            .foregroundStyle(Tokens.meta)
                    }
                }
            case .checked(let outcome):
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(outcome.savedMessage)
                            .font(AppFont.callout)
                            .foregroundStyle(outcome.isValid ? Tokens.good : Tokens.attention)
                            .fixedSize(horizontal: false, vertical: true)
                        if !outcome.isValid {
                            Button(Copy.KeyCheck.checkAgain) {
                                Task { await keyChecker.recheckSaved(provider) }
                            }
                            .buttonStyle(.smallBordered)
                        }
                    }
                }
            case .unchecked:
                EmptyView()
            }
        }
    }

    /// Save first, then ask the provider: the key belongs to the user, so it is stored whatever
    /// the network says about it.
    private func saveAndCheck() {
        let key = trimmedKey
        guard !key.isEmpty else { return }
        settings.setApiKey(key, for: provider)
        newKey = ""
        didSave = true
        Task { await keyChecker.check(key, for: provider) }
    }
}

// MARK: - Outcome vocabulary (U9: the app's words, never the provider's)

extension ApiKeyCheckOutcome {
    /// The verdict on its own — the same sentence the onboarding key screen shows.
    var verdict: String {
        switch self {
        case .valid: return Copy.KeyCheck.valid
        case .missing: return Copy.KeyCheck.unexpected
        case .rejected: return Copy.KeyCheck.rejected
        case .notPermitted: return Copy.KeyCheck.notPermitted
        case .outOfCredit: return Copy.KeyCheck.outOfCredit
        case .rateLimited: return Copy.KeyCheck.rateLimited
        case .providerUnavailable: return Copy.KeyCheck.providerUnavailable
        case .unreachable: return Copy.KeyCheck.unreachable
        case .unexpected: return Copy.KeyCheck.unexpected
        }
    }

    /// After a save: the key is in the Keychain either way, and then what came back.
    var savedMessage: String { Copy.KeyCheck.saved(verdict) }

    /// The same verdict in one word, for the Settings row.
    var rowWord: String? {
        switch self {
        case .valid: return Copy.KeyCheck.Row.valid
        case .missing: return nil
        case .rejected: return Copy.KeyCheck.Row.rejected
        case .notPermitted: return Copy.KeyCheck.Row.notPermitted
        case .outOfCredit: return Copy.KeyCheck.Row.outOfCredit
        case .rateLimited: return Copy.KeyCheck.Row.rateLimited
        case .providerUnavailable: return Copy.KeyCheck.Row.providerUnavailable
        case .unreachable: return Copy.KeyCheck.Row.unreachable
        case .unexpected: return Copy.KeyCheck.Row.unexpected
        }
    }
}

extension ApiKeyStatus {
    /// What the key row appends after the masked value; nil when there is nothing to say.
    var rowWord: String? {
        switch self {
        case .unchecked: return nil
        case .checking: return Copy.KeyCheck.Row.checking
        case .checked(let outcome): return outcome.rowWord
        }
    }
}

#Preview("Transcription & AI") {
    NavigationStack {
        SettingsTranscriptionScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
