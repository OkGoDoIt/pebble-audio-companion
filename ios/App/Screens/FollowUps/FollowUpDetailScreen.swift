import AppDB
import SwiftUI

/// One follow-up, opened.
///
/// The screen exists to answer the question the old two-line card could not: *why is this
/// here?* An always-on microphone proposing things for your to-do list has to show its working,
/// or the only rational response to a wrong item is to distrust every item. So the middle of
/// this screen is the sentence that was actually heard, when it was heard, in which recording —
/// and one tap plays it.
struct FollowUpDetailScreen: View {
    let id: String

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model = FollowUpDetailViewModel()
    @State private var showingEditor = false
    @State private var showingDatePicker = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.blockGap) {
                if let item = model.item {
                    headline(item)
                    attributes(item)
                    provenance(item)
                    actions(item)
                } else if model.loaded {
                    missing
                }
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .background(Tokens.ground)
        .navigationTitle(Copy.FollowUps.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.item != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(Copy.Common.edit) { showingEditor = true }
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            FollowUpEditorSheet(
                title: Copy.FollowUps.editTitle,
                text: model.item?.text ?? "",
                dueAt: model.item?.dueDate
            ) { text, due in
                model.setText(text)
                model.setDue(due)
            }
        }
        .sheet(isPresented: $showingDatePicker) {
            FollowUpDatePickerSheet(date: model.item?.dueDate) { picked in
                model.setDue(picked)
            }
        }
        .confirmationDialog(
            Copy.FollowUps.deleteConfirm, isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button(Copy.FollowUps.delete, role: .destructive) {
                Haptics.destructiveConfirmed()
                model.delete()
                dismiss()
            }
        }
        .task { await model.start(id: id) }
    }

    // MARK: Headline

    private func headline(_ item: FollowUpItem) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.text)
                    .font(AppFont.detailTitle)
                    .foregroundStyle(item.done ? Tokens.meta : Tokens.label)
                    .strikethrough(item.done, color: Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                if let why = item.why, !why.isEmpty, !item.done {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Copy.FollowUps.ifForgotten)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.faint)
                        Text(why)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button {
                    Haptics.checkedOff()
                    model.toggleDone()
                } label: {
                    Text(item.done ? Copy.FollowUps.markNotDone : Copy.FollowUps.markDone)
                }
                .buttonStyle(item.done ? AnyButtonStyle(.borderedTint) : AnyButtonStyle(.inCardFilled))
            }
        }
    }

    // MARK: Date + priority

    private func attributes(_ item: FollowUpItem) -> some View {
        ListCard {
            SettingsRow(
                title: Copy.FollowUps.due,
                value: item.dueDate.map { FollowUpFormatting.day($0, now: model.now) }
                    ?? Copy.FollowUps.noDue,
                valueColor: dueColor(item)
            ) {
                showingDatePicker = true
            }
            Menu {
                Picker(Copy.FollowUps.priority, selection: priorityBinding) {
                    ForEach(FollowUpPriority.allCases, id: \.self) { priority in
                        Text(FollowUpFormatting.priorityLabel(priority)).tag(priority)
                    }
                }
            } label: {
                SettingsRowLabel(
                    title: Copy.FollowUps.priority,
                    value: FollowUpFormatting.priorityLabel(item.priority))
            }
            .buttonStyle(.plain)
            if let snoozed = item.snoozedUntil, snoozed > model.now {
                SettingsRow(
                    title: Copy.FollowUps.snooze,
                    value: FollowUpFormatting.day(snoozed, now: model.now),
                    valueColor: Tokens.attention
                ) {
                    model.snooze(nil)
                }
            }
        }
    }

    private var priorityBinding: Binding<FollowUpPriority> {
        Binding(
            get: { model.item?.priority ?? .normal },
            set: { model.setPriority($0) })
    }

    private func dueColor(_ item: FollowUpItem) -> Color {
        guard let due = item.dueDate, !item.done else { return Tokens.meta }
        return FollowUpFormatting.dueMeta(due, now: model.now).isUrgent
            ? Tokens.attention : Tokens.meta
    }

    // MARK: Where it came from

    @ViewBuilder
    private func provenance(_ item: FollowUpItem) -> some View {
        if item.origin == .user {
            Card {
                Text(Copy.FollowUps.addedByYou)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
            }
        } else if let quote = item.quote, !quote.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Copy.FollowUps.heardTitle)
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)

                    // The words, set as a quotation: this is the recording speaking, not the
                    // app, and the visual difference is the whole point of showing it.
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle()
                            .fill(Tokens.tintSoft)
                            .frame(width: 3)
                            .clipShape(Capsule())
                            .accessibilityHidden(true)
                        Text("\u{201C}\(quote)\u{201D}")
                            .font(AppFont.subBody)
                            .italic()
                            .foregroundStyle(Tokens.secondaryBody)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    Text(sourceLine(item))
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.source != nil {
                        Button {
                            open()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                Text(Copy.FollowUps.openConversation)
                            }
                        }
                        .buttonStyle(.smallBordered)
                    }
                }
            }
        }
    }

    private func sourceLine(_ item: FollowUpItem) -> String {
        let heard = Copy.FollowUps.capturedOn(
            FollowUpFormatting.heardAt(item.created, now: model.now))
        guard let title = item.sourceConversationTitle else { return heard }
        return "\(heard) · \(title)"
    }

    private func open() {
        guard let target = model.source else { return }
        router.push(
            .conversation(
                id: target.conversationId, atMs: target.mediaOffsetMs, focus: target.focus))
    }

    // MARK: Snooze / file away / delete

    private func actions(_ item: FollowUpItem) -> some View {
        VStack(spacing: Tokens.blockGap) {
            if !item.done {
                ListCard {
                    Menu {
                        Button(Copy.FollowUps.snoozeTomorrow) { model.snooze(model.tomorrow) }
                        Button(Copy.FollowUps.snoozeNextWeek) { model.snooze(model.nextWeek) }
                        if item.snoozedUntil != nil {
                            Button(Copy.FollowUps.unsnooze) { model.snooze(nil) }
                        }
                    } label: {
                        SettingsRowLabel(title: Copy.FollowUps.snooze, value: nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            ListCard {
                if item.isArchived {
                    SettingsRow(title: Copy.FollowUps.restore, showsChevron: false) {
                        model.setArchived(false)
                    }
                } else {
                    SettingsRow(title: Copy.FollowUps.fileAway, showsChevron: false) {
                        model.setArchived(true)
                    }
                }
            }
            ListCard {
                DestructiveRow(title: "\(Copy.FollowUps.delete)…") { confirmDelete = true }
            }
        }
    }

    private var missing: some View {
        Text(Copy.Empty.followUpsAllDone)
            .font(AppFont.subBody)
            .foregroundStyle(Tokens.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }
}

/// A row that looks like `SettingsRow` but is a Menu's label rather than its own button —
/// `SettingsRow` owns its tap, and nesting that inside a Menu swallows the menu.
private struct SettingsRowLabel: View {
    let title: String
    let value: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AppFont.callout)
                .foregroundStyle(Tokens.label)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.meta)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.chevron)
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Erases the two button styles the headline switches between, which otherwise cannot share a
/// `.buttonStyle(_:)` call site.
private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - View model

@MainActor
@Observable
final class FollowUpDetailViewModel {
    private let store: any FollowUpsDataSource
    private var id: String = ""

    private(set) var item: FollowUpItem?
    /// Where "open the recording" goes. Nil when the item was hand-written, or when its
    /// recording has since been deleted — either way the button is simply not offered.
    private(set) var source: CitationTarget?
    private(set) var loaded = false
    private(set) var now = Date()

    init(source: (any FollowUpsDataSource)? = nil) {
        store = source ?? AskLibraryDataSources.current.followUps
    }

    func start(id: String) async {
        self.id = id
        await reload()
        for await _ in store.followUpUpdates() {
            await reload()
        }
    }

    private func reload() async {
        now = Date()
        item = try? await store.item(id: id)
        source = await store.source(of: id)
        loaded = true
    }

    var tomorrow: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    }

    var nextWeek: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)) ?? now
    }

    func toggleDone() {
        guard let item else { return }
        // Optimistic: the button's label flips on the tap, not on the write.
        self.item?.done.toggle()
        Task {
            try? await store.setDone(id: item.id, done: !item.done)
            await reload()
        }
    }

    func setText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item?.text else { return }
        item?.text = trimmed
        Task {
            try? await store.setText(id: id, text: trimmed)
            await reload()
        }
    }

    func setDue(_ date: Date?) {
        item?.dueAtMs = date.map { Int64($0.timeIntervalSince1970 * 1000) }
        Task {
            try? await store.setDue(
                id: id, dueAtMs: date.map { Int64($0.timeIntervalSince1970 * 1000) })
            await reload()
        }
    }

    func setPriority(_ priority: FollowUpPriority) {
        item?.priority = priority
        Task {
            try? await store.setPriority(id: id, priority: priority)
            await reload()
        }
    }

    func snooze(_ date: Date?) {
        item?.snoozedUntilMs = date.map { Int64($0.timeIntervalSince1970 * 1000) }
        Task {
            try? await store.snooze(
                id: id, untilMs: date.map { Int64($0.timeIntervalSince1970 * 1000) })
            await reload()
        }
    }

    func setArchived(_ archived: Bool) {
        Task {
            try? await store.setArchived(id: id, archived: archived)
            await reload()
        }
    }

    func delete() {
        Task { try? await store.delete(id: id) }
    }
}
