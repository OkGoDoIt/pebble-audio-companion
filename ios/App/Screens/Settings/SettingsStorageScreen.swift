import CompanionRuntime
import SegmentStore
import StatusUI
import SwiftUI

/// Settings · Storage.
///
/// The questions a person brings here, one section each, in the order they are asked:
///
///  1. **How much room is this taking, and of what?** One number, one bar, a legend.
///  2. **What happens to them as they get older, or as room runs out?** One path with two
///     optional stops, iCloud and deleted (`StoragePath`), each saying when it is reached. A
///     stop's own screen sets it, and says beside every choice what that choice would move or
///     delete.
///  3. **Can I have the files?** Export, and what it would take.
///
/// Delete All stays last, in its own card. Privacy has its own screen
/// (`SettingsPrivacyScreen`): "where does my data go?" is a different question.
struct SettingsStorageScreen: View {
    @Environment(AppSettings.self) private var settings

    private var storage: StorageStatsSource { SettingsDataSources.current.storage }

    private enum ExportState: Equatable { case idle, exporting, done(Int) }
    @State private var exportState: ExportState = .idle
    @State private var confirmDeleteAll = false

    var body: some View {
        SettingsScroll {
            overviewCard

            SettingsSectionHeader(title: Copy.Settings.Storage.pathSection)
            StoragePathCard(path: path) {
                SettingsStorageStopScreen(stop: .cloud)
            } deleteDestination: {
                SettingsStorageStopScreen(stop: .deleted)
            }
            SettingsFooter(text: path.footer)

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
            if let overview = storage.overview, overview.isMeasured {
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
                        if let warning = spaceWarning(overview) {
                            Text(warning)
                                .font(AppFont.footnote)
                                .foregroundStyle(Tokens.attention)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
                                color: Tokens.neutralDot, title: Copy.Settings.Storage.legendExports,
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

    /// The phone itself is nearly full: what that does to recording, before or as it does it.
    private func spaceWarning(_ overview: StorageOverview) -> String? {
        let floor = AppSettings.retentionLimitLabel(RetentionConfig.defaultPauseFloorBytes)
        if overview.freeBytes < RetentionConfig.defaultPauseFloorBytes {
            return Copy.Settings.Storage.pausedForSpace(pauseFloor: floor)
        }
        return overview.freeBytes < RetentionConfig.defaultLowStorageFloorBytes
            ? Copy.Settings.Storage.lowSpace(pauseFloor: floor) : nil
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
            parts.append(.init(id: "exports", bytes: overview.exportBytes, color: Tokens.neutralDot))
        }
        if overview.temporaryBytes >= Self.worthNaming {
            parts.append(.init(id: "tmp", bytes: overview.temporaryBytes, color: Tokens.quiet, hatched: true))
        }
        return parts
    }

    // MARK: The path

    private var path: StoragePath {
        let rule = settings.cloudRule
        return StoragePath(
            .init(
                retentionDays: settings.retentionDays,
                retentionMaxBytes: settings.retentionMaxBytes,
                cloudEnabled: settings.coldStorageEnabled,
                cloudChosenDays: settings.coldStorageMinAgeDays,
                cloudRule: rule,
                toMoveBytes: rule.map {
                    storage.wouldMove(ageDays: $0.ageDays, maxBytes: $0.maxBytes).bytes
                } ?? 0,
                overview: storage.overview))
    }

    // MARK: Export

    /// A WAV is about 16 times the stored recording, so what it would take is said before it is
    /// started, and one the phone has no room for is not started: filling the phone pauses
    /// recording.
    private var exportCard: some View {
        @Bindable var settings = settings
        let overview = storage.overview
        let fits = overview?.exportFits ?? true
        let canExport = fits && (overview?.exportAllBytes ?? 1) > 0
        return ListCard {
            TintActionRow(
                title: (overview?.audioInCloudBytes ?? 0) > 0
                    ? Copy.Settings.Storage.exportOnPhone : Copy.Settings.Storage.exportAll,
                subtitle: overview.map { exportSubtitle($0, fits: fits) },
                action: exportAll
            ) {
                exportAccessory
            }
            .disabled(!canExport)
            .opacity(canExport ? 1 : 0.5)
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
        guard overview.exportAllBytes > 0 else { return Copy.Settings.Storage.nothingToExport }
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
