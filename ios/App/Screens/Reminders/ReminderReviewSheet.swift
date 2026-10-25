import AppDB
import SwiftUI

/// The review (`docs/reminders.md`, mockup v4 frames 3–7): the follow-ups the app was unsure of,
/// one card at a time, then the summary of everything decided today.
///
/// One gesture, one meaning. Swipe right or tap ✓ is Remind me; swipe left or tap ✕ is Skip.
/// "Not Now" closes, and unanswered cards wait for next time. The summary that follows is the
/// only undo: there is no snackbar.
struct ReminderReviewSheet: View {
    let start: ReminderSheet

    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @State private var model = ReminderReviewModel(onDatedReminder: {
        Task { @MainActor in await ReminderHomeSources.current.askForAlertPermissionIfNeeded() }
    })
    @State private var player = MomentPlayer()

    var body: some View {
        VStack(spacing: 0) {
            header
            switch model.phase {
            case .loading:
                Spacer()
            case .cards:
                ReviewCards(model: model, player: player, openMoment: open)
                    .transition(.opacity)
            case .summary:
                ReviewSummary(model: model) { dismiss() }
                    .transition(.opacity)
            }
        }
        .background(Tokens.ground)
        .animation(Motion.animation(.easeInOut(duration: 0.25)), value: model.phase)
        .interactiveDismissDisabled(model.savingDetails)
        .presentationDragIndicator(.visible)
        .presentationBackground(Tokens.ground)
        .presentationCornerRadius(Tokens.sheetRadius)
        .task { await model.start(start) }
        .onDisappear { player.stop() }
    }

    /// The sheet's own bar: "Follow-ups" centred, "1 of 3" at the trailing edge. Drawn rather
    /// than a navigation bar: a toolbar item on iOS 26 gets a glass capsule, and a counter is not
    /// a button.
    private var header: some View {
        ZStack {
            Text(Copy.Reminders.reviewTitle)
                .font(AppFont.headline)
                .foregroundStyle(Tokens.label)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Spacer()
                if let counter = model.counter {
                    Text(counter)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.meta)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .padding(.trailing, 18)
        }
        .frame(height: 52)
        .padding(.top, 10)
    }

    /// No audio to play here: the moment opens in its conversation, out of the sheet first.
    private func open(_ target: CitationTarget) {
        dismiss()
        router.navigate(
            to: .conversation(
                id: target.conversationId, atMs: target.mediaOffsetMs, focus: target.focus))
    }
}

// MARK: - Cards

private struct ReviewCards: View {
    let model: ReminderReviewModel
    let player: MomentPlayer
    let openMoment: (CitationTarget) -> Void

    @State private var editingTitle = false
    @State private var drag: CGSize = .zero

    /// The card on top and the two behind it.
    private var visible: [FollowUpItem] {
        (model.current.map { [$0] } ?? []) + model.behind
    }
    /// Cards on their way off the screen, drawn above the stack until they are gone.
    @State private var leaving: [Leaving] = []
    /// Past the threshold during this drag, so the haptic fires once per crossing.
    @State private var armed = false

    struct Leaving: Identifiable {
        let item: FollowUpItem
        var offset: CGSize
        var id: String { item.id }
    }

    /// How far a card has to travel to count, and how fast a short flick has to be.
    static let threshold: CGFloat = 110
    static let flingVelocity: CGFloat = 700

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let cardHeight = max(160, min(470, geometry.size.height - 36))
                ZStack(alignment: .top) {
                    // One keyed list, deepest first, so when an answer advances the queue the
                    // card behind slides up into place rather than being swapped for a new one.
                    ForEach(Array(visible.enumerated()).reversed(), id: \.element.id) {
                        depth, item in
                        if depth == 0 {
                            ReviewCard(
                                item: item, height: cardHeight,
                                isPlaying: player.playingId == item.id,
                                stamp: stamp, stampStrength: stampStrength,
                                onTextFocusChange: { editingTitle = $0 },
                                onEdit: { text, due, priority in
                                    model.editDetails(id: item.id, text: text, dueAt: due, priority: priority)
                                }
                            ) {
                                play(item)
                            }
                            .offset(drag)
                            .rotationEffect(.degrees(Double(drag.width / 18)), anchor: .bottom)
                            .simultaneousGesture(swipe)
                            .accessibilityElement(children: .contain)
                            .accessibilityHint(Copy.Reminders.cardHint)
                            .accessibilityAction(named: Copy.Reminders.remindMe) {
                                commit(.remind)
                            }
                            .accessibilityAction(named: Copy.Reminders.skip) { commit(.skip) }
                            .zIndex(1)
                        } else {
                            // Opaque, dimmed toward the ground rather than see-through:
                            // two translucent cards showed each other's words.
                            ReviewCard(
                                item: item, height: cardHeight, isPlaying: false,
                                dimming: depth == 1 ? 0.1 : 0.3
                            ) {}
                                .scaleEffect(1 - 0.05 * CGFloat(depth), anchor: .top)
                                .offset(y: depth == 1 ? 30 : 62)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    ForEach(leaving) { card in
                        ReviewCard(item: card.item, height: cardHeight, isPlaying: false,
                            stamp: card.offset.width > 0 ? .remind : .skip, stampStrength: 1) {}
                            .offset(card.offset)
                            .rotationEffect(
                                .degrees(Double(card.offset.width / 18)), anchor: .bottom)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .zIndex(2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: 506)
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.top, 6)

            if let error = model.saveError {
                VStack(spacing: 4) {
                    Text(error).font(AppFont.footnote).foregroundStyle(Tokens.attention)
                    Button(Copy.Common.retry) { model.retryDetails() }
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, Tokens.screenMargin)
            }
            decideButtons
                .disabled(!model.canDecide)
                .padding(.top, 26)

            Spacer(minLength: 12)

            Button(Copy.Reminders.notNow) { dismissSheet() }
                .disabled(model.savingDetails)
                .font(AppFont.bodyPlain)
                .foregroundStyle(Tokens.tint)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 20)
        }
    }

    @Environment(\.dismiss) private var dismissSheet

    // MARK: Decide buttons

    private var decideButtons: some View {
        HStack(spacing: 64) {
            DecideButton(
                title: Copy.Reminders.skip, systemImage: "xmark", isPrimary: false,
                isHot: stamp == .skip && stampStrength >= 1
            ) { commit(.skip) }
            DecideButton(
                title: Copy.Reminders.remindMe, systemImage: "checkmark", isPrimary: true,
                isHot: stamp == .remind && stampStrength >= 1
            ) { commit(.remind) }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Gesture

    private var stamp: ReviewCard.Stamp? {
        if drag.width > 16 { return .remind }
        if drag.width < -16 { return .skip }
        return nil
    }

    /// 0 at rest, 1 well before the threshold: the stamp fades in quickly, so it is never a
    /// half-transparent label over the card's words for long.
    private var stampStrength: Double {
        min(1, max(0, Double((abs(drag.width) - 16) / 44)))
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard model.canDecide, !editingTitle,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                drag = CGSize(width: value.translation.width, height: value.translation.height * 0.2)
                let past = abs(value.translation.width) >= Self.threshold
                if past != armed {
                    armed = past
                    if past { Haptics.impact(.light) }
                }
            }
            .onEnded { value in
                armed = false
                let distance = value.translation.width
                let flung =
                    abs(value.velocity.width) >= Self.flingVelocity
                    && (value.velocity.width > 0) == (distance > 0) && abs(distance) > 30
                if model.canDecide, !editingTitle,
                   abs(distance) > abs(value.translation.height),
                   abs(distance) >= Self.threshold || flung {
                    commit(distance > 0 ? .remind : .skip)
                } else {
                    withAnimation(Motion.animation(.spring(response: 0.35, dampingFraction: 0.7))) {
                        drag = .zero
                    }
                }
            }
    }

    /// Swipe or tap: the card leaves in the direction of its answer and the next comes up.
    private func commit(_ decision: ReminderReviewModel.Decision) {
        guard let item = model.current, model.canDecide else { return }
        player.stop()
        if decision == .remind { Haptics.checkedOff() } else { Haptics.impact(.soft) }
        let direction: CGFloat = decision == .remind ? 1 : -1
        let start = drag == .zero ? CGSize(width: direction * 1, height: 0) : drag
        leaving.append(Leaving(item: item, offset: start))
        drag = .zero
        withAnimation(Motion.animation(.easeIn(duration: 0.26))) {
            if let index = leaving.firstIndex(where: { $0.id == item.id }) {
                leaving[index].offset = CGSize(
                    width: direction * 640, height: start.height + 40)
            }
        }
        withAnimation(Motion.animation(.spring(response: 0.38, dampingFraction: 0.85))) {
            _ = model.decide(decision)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            leaving.removeAll { $0.id == item.id }
        }
    }

    private func play(_ item: FollowUpItem) {
        Task {
            if let target = await player.toggle(item) { openMoment(target) }
        }
    }
}

/// The round ✕ and ✓ under the stack: 64 pt, labelled underneath.
private struct DecideButton: View {
    let title: String
    let systemImage: String
    let isPrimary: Bool
    let isHot: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: isPrimary ? 24 : 21, weight: .semibold))
                    .foregroundStyle(isPrimary ? Tokens.onTint : Tokens.tertiary)
                    .frame(width: 64, height: 64)
                    .background {
                        if isPrimary {
                            Circle().fill(Tokens.tint)
                                .shadow(color: Tokens.tint.opacity(0.35), radius: 8, y: 6)
                        } else {
                            Circle().fill(Tokens.surface)
                                .overlay(Circle().strokeBorder(Tokens.cardBorder, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.06), radius: 6, y: 4)
                        }
                    }
                    .background {
                        Circle().fill(isPrimary ? Tokens.tintFill18 : Tokens.grayChipFill)
                            .padding(isHot ? -8 : 0)
                    }
                    .scaleEffect(isHot ? 1.12 : 1)
                Text(title)
                    .font(isPrimary ? AppFont.chip.weight(.semibold) : AppFont.chip)
                    .foregroundStyle(isPrimary ? Tokens.tint : Tokens.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.animation(.snappy(duration: 0.2)), value: isHot)
        .accessibilityLabel(title)
    }
}

// MARK: - One card

struct ReviewCard: View {
    enum Stamp { case remind, skip }

    let item: FollowUpItem
    let height: CGFloat
    let isPlaying: Bool
    var stamp: Stamp? = nil
    var stampStrength: Double = 0
    /// How far a card further back in the stack fades toward the ground.
    var dimming: Double = 0
    var onTextFocusChange: ((Bool) -> Void)? = nil
    var onEdit: ((String, Date?, FollowUpPriority) -> Void)? = nil
    @FocusState private var editingTitle: Bool
    let play: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(provenance)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                    if let onEdit {
                        TextField("Follow-up", text: Binding(
                            get: { item.text },
                            set: { onEdit($0, item.dueDate, item.priority) }), axis: .vertical)
                            .font(AppFont.detailTitle)
                            .foregroundStyle(Tokens.label)
                            .focused($editingTitle)
                            .onChange(of: editingTitle) { _, focused in onTextFocusChange?(focused) }
                            .onDisappear { onTextFocusChange?(false) }
                            .submitLabel(.done)
                            .onSubmit { editingTitle = false }
                            .accessibilityLabel("Follow-up")
                            .accessibilityHint("Tap to edit")
                        editableMetadata(onEdit)
                    } else {
                        Text(item.text)
                            .font(AppFont.detailTitle)
                            .foregroundStyle(Tokens.label)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 6) {
                            Label(dueLabel, systemImage: "calendar")
                            Label(Copy.Reminders.priority(FollowUpFormatting.priorityLabel(item.priority)), systemImage: "flag")
                        }
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.secondaryBody)
                    }
                    if let why = item.why, !why.isEmpty {
                        Text(Copy.FollowUps.ifForgotten(why))
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.tertiary)
                    }
                    if let quote = item.quote, !quote.isEmpty {
                        Rectangle().fill(Tokens.hairline).frame(height: 0.5)
                        Text("\u{201C}\(quote)\u{201D}")
                            .font(AppFont.subBody)
                            .italic()
                            .foregroundStyle(Tokens.secondaryBody)
                            .lineSpacing(4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            if item.sourceConversationId != nil { playRow }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: .top)
        .background(Tokens.surface)
        .overlay {
            if dimming > 0 { Tokens.ground.opacity(dimming).allowsHitTesting(false) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.sheetRadius))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.08), radius: 15, y: 10)
        .overlay(alignment: stamp == .skip ? .topTrailing : .topLeading) {
            if let stamp {
                StampView(stamp: stamp)
                    .opacity(stampStrength)
                    .padding(.top, 22)
                    .padding(.horizontal, 18)
                    .accessibilityHidden(true)
            }
        }
    }

    private func editableMetadata(_ onEdit: @escaping (String, Date?, FollowUpPriority) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let due = item.dueDate {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        duePicker(due, onEdit: onEdit)
                        clearDate(onEdit)
                    }
                    VStack(alignment: .leading) {
                        duePicker(due, onEdit: onEdit)
                        clearDate(onEdit)
                    }
                }
            } else {
                Button {
                    editingTitle = false
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1,
                        to: Calendar.current.startOfDay(for: Date())) ?? Date()
                    onEdit(item.text, tomorrow, item.priority)
                } label: {
                    Label(Copy.Reminders.addDueDate, systemImage: "calendar.badge.plus")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.tint)
            }
            Menu {
                Picker(Copy.FollowUps.priority, selection: Binding(
                    get: { item.priority },
                    set: { onEdit(item.text, item.dueDate, $0) })) {
                    ForEach(FollowUpPriority.allCases, id: \.self) { value in
                        Text(FollowUpFormatting.priorityLabel(value)).tag(value)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Label(Copy.Reminders.priority(FollowUpFormatting.priorityLabel(item.priority)),
                          systemImage: "flag")
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.secondaryBody)
        }
        .font(AppFont.subBody)
        .tint(Tokens.tint)
    }

    private func duePicker(_ due: Date,
        onEdit: @escaping (String, Date?, FollowUpPriority) -> Void) -> some View {
        DatePicker(selection: Binding(get: { due }, set: { onEdit(item.text, $0, item.priority) }),
                   displayedComponents: .date) {
            Label(Copy.FollowUps.due, systemImage: "calendar")
        }
        .datePickerStyle(.compact)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func clearDate(_ onEdit: @escaping (String, Date?, FollowUpPriority) -> Void) -> some View {
        Button {
            onEdit(item.text, nil, item.priority)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Tokens.meta)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Copy.FollowUps.clearDue)
    }

    private var dueLabel: String {
        guard let due = item.dueDate else { return Copy.Reminders.noDueDate }
        // Always name the actual suggested date, including past dates, before it is accepted.
        return Copy.FollowUps.dueOn(due.formatted(date: .abbreviated, time: .omitted))
    }

    /// "10:05 AM · Catching up about Vietnam".
    private var provenance: String {
        [TimeFmt.time(item.said), item.sourceConversationTitle]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var playRow: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.onTint)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Tokens.tint))
                VStack(alignment: .leading, spacing: 0) {
                    Text(Copy.Reminders.playTheMoment)
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)
                    if let length = item.momentLengthMs {
                        Text(TimeFmt.timecode(length))
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.meta)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? Copy.Reminders.stopPlaying : Copy.Reminders.playTheMoment)
    }
}

/// "✓ Remind me" tilted over the card's leading corner on the way right; "Skip" over the
/// trailing one on the way left.
private struct StampView: View {
    let stamp: ReviewCard.Stamp

    var body: some View {
        HStack(spacing: 6) {
            if stamp == .remind {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
            }
            Text(stamp == .remind ? Copy.Reminders.remindMe : Copy.Reminders.skip)
                .font(AppFont.cardHead)
        }
        .foregroundStyle(Tokens.onTint)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(stamp == .remind ? Tokens.tint : Tokens.tertiary))
        .shadow(
            color: (stamp == .remind ? Tokens.tint : Color.black).opacity(stamp == .remind ? 0.35 : 0.2),
            radius: 9, y: 6)
        .rotationEffect(.degrees(stamp == .remind ? -7 : 7))
    }
}

// MARK: - Summary

private struct ReviewSummary: View {
    let model: ReminderReviewModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.blockGap) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Copy.Reminders.added(model.addedCount))
                            .font(AppFont.screenTitle)
                            .foregroundStyle(Tokens.label)
                            .contentTransition(.numericText())
                            .accessibilityAddTraits(.isHeader)
                        Text(
                            model.summary.isEmpty
                                ? Copy.Reminders.nothingToday : Copy.Reminders.fromToday
                        )
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.tertiary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)

                    if !model.summary.isEmpty {
                        ListCard(rowVerticalPadding: 10) {
                            ForEach(model.summary) { item in
                                SummaryRow(item: item) {
                                    Haptics.impact(.light)
                                    Task { await model.flip(item) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Tokens.screenMargin)
                .padding(.bottom, 16)
                .animation(
                    Motion.animation(.snappy(duration: 0.2)),
                    value: model.summary.map(\.stage))
            }
            Button(Copy.Common.done, action: done)
                .buttonStyle(.primaryFilled)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 20)
        }
    }
}

private struct SummaryRow: View {
    let item: FollowUpItem
    let flip: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.label)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            StatePill(isReminder: item.stage == .reminder, action: flip)
        }
    }

    /// Its due date when it has one (amber when today or late), otherwise when it was said.
    @ViewBuilder
    private var meta: some View {
        if let due = item.dueDate {
            let dueMeta = FollowUpFormatting.dueMeta(due, now: Date())
            HStack(spacing: 5) {
                if dueMeta.isUrgent {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 11, weight: .bold))
                        .accessibilityHidden(true)
                }
                Text(dueMeta.text)
            }
            .font(AppFont.footnote)
            .foregroundStyle(dueMeta.isUrgent ? Tokens.attention : Tokens.meta)
        } else {
            Text(TimeFmt.time(item.said))
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.meta)
        }
    }
}

/// "✓ Reminder" in the tint, or "Skipped" in gray, at the row's trailing edge. A tap flips it.
struct StatePill: View {
    let isReminder: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isReminder {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                }
                Text(isReminder ? Copy.Reminders.stateReminder : Copy.Reminders.stateSkipped)
                    .font(AppFont.smallButton)
            }
            .foregroundStyle(isReminder ? Tokens.tint : Tokens.tertiary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(isReminder ? Tokens.tintFill12 : Tokens.grayChipFill))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(isReminder ? Copy.Reminders.stateReminder : Copy.Reminders.stateSkipped)
        .accessibilityHint(isReminder ? Copy.Reminders.reminderHint : Copy.Reminders.skippedHint)
    }
}

#Preview("Review") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ReminderReviewSheet(start: .review)
        }
        .environment(AppRouter())
        .tint(Tokens.tint)
}
