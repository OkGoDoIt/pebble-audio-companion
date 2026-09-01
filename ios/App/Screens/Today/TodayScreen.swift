import SwiftUI
import StatusUI

/// Today tab root (Main artboard, extraction §2.4): status card with the live minute,
/// day coverage, recap, follow-ups, conversations. Ask is one tap from the title bar.
struct TodayScreen: View {
    @Environment(AppRouter.self) private var router
    @State private var viewModel = TodayViewModel()
    @State private var poppedSpan: CoverageSpanDisplay?

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
        .task { await viewModel.observe() }
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
                RecapDetailView(detail: viewModel.snapshot.recap?.detail)
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

    // MARK: Status card (all families; recording composes the live minute + Pause link)

    @ViewBuilder
    private var statusCard: some View {
        let status = viewModel.status
        if status.family == .recording {
            recordingCard(status)
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

    /// The artboard's Recording card: dot · "Recording" · Pause link; connected sub-line;
    /// 40-bar live minute; taxonomy legend.
    private func recordingCard(_ status: StatusModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(color: Tokens.good, size: .status)
                    Text(status.headline)
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                    Spacer()
                    Button(Copy.Today.pause) {
                        Haptics.captureEnded()
                        viewModel.pauseTapped()
                    }
                    .font(AppFont.pill)
                    .foregroundStyle(Tokens.tint)
                    .buttonStyle(.plain)
                    .padding(.vertical, 11)
                    .padding(.leading, 12)
                    .contentShape(Rectangle())
                    .padding(.vertical, -11)
                    .padding(.leading, -12)
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

    // MARK: Recap card (sparkle · "Today so far" · updated · digest → cited detail)

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
                        Spacer()
                        Text(recap.updatedText)
                            .font(.system(.caption))
                            .foregroundStyle(Tokens.faint)
                    }
                    Text(recap.digest)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.secondaryBody)
                        .lineSpacing(5)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        }
        .buttonStyle(.plain)
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
        if !viewModel.visibleFollowUps.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.blockGap) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Copy.FollowUps.title)
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

                ListCard(rowVerticalPadding: 10) {
                    ForEach(viewModel.visibleFollowUps) { item in
                        followUpRow(item)
                    }
                }
            }
        }
    }

    private func followUpRow(_ item: FollowUpItem) -> some View {
        Button {
            router.todayPath.append(.followUp(id: item.id))
        } label: {
            FollowUpRow(item: item, now: viewModel.now) {
                Haptics.checkedOff()
                withAnimation(Motion.animation(.snappy(duration: 0.25))) {
                    viewModel.toggleFollowUp(item)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(Copy.A11y.followUpOpenHint)
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
    .tint(Tokens.tint)
}
