import Intelligence
import SwiftUI
import UIKit

/// Settings · About You · Contacts / Calendar — where the chevrons finally go (AY).
///
/// Both rows on About You had a chevron and no destination, so the only control over either
/// source was the screen's "Clear Imported Context", which removed BOTH and everything else in
/// the context with them. This screen is the missing middle: switch one source off, narrow what
/// it reads, and see whether it is still working.
///
/// Three rules it is built to:
///
/// - **The switch is the only thing that can ask for permission.** Nothing else on this
///   screen — not opening it, not the picker, not Update Now — can raise a system prompt.
///   Listing the groups requires access we already have; without it the list is empty and the
///   screen says why instead of showing a control that does nothing.
/// - **Off means removed.** Turning a source off takes its names or titles back out of the
///   personal context immediately. A switch that says "off" over data still going into every
///   prompt would be the same lie the old Clear-only screen told by omission.
/// - **One line of status.** When it last worked, or what is wrong — never a running commentary
///   on an import that is behaving.
struct SettingsAboutYouSourceScreen: View {
    let kind: ContextImportKind

    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL

    private var source: AboutYouSource { SettingsDataSources.current.aboutYou }
    private var state: ImportSourceState { source.state(for: kind) }
    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    @State private var choices: [ImportChoice] = []

    var body: some View {
        SettingsScroll {
            ListCard {
                HStack(spacing: 12) {
                    Text(Copy.Settings.AboutYou.importFrom(name))
                        .font(AppFont.callout)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 10)
                    Toggle(Copy.Settings.AboutYou.importFrom(name), isOn: enabledBinding)
                        .labelsHidden()
                        .tint(Tokens.good)
                }
            }
            SettingsFooter(text: purposeAndDestination)

            if state.isEnabled {
                switch state.access {
                case .granted:
                    picker
                    if kind == .calendar { window }
                case .limited:
                    SettingsFooter(text: Copy.Settings.AboutYou.contactsLimited)
                case .denied, .notDetermined:
                    EmptyView()
                }

                ListCard {
                    if state.access == .denied {
                        TintActionRow(title: Copy.Settings.AboutYou.openIosSettings) {
                            openIosSettings()
                        }
                    } else {
                        TintActionRow(
                            title: Copy.Settings.AboutYou.updateNow,
                            action: { source.refresh(kind) }
                        ) {
                            if state.isRefreshing { ProgressView().controlSize(.small) }
                        }
                    }
                }
                if let status = Copy.Settings.AboutYou.sourceStatusLine(state, nowMs: nowMs) {
                    SettingsFooter(text: status)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        // Re-listed whenever the source is switched on or its access changes — and never
        // otherwise, so an import finishing does not re-query Contacts for its group list.
        .task(id: choicesToken) {
            choices = await source.choices(for: kind)
        }
    }

    private var name: String { Copy.Settings.AboutYou.sourceName(kind) }

    /// What this source contributes, and where that text ends up — the second half derived from
    /// the same modes as the privacy stance, so turning cloud AI off removes the sentence
    /// rather than leaving a stale claim.
    private var purposeAndDestination: String {
        [
            Copy.Settings.AboutYou.sourcePurpose(kind),
            Copy.Settings.AboutYou.sourceDestination(
                kind, destinations: settings.cloudDestinations),
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { state.isEnabled },
            set: { source.setEnabled($0, for: kind) }
        )
    }

    private var choicesToken: String { "\(state.isEnabled)-\(state.access)" }

    // MARK: What to import from

    @ViewBuilder
    private var picker: some View {
        if choices.isEmpty {
            SettingsFooter(text: Copy.Settings.AboutYou.nothingToPick)
        } else {
            ListCard {
                SelectRow(
                    title: kind == .contacts
                        ? Copy.Settings.AboutYou.allContacts
                        : Copy.Settings.AboutYou.allCalendars,
                    detail: nil,
                    isSelected: state.selection == .all
                ) {
                    source.setSelection(.all, for: kind)
                }
            }
            section(.account, header: Copy.Settings.AboutYou.accountsSection)
            section(.group, header: Copy.Settings.AboutYou.groupsSection)
            section(.calendar, header: Copy.Settings.AboutYou.calendarsSection)
        }
    }

    @ViewBuilder
    private func section(_ kindOfChoice: ImportChoiceSection, header: String) -> some View {
        let rows = choices.filter { $0.section == kindOfChoice }
        if !rows.isEmpty {
            SettingsSectionHeader(title: header)
            ListCard {
                ForEach(rows) { choice in
                    SelectRow(
                        title: choice.name,
                        detail: choice.detail,
                        isSelected: state.selection.includes(choice.id)
                    ) {
                        source.setSelection(
                            state.selection.toggling(choice.id, available: choices.map(\.id)),
                            for: kind
                        )
                    }
                }
            }
        }
    }

    // MARK: How far the calendar reaches

    /// Two rows rather than one "range": people think about "how far back" and "how far ahead"
    /// separately, and someone who wants last month but not next year can say so.
    @ViewBuilder
    private var window: some View {
        SettingsSectionHeader(title: Copy.Settings.AboutYou.rangeSection)
        ListCard {
            SettingsPushRow(
                title: Copy.Settings.AboutYou.pastRow,
                value: Copy.Settings.AboutYou.days(state.pastDays)
            ) {
                ChoiceScreen(
                    title: Copy.Settings.AboutYou.pastRow,
                    options: Self.pastOptions,
                    selection: Binding(
                        get: { state.pastDays },
                        set: {
                            source.setCalendarWindow(
                                pastDays: $0, futureDays: state.futureDays)
                        }
                    )
                )
            }
            SettingsPushRow(
                title: Copy.Settings.AboutYou.aheadRow,
                value: Copy.Settings.AboutYou.days(state.futureDays)
            ) {
                ChoiceScreen(
                    title: Copy.Settings.AboutYou.aheadRow,
                    options: Self.aheadOptions,
                    selection: Binding(
                        get: { state.futureDays },
                        set: {
                            source.setCalendarWindow(
                                pastDays: state.pastDays, futureDays: $0)
                        }
                    )
                )
            }
        }
    }

    private static let pastOptions: [ChoiceScreen<Int>.Option] = [0, 7, 30, 90, 365].map {
        ChoiceScreen<Int>.Option(value: $0, label: Copy.Settings.AboutYou.days($0))
    }
    private static let aheadOptions: [ChoiceScreen<Int>.Option] = [7, 30, 90, 365].map {
        ChoiceScreen<Int>.Option(value: $0, label: Copy.Settings.AboutYou.days($0))
    }

    private func openIosSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

/// A multi-select row: the same checkmark `ChoiceScreen` uses, but several can be ticked.
private struct SelectRow: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppFont.callout)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                    }
                }
                Spacer(minLength: 10)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Contacts") {
    NavigationStack {
        SettingsAboutYouSourceScreen(kind: .contacts)
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}

#Preview("Calendar") {
    NavigationStack {
        SettingsAboutYouSourceScreen(kind: .calendar)
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
