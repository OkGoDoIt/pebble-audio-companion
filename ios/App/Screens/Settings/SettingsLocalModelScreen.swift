import SwiftUI

/// Settings · Transcription & AI → **Local model** (pushed).
///
/// M3: the on-device engine is Apple's SpeechAnalyzer, whose "models" are per-locale system
/// speech assets. So the honest choice here is *which language* — there is no third-party
/// model catalog to offer. Opening this screen downloads nothing; a download starts only on an
/// explicit tap, and every state iOS reports is shown as it is (Part 6.7).
struct SettingsLocalModelScreen: View {
    @Environment(AppSettings.self) private var settings

    private var model: LocalModelManaging { SettingsDataSources.current.localModel }

    @State private var confirmRemove = false

    var body: some View {
        SettingsScroll {
            SettingsSectionHeader(title: Copy.Settings.TranscriptionAI.languageSection)
            ListCard {
                ForEach(model.languages) { language in
                    LocalLanguageRow(
                        language: language,
                        state: model.state(for: language.id),
                        isSelected: language.id == settings.localSpeechLanguageId,
                        select: { select(language) },
                        cancel: { model.cancelDownload(language.id) }
                    )
                }
            }

            if let selected = model.language(settings.localSpeechLanguageId),
                model.state(for: selected.id) == .installed
            {
                ListCard {
                    DestructiveRow(
                        title: Copy.Settings.TranscriptionAI.removeLanguage(selected.shortName)
                    ) {
                        confirmRemove = true
                    }
                }
            }

            SettingsFooter(text: Copy.Settings.TranscriptionAI.wifiFootnote)

            #if DEBUG
                ListCard {
                    TintActionRow(title: "Debug: simulate failed download") {
                        model.debugFailDownload(settings.localSpeechLanguageId)
                    }
                }
            #endif
        }
        .navigationTitle(Copy.Settings.TranscriptionAI.localModel)
        .navigationBarTitleDisplayMode(.inline)
        // Reading iOS's inventory is the only thing opening this screen does.
        .task { model.refresh() }
        .confirmationDialog(
            removeTitle,
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button(Copy.Settings.TranscriptionAI.removeLanguageButton, role: .destructive) {
                Haptics.destructiveConfirmed()
                model.delete(settings.localSpeechLanguageId)
            }
        } message: {
            Text(Copy.Settings.TranscriptionAI.removeLanguageNote)
        }
    }

    private var removeTitle: String {
        model.language(settings.localSpeechLanguageId)?.name
            ?? Copy.Settings.TranscriptionAI.localModel
    }

    /// The one action on this screen: pick the language on-device transcription runs in, and
    /// fetch its assets when iOS does not have them yet.
    private func select(_ language: LocalSpeechLanguage) {
        settings.localSpeechLanguageId = language.id
        if model.state(for: language.id) != .installed {
            model.download(language.id)
        }
    }
}

// MARK: - Language row

/// One language: name, what iOS reports about it, and — while a download runs — the real
/// progress with a Cancel (never a spinner that means nothing).
private struct LocalLanguageRow: View {
    let language: LocalSpeechLanguage
    let state: LocalModelState
    let isSelected: Bool
    let select: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: select) {
                HStack(spacing: 10) {
                    Text(language.name)
                        .font(AppFont.callout)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 10)
                    accessory
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Tokens.tint)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            switch state {
            case .downloading(let progress):
                HStack(spacing: 12) {
                    ProgressView(value: progress)
                        .tint(Tokens.tint)
                    Button(Copy.Common.cancel, action: cancel)
                        .font(AppFont.smallButton)
                        .foregroundStyle(Tokens.tint)
                        .buttonStyle(.plain)
                }
            case .failed:
                Button(Copy.Common.tryAgain, action: select)
                    .buttonStyle(.smallBordered)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch state {
        case .notInstalled:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Tokens.tint)
                .accessibilityHidden(true)
        case .waitingForWiFi:
            stateText(Copy.Settings.TranscriptionAI.waitingForWiFi, color: Tokens.meta)
        case .downloading(let progress):
            stateText(
                Copy.Settings.TranscriptionAI.downloading(Int(progress * 100)), color: Tokens.meta
            )
        case .installed:
            if !isSelected {
                stateText(Copy.Settings.TranscriptionAI.installedValue, color: Tokens.meta)
            }
        case .failed:
            stateText(Copy.Settings.TranscriptionAI.downloadFailed, color: Tokens.attention)
        }
    }

    private func stateText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(AppFont.subBody)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// VoiceOver reads name + state + whether this is the language in use.
    private var accessibilityLabel: String {
        var parts = [language.name]
        switch state {
        case .notInstalled: parts.append(Copy.Settings.TranscriptionAI.downloadAction)
        case .waitingForWiFi: parts.append(Copy.Settings.TranscriptionAI.waitingForWiFi)
        case .downloading(let progress):
            parts.append(Copy.Settings.TranscriptionAI.downloading(Int(progress * 100)))
        case .installed: parts.append(Copy.Settings.TranscriptionAI.installedValue)
        case .failed: parts.append(Copy.Settings.TranscriptionAI.downloadFailed)
        }
        if isSelected { parts.append(Copy.Settings.TranscriptionAI.inUse) }
        return parts.joined(separator: ", ")
    }
}

#Preview("Local model") {
    NavigationStack {
        SettingsLocalModelScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
