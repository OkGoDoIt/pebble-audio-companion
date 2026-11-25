import CompanionRuntime
import StatusUI
import SwiftUI

/// Settings · Storage.
///
/// The questions a person brings here, one section each, in the order they are asked:
///
///  1. **How much room is this taking, and of what?** One number, one bar, a legend.
///  2. **How long are recordings kept?** The two rules that delete, in one card, and under it
///     one line for what they add up to. A choice that would delete something already here says
///     how much, beside the choice, before it is tapped.
///  3. **Can I keep everything and still have room?** One row: older audio moves to iCloud, after
///     an age or not at all. The picker says what each age would move. The phone/iCloud split is
///     drawn only once there is one.
///  4. **Can I have the files?** Export, and what it would take.
///
/// Delete All stays last, in its own card. Privacy has its own screen
/// (`SettingsPrivacyScreen`): "where does my data go?" is a different question.
struct SettingsStorageScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dynamicTypeSize) private var typeSize

    private var storage: StorageStatsSource { SettingsDataSources.current.storage }

    private enum ExportState: Equatable { case idle, exporting, done(Int) }
    @State private var exportState: ExportState = .idle
    @State private var confirmDeleteAll = false

    var body: some View {
        SettingsScroll {
            overviewCard

            SettingsSectionHeader(title: Copy.Settings.Storage.recordingsSection)
            recordingsCard
            SettingsFooter(
                text: Copy.Settings.Storage.deletingLine(
                    keepDays: settings.retentionDays, limitBytes: settings.retentionMaxBytes,
                    cloud: settings.coldStorageEnabled
                        || (storage.overview?.audioInCloudBytes ?? 0) > 0))

            SettingsSectionHeader(title: Copy.Settings.Storage.cloudSection)
            cloudCard
            SettingsFooter(text: Copy.Settings.Storage.cloudFooter)

            SettingsSectionHeader(title: Copy.Settings.Storage.exportSection)
            exportCard

            ListCard {
                DestructiveRow(title: Copy.Settings.Storage.deleteAll) {
                    confirmDeleteAll = true
                }
            }
            .padding(.top, Tokens.blockGap)
            .confirmationDialog(
                Copy.Settings.Storage.deleteAllTitle,
                isPresented: $confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button(Copy.Settings.Storage.deleteAllConfirm, role: .destructive) {
                    storage.deleteAllRecordings()
                }
            } message: {
                Text(Copy.Settings.Storage.deleteAllMessage(serverHost: SettingsDataSources.current.assistants.deleteAllHost))
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
                        if overview.exportBytes >= Self.worthNaming {
                            StorageLegendRow(
                                color: Tokens.captured, title: Copy.Settings.Storage.legendExports,
                                value: Formatting.storageSize(overview.exportBytes))
                        }
                        if overview.temporaryBytes >= Self.worthNaming {
                            StorageLegendRow(
                                color: Tokens.quiet, hatched: true,
                                title: Copy.Settings.Storage.legendTemporary,
                                value: Formatting.storageSize(overview.temporaryBytes),
                                note: Copy.Settings.Storage.temporaryCleaned)
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

    /// Below this, exports and temporary files are a few megabytes and not a story.
    private static let worthNaming: Int64 = 50 * 1024 * 1024

    private func overviewParts(_ overview: StorageOverview) -> [StorageBar.Part] {
        var parts: [StorageBar.Part] = [
            .init(id: "audio", bytes: overview.audioOnPhoneBytes, color: Tokens.tint),
            .init(id: "text", bytes: overview.textBytes, color: Tokens.tintSoft),
            .init(id: "model", bytes: overview.modelBytes, color: Tokens.quiet),
        ]
        if overview.exportBytes >= Self.worthNaming {
            parts.append(.init(id: "exports", bytes: overview.exportBytes, color: Tokens.captured))
        }
        if overview.temporaryBytes >= Self.worthNaming {
            parts.append(.init(id: "tmp", bytes: overview.temporaryBytes, color: Tokens.quiet, hatched: true))
        }
        return parts
    }

    // MARK: Recordings

    private var recordingsCard: some View {
        @Bindable var settings = settings
        let limit = settings.retentionMaxBytes
        return ListCard {
            SettingsPushRow(
                title: Copy.Settings.Storage.keep,
                value: Copy.Settings.Storage.keepLabel(settings.retentionDays)
            ) {
                ChoiceScreen(
                    title: Copy.Settings.Storage.keep,
                    options: AppSettings.retentionOptions.map(keepOption),
                    selection: $settings.retentionDays)
            }
            SettingsPushRow(
                title: Copy.Settings.Storage.storageLimit,
                value: AppSettings.retentionLimitLabel(limit)
            ) {
                ChoiceScreen(
                    title: Copy.Settings.Storage.storageLimit,
                    options: AppSettings.retentionLimitOptions.map(limitOption),
                    selection: $settings.retentionMaxBytes)
            }
            // Only once a limit exists: without one there is no proportion to draw.
            if limit > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    StorageBar(
                        parts: [
                            .init(
                                id: "used", bytes: min(storage.recordingsBytes, limit),
                                color: Tokens.tint)
                        ],
                        total: limit, height: 8)
                    Text(
                        Copy.Settings.Storage.usedOfLimit(
                            used: Formatting.storageSize(storage.recordingsBytes),
                            limit: AppSettings.retentionLimitLabel(limit)))
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Deleting starts on the next pass after the tap, so what a shorter choice would delete is
    /// beside it, not on the far side of it.
    private func keepOption(_ days: Int) -> ChoiceScreen<Int>.Option {
        let count = days < settings.retentionDays ? storage.wouldDelete(olderThanDays: days) : 0
        return .init(
            value: days, label: Copy.Settings.Storage.keepLabel(days),
            consequence: count > 0 ? Copy.Settings.Storage.deletesCount(count) : nil,
            destroys: true)
    }

    private func limitOption(_ bytes: Int64) -> ChoiceScreen<Int64>.Option {
        let over = bytes > 0 && bytes != settings.retentionMaxBytes
            ? storage.recordingsBytes - bytes : 0
        return .init(
            value: bytes, label: AppSettings.retentionLimitLabel(bytes),
            consequence: over > 0
                ? Copy.Settings.Storage.deletesSize(Formatting.storageSize(over)) : nil,
            destroys: true)
    }

    // MARK: iCloud

    /// The shortest Keep recordings under which some offered move age can take effect.
    private static let minimumKeepDaysForCloud: Int = {
        let youngestAge = AppSettings.coldStorageAgeOptions.min() ?? 0
        return AppSettings.retentionOptions.first { $0 > youngestAge } ?? youngestAge + 1
    }()

    /// One row, "off" among its choices, and what has moved so far.
    ///
    /// The age shown is the EFFECTIVE one (`effectiveColdStorageMinAgeDays`): Keep recordings
    /// deletes first, so a move age at or past it is a rule that never fires. Under the defaults
    /// (move at 2 months, keep 1 month) the screen once showed "2 months" and a switch that,
    /// turned on, moved nothing, ever.
    private var cloudCard: some View {
        let overview = storage.overview
        let available = overview?.cloudAvailable ?? false
        let effectiveAge = settings.effectiveColdStorageMinAgeDays
        let on = settings.coldStorageEnabled
        // A rule that could move nothing is not offered, but one already on can be turned off.
        let canChoose = (available && effectiveAge != nil) || on
        let value = on ? effectiveAge.map(Copy.Settings.Storage.cloudAfter) : nil
        return ListCard {
            if canChoose {
                SettingsPushRow(
                    title: Copy.Settings.Storage.cloudMove,
                    value: value ?? Copy.Settings.Storage.cloudOff,
                    subtitle: cloudSubtitle
                ) {
                    cloudChoices
                }
            } else {
                SettingsRow(
                    title: Copy.Settings.Storage.cloudMove, value: Copy.Settings.Storage.cloudOff,
                    subtitle: available ? cloudSubtitle : nil, showsChevron: false)
            }
            if overview != nil, !available {
                note(Copy.Settings.Storage.cloudUnavailable)
            }
            if on, let effectiveAge, effectiveAge != settings.coldStorageMinAgeDays {
                note(
                    Copy.Settings.Storage.cloudAgeShortened(
                        effectiveDays: effectiveAge, chosenDays: settings.coldStorageMinAgeDays,
                        keepDays: settings.retentionDays))
            }
            if let overview, overview.audioInCloudBytes + overview.uploadingBytes > 0 {
                splitRow(overview)
            }
            if let error = overview?.cloudError, available {
                note(Copy.Settings.Storage.cloudError(error))
            }
            if let overview, available, !on, overview.audioInCloudBytes > 0 {
                bringBackRow(overview)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(AppFont.footnote)
            .foregroundStyle(Tokens.secondaryBody)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cloudSubtitle: String? {
        guard settings.effectiveColdStorageMinAgeDays != nil else {
            return Copy.Settings.Storage.cloudNeedsLongerKeep(
                minimumKeepDays: Self.minimumKeepDaysForCloud)
        }
        guard !settings.coldStorageEnabled, let youngest = settings.coldStorageAgeChoices.min()
        else { return nil }
        let bytes = storage.wouldMove(olderThanDays: youngest).bytes
        return bytes > 0
            ? Copy.Settings.Storage.cloudCouldFree(Formatting.storageSize(bytes)) : nil
    }

    /// 0 is "Off". A pick of an age turns the rule on at it.
    private var cloudChoices: some View {
        let ages = settings.coldStorageAgeChoices
        return ChoiceScreen(
            title: Copy.Settings.Storage.cloudMove,
            options: [.init(value: 0, label: Copy.Settings.Storage.cloudOff)]
                + ages.map { days in
                    let bytes = storage.wouldMove(olderThanDays: days).bytes
                    return .init(
                        value: days, label: Copy.Settings.Storage.cloudAfter(days),
                        consequence: bytes > 0
                            ? Copy.Settings.Storage.moves(Formatting.storageSize(bytes)) : nil)
                },
            selection: Binding(
                get: {
                    settings.coldStorageEnabled ? settings.effectiveColdStorageMinAgeDays ?? 0 : 0
                },
                set: { days in
                    if days > 0 { settings.coldStorageMinAgeDays = days }
                    settings.coldStorageEnabled = days > 0
                }),
            footer: ages.count < AppSettings.coldStorageAgeOptions.count
                ? Copy.Settings.Storage.cloudAgesLimited(keepDays: settings.retentionDays) : nil)
    }

    /// Every recording's audio, divided between this phone and iCloud. What is uploading is
    /// still on the phone, hatched.
    private func splitRow(_ overview: StorageOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StorageBar(
                parts: [
                    .init(
                        id: "phone", bytes: overview.audioOnPhoneBytes - overview.uploadingBytes,
                        color: Tokens.tint),
                    .init(
                        id: "moving", bytes: overview.uploadingBytes, color: Tokens.captured,
                        hatched: true),
                    .init(id: "cloud", bytes: overview.audioInCloudBytes, color: Tokens.captured),
                ],
                total: max(overview.audioBytes, 1),
                height: 8)
            // Two legends side by side, each on its own half, so neither can push the card
            // past the screen margin whatever the numbers are.
            let legends = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))
            legends {
                StorageLegendRow(
                    color: Tokens.tint, title: Copy.Settings.Storage.barOnPhone,
                    value: Formatting.storageSize(overview.audioOnPhoneBytes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                StorageLegendRow(
                    color: Tokens.captured, title: Copy.Settings.Storage.barCloud,
                    value: Formatting.storageSize(overview.audioInCloudBytes))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if overview.uploadingBytes > 0 {
                Text(Copy.Settings.Storage.uploading(Formatting.storageSize(overview.uploadingBytes)))
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.meta)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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

    /// A WAV is about 16 times the stored recording, so what it would take is said before it is
    /// started, and one the phone has no room for is not started: filling the phone pauses
    /// recording.
    private var exportCard: some View {
        @Bindable var settings = settings
        let overview = storage.overview
        let fits = overview?.exportFits ?? true
        return ListCard {
            TintActionRow(
                title: Copy.Settings.Storage.exportAll,
                subtitle: overview.map { exportSubtitle($0, fits: fits) },
                action: exportAll
            ) {
                exportAccessory
            }
            .disabled(!fits)
            .opacity(fits ? 1 : 0.5)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Copy.Settings.Storage.autoExport)
                        .font(AppFont.callout)
                        .foregroundStyle(Tokens.label)
                    Text(Copy.Settings.Storage.autoExportSub)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Toggle(Copy.Settings.Storage.autoExport, isOn: $settings.automaticWavExportEnabled)
                    .labelsHidden()
                    .tint(Tokens.good)
                    .disabled(!fits && !settings.automaticWavExportEnabled)
            }
        }
    }

    private func exportSubtitle(_ overview: StorageOverview, fits: Bool) -> String {
        let size = Formatting.storageSize(overview.exportAllBytes)
        return fits
            ? Copy.Settings.Storage.exportAllSub(size) : Copy.Settings.Storage.exportNeeds(size)
    }

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
