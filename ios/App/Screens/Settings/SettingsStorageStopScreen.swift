import StatusUI
import SwiftUI

/// Storage · one stop on a recording's path: when it is reached. The same two questions for
/// either stop, how old and how full, and either answer alone is enough. Choosing one does not
/// leave the screen, since the other may be next.
struct SettingsStorageStopScreen: View {
    enum Stop { case cloud, deleted }

    let stop: Stop

    @Environment(AppSettings.self) private var settings
    @State private var pending: Pending?
    private var storage: StorageStatsSource { SettingsDataSources.current.storage }
    private typealias C = Copy.Settings.Storage

    private struct Choice: Identifiable {
        let id: Int64
        let label: String
        var consequence: String? = nil
        var isSelected: Bool
        var isEnabled = true
        let choose: () -> Void
    }

    var body: some View {
        SettingsScroll {
            switch stop {
            case .cloud: cloud
            case .deleted: deleted
            }
        }
        .navigationTitle(stop == .cloud ? C.moveTitle : C.deleteTitle)
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            pending?.deletion.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { pending in
            Button(pending.deletion.confirm, role: .destructive, action: pending.apply)
            Button(Copy.Common.cancel, role: .cancel) {}
        } message: { pending in
            Text(pending.deletion.message)
        }
        // Pushed over Storage, which stops watching when it leaves the screen; the sizes beside
        // the choices are as live here as there.
        .onAppear { storage.setVisible(true) }
        .onDisappear { storage.setVisible(false) }
    }

    @ViewBuilder
    private func section(_ title: String, _ choices: [Choice], destroys: Bool) -> some View {
        SettingsSectionHeader(title: title)
        ListCard {
            ForEach(choices) { choice in
                Button(action: choice.choose) {
                    ChoiceRowLabel(
                        label: choice.label, consequence: choice.consequence, destroys: destroys,
                        isSelected: choice.isSelected)
                }
                .buttonStyle(.plain)
                .disabled(!choice.isEnabled)
                .accessibilityAddTraits(choice.isSelected ? .isSelected : [])
            }
        }
    }

    // MARK: iCloud

    private var cloudReachable: Bool { storage.overview?.cloudAvailable ?? true }

    /// What is chosen, in the pickers' terms: an age (nil is Never) and a limit (0 is none).
    private var cloudAge: Int? { settings.cloudRule?.ageDays }
    private var cloudLimit: Int64 { settings.coldStorageEnabled ? settings.coldStorageMaxBytes : 0 }

    @ViewBuilder
    private var cloud: some View {
        // Why nothing here can be chosen, before the choices.
        if !cloudReachable {
            SettingsFooter(text: C.cloudUnavailable)
        }
        section(C.byAge, cloudAges, destroys: false)
        if settings.coldStorageAgeChoices.count < AppSettings.coldStorageAgeOptions.count {
            SettingsFooter(
                text: C.agesLimited(
                    keepDays: settings.retentionDays, none: settings.coldStorageAgeChoices.isEmpty))
        }
        section(C.byRoom, cloudLimits, destroys: false)
        SettingsFooter(text: C.moveFooter)
        if let overview = storage.overview, overview.cloudAvailable, !settings.coldStorageEnabled,
            overview.audioInCloudBytes > 0
        {
            ListCard { bringBack(overview) }
                .padding(.top, Tokens.blockGap)
        }
    }

    private var cloudAges: [Choice] {
        settings.coldStorageAgeChoices.map { days in
            Choice(
                id: Int64(days), label: C.ageLabel(days),
                consequence: moves(storage.wouldMove(ageDays: days, maxBytes: 0)),
                isSelected: cloudAge == days, isEnabled: cloudReachable
            ) { settings.setCloudRule(ageDays: days, maxBytes: cloudLimit) }
        } + [
            // Turning the rule down is always possible, reachable or not.
            Choice(id: 0, label: C.never, isSelected: cloudAge == nil) {
                settings.setCloudRule(ageDays: nil, maxBytes: cloudLimit)
            }
        ]
    }

    private var cloudLimits: [Choice] {
        sized { bytes in
            let wouldMove = bytes > 0 ? storage.wouldMove(ageDays: nil, maxBytes: bytes) : nil
            return Choice(
                id: bytes, label: AppSettings.retentionLimitLabel(bytes),
                consequence: wouldMove.flatMap(moves),
                isSelected: cloudLimit == bytes, isEnabled: cloudReachable || bytes == 0
            ) { settings.setCloudRule(ageDays: cloudAge, maxBytes: bytes) }
        }
    }

    private func moves(_ preview: StoragePreview) -> String? {
        preview.bytes > 0 ? C.moves(Formatting.storageSize(preview.bytes)) : nil
    }

    /// The limits smallest first, with No limit last, as Never is in the ages.
    private func sized(_ choice: (Int64) -> Choice) -> [Choice] {
        (AppSettings.retentionLimitOptions.filter { $0 > 0 }.sorted() + [0]).map(choice)
    }

    @ViewBuilder
    private func bringBack(_ overview: StorageOverview) -> some View {
        if let restoring = overview.restoring {
            HStack(spacing: 10) {
                ProgressView(value: Double(restoring.done), total: Double(max(restoring.total, 1)))
                    .tint(Tokens.tint)
                Text(C.bringingBack(done: restoring.done, total: restoring.total))
                    .font(AppFont.footnote.monospacedDigit())
                    .foregroundStyle(Tokens.meta)
                    .lineLimit(1)
                    .fixedSize()
            }
        } else {
            let fits = overview.bringBackFits
            TintActionRow(
                title: C.bringBack(Formatting.storageSize(overview.audioInCloudBytes)),
                subtitle: fits ? nil : C.bringBackNoRoom(Formatting.storageSize(overview.freeBytes))
            ) {
                storage.bringEverythingBack()
            }
            .disabled(!fits)
            .opacity(fits ? 1 : 0.5)
        }
    }

    // MARK: Deleted

    @ViewBuilder
    private var deleted: some View {
        section(C.byAge, deleteAges, destroys: true)
        // A full phone deletes only when there is no iCloud stop before this one.
        if settings.cloudRule == nil {
            section(C.byRoom, deleteLimits, destroys: true)
        }
        SettingsFooter(
            text: cloudDeletes ? C.deleteCloudFooter : C.deleteFooter)
    }

    private var cloudDeletes: Bool {
        settings.cloudRule != nil || (storage.overview?.audioInCloudBytes ?? 0) > 0
    }

    /// What is here has been counted. Until then a choice that could delete some of it is not
    /// offered: it could neither say how much nor know to ask.
    private var isCounted: Bool { storage.overview != nil }

    private var deleteAges: [Choice] {
        let current = settings.retentionDays
        return AppSettings.retentionOptions.map { days in
            let count = days < current ? storage.wouldDelete(olderThanDays: days) : 0
            let deletion = StorageDeletion.age(
                days, current: current, count: count, cloud: cloudDeletes)
            return Choice(
                id: Int64(days),
                label: days == AppSettings.keepForever ? C.never : C.ageLabel(days),
                consequence: deletion.map { _ in C.deletesCount(count) },
                isSelected: current == days, isEnabled: isCounted || days >= current
            ) { ask(deletion) { settings.retentionDays = days } }
        }
    }

    private var deleteLimits: [Choice] {
        let current = settings.retentionMaxBytes
        return sized { bytes in
            let used = storage.overview?.audioOnPhoneBytes ?? 0
            let deletion = StorageDeletion.limit(bytes, current: current, used: used)
            return Choice(
                id: bytes, label: AppSettings.retentionLimitLabel(bytes),
                consequence: deletion.map { _ in
                    C.deletesSize(Formatting.storageSize(used - bytes))
                },
                isSelected: current == bytes, isEnabled: isCounted || bytes == 0 || bytes == current
            ) { ask(deletion) { settings.setDeleteLimit(bytes) } }
        }
    }

    private struct Pending {
        let deletion: StorageDeletion
        let apply: () -> Void
    }

    private func ask(_ deletion: StorageDeletion?, then apply: @escaping () -> Void) {
        guard let deletion else { return apply() }
        pending = Pending(deletion: deletion, apply: apply)
    }
}

#Preview("Move to iCloud") {
    NavigationStack { SettingsStorageStopScreen(stop: .cloud) }
        .environment(AppSettings())
        .tint(Tokens.tint)
}

#Preview("Delete") {
    NavigationStack { SettingsStorageStopScreen(stop: .deleted) }
        .environment(AppSettings())
        .tint(Tokens.tint)
}
