import Receiver
import SwiftUI
import StatusUI

/// Today tab root (Main artboard, extraction §2.4): status card with the live minute,
/// day coverage, recap, follow-ups, conversations. Ask is one tap from the title bar.
struct TodayScreen: View {
    @Environment(AppRouter.self) private var router
    /// The capture switch's truth: `captureIntent` plus the opt-in pause schedule. Observed
    /// here so the card re-renders the moment either changes, whoever changed it — this screen,
    /// Settings, Control Center, a widget button, or the timer coming due.
    @Environment(AppSettings.self) private var settings
    @State private var viewModel = TodayViewModel()
    @State private var poppedSpan: CoverageSpanDisplay?
    /// Which follow-up row is showing its swipe actions — at most one at a time, card-wide.
    @State private var openSwipeRow: String?
    /// What waits for review and what today added, for the Reminders section's top rows.
    @State private var reminderDigest = ReminderDigestModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.blockGap) {
                statusCard

                if let line = viewModel.emptyLine {
                    emptyLineView(line)
                } else {
                    if let coverage = viewModel.snapshot.coverage {
                        coverageCard(coverage)
                    }
                    if let recap = viewModel.snapshot.recap {
                        recapCard(recap)
                    }
                    followUpsSection
                    if !viewModel.snapshot.conversations.isEmpty {
                        conversationsSection
                    }
                }
            }
            .padding(.horizontal, Tokens.screenMargin)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Tokens.ground)
        .navigationTitle(Copy.Today.title)
        .navigationDestination(for: Route.self) { route in
            destination(for: route)
        }
        // Its snackbars post to `UndoCenter.shared`, which `RootView` hosts once for the
        // whole app — a second host here would stack one snackbar on top of the other.
        .task { await viewModel.observe() }
        .task { await reminderDigest.observe() }
    }

    // MARK: Route destinations (the Today stack)

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .live:
            LiveConversationScreen()
        case .note(let id):
            // The recap detail rides the `.note` route (digest id `day-<dateKey>`); every
            // other id is a saved note reached from a conversation opened in THIS stack.
            if id.hasPrefix(RecapDisplay.digestIdPrefix) {
                // The whole `RecapDisplay`, not just its detail: the pushed screen shows the
                // FULL digest, and it also needs to know whether the card that pushed it was
                // showing a shortened form so it can say so.
                RecapDetailView(recap: viewModel.snapshot.recap)
            } else {
                SavedNotesScreen(noteId: id)
            }
        case .conversation(let id, let atMs, let focus):
            // The same detail screen the Library pushes — the native back button names
            // whichever parent actually pushed it, so no origin needs threading through.
            ConversationScreen(conversationId: id, atMs: atMs, focus: focus)
        case .followUp(let id):
            // Opened in THIS stack. Tapping a row on Today should not move the person to
            // another tab; "See all" is the thing that does that, and it says so.
            FollowUpDetailScreen(id: id)
        default:
            Color.clear.background(Tokens.ground)
        }
    }

    // The title-bar Ask pill is gone: Ask is a tab now, labelled, one tap away from anywhere,
    // and a second entry point to it on the one screen the tab bar is always showing was a
    // control that had to be explained rather than read. The Conversation screen keeps its own
    // Ask pill — that one carries a scope you cannot get to any other way.

    // MARK: Status card
    //
    // Two families draw their own card because they are the two where the thing to change is
    // CAPTURE ITSELF, and both now carry the same switch (`CaptureToggle`) in the same place:
    //
    //   .recording  the switch, the connected sub-line, the live minute, the legend
    //   .paused     the switch (on, amber), when the pause ends, and Resume now
    //
    // Every other family keeps the plain `StatusCard`: those cards are about a problem to
    // resolve — Bluetooth off, out of range, a prompt waiting on the watch — and their one
    // action is the resolution. A capture switch beside it would compete with the thing the
    // person actually has to do, and capture intent is not what is wrong in any of them.
    //
    // The `.paused` family is checked against the INTENT, not just the family, because the kit
    // also reports `.paused` for pauses this phone did not ask for — a microphone conflict, a
    // flat watch battery, the watch's own power save, low storage. Those keep the approved card
    // that names the cause: a "Resume now" button that cannot resume anything, next to a switch
    // that is already on, would be the emptiest control on the screen.

    @ViewBuilder
    private var statusCard: some View {
        let status = viewModel.status
        if status.family == .recording {
            recordingCard(status)
        } else if status.family == .paused, settings.captureIntent == .paused {
            pausedCard(status)
        } else {
            StatusCard(
                dotColor: status.dot.tokenColor,
                headline: status.headline,
                line: status.detail ?? "",
                action: status.action.flatMap { action in
                    guard action != .stop else { return nil }
                    return StatusCard.Action(
                        title: action.defaultLabel ?? Copy.Common.tryAgain,
                        style: action.cardStyle
                    ) {
                        // Only the capture transport gets a haptic; helper actions stay silent.
                        switch action {
                        case .start, .resume: Haptics.captureStarted()
                        case .stop: Haptics.captureEnded()
                        default: break
                        }
                        viewModel.perform(action)
                    }
                }
            )
        }
    }

    /// The Recording card: dot · "Recording" · the capture switch; connected sub-line; 40-bar
    /// live minute; taxonomy legend.
    ///
    /// The switch replaces the "Pause" text link the artboard drew here. Three reasons, in the
    /// order they matter: a link that stops a microphone should look like a control and not
    /// like prose; the same operation lived in Settings as a switch, so one of the two had to
    /// give; and a link has one meaning, while the switch's off position now means the same
    /// `.off` on both screens, leaving `.paused` free to mean the temporary thing the "Pause
    /// for…" menu arms.
    private func recordingCard(_ status: StatusModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(color: Tokens.good, size: .status)
                    Text(status.headline)
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                    Spacer(minLength: 8)
                    captureToggle
                }
                if let detail = status.detail {
                    Text(detail)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                }
                if viewModel.showsLiveMinute {
                    WaveformView(slots: viewModel.snapshot.liveMinute)
                    WaveformLegend()
                }
            }
        }
    }

    /// The Paused card. Same shape as Recording, because it is the same control in a different
    /// state: the switch stays ON and amber (the setting is enabled, capture is suspended), the
    /// line says how the pause ends, and Resume now is the one action.
    ///
    /// The line comes from `CaptureStatus`, not from the kit's status model, because only this
    /// side knows about the opt-in timer — "Paused · recording resumes at 3:40 PM" is a
    /// materially different sentence from "the watch is not capturing", and a person who set a
    /// timer needs to see it honoured somewhere.
    private func pausedCard(_ status: StatusModel) -> some View {
        let capture = CaptureStatus(settings)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(color: Tokens.attention, size: .status)
                    Text(status.headline)
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                    Spacer(minLength: 8)
                    captureToggle
                }
                Text(capture.schedule.isArmed ? capture.line : (status.detail ?? capture.line))
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Copy.Capture.resumeNow) {
                    Haptics.captureStarted()
                    captureController.resumeNow()
                }
                .buttonStyle(.inCardFilled)
                .padding(.top, 2)
            }
        }
    }

    /// The one capture control, built from Today's transport. Long-press opens the opt-in
    /// "Pause for…" menu; a snackbar reports a reminder iOS will not deliver, rather than
    /// leaving someone relying on a nudge that is never coming.
    private var captureToggle: some View {
        CaptureToggle(controller: captureController) {
            UndoCenter.shared.snackbar = SnackbarItem(message: Copy.Capture.reminderUnavailable)
        }
    }

    private var captureController: CaptureController {
        viewModel.captureController(settings: settings)
    }

    // MARK: Empty state (6.7) — first run, or startup recovery still reading the store

    private func emptyLineView(_ line: String) -> some View {
        Text(line)
            .font(AppFont.subBody)
            .foregroundStyle(Tokens.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }

    private func coverageHeadline(_ coverage: CoverageDisplay) -> some View {
        Text(coverage.headline)
            .font(AppFont.cardHead)
            .foregroundStyle(Tokens.label)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func coverageMissingNote(_ coverage: CoverageDisplay) -> some View {
        if let missing = coverage.missingText {
            Text(missing)
                .font(.system(.caption))
                .foregroundStyle(Tokens.missing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Day coverage (headline · missing · strip · axis; Q11 tap-to-explain)

    private func coverageCard(_ coverage: CoverageDisplay) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                // Side by side while both fit; stacked once Dynamic Type would hyphenate
                // the headline into fragments.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        coverageHeadline(coverage)
                        Spacer()
                        coverageMissingNote(coverage)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        coverageHeadline(coverage)
                        coverageMissingNote(coverage)
                    }
                }
                CoverageStrip(spans: coverage.stripSpans) { tapped in
                    if let hit = coverage.spans.first(where: { $0.span == tapped }),
                        hit.popoverText != nil
                    {
                        poppedSpan = hit
                    }
                }
                .popover(item: $poppedSpan) { span in
                    Text(span.popoverText ?? "")
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.label)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .presentationCompactAdaptation(.popover)
                        .task {
                            // Q11: one line, auto-dismisses.
                            try? await Task.sleep(for: .seconds(2.5))
                            poppedSpan = nil
                        }
                }
            }
        }
    }

    // MARK: Recap card (sparkle · "Today so far" · updated · chevron; digest → full detail)
    //
    // The card has always pushed the cited detail, and nothing on it said so — no chevron, no
    // line, just a paragraph that happened to be tappable. That was survivable while the digest
    // was two sentences. It stopped being survivable once the digest grew: on a full day the
    // card became the tallest thing on Today, pushing coverage, follow-ups and conversations
    // below the fold, and the way out of that was invisible.
    //
    // So: `cardText` is the CONDENSED digest when the second AI pass produced one
    // (`RecapCondenser` — see `RecapDisplay.condensed`), the full digest otherwise, and the
    // header row carries the chevron that says where the rest lives. The extra "Read the full
    // recap" line appears only when there IS more, so it can never promise something the tap
    // does not deliver.
    //
    // The fallback is CLAMPED (`RecapDisplay.cardLineLimit`). Leaning on the condensation alone
    // left the card's height in the hands of a second AI call: when it had not run yet, or the
    // day's digest overran by more than the acceptance rule would shorten, the card went back
    // to being the tallest thing on Today with nothing on screen admitting it.

    private func recapCard(_ recap: RecapDisplay) -> some View {
        Button {
            router.todayPath.append(.note(id: recap.detail.id))
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tokens.tint)
                        Text(Copy.Today.recapTitle)
                            .font(AppFont.cardHead)
                            .foregroundStyle(Tokens.label)
                        Spacer(minLength: 8)
                        Text(recap.updatedText)
                            .font(.system(.caption))
                            .foregroundStyle(Tokens.faint)
                            .layoutPriority(-1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tokens.chevron)
                            .accessibilityHidden(true)
                    }
                    Text(recap.cardText)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.secondaryBody)
                        .lineSpacing(5)
                        .multilineTextAlignment(.leading)
                        // Bounded when the card is showing an uncondensed digest — see
                        // `RecapDisplay.cardLineLimit`. Without it the card's height is whatever
                        // the model wrote, and a busy day put a three-paragraph essay above
                        // everything else on Today.
                        .lineLimit(recap.cardLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityHint(Copy.Recap.openHint)
    }

    // MARK: Follow-ups — the three that matter, and a way out to the rest
    //
    // Today shows a GLANCE, not a list. It used to show two rows with "See all 20" wedged into
    // the first one's text (which is why row one was narrower than row two), and "See all"
    // expanded twenty items into the middle of the feed. There is a tab for the list now; this
    // is the reminder that it has something in it.
    //
    // Nothing here is done: a ticked item leaves the card, because a card capped at three
    // rows cannot afford to spend one on something already finished.

    @ViewBuilder
    private var followUpsSection: some View {
        if !viewModel.visibleFollowUps.isEmpty || !reminderDigest.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.blockGap) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Copy.Reminders.title)
                        .font(AppFont.sectionTitle)
                        .foregroundStyle(Tokens.label)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if viewModel.openFollowUpCount > viewModel.visibleFollowUps.count {
                        Button(Copy.Today.seeAll(viewModel.openFollowUpCount)) {
                            router.navigate(to: .followUps(scope: nil))
                        }
                        .font(AppFont.chip)
                        .foregroundStyle(Tokens.tint)
                        .buttonStyle(.plain)
                        .fixedSize()
                    }
                }
                .padding(.top, 4)

                // The way into the review and today's summary, the same two rows the Reminders
                // tab starts with (`docs/reminders.md`).
                ReminderEntryCard(digest: reminderDigest) { router.reminderSheet = $0 }

                // The rows draw their own inset: a `SwipeRow`'s buttons have to reach the
                // card's edges, and a row the card has inset can only slide within that inset.
                if !viewModel.visibleFollowUps.isEmpty {
                    ListCard(rowVerticalPadding: 0, rowHorizontalPadding: 0) {
                        ForEach(viewModel.visibleFollowUps) { item in
                            followUpRow(item)
                        }
                    }
                    .animation(
                        Motion.animation(.snappy(duration: 0.25)),
                        value: viewModel.visibleFollowUps.map { "\($0.id)\($0.done)" }.joined())
                }
            }
        }
    }

    /// Tick, put off, delete — by swipe, by long press, and by VoiceOver action, exactly as on
    /// the Follow-ups tab. Two rows that look identical must not behave differently depending on
    /// which of them happens to live inside a `List`.
    private func followUpRow(_ item: FollowUpItem) -> some View {
        SwipeRow(
            rowID: item.id,
            leading: [
                SwipeAction(
                    id: "done", title: item.done ? Copy.FollowUps.markNotDone : Copy.FollowUps.markDone,
                    systemImage: item.done ? "arrow.uturn.backward" : "checkmark",
                    tint: Tokens.good
                ) { toggle(item) }
            ],
            trailing: trailingActions(item),
            openRow: $openSwipeRow
        ) {
            Button {
                router.todayPath.append(.followUp(id: item.id))
            } label: {
                FollowUpRow(item: item, now: viewModel.now) { toggle(item) }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Copy.A11y.followUpOpenHint)
        }
        // Swipe is never the only path to an action: the same three live in a long-press menu,
        // where they are discoverable without guessing.
        .contextMenu {
            Button {
                toggle(item)
            } label: {
                Label(
                    item.done ? Copy.FollowUps.markNotDone : Copy.FollowUps.markDone,
                    systemImage: item.done ? "arrow.uturn.backward" : "checkmark.circle")
            }
            if !item.done {
                Menu {
                    Button(Copy.FollowUps.snoozeTomorrow) { snooze(item, until: viewModel.tomorrow) }
                    Button(Copy.FollowUps.snoozeNextWeek) { snooze(item, until: viewModel.nextWeek) }
                } label: {
                    Label(Copy.FollowUps.snooze, systemImage: "clock.badge")
                }
            }
            Divider()
            Button(role: .destructive) {
                delete(item)
            } label: {
                Label(Copy.FollowUps.delete, systemImage: "trash")
            }
        }
    }

    /// Delete first, so it is the edge-most button and the one a full swipe commits to — the
    /// order `swipeActions` gives the same row on the Follow-ups tab.
    private func trailingActions(_ item: FollowUpItem) -> [SwipeAction] {
        var actions = [
            SwipeAction(
                id: "delete", title: Copy.FollowUps.delete, systemImage: "trash",
                tint: Tokens.destructive, isDestructive: true
            ) { delete(item) }
        ]
        if !item.done {
            actions.append(
                SwipeAction(
                    id: "snooze", title: Copy.FollowUps.snooze, systemImage: "clock.badge",
                    tint: Tokens.attention
                ) { snooze(item, until: viewModel.tomorrow) })
        }
        return actions
    }

    private func toggle(_ item: FollowUpItem) {
        Haptics.checkedOff()
        viewModel.toggleFollowUp(item)
    }

    /// Destructive, so it is undoable. The snackbar is the app's standing undo affordance and
    /// the only thing between a mis-swipe and a lost commitment.
    private func delete(_ item: FollowUpItem) {
        viewModel.deleteFollowUp(item)
        UndoCenter.shared.snackbar = SnackbarItem(
            message: Copy.FollowUps.deleted, actionTitle: Copy.Common.undo
        ) {
            viewModel.undoDeleteFollowUp(item)
        }
    }

    /// Undoable like the delete: putting something off is a decision, and a mis-swipe is easy.
    private func snooze(_ item: FollowUpItem, until date: Date) {
        viewModel.snoozeFollowUp(item, until: date)
        UndoCenter.shared.snackbar = SnackbarItem(
            message: Copy.FollowUps.putOff(FollowUpFormatting.day(date, now: viewModel.now)),
            actionTitle: Copy.Common.undo
        ) {
            viewModel.snoozeFollowUp(item, until: nil)
        }
    }

    // MARK: Conversations (live row w/ rolling snippet + Live badge; finished rows)

    private var conversationsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
            Text(Copy.Today.conversationsSection)
                .font(AppFont.sectionTitle)
                .foregroundStyle(Tokens.label)
                .padding(.top, 4)

            ListCard {
                ForEach(viewModel.snapshot.conversations) { row in
                    conversationRow(row)
                }
            }
        }
    }

    private func conversationRow(_ row: ConversationRowDisplay) -> some View {
        Button {
            router.todayPath.append(
                row.isLive ? .live : .conversation(id: row.id, atMs: nil)
            )
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(AppFont.rowTitle)
                        .foregroundStyle(Tokens.label)
                        // A generated title can run long; two lines here, the whole thing
                        // on the detail screen.
                        .lineLimit(2)
                    Text(row.meta)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                    if let snippet = row.snippet {
                        Text(snippet)
                            .font(AppFont.footnote)
                            .italic()
                            .foregroundStyle(Tokens.tertiary)
                            .lineLimit(1)
                    } else if let statusLine = row.statusLine {
                        // Not italic and not quoted: this is the app saying why there is
                        // nothing to quote, not the recording saying something.
                        Text(statusLine)
                            .font(AppFont.footnote)
                            .foregroundStyle(Tokens.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if row.isLive {
                    LiveBadge()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.chevron)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("Today") {
    let router = AppRouter()
    return NavigationStack {
        TodayScreen()
    }
    .environment(router)
    .environment(AppSettings())
    .tint(Tokens.tint)
}
