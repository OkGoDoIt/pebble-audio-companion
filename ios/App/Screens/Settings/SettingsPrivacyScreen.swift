import SearchKit
import StatusUI
import SwiftUI

/// Settings · Privacy: where audio and text go under the current modes, the one privacy
/// control (what the system search index may see), and the standing commitments.
///
/// This used to share a screen with Storage. The two answer different questions — "where does
/// my data go?" and "how much room is it taking?" — and the storage half has grown an iCloud
/// rule and an overview of its own, so each gets a screen that fits on one screenful.
struct SettingsPrivacyScreen: View {
    @Environment(AppSettings.self) private var settings

    /// Derived fresh on every read from the observed modes — never cached, so a mode changed on
    /// the Transcription & AI screen is reflected here the moment this screen redraws.
    private var stance: Copy.Privacy.Stance { settings.privacyStance }

    /// What the pipeline is doing right now, as against what the configuration allows: the
    /// present-tense half of the stance. Empty whenever the chosen path is working.
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

            if let deletionNote = stance.deletionNote {
                SettingsFooter(text: deletionNote)
            }

            SettingsSectionHeader(title: Copy.Settings.Storage.privacySection)
            commitmentsCard
            SettingsFooter(text: Copy.Settings.Storage.footer)
        }
        .navigationTitle(Copy.Settings.Privacy.title)
    }

    /// The live half: what THIS configuration does with audio and with text. The dot is `good`
    /// when nothing leaves and neutral otherwise — never `attention`: cloud transcription is a
    /// choice the user made on purpose, not a warning.
    private var stanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
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
                ForEach(fallbackNotices) { notice in
                    Text(notice.text)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.label)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
}

#Preview("Privacy") {
    NavigationStack {
        SettingsPrivacyScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
