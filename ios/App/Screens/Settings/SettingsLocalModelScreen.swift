import SwiftUI

/// Settings · Transcription & AI → **Local model** (pushed).
///
/// The row that leads here never acts on its own: opening this screen downloads nothing, and a
/// download starts only when a specific model is chosen — with its size shown before the tap.
/// Every entry carries the four Part 6.7 states (not installed · downloading with real progress
/// + Cancel · installed · failed + Try Again).
struct SettingsLocalModelScreen: View {
    @Environment(AppSettings.self) private var settings

    private var model: LocalModelManaging { SettingsDataSources.current.localModel }

    @State private var removeTarget: LocalModelOption?

    var body: some View {
        SettingsScroll {
            // The chosen model is one that downloads, and it is not here. The kit transcribes
            // with Apple Speech meanwhile (`SelectableLocalTranscriptionProvider.resolution`),
            // so this screen says which engine is actually running rather than showing a check
            // mark beside a model that is doing nothing.
            if model.fallsBackToAppleSpeech(settings.localTranscriptionModelId),
                let missing = model.model(settings.localTranscriptionModelId)
            {
                Card {
                    HStack(alignment: .top, spacing: 8) {
                        StatusDot(color: Tokens.attention, size: .lifecycle)
                            .padding(.top, 5)
                        Text(fallbackNotice(missing))
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.secondaryBody)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            ListCard {
                ForEach(model.models) { option in
                    LocalModelRow(
                        option: option,
                        state: model.state(for: option.id),
                        isSelected: option.id == settings.localTranscriptionModelId,
                        select: { select(option) },
                        cancel: { model.cancelDownload(option.id) }
                    )
                }
            }

            // Everything actually taking up room here, not only the engine in use: with three
            // downloadable models in the catalog, a 1.2 GB one you tried once would otherwise
            // be unremovable without selecting it first.
            if !installed.isEmpty {
                ListCard {
                    ForEach(installed) { option in
                        DestructiveRow(
                            title: Copy.Settings.TranscriptionAI.removeModel(option.compactName)
                        ) {
                            removeTarget = option
                        }
                    }
                }
            }

            SettingsFooter(text: Copy.Settings.TranscriptionAI.wifiFootnote)

            #if DEBUG
                ListCard {
                    TintActionRow(title: "Debug: simulate failed download") {
                        model.debugFailDownload(settings.localTranscriptionModelId)
                    }
                }
            #endif
        }
        .navigationTitle(Copy.Settings.TranscriptionAI.localModel)
        .navigationBarTitleDisplayMode(.inline)
        // Re-reading install state is the only thing opening this screen does.
        .task { model.refresh() }
        .confirmationDialog(
            removeTarget?.displayName ?? Copy.Settings.TranscriptionAI.localModel,
            isPresented: Binding(
                get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: removeTarget
        ) { target in
            Button(Copy.Settings.TranscriptionAI.removeModelButton, role: .destructive) {
                Haptics.destructiveConfirmed()
                model.delete(target.id)
            }
        } message: { target in
            Text(removeNote(target))
        }
    }

    /// The fallback fact, worded for whether anything is being done about it right now.
    private func fallbackNotice(_ option: LocalModelOption) -> String {
        model.state(for: option.id).isBusy
            ? Copy.Settings.TranscriptionAI.fallbackNoticeInProgress(option.compactName)
            : Copy.Settings.TranscriptionAI.fallbackNotice(option.compactName)
    }

    private var installed: [LocalModelOption] {
        model.models.filter { model.state(for: $0.id) == .installed }
    }

    /// Honest about what removal actually does: app-owned weights go now, system speech files
    /// go when iOS decides it needs the room.
    private func removeNote(_ option: LocalModelOption) -> String {
        guard let size = option.sizeText else {
            return Copy.Settings.TranscriptionAI.removeSystemModelNote
        }
        return Copy.Settings.TranscriptionAI.removeModelNote(size)
    }

    /// The one action here: make a model the on-device engine, and fetch it if it isn't here.
    /// Tapping a row whose download is already running must not start a second one.
    private func select(_ option: LocalModelOption) {
        settings.localTranscriptionModelId = option.id
        let state = model.state(for: option.id)
        guard state != .installed, !state.isBusy else { return }
        model.download(option.id)
    }
}

// MARK: - Model row

/// Name · standing · size · what it is for, then whatever state the engine reports — including
/// real download progress with a Cancel (never a spinner that stands for nothing).
private struct LocalModelRow: View {
    let option: LocalModelOption
    let state: LocalModelState
    let isSelected: Bool
    let select: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text(option.displayName)
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
                    Text(standingLine)
                        .font(AppFont.footnote)
                        .foregroundStyle(option.isRecommended ? Tokens.tint : Tokens.meta)
                    Text(option.description)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // An engine that cannot run here is shown, and says why, but cannot be chosen.
            .disabled(state == .unavailable)
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
            // Unpacking: the bytes are all here, so the bar is full and honest — but there is
            // no second number to report, and it is still cancellable.
            case .installing:
                HStack(spacing: 12) {
                    ProgressView(value: 1)
                        .tint(Tokens.tint)
                    Button(Copy.Common.cancel, action: cancel)
                        .font(AppFont.smallButton)
                        .foregroundStyle(Tokens.tint)
                        .buttonStyle(.plain)
                }
            case .failed:
                // Same slot the progress bar uses: what went wrong, and the way out of it.
                HStack(spacing: 12) {
                    Text(Copy.Settings.TranscriptionAI.downloadFailed)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.attention)
                    Spacer(minLength: 10)
                    Button(Copy.Common.tryAgain, action: select)
                        .buttonStyle(.smallBordered)
                }
            default:
                EmptyView()
            }
        }
    }

    /// "Recommended · 706 MB" — or just "Built in" for the engine that downloads nothing.
    private var standingLine: String {
        [option.shortLabel, option.sizeText].compactMap { $0 }.joined(separator: " · ")
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
            // Just the number: the bar below says "downloading", and the longer phrase pushed
            // the model's name into a second line mid-download.
            stateText(Copy.Settings.TranscriptionAI.percent(Int(progress * 100)), color: Tokens.meta)
        case .installing:
            stateText(Copy.Settings.TranscriptionAI.installing, color: Tokens.meta)
        case .installed:
            if !isSelected {
                stateText(Copy.Settings.TranscriptionAI.installedValue, color: Tokens.meta)
            }
        case .failed:
            // The failure and its Try Again live on the line below, together.
            EmptyView()
        case .unavailable:
            stateText(Copy.Settings.TranscriptionAI.unavailable, color: Tokens.meta)
        }
    }

    private func stateText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(AppFont.subBody)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    /// VoiceOver reads name, standing, state, and whether this is the engine in use.
    private var accessibilityLabel: String {
        var parts = [option.displayName, standingLine]
        switch state {
        case .notInstalled: parts.append(Copy.Settings.TranscriptionAI.downloadAction)
        case .waitingForWiFi: parts.append(Copy.Settings.TranscriptionAI.waitingForWiFi)
        case .downloading(let progress):
            parts.append(Copy.Settings.TranscriptionAI.downloading(Int(progress * 100)))
        case .installing: parts.append(Copy.Settings.TranscriptionAI.installing)
        case .installed: parts.append(Copy.Settings.TranscriptionAI.installedValue)
        case .failed: parts.append(Copy.Settings.TranscriptionAI.downloadFailed)
        case .unavailable: parts.append(Copy.Settings.TranscriptionAI.unavailable)
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
