import CompanionRuntime
import StatusUI
import SwiftUI

/// Settings · Storage.
///
/// The questions a person brings here, in the order they are answered:
///
///  1. **How much room is this taking, and of what?** One number, one bar, a legend: the
///     recordings next to the transcripts, the speech model and anything temporary, against
///     what the phone has free. Because on 2026-10-12 the one number iOS showed for the app
///     was 11.7 GB and the recordings were 2.1 GB of it.
///  2. **Can I keep everything and still have room?** The iCloud rule: audio older than an age
///     moves to iCloud Drive and comes back when played. The split bar shows what that means
///     for THIS library before the switch is touched, and follows the age picker.
///  3. **What gets deleted, and when?** Keep audio and the storage limit, in their own section,
///     named "Deleting" so the two rules that destroy are never mistaken for the one that moves.
///  4. Export and delete-all, where they always were.
///
/// Privacy has its own screen now (`SettingsPrivacyScreen`): "where does my data go?" is a
/// different question, and this one needs the whole screen.
struct SettingsStorageScreen: View {
    @Environment(AppSettings.self) private var settings

    private var storage: StorageStatsSource { SettingsDataSources.current.storage }

    private enum ExportState: Equatable { case idle, exporting, done(Int) }
    @State private var exportState: ExportState = .idle
    @State private var confirmDeleteAll = false

    var body: some View {
        @Bindable var settings = settings
        SettingsScroll {
            overviewCard

            SettingsSectionHeader(title: Copy.Settings.Storage.recordingsSection)
            cloudCard
            SettingsFooter(text: Copy.Settings.Storage.cloudFooter)

            SettingsSectionHeader(title: Copy.Settings.Storage.deletingSection)
            ListCard {
                SettingsPushRow(
                    title: Copy.Settings.Storage.keepAudio,
                    value: Copy.Settings.Storage.keepDays(settings.retentionDays)
                ) {
                    ChoiceScreen(
                        title: Copy.Settings.Storage.keepAudio,
                        options: AppSettings.retentionOptions.map {
                            .init(value: $0, label: Copy.Settings.Storage.keepDays($0))
                        },
                        selection: $settings.retentionDays,
                        footer: settings.coldStorageEnabled
                            ? Copy.Settings.Storage.keepAudioCloudFooter : nil
                    )
                }
                SettingsPushRow(
                    title: Copy.Settings.Storage.storageLimit,
                    value: AppSettings.retentionLimitLabel(settings.retentionMaxBytes)
                ) {
                    ChoiceScreen(
                        title: Copy.Settings.Storage.storageLimit,
                        options: AppSettings.retentionLimitOptions.map {
                            .init(value: $0, label: AppSettings.retentionLimitLabel($0))
                        },
                        selection: $settings.retentionMaxBytes,
                        footer: Copy.Settings.Storage.limitFooter
                    )
                }
                // Only meaningful once a limit exists — with none set there is no proportion to
                // report, and the bare size is already in the overview.
                if settings.retentionMaxBytes > 0 {
                    SettingsRow(
                        title: Copy.Settings.Storage.usedOfLimit(
                            used: Formatting.storageSize(storage.recordingsBytes),
                            limit: AppSettings.retentionLimitLabel(settings.retentionMaxBytes)
                        ),
                        showsChevron: false
                    )
                }
            }
            SettingsFooter(text: Copy.Settings.Storage.limitFooter)

            ListCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Copy.Settings.Storage.autoExport)
                            .font(AppFont.callout)
                            .foregroundStyle(Tokens.label)
                        Text(Copy.Settings.Storage.autoExportSub)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                    }
                    Spacer(minLength: 10)
                    Toggle(Copy.Settings.Storage.autoExport, isOn: $settings.automaticWavExportEnabled)
                        .labelsHidden()
                }
                TintActionRow(title: Copy.Settings.Storage.exportAll, action: exportAll) {
                    exportAccessory
                }
            }

            ListCard {
                DestructiveRow(title: Copy.Settings.Storage.deleteAll) {
                    confirmDeleteAll = true
                }
            }
            .confirmationDialog(
                Copy.Settings.Storage.deleteAllTitle,
                isPresented: $confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button(Copy.Settings.Storage.deleteAllConfirm, role: .destructive) {
                    storage.deleteAllRecordings()
                }
            } message: {
                Text(Copy.Settings.Storage.deleteAllMessage)
            }
        }
        .navigationTitle(Copy.Settings.Storage.title)
        // The sidecar read and the file walk only run while this screen is being looked at;
        // see `LiveStorageStatsSource.setVisible`.
        .onAppear { storage.setVisible(true) }
        .onDisappear { storage.setVisible(false) }
    }

    // MARK: Overview

    /// The one number, the bar, the legend. Measured against the phone: the bar's whole is
    /// what we hold, and the free space sits under it as a fact rather than as a part — the
    /// rest of the phone is not ours to draw.
    private var overviewCard: some View {
        Card {
            if let overview = storage.overview {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Copy.Settings.Storage.onThisPhone(Formatting.storageSize(overview.onPhoneBytes)))
                            .font(AppFont.sectionTitle)
                            .foregroundStyle(Tokens.label)
                        Text(
                            Copy.Settings.Storage.freeOfCapacity(
                                free: Formatting.storageSize(overview.freeBytes),
                                capacity: StorageCapacity.label(overview.capacityBytes))
                        )
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                    }
                    StorageBar(parts: overviewParts(overview), total: overview.onPhoneBytes)
                    VStack(alignment: .leading, spacing: 8) {
                        StorageLegendRow(
                            color: Tokens.tint, title: Copy.Settings.Storage.legendAudio,
                            value: Formatting.storageSize(overview.audioOnPhoneBytes))
                        StorageLegendRow(
                            color: Tokens.tintSoft, title: Copy.Settings.Storage.legendText,
                            value: Formatting.storageSize(overview.textBytes))
                        StorageLegendRow(
                            color: Tokens.quiet, title: Copy.Settings.Storage.legendModel,
                            value: Formatting.storageSize(overview.modelBytes))
                        if overview.temporaryBytes >= Self.temporaryWorthNaming {
                            StorageLegendRow(
                                color: Tokens.quiet, hatched: true,
                                title: Copy.Settings.Storage.legendTemporary,
                                value: Formatting.storageSize(overview.temporaryBytes),
                                note: Copy.Settings.Storage.temporaryCleaned)
                        }
                        if overview.audioInCloudBytes > 0 {
                            StorageLegendRow(
                                color: Tokens.captured, title: Copy.Settings.Storage.legendCloud,
                                value: Formatting.storageSize(overview.audioInCloudBytes),
                                note: Copy.Settings.Storage.legendCloudNote(overview.audioInCloudCount))
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(Copy.Settings.Storage.measuring)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.meta)
                }
            }
        }
    }

    /// The shortest Keep audio under which some offered move age can take effect (30 days).
    private static let minimumKeepDaysForCloud: Int = {
        let youngestAge = AppSettings.coldStorageAgeOptions.min() ?? 0
        return AppSettings.retentionOptions.first { $0 > youngestAge } ?? youngestAge + 1
    }()

    /// Below this, temporary files are the ordinary few megabytes of scratch and not a story.
    private static let temporaryWorthNaming: Int64 = 50 * 1024 * 1024


    private func overviewParts(_ overview: StorageOverview) -> [StorageBar.Part] {
        var parts: [StorageBar.Part] = [
            .init(id: "audio", bytes: overview.audioOnPhoneBytes, color: Tokens.tint),
            .init(id: "text", bytes: overview.textBytes, color: Tokens.tintSoft),
            .init(id: "model", bytes: overview.modelBytes, color: Tokens.quiet),
        ]
        if overview.temporaryBytes >= Self.temporaryWorthNaming {
            parts.append(.init(id: "tmp", bytes: overview.temporaryBytes, color: Tokens.quiet, hatched: true))
        }
        return parts
    }

    // MARK: iCloud

    /// The rule, its age, and the split it makes of the recordings — drawn before the switch is
    /// on, so the switch is never a surprise. The split bar is the same component as the
    /// overview's, over a different whole: all the audio there is.
    ///
    /// Everything here shows the EFFECTIVE age (`effectiveColdStorageMinAgeDays`): "Keep audio"
    /// deletes recordings first, so a move age at or past it is a rule that never fires. Under
    /// the defaults (move at 2 months, keep 30 days) the card used to show "2 months" and a
    /// switch that, turned on, moved nothing, ever. Now it shows what will happen and says why.
    private var cloudCard: some View {
        @Bindable var settings = settings
        let overview = storage.overview
        let available = overview?.cloudAvailable ?? false
        let effectiveAge = settings.effectiveColdStorageMinAgeDays
        let preview = effectiveAge.map { storage.wouldMove(olderThanDays: $0) }
            ?? StoragePreview(bytes: 0, count: 0, percent: 0)
        return ListCard {
            HStack(spacing: 12) {
                Text(Copy.Settings.Storage.cloudToggle)
                    .font(AppFont.callout)
                    .foregroundStyle(available && effectiveAge != nil ? Tokens.label : Tokens.meta)
                Spacer(minLength: 10)
                Toggle(Copy.Settings.Storage.cloudToggle, isOn: $settings.coldStorageEnabled)
                    .labelsHidden()
                    // A rule that could move nothing is not offered — but one already on stays
                    // switchable, so it can be turned off.
                    .disabled(!available || (effectiveAge == nil && !settings.coldStorageEnabled))
            }
            // Why the switch is off and cannot be turned on, directly under it.
            if !available {
                Text(Copy.Settings.Storage.cloudUnavailable)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.secondaryBody)
                    .fixedSize(horizontal: false, vertical: true)
            } else if effectiveAge == nil {
                Text(
                    Copy.Settings.Storage.cloudBlockedByKeepAudio(
                        keepDays: settings.retentionDays,
                        minimumKeepDays: Self.minimumKeepDaysForCloud))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.secondaryBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let effectiveAge {
                SettingsPushRow(
                    title: Copy.Settings.Storage.cloudAge,
                    value: Copy.Settings.Storage.ageLabel(effectiveAge)
                ) {
                    ChoiceScreen(
                        title: Copy.Settings.Storage.cloudAge,
                        options: settings.coldStorageAgeChoices.map {
                            .init(value: $0, label: Copy.Settings.Storage.ageLabel($0))
                        },
                        // Checks the age in force; a pick is stored as the new choice.
                        selection: Binding(
                            get: { settings.effectiveColdStorageMinAgeDays ?? settings.coldStorageMinAgeDays },
                            set: { settings.coldStorageMinAgeDays = $0 }),
                        footer: Copy.Settings.Storage.cloudAgeFooter(
                            keepDays: settings.retentionDays,
                            limited: settings.coldStorageAgeChoices.count
                                < AppSettings.coldStorageAgeOptions.count)
                    )
                }
                // The choice was older than Keep audio allows: say what happens instead, and why.
                if effectiveAge != settings.coldStorageMinAgeDays {
                    Text(
                        Copy.Settings.Storage.cloudAgeShortened(
                            effectiveDays: effectiveAge, chosenDays: settings.coldStorageMinAgeDays,
                            keepDays: settings.retentionDays))
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.secondaryBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let overview, effectiveAge != nil || overview.audioInCloudBytes > 0 {
                splitRow(overview, preview: preview)
            }
            if let error = overview?.cloudError, available {
                Text(Copy.Settings.Storage.cloudError(error))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.secondaryBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let overview, available, !settings.coldStorageEnabled, overview.audioInCloudBytes > 0 {
                bringBackRow(overview)
            }
        }
    }

    /// The recordings as a whole, split between the phone and iCloud. Off: the part that WOULD
    /// move is hatched, so it reads as "spoken for" rather than gone. On: what has moved is
    /// solid, what is uploading is hatched.
    @ViewBuilder
    private func splitRow(_ overview: StorageOverview, preview: StoragePreview) -> some View {
        let on = settings.coldStorageEnabled
        let staying = max(overview.audioOnPhoneBytes - (on ? overview.uploadingBytes : preview.bytes), 0)
        VStack(alignment: .leading, spacing: 8) {
            StorageBar(
                parts: [
                    .init(id: "phone", bytes: staying, color: Tokens.tint),
                    .init(
                        id: "moving", bytes: on ? overview.uploadingBytes : preview.bytes,
                        color: Tokens.captured, hatched: true),
                    .init(id: "cloud", bytes: overview.audioInCloudBytes, color: Tokens.captured),
                ],
                total: max(overview.audioBytes, 1),
                height: 8)
            // Two legends side by side, each on its own half, so neither can push the card
            // past the screen margin whatever the numbers are.
            HStack(spacing: 12) {
                StorageLegendRow(
                    color: Tokens.tint, title: Copy.Settings.Storage.barOnPhone,
                    value: Formatting.storageSize(staying))
                    .frame(maxWidth: .infinity, alignment: .leading)
                StorageLegendRow(
                    color: Tokens.captured, title: Copy.Settings.Storage.barCloud,
                    value: Formatting.storageSize(
                        overview.audioInCloudBytes + (on ? overview.uploadingBytes : preview.bytes)))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(splitLine(overview, preview: preview))
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.meta)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func splitLine(_ overview: StorageOverview, preview: StoragePreview) -> String {
        if settings.coldStorageEnabled {
            if overview.audioInCloudBytes == 0, overview.uploadingBytes == 0 {
                return preview.bytes > 0
                    ? Copy.Settings.Storage.wouldMove(
                        size: Formatting.storageSize(preview.bytes), percent: preview.percent)
                    : Copy.Settings.Storage.inCloudNothingYet
            }
            return Copy.Settings.Storage.inCloud(
                size: Formatting.storageSize(overview.audioInCloudBytes),
                uploading: overview.uploadingBytes > 0
                    ? Formatting.storageSize(overview.uploadingBytes) : nil)
        }
        if overview.audioInCloudBytes > 0 {
            return Copy.Settings.Storage.stillInCloud(Formatting.storageSize(overview.audioInCloudBytes))
        }
        return preview.bytes > 0
            ? Copy.Settings.Storage.wouldMove(
                size: Formatting.storageSize(preview.bytes), percent: preview.percent)
            : Copy.Settings.Storage.wouldMoveNothing
    }

    @ViewBuilder
    private func bringBackRow(_ overview: StorageOverview) -> some View {
        if let restoring = overview.restoring {
            HStack(spacing: 10) {
                ProgressView(value: Double(restoring.done), total: Double(max(restoring.total, 1)))
                    .tint(Tokens.tint)
                Text(Copy.Settings.Storage.bringingBack(done: restoring.done, total: restoring.total))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
                    .lineLimit(1)
                    .fixedSize()
            }
        } else {
            TintActionRow(
                title: Copy.Settings.Storage.bringBack(Formatting.storageSize(overview.audioInCloudBytes))
            ) {
                storage.bringEverythingBack()
            }
        }
    }

    // MARK: Export

    @ViewBuilder
    private var exportAccessory: some View {
        switch exportState {
        case .idle:
            EmptyView()
        case .exporting:
            ProgressView().controlSize(.small)
        case .done(let count):
            Text(Copy.Settings.Storage.exported(count))
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.good)
        }
    }

    /// B10: shows progress and ends in a result line, never fire-and-forget. The count is
    /// what was actually written, not what we hoped to write.
    private func exportAll() {
        guard exportState != .exporting else { return }
        exportState = .exporting
        Task {
            let written = await storage.exportAllAudio()
            exportState = .done(written)
        }
    }
}

#Preview("Storage") {
    NavigationStack {
        SettingsStorageScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
