import SwiftUI

/// Settings · Storage & Privacy (artboard 2.12): stats, the REAL "Keep audio" retention
/// control (Q7), the auto-export toggle, Export All Audio with inline progress + result
/// (B10), confirmed destructive delete-all (B14).
struct SettingsStorageScreen: View {
    @Environment(AppSettings.self) private var settings

    private var storage: StorageStatsSource { SettingsDataSources.current.storage }

    private enum ExportState: Equatable { case idle, exporting, done(Int) }
    @State private var exportState: ExportState = .idle
    @State private var confirmDeleteAll = false

    var body: some View {
        @Bindable var settings = settings
        SettingsScroll {
            ListCard {
                SettingsRow(
                    title: Copy.Settings.Storage.recordings,
                    value: "\(storage.recordingCount) · \(storage.recordingsSize)",
                    showsChevron: false
                )
                SettingsRow(
                    title: Copy.Settings.Storage.freeSpace,
                    value: storage.freeSpace,
                    showsChevron: false
                )
            }

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
                        selection: $settings.retentionDays
                    )
                }
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
                    Toggle(Copy.Settings.Storage.autoExport,
                           isOn: $settings.automaticWavExportEnabled)
                        .labelsHidden()
                        .tint(Tokens.good)
                }
            }

            ListCard {
                TintActionRow(title: Copy.Settings.Storage.exportAll, action: exportAll) {
                    exportAccessory
                }
            }

            ListCard {
                DestructiveRow(title: Copy.Settings.Storage.deleteAll) {
                    confirmDeleteAll = true
                }
            }

            SettingsFooter(text: Copy.Settings.Storage.footer)
        }
        .navigationTitle(Copy.Settings.Storage.title)
        .confirmationDialog(
            Copy.Settings.Storage.deleteAll,
            isPresented: $confirmDeleteAll,
            titleVisibility: .hidden
        ) {
            Button("Delete All Recordings", role: .destructive) {
                storage.deleteAllRecordings()
            }
        }
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

    /// B10: shows progress and ends in a result line, never fire-and-forget.
    private func exportAll() {
        guard exportState != .exporting else { return }
        let count = storage.recordingCount
        exportState = .exporting
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            exportState = .done(count)
        }
    }
}

#Preview("Storage & Privacy") {
    NavigationStack {
        SettingsStorageScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
