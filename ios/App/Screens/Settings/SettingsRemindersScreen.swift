import CompanionRuntime
import SwiftUI
import UIKit
import UserNotifications

/// Settings › Reminders (`docs/reminders.md`, mockup v4 section 2): where reminders are kept,
/// when they alert, and the evening review.
///
/// There is always exactly one home. Choosing Apple Reminders asks iOS for access first (the
/// lists cannot be shown without it), then one sheet asks which list and moves everything in the
/// same tap. Coming back to Pebble Audio asks once when there is something to bring back.
struct SettingsRemindersScreen: View {
    @State private var model = SettingsRemindersModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsScroll {
            SettingsSectionHeader(title: Copy.Reminders.keepIn)
            ListCard {
                homeOption(.app, title: Copy.Reminders.pebbleAudio)
                homeOption(.apple, title: Copy.Reminders.appleReminders)
                if model.preferences.home == .apple {
                    NavigationLink {
                        ReminderListPicker(
                            lists: model.lists, newListExists: model.newListExists,
                            selection: model.listSelection
                        ) { choice in
                            Task { await model.pickList(choice) }
                        }
                    } label: {
                        listRow
                    }
                    .buttonStyle(.plain)
                }
            }
            if model.showsAccessOff {
                accessOffCard
            }

            SettingsSectionHeader(title: Copy.Reminders.alerts)
            ListCard {
                toggleRow(
                    Copy.Reminders.alertOnDueDate, isOn: model.preferences.dueAlerts,
                    warns: model.notificationsDenied
                ) { model.setDueAlerts($0) }
                if model.preferences.dueAlerts {
                    timeRow(Copy.Reminders.alertTime, minutes: model.preferences.dueAlertMinutes) {
                        value in model.update { $0.dueAlertMinutes = value }
                    }
                }
            }

            SettingsSectionHeader(title: Copy.Reminders.reviewSection)
            ListCard {
                toggleRow(
                    Copy.Reminders.eveningReview, isOn: model.preferences.eveningReview,
                    warns: model.notificationsDenied
                ) { model.setEveningReview($0) }
                if model.preferences.eveningReview {
                    timeRow(Copy.Reminders.time, minutes: model.preferences.eveningReviewMinutes) {
                        value in model.update { $0.eveningReviewMinutes = value }
                    }
                }
            }
        }
        .navigationTitle(Copy.Reminders.title)
        .navigationBarTitleDisplayMode(.inline)
        .animation(Motion.animation(.snappy(duration: 0.25)), value: model.preferences)
        .task { await model.observe() }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await model.refreshPermissions() }
        }
        .sheet(item: $model.moveOffer) { offer in
            MoveToAppleSheet(offer: offer) { choice in
                await model.moveToApple(choice)
            }
        }
        .alert(
            model.changeListOffer.map {
                Copy.Reminders.changeListTitle($0.count, to: $0.listTitle)
            } ?? "",
            isPresented: Binding(
                get: { model.changeListOffer != nil },
                set: { if !$0 { model.changeListOffer = nil } }),
            // Presented with the offer itself: the alert clears `changeListOffer` as it
            // dismisses, before a button's action runs.
            presenting: model.changeListOffer
        ) { offer in
            Button(Copy.Reminders.moveThem) {
                Task { await model.changeList(offer, moveOpen: true) }
            }
            Button(Copy.Reminders.onlyNewOnes) {
                Task { await model.changeList(offer, moveOpen: false) }
            }
        }
        .alert(
            Copy.Reminders.bringBackTitle(model.bringBackCount ?? 0),
            isPresented: Binding(
                get: { model.bringBackCount != nil },
                set: { if !$0 { model.bringBackCount = nil } })
        ) {
            Button(Copy.Reminders.bringThemBack) { Task { await model.bringBack() } }
            Button(Copy.Common.cancel, role: .cancel) {}
        }
    }

    // MARK: Rows

    private func homeOption(_ home: ReminderHome, title: String) -> some View {
        let selected = model.preferences.home == home
        return Button {
            Task { await model.choose(home) }
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                if model.working == home {
                    ProgressView()
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.working != nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var listRow: some View {
        HStack(spacing: 10) {
            Text(Copy.Reminders.list)
                .font(AppFont.callout)
                .foregroundStyle(Tokens.label)
            Spacer(minLength: 10)
            if let list = model.currentList {
                HStack(spacing: 6) {
                    ListDot(hex: list.colorHex, side: 14)
                    Text(list.title)
                        .lineLimit(1)
                }
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.meta)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.chevron)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func toggleRow(
        _ title: String, isOn: Bool, warns: Bool, set: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
                if isOn && warns {
                    Text(Copy.Reminders.notificationsOff)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            Toggle(title, isOn: Binding(get: { isOn }, set: set))
                .labelsHidden()
                .tint(Tokens.good)
        }
    }

    private func timeRow(
        _ title: String, minutes: Int, set: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(AppFont.callout)
                .foregroundStyle(Tokens.label)
            Spacer(minLength: 10)
            DatePicker(
                title,
                selection: Binding(
                    get: { ReminderTime.date(minutes: minutes) },
                    set: { set(ReminderTime.minutes(of: $0)) }),
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .datePickerStyle(.compact)
        }
    }

    /// Access was turned off in iOS: only Settings can turn it back on.
    private var accessOffCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(Tokens.attention).frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(Copy.Reminders.accessOff)
                        .font(AppFont.rowTitle)
                        .foregroundStyle(Tokens.label)
                }
                Button(Copy.Status.openSettings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.inCardFilled)
            }
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class SettingsRemindersModel {
    /// The sheet that moves everything to Apple Reminders.
    struct MoveOffer: Identifiable {
        let count: Int
        let lists: [AppleReminderList]
        let newListExists: Bool
        var id: Int { count }
    }

    struct ChangeListOffer {
        let choice: RemindersHome.ListChoice
        let count: Int
        let listTitle: String
    }

    private(set) var preferences = ReminderPreferences()
    private(set) var lists: [AppleReminderList] = []
    private(set) var access: RemindersHome.AccessState = .notAsked
    private(set) var notificationsDenied = false
    /// The home being switched to, while it moves.
    private(set) var working: ReminderHome?
    /// Set after the person picked Apple Reminders and iOS said no: the note stays until access
    /// comes back.
    private(set) var refusedJustNow = false
    var moveOffer: MoveOffer?
    var changeListOffer: ChangeListOffer?
    var bringBackCount: Int?

    private var source: any ReminderHomeSource { ReminderHomeSources.current }

    var showsAccessOff: Bool {
        access == .refused && (preferences.home == .apple || refusedJustNow)
    }

    var newListExists: Bool { lists.contains { $0.title == RemindersHome.newListTitle } }

    var currentList: AppleReminderList? {
        lists.first { $0.id == preferences.appleListId }
    }

    var listSelection: String? { preferences.appleListId }

    func observe() async {
        await refreshPermissions()
        for await value in source.preferenceUpdates() {
            if preferences != value { preferences = value }
            refreshLists()
        }
    }

    func refreshPermissions() async {
        access = source.access
        if access != .refused { refusedJustNow = false }
        refreshLists()
        let status = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
        notificationsDenied = status == .denied
    }

    private func refreshLists() {
        let next = source.access == .allowed ? source.lists() : []
        if next != lists { lists = next }
    }

    func update(_ change: (inout ReminderPreferences) -> Void) { source.update(change) }

    /// Turning an alert on is the moment iOS is asked about notifications.
    func setDueAlerts(_ on: Bool) {
        source.update { $0.dueAlerts = on }
        if on { Task { await askForNotifications() } }
    }

    func setEveningReview(_ on: Bool) {
        source.update { $0.eveningReview = on }
        if on { Task { await askForNotifications() } }
    }

    private func askForNotifications() async {
        await source.askForAlertPermissionIfNeeded()
        await refreshPermissions()
    }

    // MARK: Home

    func choose(_ home: ReminderHome) async {
        guard home != preferences.home, working == nil else { return }
        switch home {
        case .apple:
            // iOS asks now, and only now: the lists cannot be shown without access.
            var allowed = source.access == .allowed
            if !allowed { allowed = await source.requestAccess() }
            guard allowed else {
                refusedJustNow = true
                await refreshPermissions()
                return
            }
            await refreshPermissions()
            moveOffer = MoveOffer(
                count: await source.openReminderCount(), lists: lists,
                newListExists: newListExists)
        case .app:
            let count = await source.openReminderCount()
            if count > 0 {
                bringBackCount = count
            } else {
                await bringBack()
            }
        }
    }

    func moveToApple(_ choice: RemindersHome.ListChoice) async {
        working = .apple
        _ = try? await source.switchToApple(choice)
        working = nil
        moveOffer = nil
        refreshLists()
    }

    func bringBack() async {
        working = .app
        _ = try? await source.switchToApp()
        working = nil
        bringBackCount = nil
    }

    // MARK: List

    /// New reminders go to the list picked; the open ones in the old list move only if the
    /// person says so, and nothing is asked when there are none.
    func pickList(_ choice: RemindersHome.ListChoice) async {
        let pickedId: String? = {
            if case .existing(let id) = choice { return id }
            return lists.first { $0.title == RemindersHome.newListTitle }?.id
        }()
        guard pickedId == nil || pickedId != preferences.appleListId else { return }
        let old = preferences.appleListId
        var count = 0
        if let old { count = await source.openCount(inList: old) }
        if count > 0 {
            let title = pickedId.flatMap { id in lists.first { $0.id == id }?.title }
                ?? RemindersHome.newListTitle
            changeListOffer = ChangeListOffer(choice: choice, count: count, listTitle: title)
        } else {
            _ = try? await source.changeList(choice, moveOpen: false)
            refreshLists()
        }
    }

    func changeList(_ offer: ChangeListOffer, moveOpen: Bool) async {
        changeListOffer = nil
        _ = try? await source.changeList(offer.choice, moveOpen: moveOpen)
        refreshLists()
    }
}

/// A preference's clock time, stored as minutes past midnight.
enum ReminderTime {
    static func date(minutes: Int) -> Date {
        Calendar.current.date(
            bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    static func minutes(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

// MARK: - The move sheet

/// "Move 48 open reminders to Apple Reminders": the list is chosen here, in the same sheet that
/// moves them, so nothing is ever moved into a list the person did not pick.
private struct MoveToAppleSheet: View {
    let offer: SettingsRemindersModel.MoveOffer
    let move: (RemindersHome.ListChoice) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var choice: String = MoveToAppleSheet.newListTag
    @State private var moving = false

    static let newListTag = "new-list"

    var body: some View {
        VStack(spacing: 0) {
            Text(Copy.Reminders.moveTitle(offer.count))
                .font(AppFont.detailTitle)
                .foregroundStyle(Tokens.label)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 30)
                .padding(.horizontal, 8)

            ListCard {
                HStack(spacing: 10) {
                    Text(Copy.Reminders.list)
                        .font(AppFont.callout)
                        .foregroundStyle(Tokens.label)
                    Spacer(minLength: 10)
                    Menu {
                        Picker(Copy.Reminders.list, selection: $choice) {
                            ForEach(options, id: \.tag) { option in
                                Label {
                                    Text(option.title)
                                } icon: {
                                    // Drawn in the list's own color: a menu otherwise draws
                                    // every glyph in its text color.
                                    Image(uiImage: ListDot.menuImage(hex: option.colorHex))
                                }
                                .tag(option.tag)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            ListDot(hex: selected.colorHex, side: 14)
                            Text(selected.title)
                                .font(AppFont.subBody)
                                .foregroundStyle(Tokens.label)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Tokens.meta)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(Copy.Reminders.list), \(selected.title)")
                }
            }
            .padding(.top, 22)

            Spacer(minLength: 20)

            Button {
                moving = true
                Task {
                    await move(choice == Self.newListTag ? .newList : .existing(id: choice))
                    moving = false
                    dismiss()
                }
            } label: {
                if moving {
                    ProgressView().tint(Tokens.onTint)
                } else {
                    Text(offer.count == 0 ? Copy.Common.done : Copy.Reminders.move)
                }
            }
            .buttonStyle(.primaryFilled)
            .disabled(moving)

            Button(Copy.Common.cancel) { dismiss() }
                .font(AppFont.bodyPlain)
                .foregroundStyle(Tokens.tint)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .background(Tokens.ground)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Tokens.ground)
        .interactiveDismissDisabled(moving)
        .onAppear {
            // The existing Pebble Audio list when there is one; otherwise a new one by that name.
            if let existing = offer.lists.first(where: { $0.title == RemindersHome.newListTitle }) {
                choice = existing.id
            }
        }
    }

    private struct Option {
        let tag: String
        let title: String
        let colorHex: String
    }

    private var options: [Option] {
        var all: [Option] = []
        if !offer.newListExists {
            all.append(
                Option(
                    tag: Self.newListTag,
                    title: "\(RemindersHome.newListTitle) (\(Copy.Reminders.newList.lowercased()))",
                    colorHex: ListDot.pebbleHex))
        }
        all += offer.lists.map { Option(tag: $0.id, title: $0.title, colorHex: $0.colorHex) }
        return all
    }

    private var selected: Option {
        options.first { $0.tag == choice }
            ?? Option(tag: Self.newListTag, title: RemindersHome.newListTitle, colorHex: ListDot.pebbleHex)
    }
}

// MARK: - The list picker

/// Where new reminders go while they are kept in Apple Reminders: the person's own lists, in
/// their own colors, and a new "Pebble Audio" list while there is none.
private struct ReminderListPicker: View {
    let lists: [AppleReminderList]
    let newListExists: Bool
    let selection: String?
    let pick: (RemindersHome.ListChoice) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsScroll {
            ListCard {
                if !newListExists {
                    row(
                        title: RemindersHome.newListTitle, hex: ListDot.pebbleHex,
                        trailing: Copy.Reminders.newList, selected: false
                    ) { choose(.newList) }
                }
                ForEach(lists) { list in
                    row(
                        title: list.title, hex: list.colorHex, trailing: nil,
                        selected: list.id == selection
                    ) { choose(.existing(id: list.id)) }
                }
            }
        }
        .navigationTitle(Copy.Reminders.list)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ choice: RemindersHome.ListChoice) {
        dismiss()
        pick(choice)
    }

    private func row(
        title: String, hex: String, trailing: String?, selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ListDot(hex: hex, side: 22)
                Text(title)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                Spacer(minLength: 10)
                if let trailing {
                    Text(trailing)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.meta)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A Reminders list's glyph: its color as a filled circle with the list mark in white, so a row
/// reads as "this is in Reminders" at a glance.
struct ListDot: View {
    /// The Pebble Audio list is made in the app's tint.
    static let pebbleHex = "#5B5BD6"

    let hex: String
    let side: CGFloat

    var body: some View {
        Circle()
            .fill(Color(listHex: hex) ?? Tokens.tint)
            .frame(width: side, height: side)
            .overlay(
                Image(systemName: "list.bullet")
                    .font(.system(size: side * 0.5, weight: .bold))
                    .foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

extension ListDot {
    /// The list's color as a filled circle, for a menu row.
    static func menuImage(hex: String) -> UIImage {
        let color = Color(listHex: hex).map(UIColor.init) ?? UIColor(Tokens.tint)
        let base = UIImage(systemName: "circle.fill") ?? UIImage()
        return base.withTintColor(color, renderingMode: .alwaysOriginal)
    }
}

extension Color {
    /// `#RRGGBB`, as `AppleReminderList.colorHex` carries it.
    init?(listHex: String) {
        let digits = listHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

#Preview("Settings › Reminders") {
    NavigationStack {
        SettingsRemindersScreen()
    }
    .tint(Tokens.tint)
}
