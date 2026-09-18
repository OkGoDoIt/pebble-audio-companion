import SearchKit
import StatusUI
import SwiftUI

/// Settings · Storage & Privacy (artboard 2.12): the privacy stance for the current modes,
/// stats, the REAL "Keep audio" retention control (Q7), the auto-export toggle, Export All
/// Audio with inline progress + result (B10), confirmed destructive delete-all (B14).
///
/// The screen is titled "Storage & Privacy" and, until now, carried no privacy content at all:
/// the only statement anywhere was the one-line footer on the Settings root. The stance is split
/// deliberately. The half that DEPENDS ON THE CONFIGURATION leads the screen, because that is
/// the answer someone opening "the privacy page" came for and it changes under them. The half
/// that never changes sits at the foot with the legal footnote, where standing policy belongs
/// and where it cannot push the storage controls off the first screenful.
struct SettingsStorageScreen: View {
    @Environment(AppSettings.self) private var settings

    private var storage: StorageStatsSource { SettingsDataSources.current.storage }

    private enum ExportState: Equatable { case idle, exporting, done(Int) }
    @State private var exportState: ExportState = .idle
    @State private var confirmDeleteAll = false

    /// Derived fresh on every read from the observed modes — never cached, so a mode changed on
    /// the Transcription & AI screen is reflected here the moment this screen redraws.
    private var stance: Copy.Privacy.Stance { settings.privacyStance }

    /// What the pipeline is doing right now, as against what the configuration allows: the
    /// present-tense half of the stance. Empty whenever the chosen path is working, which is the
    /// normal case — see `Copy+ProcessingFallback.swift` for why this line lives here.
    private var fallbackNotices: [Copy.Privacy.FallbackNotice] {
        Copy.Privacy.FallbackNotice.current(settings, SettingsDataSources.current.processing)
    }

    var body: some View {
        @Bindable var settings = settings
        SettingsScroll {
            stanceCard

            // The one privacy control: what the system's search index is given. Directly
            // under the stance because it is the same question — where does the text go —
            // with an answer the person sets rather than reads.
            ListCard {
                SettingsPushRow(
                    title: Copy.Settings.Storage.systemSearch,
                    value: Copy.Settings.Storage.systemSearchLabel(settings.systemSearchVisibility)
                ) {
                    ChoiceScreen(
                        title: Copy.Settings.Storage.systemSearch,
                        options: SystemSearchVisibility.allCases.reversed().map {
                            .init(value: $0, label: Copy.Settings.Storage.systemSearchLabel($0))
                        },
                        selection: $settings.systemSearchVisibility,
                        footer: Copy.Settings.Storage.systemSearchChoiceFooter
                    )
                }
            }
            SettingsFooter(text: Copy.Settings.Storage.systemSearchFooter)

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
                // report, and a bare size is already the Recordings row above.
                if settings.retentionMaxBytes > 0 {
                    SettingsRow(
                        title: Copy.Settings.Storage.usedOfLimit(
                            used: Formatting.storageSize(storage.recordingsBytes),
                            limit: AppSettings.retentionLimitLabel(settings.retentionMaxBytes)
                        ),
                        showsChevron: false
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
            // Sits under the two controls it describes, not with the legal note at the foot.
            SettingsFooter(text: Copy.Settings.Storage.limitFooter)

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
            // Anchored to the card that raises it. Attached to `SettingsScroll` the source rect
            // is the whole screen, and iOS 26 places the panel against the top of it — far from
            // the row that was tapped. Same fix as `SettingsWatchScreen`.
            .confirmationDialog(
                Copy.Settings.Storage.deleteAllTitle,
                isPresented: $confirmDeleteAll,
                titleVisibility: .visible
            ) {
                Button(Copy.Settings.Storage.deleteAllConfirm, role: .destructive) {
                    Haptics.destructiveConfirmed()
                    storage.deleteAllRecordings()
                }
            } message: {
                Text(Copy.Settings.Storage.deleteAllMessage)
            }
            // Sits with the button it qualifies. Deleting here is complete on this phone and
            // reaches nothing a provider has already been sent — that is a fact about THIS
            // control, so it belongs under it rather than in the policy block below.
            if let deletionNote = stance.deletionNote {
                SettingsFooter(text: deletionNote)
            }

            SettingsSectionHeader(title: Copy.Settings.Storage.privacySection)
            commitmentsCard
            SettingsFooter(text: Copy.Settings.Storage.footer)
        }
        .navigationTitle(Copy.Settings.Storage.title)
        // The byte sweep only runs while this screen is being looked at; see
        // `LiveStorageStatsSource.setVisible`.
        .onAppear { storage.setVisible(true) }
        .onDisappear { storage.setVisible(false) }
    }

    // MARK: Privacy

    /// The live half: what THIS configuration does with audio and with text.
    ///
    /// The dot is `good` when nothing leaves and neutral otherwise — never `attention`. Cloud
    /// transcription is a choice the user made on purpose, and colouring it as a warning would
    /// be the scare-mongering this copy is written against. The dot marks "nothing leaves", it
    /// does not grade the configuration.
    private var stanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                // Same dot + headline pairing `StatusCard` uses, one size down: this is a
                // settings card, not a status card.
                HStack(spacing: 8) {
                    StatusDot(
                        color: stance.isFullyLocal ? Tokens.good : Tokens.neutralDot,
                        size: .lifecycle
                    )
                    Text(stance.headline)
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(stance.summary)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.secondaryBody)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(stance.qualifiers, id: \.self) { qualifier in
                    Text(qualifier)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The present tense, directly under the conditional it completes. The qualifier
                // above says a "first" mode CAN use the other path; this says it IS, and why.
                // Absent whenever the chosen path is working, so there is nothing standing here
                // to be ignored — and `label`, not `meta`, because unlike the qualifier this is
                // a statement about right now that someone might want to act on.
                ForEach(fallbackNotices) { notice in
                    Text(notice.text)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.label)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // One element: VoiceOver should read the stance as the single statement it is, not as
        // four fragments a swipe apart.
        .accessibilityElement(children: .combine)
    }

    /// The fixed half. `ListCard` gives each line its own row and hairline, which is what keeps
    /// four sentences from reading as a paragraph of legal text (UX plan §17: no wall of it).
    private var commitmentsCard: some View {
        ListCard {
            ForEach(stance.commitments, id: \.self) { commitment in
                Text(commitment)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.secondaryBody)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

#Preview("Storage & Privacy") {
    NavigationStack {
        SettingsStorageScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
