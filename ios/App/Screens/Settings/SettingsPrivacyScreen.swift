import SearchKit
import SwiftUI

/// Settings · Privacy (round 3: 09a–09e), derived in full from `PrivacyInputs`
/// (`PrivacyModel`, `docs/privacy-model.md`): the stance (a heading, one line, and the flow from
/// This iPhone to every place it sends to, with the assistants hanging off the server), then
/// where it goes, who can read the archive, what Siri and Spotlight can see, and the commitments.
/// Nothing on this screen is written by hand per state, so it cannot disagree with the setup
/// screens or Delete All.
struct SettingsPrivacyScreen: View {
    @Environment(AppSettings.self) private var settings

    private var assistants: AssistantsSource { SettingsDataSources.current.assistants }

    private var presentation: PrivacyPresentation {
        PrivacyModel.derive(PrivacyModel.inputs(settings), nowMs: assistants.nowMs)
    }

    /// What the pipeline is doing right now, as against what the configuration allows: the
    /// present-tense half. Empty whenever the chosen path is working.
    private var fallbackNotices: [Copy.Privacy.FallbackNotice] {
        Copy.Privacy.FallbackNotice.current(settings, SettingsDataSources.current.processing)
    }

    var body: some View {
        @Bindable var settings = settings
        let presentation = self.presentation
        AssistantScroll {
            stanceCard(presentation)

            if presentation.hasFlow {
                AssistantSectionHeader(title: Copy.Settings.Privacy.whereItGoes)
                AssistantList {
                    ForEach(presentation.destinations) { destination in
                        destinationRow(destination)
                    }
                }
                ForEach(presentation.whereItGoesFooters, id: \.self) { AssistantFooter(text: $0) }
                ForEach(fallbackNotices) { notice in
                    AssistantFooter(text: notice.text, color: Tokens.label)
                }
            }

            if let rows = presentation.whoCanRead {
                AssistantSectionHeader(title: Copy.Settings.Privacy.whoCanRead)
                AssistantList {
                    if rows.isEmpty {
                        Text(Copy.Settings.Privacy.noAssistant)
                            .font(AppFont.callout)
                            .foregroundStyle(Tokens.tertiary)
                        NavigationLink {
                            AssistantsConnectScreen(inSetup: false)
                        } label: {
                            tintRow(Copy.Settings.Privacy.connect)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(rows, id: \.self) { row in
                            NavigationLink(value: Route.settings(.server)) { assistantRow(row) }
                                .buttonStyle(.plain)
                        }
                        NavigationLink(value: Route.settings(.server)) {
                            tintRow(Copy.Settings.Privacy.manage)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let footer = presentation.whoCanReadFooter { AssistantFooter(text: footer) }
            }

            AssistantList {
                NavigationLink {
                    ChoiceScreen(
                        title: Copy.Settings.Storage.systemSearch,
                        options: SystemSearchVisibility.allCases.reversed().map {
                            .init(value: $0, label: Copy.Settings.Storage.systemSearchLabel($0))
                        },
                        selection: $settings.systemSearchVisibility,
                        footer: Copy.Settings.Storage.systemSearchChoiceFooter)
                } label: {
                    AssistantNavRowLabel(
                        title: Copy.Settings.Storage.systemSearch,
                        subtitle: Copy.Settings.Storage.systemSearchLabel(PrivacyModel.inputs(settings).systemSearch))
                }
                .buttonStyle(.plain)
                if presentation.whoCanRead == nil {
                    NavigationLink(value: Route.settings(.server)) {
                        AssistantNavRowLabel(
                            title: Copy.AssistantAccess.rowTitle, subtitle: assistants.rowValue)
                    }
                    .buttonStyle(.plain)
                }
            }

            AssistantSectionHeader(title: Copy.Settings.Privacy.commitmentsSection)
            AssistantList {
                ForEach(presentation.commitments, id: \.self) { commitment in
                    Text(commitment)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.secondaryBody)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                }
            }
            SettingsFooter(text: Copy.Settings.Storage.footer)
        }
        .navigationTitle(Copy.Settings.Privacy.title)
        .navigationBarTitleDisplayMode(.large)
        .onAppear { assistants.startObserving() }
        .onDisappear { assistants.stopObserving() }
    }

    // MARK: The stance

    private func stanceCard(_ presentation: PrivacyPresentation) -> some View {
        AssistantCard {
            AssistantStateHead(
                dot: presentation.dot == .good ? Tokens.good : Tokens.neutralDot,
                heading: presentation.headline, line: presentation.line)
            if presentation.hasFlow {
                PrivacyFlowTree(presentation: presentation)
                    .padding(.top, 14)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func destinationRow(_ destination: PrivacyDestination) -> some View {
        let label = HStack(spacing: 12) {
            destinationTile(destination, size: .list)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.name)
                    .font(AppFont.rowTitle)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(destination.why)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if !destination.chips.isEmpty {
                    ChipFlow(spacing: 6) {
                        ForEach(destination.chips, id: \.self) { AssistantChip(chip: $0) }
                    }
                    .padding(.top, 6)
                }
                if let meta = destination.meta {
                    Text(meta)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if route(destination) != nil || destination.control == .muse && PrivacyHooks.museScreen != nil {
                AssistantChevron()
            }
        }
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)

        if let route = route(destination) {
            NavigationLink(value: route) { label }.buttonStyle(.plain)
        } else if destination.control == .muse, let screen = PrivacyHooks.museScreen {
            NavigationLink { screen() } label: { label }.buttonStyle(.plain)
        } else {
            label
        }
    }

    private func route(_ destination: PrivacyDestination) -> Route? {
        switch destination.control {
        case .transcription: return .settings(.transcription)
        case .storage: return .settings(.storage)
        case .assistants: return .settings(.server)
        case .muse: return nil
        }
    }

    private func assistantRow(_ row: PrivacyAssistantRow) -> some View {
        HStack(spacing: 12) {
            BrandTile(mark: row.mark)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(AppFont.rowTitle)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.lastRead)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ChipFlow(spacing: 6) { AssistantChip(chip: row.chip) }
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AssistantChevron()
        }
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func tintRow(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(AppFont.bodyPlain)
                .foregroundStyle(Tokens.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
            AssistantChevron()
        }
        .contentShape(Rectangle())
    }
}

/// A destination's tile: the vendor's mark, or the app's own server glyph.
@ViewBuilder
func destinationTile(_ destination: PrivacyDestination, size: TileSize) -> some View {
    if let mark = destination.mark {
        BrandTile(mark: mark, size: size)
    } else {
        GlyphTile(systemName: "server.rack", style: .own, size: size)
    }
}

/// Where the Muse feature plugs into the Privacy screen: its state (D7) and its screen. Nil on
/// a build without Muse, which then lists no Meta row.
@MainActor
enum PrivacyHooks {
    static var museState: () -> PrivacyInputs.MuseState? = { nil }
    static var museScreen: (() -> AnyView)?
}

extension PrivacyModel {
    /// The inputs as they stand: the modes and rules from Settings, the server and its
    /// assistants from the sync, and Muse from its feature. A DEBUG review state overrides them.
    @MainActor
    static func inputs(_ settings: AppSettings) -> PrivacyInputs {
        if let demo = AssistantsDemo.privacyInputs { return demo }
        return PrivacyInputs(
            transcriptionDestination: settings.cloudTranscriptionDestination,
            transcriptionFallbackOnly: settings.transcriptionMode == .localFirst,
            aiDestination: settings.remoteAiDestination,
            aiFallbackOnly: settings.aiMode == .localFirst,
            iCloudAgeDays: settings.coldStorageEnabled ? settings.effectiveColdStorageMinAgeDays : nil,
            systemSearch: settings.systemSearchVisibility,
            server: SettingsDataSources.current.assistants.privacyServer,
            museState: PrivacyHooks.museState())
    }
}

#Preview("Privacy") {
    NavigationStack {
        SettingsPrivacyScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
